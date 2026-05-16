# su_mcp/su_mcp/handlers/view.rb
#
# Operation order (do NOT reorder without re-deriving snapshot/restore
# invariants):
#   0. validate -> guards (active_model!, active_view)
#   1. snapshot (camera deep-copy + RO subset) if restore_view
#   2. preset    (DIRECT view.camera = ... -- synchronous in SU 2026; see §5.2)
#   3. style     (RenderMode enum write -- empirically the only reliable way)
#   4. zoom_extents (rescued -- empty-model dialog tolerated)
#   5. write_image into Tempfile
#   6. size cap check (< 32 MiB raw)
#   7. binread
#   8. restore (outer `ensure` -- runs on any exception path)
require "base64"
require "tempfile"

module SU_MCP
  module Handlers
    module View
      V  = SU_MCP::Helpers::Validation
      E  = SU_MCP::Core::StructuredError
      EH = SU_MCP::Helpers::Entities

      ALLOWED_PRESETS = %w[current front back left right top bottom iso].freeze
      ALLOWED_STYLES  = %w[default shaded hidden_line wireframe].freeze
      MIN_MAX_SIZE = 64
      MAX_MAX_SIZE = 4096
      MAX_RAW_BYTES = 32 * 1024 * 1024

      # SketchUp 2026 RenderMode enum (verified empirically -- review iter 1):
      # 0=wireframe, 1=hidden_line, 2=shaded, 3=textured_shaded,
      # 4=monochrome, 5=sketchy, 6=x-ray.
      STYLE_RO = {
        "shaded"      => { "RenderMode" => 2 },
        "hidden_line" => { "RenderMode" => 1 },
        "wireframe"   => { "RenderMode" => 0 },
      }.freeze

      # Direction vectors for camera presets (eye = target + dir*distance).
      # NOTE: these vectors are NOT pre-normalized -- `iso` is (1,-1,1), not
      # (1/sqrt(3), -1/sqrt(3), 1/sqrt(3)). Normalization happens at use site via
      # `offset.length = dist` in `build_preset_camera`. Kept unnormalized for
      # readability of intent (axis-aligned <-> unit, iso <-> unit cube corner).
      # `up` is Z+ for elevation views, Y+ for top/bottom (otherwise camera
      # goes singular when view-vector parallels world up).
      PRESET_DIR = {
        "front"  => [Geom::Vector3d.new( 0, -1,  0), Geom::Vector3d.new(0, 0, 1)],
        "back"   => [Geom::Vector3d.new( 0,  1,  0), Geom::Vector3d.new(0, 0, 1)],
        "left"   => [Geom::Vector3d.new(-1,  0,  0), Geom::Vector3d.new(0, 0, 1)],
        "right"  => [Geom::Vector3d.new( 1,  0,  0), Geom::Vector3d.new(0, 0, 1)],
        "top"    => [Geom::Vector3d.new( 0,  0,  1), Geom::Vector3d.new(0, 1, 0)],
        "bottom" => [Geom::Vector3d.new( 0,  0, -1), Geom::Vector3d.new(0, 1, 0)],
        "iso"    => [Geom::Vector3d.new( 1, -1,  1), Geom::Vector3d.new(0, 0, 1)],
      }.freeze

      def self.viewport_screenshot(params)
        # 0. Validate params and guards.
        max_size      = require_max_size(params)
        view_preset   = V.require_enum(params, "view_preset", ALLOWED_PRESETS)
        style         = V.require_enum(params, "style", ALLOWED_STYLES)
        zoom_extents  = V.optional_bool(params, "zoom_extents", false)
        restore_view  = V.optional_bool(params, "restore_view", true)

        model = EH.active_model!                              # raises if nil
        view  = model.active_view
        raise E.new(-32000, "no active view") if view.nil?

        # 1. Snapshot (only if we will mutate).
        snap_camera = nil
        snap_ro     = nil
        if restore_view
          c = view.camera
          # 2D / match-photo guard. Only eye/target/up/perspective/fov/height
          # are deep-copied; 2D cameras carry aspect_ratio, image_width,
          # scale_2d, center_2d that we don't restore. Fail fast rather than
          # silently regress the viewport -- see design §5.4 step 1, §5.6
          # edge cases.
          if c.respond_to?(:is_2d?) && c.is_2d?
            raise E.new(-32000,
              "restore_view is not supported for 2D / match-photo cameras " \
              "(camera.is_2d? == true); pass restore_view=false to take the " \
              "screenshot without restoring viewport state")
          end
          # Construct a fresh Camera (deep copy) -- verified safe in SU 2026.
          snap_camera = Sketchup::Camera.new(c.eye, c.target, c.up)
          snap_camera.perspective = c.perspective?
          if c.perspective?
            snap_camera.fov = c.fov
          else
            snap_camera.height = c.height
          end
          if style != "default"
            snap_ro = {}
            STYLE_RO[style].each_key { |k| snap_ro[k] = model.rendering_options[k] }
          end
        end

        vw = view.vpwidth.to_f
        vh = view.vpheight.to_f
        if vw <= 0 || vh <= 0
          raise E.new(-32603, "viewport has zero dimensions (vw=#{vw}, vh=#{vh})")
        end
        scale = max_size.to_f / [vw, vh].max
        out_w = (vw * scale).round
        out_h = (vh * scale).round

        data = nil
        begin
          # 2. Preset -- direct camera assignment (synchronous; send_action is async).
          # `visible_bounds(model)` is used instead of `model.bounds` so the
          # preset frames only the geometry the user currently sees -- consistent
          # with design §5.6 (screenshot captures the user-visible state and
          # does not temporarily unhide anything). Falls back to model.bounds
          # when nothing is visible (empty model or everything hidden).
          if view_preset != "current"
            bb = SU_MCP::Helpers::Geometry.visible_bounds(model)
            view.camera = build_preset_camera(view_preset, bb, view.camera)
          end

          # 3. Style -- RenderMode write (verified writeable in SU 2026).
          if style != "default"
            STYLE_RO[style].each { |k, v| model.rendering_options[k] = v }
          end

          # 4. zoom_extents -- empty-model dialog tolerated.
          if zoom_extents
            begin
              view.zoom_extents
            rescue StandardError => e
              SU_MCP::Core::Logger.log("WARN", "zoom_extents failed: #{e.class}: #{e.message}")
            end
          end

          # 5..7. write_image -> size check -> binread, all inside Tempfile block.
          Tempfile.create(["sumcp_vp_", ".png"]) do |tmp|
            tmp.close
            ok = view.write_image(
              filename: tmp.path,
              width: out_w,
              height: out_h,
              antialias: true,
              compression: 1.0,
              transparent: false,
            )
            raise E.new(-32000, "viewport write_image failed") unless ok

            size = File.size(tmp.path)
            if size > MAX_RAW_BYTES
              raise E.new(-32000,
                "screenshot too large: #{size} bytes -- reduce max_size")
            end
            data = File.binread(tmp.path)
          end
        ensure
          # 8. Restore -- runs on success AND on any exception path.
          if restore_view
            view.camera = snap_camera if snap_camera
            snap_ro&.each { |k, v| model.rendering_options[k] = v }
          end
        end

        {
          "png_base64"   => Base64.strict_encode64(data),
          "width"        => out_w,
          "height"       => out_h,
          "preset_used"  => view_preset,
          "style_used"   => style,
        }
      end

      # Build a Sketchup::Camera for one of the named presets, framed on the
      # given bounding box. Falls back to a sensible default when the box is
      # empty (`diag == 0`).
      #
      # IMPORTANT: framing differs for perspective vs orthographic cameras.
      # - Perspective: framing is governed by `eye-to-target distance` and `fov`.
      #   `dist = diag * 1.5` gives a comfortable margin around the bbox.
      # - Orthographic (parallel projection): framing is governed by
      #   `Camera#height` (the world-space vertical extent visible in the
      #   viewport). Copying the *current* camera's `height` here would clip
      #   or empty-frame the model when the saved height bears no relation to
      #   the new preset direction. We override `height` with a bbox-derived
      #   value so `view_preset="top"` (or any other ortho preset) frames the
      #   model regardless of where the camera was before.
      def self.build_preset_camera(preset, bounds, current_camera)
        dir, up = PRESET_DIR[preset]
        center  = bounds.center
        diag    = bounds.diagonal
        diag    = 1000.0 if diag.nil? || diag <= 0   # fallback for empty/hidden model
        dist    = diag * 1.5
        offset  = Geom::Vector3d.new(dir.x, dir.y, dir.z); offset.length = dist
        eye     = center + offset
        cam = Sketchup::Camera.new(eye, center, up)
        cam.perspective = current_camera.perspective?
        if cam.perspective?
          cam.fov = current_camera.fov
        else
          # Orthographic: frame the bbox via height. `diag * 0.6` matches the
          # apparent scale of the perspective fallback for typical fov=35°.
          cam.height = diag * 0.6
        end
        cam
      end

      def self.require_max_size(params)
        v = params["max_size"]
        raise E.new(-32602, "missing required field: max_size") if v.nil?
        raise E.new(-32602, "field max_size must be an integer") unless v.is_a?(Integer)
        unless v.between?(MIN_MAX_SIZE, MAX_MAX_SIZE)
          raise E.new(-32602,
                      "field max_size must be in [#{MIN_MAX_SIZE}, #{MAX_MAX_SIZE}], got #{v}")
        end
        v
      end
    end
  end
end
