# test/test_collect_components.rb
#
# Regression tests for MCPforSketchUp::Handlers::Model.collect_components.
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
  # parent stays nil (the walk up the parents stops at once) unless a test
  # sets it; a group's definition and a definition's instances default to a
  # fresh definition and an empty list. Identical in test_collect_components,
  # test_model_empty_bbox and test_model_pagination: under run_all the three
  # reopen the same classes.
  class Group
    attr_accessor :entities, :name, :entityID, :transformation, :bounds, :layer, :parent
    attr_writer :definition
    def initialize
      @transformation = Geom::Transformation.new
      @entities = []
    end
    def definition; @definition ||= Sketchup::ComponentDefinition.new; end
    def valid?; true; end
  end

  class ComponentDefinition
    attr_accessor :entities, :entityID, :name, :bounds
    attr_writer :instances
    def initialize
      @entities = []
    end
    def instances; @instances ||= []; end
  end

  class ComponentInstance
    attr_accessor :definition, :name, :entityID, :transformation, :bounds, :layer, :parent
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
    def to_a; [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0]; end
  end
end

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/units"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/entities"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/geometry"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/operation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/frames"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/model"

class TestCollectComponentsRepeatedInstances < Minitest::Test
  M = MCPforSketchUp::Handlers::Model

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
      MCPforSketchUp::Helpers::Frames::IDENTITY,
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
      MCPforSketchUp::Helpers::Frames::IDENTITY,
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

# Regression test for get_component_info world-frame fix (disputed #2 A').
# The old implementation returned describe_component(entity) with an identity
# parent_t, so a NESTED entity's bbox came back in its PARENT frame (local),
# not WORLD. get_component_info now walks up from the entity (Frames.placement:
# cushion → the chair's definition → its one instance, the chair → the model),
# so the bbox + depth match list_components exactly. We prove that for a nested
# cushion the returned bbox is the WORLD-frame one (translated by the parent's
# transform), NOT the un-translated parent-frame bbox.
class TestGetComponentInfoWorldFrame < Minitest::Test
  M = MCPforSketchUp::Handlers::Model

  # Translating transformation double: to_a gives its matrix, column-major
  # like Geom::Transformation#to_a (Helpers::Frames reads nothing else).
  class Translate
    def initialize(dx, dy, dz)
      @dx, @dy, @dz = dx, dy, dz
    end

    def to_a
      [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, @dx, @dy, @dz, 1.0]
    end
  end

  def make_layer(name)
    layer = Object.new
    layer.define_singleton_method(:name) { name }
    layer
  end

  def make_bbox
    Geom::BoundingBox.new(Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(1, 1, 1))
  end

  def setup
    @layer = make_layer("Layer0")

    # cushion is nested inside chair; chair carries a +10,+20,+30 (inches)
    # translation, so cushion's world bbox is offset from its local 0..1 bbox.
    @cushion = Sketchup::Group.new
    @cushion.name = "cushion"
    @cushion.entityID = 100
    @cushion.layer = @layer
    @cushion.bounds = make_bbox

    @chair = Sketchup::Group.new
    @chair.name = "chair"
    @chair.entityID = 1
    @chair.layer = @layer
    @chair.bounds = make_bbox
    @chair.transformation = Translate.new(10, 20, 30)
    @chair.entities = [@cushion]
    # The walk up: the cushion lives in the chair's definition, whose one
    # instance is the chair, which sits in the model (parent nil stops it).
    @chair.definition.instances = [@chair]
    @cushion.parent = @chair.definition
    # Below the model, a group is boxed by its definition's bounds through
    # the parents' matrix and its own transformation.
    @cushion.definition.bounds = make_bbox

    @model_entities = [@chair]

    # Stub the active model so get_component_info can walk from model.entities.
    model = Object.new
    entities = @model_entities
    model.define_singleton_method(:entities) { entities }
    @model = model
  end

  # collect_components walks Group#entities; entity_collection(group) -> group.entities.
  # The real Helpers::Entities is loaded; we only need active_model! / find! /
  # require_group_or_component! to resolve to our stubs FOR THE DURATION of the
  # block. We capture the original Method objects up front and re-bind them in
  # `ensure`, so the genuine implementations survive in the shared run_all.rb
  # process (an earlier draft used remove_method, which deleted the real methods
  # and broke later test files — never remove, always restore).
  def with_entities_stubs(target)
    e = MCPforSketchUp::Helpers::Entities
    model = @model
    originals = {
      active_model!:              e.method(:active_model!),
      find!:                      e.method(:find!),
      require_group_or_component!: e.method(:require_group_or_component!),
    }
    e.define_singleton_method(:active_model!) { model }
    e.define_singleton_method(:find!) { |_id| target }
    e.define_singleton_method(:require_group_or_component!) { |entity, *| entity }
    yield
  ensure
    originals.each { |name, meth| e.define_singleton_method(name, meth) } if originals
  end

  def test_nested_entity_returns_world_frame_bbox_matching_collect_components
    # World-frame bbox computed the same way list_components would.
    world = M.collect_components(@model_entities, MCPforSketchUp::Helpers::Frames::IDENTITY,
                                 recursive: true, depth: 0, max_depth: 64,
                                 seen: Set.new)
    cushion_world = world.find { |c| c["id"] == 100 }
    refute_nil cushion_world, "precondition: collect_components must enumerate the cushion"
    # The chair's +10/+20/+30-inch translation, in mm (×25.4): bbox min/max
    # corners shift accordingly. This is the WORLD frame.
    assert_equal U_mm(10), cushion_world["bbox_mm"]["min"][0]
    assert_equal U_mm(11), cushion_world["bbox_mm"]["max"][0]

    info = with_entities_stubs(@cushion) do
      M.get_component_info({ "id" => 100 })
    end

    assert_equal cushion_world["bbox_mm"], info["bbox_mm"],
      "get_component_info must return the WORLD-frame bbox (matching collect_components), not the parent frame"
    assert_equal 1, info["depth"], "nested cushion is at depth 1"

    # And prove it is NOT the parent-frame (un-translated) bbox the old code
    # would have returned via describe_component(entity) with identity parent_t.
    parent_frame = M.describe_component(@cushion)
    refute_equal parent_frame["bbox_mm"], info["bbox_mm"],
      "fix regression: get_component_info returned the parent-frame bbox"
    assert_equal U_mm(0), parent_frame["bbox_mm"]["min"][0],
      "sanity: parent-frame bbox is the un-translated local 0..1 box"
  end

  def U_mm(inches)
    MCPforSketchUp::Helpers::Units.inch_to_mm(inches)
  end
end
