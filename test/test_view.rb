# test/test_view.rb
#
# Unit tests for MCPforSketchUp::Handlers::View.viewport_screenshot.
# Stubs the SketchUp API surface we touch: Sketchup module,
# Sketchup::Model, Sketchup::View, Sketchup::Camera, RenderingOptions.

require "minitest/autorun"
require "base64"
require "tmpdir"

# 1x1 transparent PNG bytes -- used as the stubbed write_image output so
# tests assert real PNG magic bytes, not a "FAKE_PNG_BYTES" placeholder.
TINY_PNG_BYTES = Base64.strict_decode64(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9Q" \
  "DwADhgGAWjR9awAAAABJRU5ErkJggg=="
)

# --- Minimal SketchUp stubs ---------------------------------------------------
# We stub only the API our handler touches. Other tests in test/ already
# define some of these -- Ruby ``module`` declarations are additive.

# Minimal Geom stubs the production handler uses.
module Geom
  class Point3d
    attr_reader :x, :y, :z
    def initialize(x = 0, y = 0, z = 0); @x, @y, @z = x, y, z; end
    def to_a; [@x, @y, @z]; end
    def ==(o); o.is_a?(Point3d) && x == o.x && y == o.y && z == o.z; end
    def +(v); Point3d.new(@x + v.x, @y + v.y, @z + v.z); end
  end
  class Vector3d
    attr_accessor :x, :y, :z
    def initialize(x = 0, y = 0, z = 0); @x, @y, @z = x, y, z; end
    def length
      Math.sqrt(@x * @x + @y * @y + @z * @z)
    end
    def length=(l)
      cur = length
      return if cur == 0
      f = l.to_f / cur
      @x *= f; @y *= f; @z *= f
    end
  end
end unless defined?(Geom::Vector3d)

# Stub Geom::BoundingBox so visible_bounds can run under tests.
# Production code uses `Geom::BoundingBox.new` (no args) -- the real
# SketchUp class supports that. The test_collect_components.rb file
# defines a 2-arg constructor for its own purposes; we make it
# variadic so both call sites work, and add the `add`/`empty?`/`diagonal`
# methods visible_bounds needs.
module Geom
  # If another test file already defined Geom::BoundingBox (e.g.
  # test_collect_components.rb uses a 2-arg constructor), we open
  # the class and make `initialize` variadic so production
  # `Geom::BoundingBox.new` (zero args) also works. Add the
  # `add`/`empty?`/`diagonal` methods visible_bounds relies on.
  class BoundingBox
    def initialize(*args)
      @entries = []
      @vmin, @vmax = args if args.length == 2
    end
    def min; @vmin; end
    def max; @vmax; end
    def add(other); @entries << other; self; end
    def empty?; @entries.empty?; end
    def diagonal; 0.0; end
  end
end

