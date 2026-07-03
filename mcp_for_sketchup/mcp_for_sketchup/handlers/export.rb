# mcp_for_sketchup/mcp_for_sketchup/handlers/export.rb
require "fileutils"
require "tmpdir"

module MCPforSketchUp
  module Handlers
    module Export
      V = MCPforSketchUp::Helpers::Validation
      E = MCPforSketchUp::Helpers::Entities

      FORMATS = %w[skp obj dae stl png jpg jpeg].freeze

      def self.export(params)
        format = V.require_enum(params, "format", FORMATS).downcase
        format = "jpeg" if format == "jpg"
        model = E.active_model!

        export_path = build_export_path(format)
        # Sketchup::Model#save / #save_copy / #export and View#write_image return
        # Boolean — false on failure (disk full, permission denied,
        # format-specific error). Without this guard the handler used to claim
        # success while no file had been written, leading callers to act on a
        # phantom path.
        # skp export uses save_skp, which picks save vs save_copy by whether the
        # live model has a path (codex review):
        #   - save_copy RAISES "Model must be saved before copying" on an
        #     UNTITLED model (no path) — so an untitled model can't use it.
        #   - save re-points the live model's path AND clears its dirty flag —
        #     on a TITLED document that is silent data loss.
        # Hence: untitled → save (no real document to clobber), titled →
        # save_copy (detached copy; path + modified state left untouched).
        ok = case format
             when "skp"            then save_skp(model, export_path)
             when "obj"            then export_obj(model, export_path)
             when "dae"            then export_dae(model, export_path)
             when "stl"            then export_stl(model, export_path)
             when "png", "jpeg"    then export_image(model, export_path, format, params)
             end
        unless ok
          raise Core::StructuredError.new(-32603,
            "export(#{format}) failed (no file written; check disk/permissions)")
        end
        { "path" => export_path, "format" => format }
      end

      # Pick save vs save_copy for a .skp export by whether the live model has a
      # path. An untitled model (path == "") cannot use save_copy — it raises
      # "Model must be saved before copying" — so it falls back to save (there is
      # no real document to clobber yet). A titled model uses save_copy so its
      # path + dirty flag stay untouched (save would re-point path + clear dirty
      # = silent data loss). Both return Boolean, so the `unless ok` guard in
      # #export still applies.
      def self.save_skp(model, export_path)
        if model.path.to_s.empty?
          model.save(export_path)        # untitled: no real document to clobber
        else
          model.save_copy(export_path)   # titled: leave path + dirty untouched (codex Critical fix)
        end
      end

      def self.build_export_path(format)
        temp_dir = File.join(ENV["TEMP"] || ENV["TMP"] || Dir.tmpdir, "sketchup_exports")
        FileUtils.mkdir_p(temp_dir)
        # Microsecond precision: two exports inside the same second now produce
        # distinct filenames (the bare %S form silently overwrote on rapid calls).
        timestamp = Time.now.strftime("%Y%m%d_%H%M%S_%6N")
        File.join(temp_dir, "sketchup_export_#{timestamp}.#{format}")
      end

      def self.export_obj(model, path)
        model.export(path, {
          triangulated_faces:  true,
          doublesided_faces:   true,   # T-15: официальное имя ключа (double_sided_faces молча игнорировался)
          edges:               false,
          texture_maps:        true
        })
      end

      def self.export_dae(model, path)
        model.export(path, { triangulated_faces: true })
      end

      def self.export_stl(model, path)
        model.export(path, { units: "model" })
      end

      # Upper bound chosen to keep View#write_image from blowing the SketchUp
      # process on hostile/typo'd input (e.g. width=999999). 16384 px aligns
      # with the practical limit of consumer GPU framebuffers.
      MAX_IMAGE_DIMENSION = 16384

      def self.export_image(model, path, format, params)
        width  = validate_image_dim(params, "width",  1920)
        height = validate_image_dim(params, "height", 1080)
        view = model.active_view
        view.write_image(
          filename:    path,
          width:       width,
          height:      height,
          antialias:   true,
          transparent: format == "png"
        )
      end

      def self.validate_image_dim(params, key, default)
        return default unless params.key?(key)
        v = params[key]
        unless v.is_a?(Integer)
          raise Core::StructuredError.new(-32602,
            "field #{key} must be an integer (px), got #{v.inspect}")
        end
        unless v > 0 && v <= MAX_IMAGE_DIMENSION
          raise Core::StructuredError.new(-32602,
            "field #{key} must be in (0, #{MAX_IMAGE_DIMENSION}], got #{v}")
        end
        v
      end
    end
  end
end
