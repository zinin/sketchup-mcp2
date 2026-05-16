# test/test_helpers_geometry.rb
#
# Direct unit tests for SU_MCP::Helpers::Geometry.visible_bounds.
# The handler-level (test_view.rb) tests only cover this method through a
# method spy -- the hidden/layer-visibility filter logic ships untested
# without these.
#
# Stub strategy: this file shares Geom::Point3d and Geom::BoundingBox with
# test_view.rb / test_collect_components.rb. To avoid coupling to whichever
# definitions happen to win the load order race, we patch the methods we
# rely on (`add`, `empty?`, `diagonal`) onto Geom::BoundingBox at test
# runtime via setup/teardown. The originals are saved and restored so we
# do not leak state into other test classes.

require "minitest/autorun"

# Define a minimal Geom stub surface ONLY if no other test file has done so
# already. Other test files (test_view.rb, test_collect_components.rb)
# define richer versions; loading order is alphabetical via run_all.rb,
# which means by the time we run we may inherit a different surface --
# hence the runtime patching in setup/teardown below.
module Geom
  unless defined?(Point3d)
    class Point3d
      attr_reader :x, :y, :z
      def initialize(x = 0, y = 0, z = 0); @x, @y, @z = x, y, z; end
      def to_a; [@x, @y, @z]; end
    end
  end

  unless defined?(BoundingBox)
    # Variadic initializer so both `BoundingBox.new` (production) and
    # `BoundingBox.new(min, max)` (test_collect_components.rb) work.
    class BoundingBox
      def initialize(*_args); end
    end
  end
end

require_relative "../su_mcp/su_mcp/helpers/geometry"

