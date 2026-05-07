# test/test_collect_components.rb
#
# Regression tests for SU_MCP::Handlers::Model.collect_components.
# Verifies that the cycle-guard `seen` set is path-local: distinct
# instances of the same ComponentDefinition each get their children
# enumerated, while genuine self-references are still bounded.

require "minitest/autorun"
require "set"

# --- Minimal SketchUp / Geom stubs --------------------------------------------
# collect_components / describe_component touch a small subset of the API.
# We stub just enough for the recursion logic and bbox projection to run
# without a live SketchUp process.

module Sketchup
  class Group
    attr_accessor :entities, :name, :entityID, :transformation, :bounds, :layer
    def initialize
      @transformation = Geom::Transformation.new
      @entities = []
    end
    def valid?; true; end
  end

  class ComponentDefinition
    attr_accessor :entities, :entityID
    def initialize
      @entities = []
    end
  end

  class ComponentInstance
    attr_accessor :definition, :name, :entityID, :transformation, :bounds, :layer
    def initialize
      @transformation = Geom::Transformation.new
    end
    def valid?; true; end
  end
end

module Geom
  class Point3d
    attr_reader :x, :y, :z
    def initialize(x, y, z)
      @x, @y, @z = x, y, z
    end
  end

  class BoundingBox
    attr_reader :min, :max
    def initialize(min, max)
      @min = min
      @max = max
    end
  end

  class Transformation
    def initialize; end
    def *(other); other; end  # identity for these tests
  end
end

require_relative "../su_mcp/su_mcp/core/errors"
require_relative "../su_mcp/su_mcp/helpers/units"
require_relative "../su_mcp/su_mcp/helpers/validation"
require_relative "../su_mcp/su_mcp/helpers/entities"
require_relative "../su_mcp/su_mcp/handlers/model"

class TestCollectComponentsRepeatedInstances < Minitest::Test
  M = SU_MCP::Handlers::Model

  def make_layer(name)
    layer = Object.new
    layer.define_singleton_method(:name) { name }
    layer
  end

  def make_bbox
    Geom::BoundingBox.new(
      Geom::Point3d.new(0, 0, 0),
      Geom::Point3d.new(1, 1, 1)
    )
  end

  def make_group(name:, id:, layer:)
    g = Sketchup::Group.new
    g.name = name
    g.entityID = id
    g.layer = layer
    g.bounds = make_bbox
    g
  end

  def make_instance(name:, id:, definition:, layer:)
    inst = Sketchup::ComponentInstance.new
    inst.name = name
    inst.entityID = id
    inst.definition = definition
    inst.layer = layer
    inst.bounds = make_bbox
    inst
  end

  def setup
    @layer = make_layer("Layer0")

    cushion = make_group(name: "cushion", id: 100, layer: @layer)

    @chair_def = Sketchup::ComponentDefinition.new
    @chair_def.entityID = 200
    @chair_def.entities = [cushion]

    @chair_a = make_instance(name: "ChairA", id: 1, definition: @chair_def, layer: @layer)
    @chair_b = make_instance(name: "ChairB", id: 2, definition: @chair_def, layer: @layer)
  end

  def test_recursive_returns_nested_for_every_instance_of_same_definition
    components = M.collect_components(
      [@chair_a, @chair_b],
      Geom::Transformation.new,
      recursive: true, depth: 0, max_depth: 3, seen: Set.new
    )
    names = components.map { |c| c["name"] }
    assert_equal 2, names.count("cushion"),
      "expected nested 'cushion' under both ChairA and ChairB, got #{names.inspect}"
  end

  def test_self_referencing_definition_is_still_bounded
    # A definition that contains an instance of itself — pathological cycle.
    def_self = Sketchup::ComponentDefinition.new
    def_self.entityID = 300

    outer = make_instance(name: "Self", id: 11, definition: def_self, layer: @layer)
    inner = make_instance(name: "Self", id: 12, definition: def_self, layer: @layer)
    def_self.entities = [inner]

    components = M.collect_components(
      [outer],
      Geom::Transformation.new,
      recursive: true, depth: 0, max_depth: 100, seen: Set.new
    )

    # Cycle guard must stop recursion the first time we re-enter def_self
    # along the same path. Outer is depth=0; the first nested instance is
    # depth=1; the recursion into its (cyclic) children must be blocked,
    # so no entity at depth >= 2 may appear.
    max_depth_seen = components.map { |c| c["depth"] }.max
    assert_operator max_depth_seen, :<=, 1,
      "self-reference cycle guard failed; depth=#{max_depth_seen}, names=#{components.map { |c| c['name'] }.inspect}"
  end
end