module Sketchup
  class Camera
    attr_accessor :eye, :target, :up
    attr_writer :perspective, :fov, :height
    def initialize(eye = Geom::Point3d.new(0, 0, 0),
                   target = Geom::Point3d.new(0, 0, 0),
                   up = Geom::Vector3d.new(0, 0, 1))
      @eye, @target, @up = eye, target, up
      @perspective = true
      @fov = 35.0
      @height = 100.0
    end
    def perspective?; @perspective; end
    def fov; @fov; end
    def height; @height; end
    def ==(o)
      o.is_a?(Camera) &&
        coord_eq?(eye, o.eye) && coord_eq?(target, o.target) && coord_eq?(up, o.up) &&
        perspective? == o.perspective? && fov == o.fov && height == o.height
    end
    private
    def coord_eq?(a, b)
      ax = a.respond_to?(:x) ? [a.x, a.y, a.z] : a.to_a
      bx = b.respond_to?(:x) ? [b.x, b.y, b.z] : b.to_a
      ax == bx
    end
  end

  # Strict rendering_options stub modelled on SketchUp 2026 behavior:
  # - These keys are READ-able but WRITE-REJECTED (verified live):
  #   DisplayShaded, DisplayShadedUsingAllSameObject, DrawEdges, DrawFaces.
  # - These keys are READ + WRITE OK:
  #   RenderMode, DrawHidden, DrawProfilesOnly, Texture, DrawBackEdges.
  # Tracks all successful writes via `writes` for spy assertions.
  class RenderingOptionsStub
    WRITEABLE_KEYS = %w[RenderMode DrawHidden DrawProfilesOnly Texture DrawBackEdges].freeze
    READONLY_KEYS  = %w[DisplayShaded DisplayShadedUsingAllSameObject DrawEdges DrawFaces].freeze
    KNOWN_KEYS = (WRITEABLE_KEYS + READONLY_KEYS).freeze

    attr_reader :writes
    def initialize(initial)
      @data = initial.dup
      @writes = []
    end
    def [](k); @data[k]; end
    def []=(k, v)
      unless WRITEABLE_KEYS.include?(k)
        if READONLY_KEYS.include?(k)
          raise ArgumentError, "Rendering option could not be set to the given value"
        else
          raise ArgumentError, "unknown rendering_options key: #{k.inspect}"
        end
      end
      @writes << [k, v]
      @data[k] = v
    end
    def dup; @data.dup; end
    def each_pair(&blk); @data.each_pair(&blk); end
    def keys; @data.keys; end
  end

  # Minimal BoundingBox stub used by build_preset_camera.
  class BBox
    attr_reader :center
    def initialize(center: Geom::Point3d.new(0, 0, 0), diagonal: 1000.0)
      @center = center; @diag = diagonal
    end
    def diagonal; @diag; end
  end

  class View
    attr_accessor :model, :write_image_size_override, :zoom_extents_raises
    attr_reader :write_image_calls, :zoom_extents_calls, :camera_writes

    def initialize(model:)
      self.vpwidth = 1920          # NOTE: via setter, not direct ivar
      self.vpheight = 1080         # (see CONCERN-13 in review iter 1)
      @camera = Camera.new([10, 10, 10], [0, 0, 0], [0, 0, 1])
      @model = model
      @write_image_calls = []
      @zoom_extents_calls = 0
      @write_image_result = true
      @write_image_size_override = nil   # nil -> write TINY_PNG_BYTES; integer -> write that many bytes
      @zoom_extents_raises = false
      @camera_writes = []                # spy: every camera= assignment
    end

    attr_accessor :vpwidth, :vpheight
    attr_reader :camera

    def camera=(c)
      @camera_writes << c
      @camera = c
    end

    def write_image(filename:, width:, height:, antialias: nil, compression: nil, transparent: nil)
      @write_image_calls << {filename: filename, width: width, height: height,
                              compression: compression}
      if @write_image_result
        bytes = @write_image_size_override ? ("\x00" * @write_image_size_override) : TINY_PNG_BYTES
        File.binwrite(filename, bytes)
      end
      @write_image_result
    end

    def force_write_image_failure!; @write_image_result = false; end

    def zoom_extents
      raise StandardError, "stub zoom_extents failure" if @zoom_extents_raises
      @zoom_extents_calls += 1
    end
  end

  class Model
    attr_reader :rendering_options
    attr_accessor :bounds, :entities
    def initialize
      @rendering_options = RenderingOptionsStub.new(
        # Read-only keys, present but write-rejected.
        "DisplayShaded" => nil,
        "DisplayShadedUsingAllSameObject" => nil,
        "DrawEdges" => nil,
        "DrawFaces" => nil,
        # Writeable keys with realistic defaults.
        "RenderMode" => 2,            # shaded
        "DrawHidden" => false,
        "DrawProfilesOnly" => false,
        "Texture" => true,
        "DrawBackEdges" => false,
      )
      @bounds = BBox.new(
        center: Geom::Point3d.new(0, 0, 0),
        diagonal: 1000.0,
      )
      @entities = []  # visible_bounds iterates this; empty -> falls back to model.bounds
    end
  end

  class << self
    attr_reader :send_action_calls

    def send_action(name)
      @send_action_calls ||= []
      @send_action_calls << name
      true
    end

    def reset_send_action_calls!; @send_action_calls = [] end
    def active_model; @active_model ||= Model.new; end
    def reset_active_model!; @active_model = Model.new; end
  end