class TestHelpersGeometry < Minitest::Test
  G = SU_MCP::Helpers::Geometry

  # ---------------------------------------------------------------------------
  # Runtime BoundingBox patching.
  #
  # We attach a `@__points` array to every instance via `add`, then derive
  # `empty?` and `diagonal` from it. This is a method-level patch (not class
  # redefinition) so it survives whatever the other test files do at load time.
  # ---------------------------------------------------------------------------

  PATCH_METHODS = %i[initialize add empty? diagonal].freeze

  def setup
    # Save original method bindings so we can restore them in teardown.
    @saved = {}
    PATCH_METHODS.each do |m|
      next unless Geom::BoundingBox.instance_methods(false).include?(m) ||
                  Geom::BoundingBox.private_instance_methods(false).include?(m)
      @saved[m] = Geom::BoundingBox.instance_method(m)
    end

    # Install our patches.
    Geom::BoundingBox.class_eval do
      def initialize(*_args)
        @__points = []
      end

      def add(arg)
        @__points ||= []
        if arg.is_a?(Geom::BoundingBox)
          other_points = arg.instance_variable_get(:@__points) || []
          @__points.concat(other_points)
        elsif arg.respond_to?(:x) && arg.respond_to?(:y) && arg.respond_to?(:z)
          @__points << [arg.x.to_f, arg.y.to_f, arg.z.to_f]
        elsif arg.is_a?(Array)
          arg.each { |p| add(p.is_a?(Array) ? Geom::Point3d.new(*p) : p) }
        end
        self
      end

      def empty?
        pts = instance_variable_get(:@__points)
        pts.nil? || pts.empty?
      end

      def diagonal
        pts = instance_variable_get(:@__points)
        return 0.0 if pts.nil? || pts.empty?
        xs = pts.map { |p| p[0] }
        ys = pts.map { |p| p[1] }
        zs = pts.map { |p| p[2] }
        dx = xs.max - xs.min
        dy = ys.max - ys.min
        dz = zs.max - zs.min
        Math.sqrt(dx * dx + dy * dy + dz * dz)
      end
    end
  end

  def teardown
    # Restore any methods we patched, so other test classes in the same
    # `ruby test/run_all.rb` run inherit the original surface predictably.
    # Methods that did not exist on Geom::BoundingBox before our setup are
    # left in place (harmless -- no other test depends on their absence).
    return unless @saved
    @saved.each do |name, umethod|
      Geom::BoundingBox.send(:define_method, name, umethod)
    end
  end

  # ---------------------------------------------------------------------------
  # Stubs local to these tests -- minimal SketchUp surface visible_bounds touches.
  # ---------------------------------------------------------------------------

  class FakeLayer
    def initialize(visible:); @visible = visible; end
    def visible?; @visible; end
  end

  class FakeEntity
    attr_reader :bounds
    def initialize(bounds:, hidden: false, layer: FakeLayer.new(visible: true))
      @bounds = bounds
      @hidden = hidden
      @layer  = layer
    end
    def hidden?; @hidden; end
    def layer;  @layer;  end
  end

  class FakeModel
    attr_reader :entities, :bounds
    def initialize(entities:, bounds:)
      @entities = entities
      @bounds   = bounds
    end
  end

  # Build a Geom::BoundingBox containing the given [x,y,z] tuples so we have
  # a non-empty bbox under the test-runtime patch. Returns the bbox; uses
  # the runtime-patched `add`.
  def make_bbox(*points)
    bb = Geom::BoundingBox.new
    points.each { |p| bb.add(Geom::Point3d.new(*p)) }
    bb
  end

  # ---------------------------------------------------------------------------
  # Tests for the three branches of visible_bounds.
  # ---------------------------------------------------------------------------

  def test_all_visible_entities_union_their_bounds
    e1 = FakeEntity.new(bounds: make_bbox([0, 0, 0], [10, 10, 10]))
    e2 = FakeEntity.new(bounds: make_bbox([5, 5, 5], [20, 20, 20]))
    fallback = make_bbox([100, 100, 100])  # distinct from visible content
    model = FakeModel.new(entities: [e1, e2], bounds: fallback)

    result = G.visible_bounds(model)

    # Must NOT have fallen through to model.bounds (the fallback bbox).
    refute_equal fallback.object_id, result.object_id,
                 "visible_bounds should not return model.bounds when entities are visible"
    # Diagonal of unioned bbox is distance between (0,0,0) and (20,20,20)
    # = sqrt(3 * 20**2) = sqrt(1200) ~= 34.64.
    assert_in_delta Math.sqrt(3 * 400), result.diagonal, 1e-3
  end

  def test_all_hidden_falls_back_to_model_bounds
    hidden_entity = FakeEntity.new(bounds: make_bbox([0, 0, 0], [10, 10, 10]),
                                    hidden: true)
    fallback = make_bbox([100, 100, 100])
    model = FakeModel.new(entities: [hidden_entity], bounds: fallback)

    result = G.visible_bounds(model)

    assert_equal fallback.object_id, result.object_id,
                 "visible_bounds must return model.bounds when no visible entities remain"
  end

  def test_invisible_layer_skips_entity
    visible_layer   = FakeLayer.new(visible: true)
    invisible_layer = FakeLayer.new(visible: false)
    visible_entity  = FakeEntity.new(
      bounds: make_bbox([0, 0, 0], [10, 10, 10]),
      layer:  visible_layer,
    )
    layer_hidden_entity = FakeEntity.new(
      bounds: make_bbox([100, 100, 100], [200, 200, 200]),
      layer:  invisible_layer,
    )
    fallback = make_bbox([999, 999, 999])
    model = FakeModel.new(entities: [visible_entity, layer_hidden_entity],
                          bounds: fallback)

    result = G.visible_bounds(model)

    # Result must include ONLY the [0,0,0]-[10,10,10] range, not the
    # layer-hidden [100,100,100]-[200,200,200] range. Diagonal should be
    # sqrt(3 * 100) ~= 17.32, NOT sqrt(3 * 40000) ~= 346.4.
    refute_equal fallback.object_id, result.object_id,
                 "visible_bounds should not fall back when at least one entity is visible"
    assert_in_delta Math.sqrt(3 * 100), result.diagonal, 1e-3,
                    "expected diagonal of [0,0,0]-[10,10,10] only; got #{result.diagonal}"
  end

  def test_empty_model_falls_back_to_model_bounds
    fallback = make_bbox([5, 5, 5])
    model = FakeModel.new(entities: [], bounds: fallback)

    result = G.visible_bounds(model)

    assert_equal fallback.object_id, result.object_id,
                 "visible_bounds must return model.bounds when model has no entities"
  end
end