end

# --- Load production code -----------------------------------------------------
# Order matters: errors / config / logger / helpers must precede dispatch
# (CRITICAL-6 in review iter 1 -- dispatch.rb references Core::Logger).
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/compat"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/config"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/units"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/logger"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/entities"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/geometry"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/view"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/dispatch"

class TestView < Minitest::Test
  V = MCPforSketchUp::Handlers::View

  def setup
    Sketchup.reset_send_action_calls!
    Sketchup.reset_active_model!
    @view = Sketchup::View.new(model: Sketchup.active_model)
    # Wire the view as model.active_view.
    Sketchup.active_model.instance_variable_set(:@__view, @view)
    Sketchup.active_model.define_singleton_method(:active_view) {
      instance_variable_get(:@__view)
    }
  end

  def call(params = {})
    V.viewport_screenshot({
      "max_size" => 800,
      "view_preset" => "current",
      "zoom_extents" => false,
      "style" => "default",
      "restore_view" => true,
    }.merge(params))
  end

  # --- dispatch routing -------------------------------------------------------

  def test_dispatch_routes_to_view_handler
    response = MCPforSketchUp::Handlers::Dispatch.handle({
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "params" => {"name" => "get_viewport_screenshot",
                   "arguments" => {"max_size" => 800,
                                   "view_preset" => "current",
                                   "zoom_extents" => false,
                                   "style" => "default",
                                   "restore_view" => true}},
      "id" => 1,
      "client_version" => MCPforSketchUp::Core::Compat::MIN_PYTHON,
    })
    assert_equal "2.0", response["jsonrpc"]
    assert_equal 1, response["id"]
    assert response["result"], "expected result key"
    refute response["result"]["isError"], "expected isError=false"
  end

  # --- validation -------------------------------------------------------------

  def test_invalid_view_preset_raises
    assert_raises(MCPforSketchUp::Core::StructuredError) { call("view_preset" => "diagonal") }
  end

  def test_invalid_style_raises
    assert_raises(MCPforSketchUp::Core::StructuredError) { call("style" => "cartoon") }
  end

  def test_invalid_max_size_too_small_raises
    assert_raises(MCPforSketchUp::Core::StructuredError) { call("max_size" => 10) }
  end

  def test_invalid_max_size_too_large_raises
    assert_raises(MCPforSketchUp::Core::StructuredError) { call("max_size" => 99999) }
  end

  def test_no_active_view_raises
    # Replace active_view with nil to simulate "SketchUp not ready".
    Sketchup.active_model.define_singleton_method(:active_view) { nil }
    assert_raises(MCPforSketchUp::Core::StructuredError) { call }
  end

  # --- camera snapshot/restore -----------------------------------------------

  def test_camera_restored_when_flag_true
    # Production code now sets camera DIRECTLY (view.camera = Camera.new(...)),
    # so we can observe two assignments: (1) preset -> new camera, (2) restore -> snapshot.
    original = @view.camera
    call("view_preset" => "top", "restore_view" => true)
    # Expect at least 2 assignments: preset apply + restore.
    assert @view.camera_writes.size >= 2,
           "expected preset assignment + restore assignment; got #{@view.camera_writes.size}"
    # The FINAL camera (after handler return) must match the original snapshot
    # on every restorable property -- not just `eye`. A broken restore that only
    # writes `eye` would otherwise pass.
    final_camera = @view.camera_writes.last
    assert_equal original.eye.to_a,    final_camera.eye.to_a,    "eye not restored"
    assert_equal original.target.to_a, final_camera.target.to_a, "target not restored"
    assert_equal original.up.to_a,     final_camera.up.to_a,     "up not restored"
    assert_equal original.perspective?, final_camera.perspective?, "perspective flag not restored"
    if original.perspective?
      assert_in_delta original.fov, final_camera.fov, 1e-6, "fov not restored"
    else
      assert_in_delta original.height, final_camera.height, 1e-6, "height not restored"
    end
  end

  def test_camera_not_restored_when_flag_false
    call("view_preset" => "top", "restore_view" => false)
    # With restore_view=false, we should see exactly ONE assignment (preset apply),
    # not two -- restore step is skipped.
    assert_equal 1, @view.camera_writes.size,
                 "expected exactly 1 camera assignment (preset, no restore); got #{@view.camera_writes.size}"
  end

  def test_camera_restored_after_zoom_extents_failure
    # Outer ensure must restore camera even when zoom_extents raises (CRITICAL-3).
    # Combine with a preset switch so "restore" has something non-trivial to undo --
    # without the preset, the camera never changes and the test could pass even
    # if restore is broken.
    @view.zoom_extents_raises = true
    original = @view.camera
    # zoom_extents failure is swallowed by handler's inner `rescue StandardError`,
    # so call() returns normally -- no rescue needed here.
    call("view_preset" => "top", "zoom_extents" => true, "restore_view" => true)
    # Full property check -- any partial restore would slip past an `eye`-only assert.
    assert_equal original.eye.to_a,    @view.camera.eye.to_a,    "eye not restored"
    assert_equal original.target.to_a, @view.camera.target.to_a, "target not restored"
    assert_equal original.up.to_a,     @view.camera.up.to_a,     "up not restored"
    assert_equal original.perspective?, @view.camera.perspective?, "perspective flag not restored"
    if original.perspective?
      assert_in_delta original.fov, @view.camera.fov, 1e-6, "fov not restored"
    else
      assert_in_delta original.height, @view.camera.height, 1e-6, "height not restored"
    end
  end

  # --- rendering_options snapshot/restore -------------------------------------

  def test_rendering_options_restored_for_style
    # Pre-mutate RenderMode so we can detect proper restore (wireframe sets RenderMode=0).
    ro = Sketchup.active_model.rendering_options
    ro["RenderMode"] = 2  # shaded baseline
    snap_before = ro.dup

    call("style" => "wireframe", "restore_view" => true)

    assert_equal snap_before["RenderMode"], ro["RenderMode"],
                 "RenderMode not restored to baseline after wireframe style"
  end

  def test_rendering_options_restored_after_write_image_failure
    ro = Sketchup.active_model.rendering_options
    ro["RenderMode"] = 2  # baseline
    snap_before = ro.dup
    @view.force_write_image_failure!
    begin
      call("style" => "wireframe", "restore_view" => true)
    rescue MCPforSketchUp::Core::StructuredError
      # expected
    end
    assert_equal snap_before["RenderMode"], ro["RenderMode"],
                 "RenderMode not restored after write_image failure"
  end

  def test_rendering_options_not_restored_when_restore_view_false
    ro = Sketchup.active_model.rendering_options
    ro["RenderMode"] = 2
    snap_before = ro.dup
    call("style" => "wireframe", "restore_view" => false)
    refute_equal snap_before["RenderMode"], ro["RenderMode"],
                 "RenderMode should remain mutated to 0 when restore_view=false"
  end

  def test_no_ro_touched_when_style_default
    pre_writes = Sketchup.active_model.rendering_options.writes.size
    call("style" => "default", "restore_view" => true)
    post_writes = Sketchup.active_model.rendering_options.writes.size
    assert_equal pre_writes, post_writes,
                 "no RO writes expected when style=default"
  end

  # --- preset / zoom_extents --------------------------------------------------

  def test_camera_assigned_for_preset
    # Production code sets camera DIRECTLY via view.camera = Sketchup::Camera.new(...).
    # `send_action` is no longer used for presets (it was async in SU 2026 -- see review iter 1).
    call("view_preset" => "iso", "restore_view" => false)
    assert_equal 1, @view.camera_writes.size,
                 "expected camera assignment for preset (no restore)"
    refute_includes (Sketchup.send_action_calls || []), "viewIso:",
                    "production code must NOT call Sketchup.send_action for presets"
  end

  def test_no_camera_assigned_for_current_preset
    call("view_preset" => "current", "restore_view" => false)
    assert_empty @view.camera_writes,
                 "no camera assignment expected for view_preset='current'"
  end

  def test_2d_camera_with_restore_view_fails_fast
    # 2D / match-photo cameras carry additional state we do not copy
    # (aspect_ratio, image_width, scale_2d, center_2d). With restore_view=true
    # the handler must fail fast rather than silently regress the viewport.
    @view.camera.define_singleton_method(:is_2d?) { true }
    err = assert_raises(MCPforSketchUp::Core::StructuredError) {
      call("restore_view" => true)
    }
    assert_match(/2D|match-photo|is_2d/, err.message,
                 "expected error mentioning 2D/match-photo; got #{err.message.inspect}")
    assert_match(/restore_view=false/, err.message,
                 "expected error suggesting restore_view=false; got #{err.message.inspect}")
  end

  def test_2d_camera_with_restore_view_false_succeeds
    # restore_view=false skips the snapshot entirely, so the 2D guard is
    # bypassed -- screenshot proceeds normally.
    @view.camera.define_singleton_method(:is_2d?) { true }
    result = call("restore_view" => false)
    assert_kind_of Hash, result
    assert result.key?("png_base64")
  end

  def test_camera_assigned_for_preset_orthographic
    # When the current camera is parallel projection (perspective=false),
    # build_preset_camera must override `height` from the bbox -- copying
    # the current camera's height would clip or empty-frame the model.
    @view.camera.perspective = false
    @view.camera.height = 999_999.0      # nonsense baseline; bbox-derived override must apply
    call("view_preset" => "top", "restore_view" => false)
    assigned = @view.camera_writes.last
    refute assigned.perspective?, "preset camera should inherit perspective=false"
    refute_in_delta 999_999.0, assigned.height, 1.0,
                    "ortho preset must override height from bbox, not copy current camera's"
    # With the default test bbox (~ unit cube), `diag * 0.6` is small;
    # the exact value is implementation-defined, just assert it's bounded.
    assert assigned.height > 0 && assigned.height < 999_999.0,
           "ortho preset height should be bbox-derived, got #{assigned.height}"
  end

  def test_preset_camera_uses_visible_bounds
    # Handler must call Helpers::Geometry.visible_bounds(model) (NOT
    # model.bounds directly) so it frames only the geometry the user can
    # see. Verified via method spy -- avoids building a full entities/group
    # graph in stubs.
    spy_calls = []
    geom_mod  = MCPforSketchUp::Helpers::Geometry
    geom_mod.singleton_class.send(:alias_method, :__orig_visible_bounds, :visible_bounds)
    geom_mod.define_singleton_method(:visible_bounds) do |model|
      spy_calls << model
      Sketchup::BBox.new(center: Geom::Point3d.new(0, 0, 0), diagonal: 100.0)
    end
    begin
      call("view_preset" => "iso", "restore_view" => false)
      assert_equal 1, spy_calls.size,
                   "handler should call Helpers::Geometry.visible_bounds exactly once for preset != current"
      assert_same Sketchup.active_model, spy_calls.first,
                  "visible_bounds should receive the active model"
    ensure
      geom_mod.define_singleton_method(:visible_bounds,
                                       geom_mod.method(:__orig_visible_bounds))
      geom_mod.singleton_class.send(:remove_method, :__orig_visible_bounds)
    end
  end

  def test_visible_bounds_not_called_for_current_preset
    # For view_preset="current" no camera mutation happens, so
    # visible_bounds must not be invoked either.
    spy_calls = []
    geom_mod  = MCPforSketchUp::Helpers::Geometry
    geom_mod.singleton_class.send(:alias_method, :__orig_visible_bounds, :visible_bounds)
    geom_mod.define_singleton_method(:visible_bounds) do |model|
      spy_calls << model
      Sketchup::BBox.new(center: Geom::Point3d.new(0, 0, 0), diagonal: 100.0)
    end
    begin
      call("view_preset" => "current", "restore_view" => false)
      assert_empty spy_calls,
                   "handler must NOT call visible_bounds when view_preset='current'"
    ensure
      geom_mod.define_singleton_method(:visible_bounds,
                                       geom_mod.method(:__orig_visible_bounds))
      geom_mod.singleton_class.send(:remove_method, :__orig_visible_bounds)
    end
  end

  def test_zoom_extents_called_when_flag_true
    call("zoom_extents" => true)
    assert_equal 1, @view.zoom_extents_calls
  end

  def test_zoom_extents_not_called_when_flag_false
    call("zoom_extents" => false)
    assert_equal 0, @view.zoom_extents_calls
  end

  def test_zoom_extents_failure_does_not_propagate
    @view.zoom_extents_raises = true
    # Handler must swallow the failure (logged) and still return a response.
    result = call("zoom_extents" => true)
    assert_kind_of Hash, result
    assert result.key?("png_base64")
  end

  # --- write_image / response shape ------------------------------------------

  def test_write_image_failure_raises
    @view.force_write_image_failure!
    assert_raises(MCPforSketchUp::Core::StructuredError) { call }
  end

  def test_oversize_png_raises
    # Produce a 33 MiB "PNG" -- exceeds the 32 MiB cap.
    @view.write_image_size_override = 33 * 1024 * 1024
    err = assert_raises(MCPforSketchUp::Core::StructuredError) { call }
    assert_match(/too large|max_size/i, err.message,
                 "expected oversize error mentioning max_size or size")
  end

  def test_tempfile_cleaned_up_on_success
    call
    leftovers = Dir.glob(File.join(Dir.tmpdir, "sumcp_vp_*.png"))
    assert_empty leftovers, "leftover tmp files: #{leftovers.inspect}"
  end

  def test_tempfile_cleaned_up_on_failure
    @view.force_write_image_failure!
    begin
      call
    rescue MCPforSketchUp::Core::StructuredError
      # expected
    end
    leftovers = Dir.glob(File.join(Dir.tmpdir, "sumcp_vp_*.png"))
    assert_empty leftovers, "leftover tmp files after failure: #{leftovers.inspect}"
  end

  def test_response_structure
    result = call("view_preset" => "iso", "style" => "shaded")
    assert_kind_of Hash, result
    %w[png_base64 width height preset_used style_used].each do |k|
      assert result.key?(k), "missing #{k} in response"
    end
    assert_equal "iso", result["preset_used"]
    assert_equal "shaded", result["style_used"]
    # png_base64 must decode to bytes starting with the PNG magic header.
    decoded = Base64.strict_decode64(result["png_base64"])
    assert decoded.start_with?("\x89PNG\r\n\x1a\n".b),
           "response PNG missing magic header: got #{decoded[0..7].inspect}"
  end

  def test_aspect_ratio_preserved
    @view.vpwidth = 1920
    @view.vpheight = 1080
    result = call("max_size" => 800)
    assert_equal 800, result["width"]
    assert_equal 450, result["height"]
  end

  def test_aspect_ratio_preserved_portrait
    @view.vpwidth = 1080
    @view.vpheight = 1920
    result = call("max_size" => 800)
    assert_equal 450, result["width"]
    assert_equal 800, result["height"]
  end
end
