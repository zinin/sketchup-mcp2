# test/test_shared_refusals.rb
# Block A (M-03, spec §6.2): no mutating tool silently edits every copy of a
# component.
#
# An entity inside a definition placed more than once — a component placed
# several times, or copies of a group that still share one definition — is
# shared, and every mutating tool refuses it with -32602: the message names
# the component, says how many copies the change would affect and what to
# do instead (Frames.require_unshared!). The entity's own definition does
# not count, so moving, painting or deleting one of four chairs at the top
# level stays allowed. A target is refused inside its operation, which is
# aborted; create_component refuses while a shared group or component is
# open for editing, before any operation starts. Mutating responses report
# world boxes (describe_entity walks up the parents).
#
# Fakes: a recording model whose log holds [:start, label], :commit and
# :abort. Targets subclass the guarded Sketchup::Group / Face stubs because
# the handlers check is_a?; definitions and placements come from
# test/support/frame_fakes.rb, where a plain object (the model) ends the
# walk. Entities.active_model! is stubbed per test (SingletonStubs).
require "minitest/autorun"

require_relative "support/singleton_stubs"
require_relative "support/frame_fakes"

module Sketchup
  class Group; end unless defined?(Group)
  class ComponentInstance; end unless defined?(ComponentInstance)
  class Face; end unless defined?(Face)
end

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/units"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/entities"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/geometry"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/operation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/frames"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/geometry"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/materials"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/operations"

class TestSharedRefusals < Minitest::Test
  include SingletonStubs

  H  = MCPforSketchUp::Handlers
  F  = MCPforSketchUp::Helpers::Frames
  EH = MCPforSketchUp::Helpers::Entities
  SE = MCPforSketchUp::Core::StructuredError

  ADVICE =
    "so changing it would change every copy. To change all copies, edit the definition through " \
    "eval_ruby; to change one copy, make it unique first (Make Unique in SketchUp, or make_unique " \
    "through eval_ruby), then use the new ids of the entities inside it (list_components with " \
    "recursive=true)"

  FakeMaterial = Struct.new(:name)

  class RecordingModel
    attr_reader :log, :materials
    attr_accessor :active_path, :active_entities

    def initialize
      @log = []
      @by_id = {}
      @materials = { "red" => FakeMaterial.new("red") }
      @active_path = nil
    end

    def register(entity)
      @by_id[entity.entityID] = entity
      entity
    end

    def start_operation(name, _disable_ui = true)
      @log << [:start, name]
      true
    end

    def commit_operation
      @log << :commit
      true
    end

    def abort_operation
      @log << :abort
      true
    end

    def find_entity_by_id(id)
      @by_id[id]
    end
  end

  # A group: what find!, the guards, delete, set_material and describe_entity
  # read; erase! and transform! are recorded.
  class FakeGroup < Sketchup::Group
    attr_reader :entityID, :name, :entities, :erased
    attr_accessor :parent, :bounds

    def initialize(id, name, parent, bounds = FrameFakes.bounds([0, 0, 0], [1, 1, 1]))
      @entityID = id
      @name = name
      @parent = parent
      @bounds = bounds
      @entities = []
      @erased = false
    end

    def valid?
      true
    end

    def erase!
      @erased = true
    end

    def transform!(_transformation)
      self
    end

    def make_unique
      self
    end
  end

  class FakeFace < Sketchup::Face
    attr_reader :entityID
    attr_accessor :parent, :bounds, :material

    def initialize(id, parent, bounds = FrameFakes.bounds([0, 0, 0], [1, 1, 0]))
      @entityID = id
      @parent = parent
      @bounds = bounds
    end

    def valid?
      true
    end

    def typename
      "Face"
    end

    # The corners of its rectangle (its bounds lie in one z plane): a face
    # below a moved or turned parent is boxed by its vertices.
    def vertices
      lo = @bounds.min
      hi = @bounds.max
      [[lo.x, lo.y], [hi.x, lo.y], [hi.x, hi.y], [lo.x, hi.y]].map do |x, y|
        FrameFakes::Vertex.new(FrameFakes::Point.new(x, y, lo.z))
      end
    end
  end

  def setup
    @model = RecordingModel.new
    model = @model
    stub_singleton(EH, :active_model!) { model }
    # Component "Chair" placed twice in the model; a seat group (7) and a
    # face (8) live in its definition.
    @chair = FrameFakes::Definition.new("Chair")
    @chair_a = FrameFakes.place(@chair, id: 1, parent: @model)
    FrameFakes.place(@chair, id: 2, parent: @model)
    @seat = @model.register(FakeGroup.new(7, "seat", @chair))
    @face = @model.register(FakeFace.new(8, @chair))
  end

  def assert_refused(expected_message, label, &call)
    err = assert_raises(SE, &call)
    assert_equal(-32602, err.code)
    assert_equal expected_message, err.message
    assert_equal [[:start, label], :abort], @model.log
  end

  def seat_message(what = "entity 7")
    "#{what} is inside component 'Chair', which is placed 2 times in the model, #{ADVICE}"
  end

  def test_delete_refuses_an_entity_inside_a_shared_component
    assert_refused(seat_message, "Delete Component") { H::Geometry.delete_component("id" => "7") }
    refute @seat.erased
  end

  def test_transform_refuses_an_entity_inside_a_shared_component
    assert_refused(seat_message, "Transform Component") do
      H::Geometry.transform_component("id" => "7", "position" => [0, 0, 0])
    end
  end

  def test_set_material_refuses_a_face_inside_a_shared_component
    assert_refused(seat_message("entity 8"), "Set Material (Red)") do
      H::Materials.set_material("id" => "8", "material" => "red")
    end
    assert_nil @face.material
  end

  def test_face_inside_a_copied_group_is_refused
    top = FrameFakes::Definition.new("Group#4", group: true)
    FrameFakes.place(top, id: 3, parent: @model, name: "Top")
    FrameFakes.place(top, id: 4, parent: @model, name: "Top")
    @model.register(FakeFace.new(9, top))
    assert_refused("entity 9 is inside group 'Top', which is placed 2 times in the model, #{ADVICE}",
                   "Set Material (Red)") do
      H::Materials.set_material("id" => "9", "material" => "red")
    end
  end

  def test_boolean_refuses_a_shared_target
    @model.register(FakeGroup.new(20, "free", @model))
    assert_refused(seat_message("target (entity 7)"), "Boolean Union") do
      H::Operations.boolean_operation("target_id" => "7", "tool_id" => "20", "operation" => "union")
    end
  end

  def test_boolean_refuses_a_shared_tool
    @model.register(FakeGroup.new(20, "free", @model))
    assert_refused(seat_message("tool (entity 7)"), "Boolean Union") do
      H::Operations.boolean_operation("target_id" => "20", "tool_id" => "7", "operation" => "union")
    end
  end

  def test_chamfer_refuses_a_shared_target
    assert_refused(seat_message, "Chamfer Edges") do
      H::Operations.chamfer_edges("entity_id" => "7", "distance" => 2)
    end
  end

  def test_top_level_copy_can_be_painted_and_deleted
    # A group whose own definition has two instances, at the top level: its
    # parent is the model, so the walk meets no definition.
    copy = @model.register(FakeGroup.new(5, "chair copy", @model))
    H::Materials.set_material("id" => "5", "material" => "red")
    assert_equal [[:start, "Set Material (Red)"], :commit], @model.log
    @model.log.clear
    H::Geometry.delete_component("id" => "5")
    assert_equal [[:start, "Delete Component"], :commit], @model.log
    assert copy.erased
  end

  def test_create_component_refuses_inside_an_open_shared_component
    @model.active_path = [@chair_a]
    err = assert_raises(SE) do
      H::Geometry.create_component("type" => "cube", "dimensions" => [10, 10, 10])
    end
    assert_equal(-32602, err.code)
    assert_equal "component 'Chair' is open for editing and is placed 2 times in the model, so a new " \
                 "object would appear in every copy. Close it, or make the open copy unique first " \
                 "(Make Unique in SketchUp, or make_unique through eval_ruby), then retry", err.message
    assert_equal [], @model.log, "refused before any operation starts"
  end

  def test_create_component_passes_an_open_unique_group
    unique = FrameFakes::Definition.new("Group#9", group: true)
    @model.active_path = [FrameFakes.place(unique, id: 11, parent: @model, name: "Box")]
    sentinel = Class.new(StandardError)
    entities = Object.new
    entities.define_singleton_method(:add_group) { raise sentinel }
    @model.active_entities = entities
    assert_raises(sentinel) do
      H::Geometry.create_component("type" => "cube", "dimensions" => [10, 10, 10])
    end
    assert_equal [[:start, "Create Component (Cube)"], :abort], @model.log
  end

  def test_mutating_responses_report_world_bbox
    group = FrameFakes::Definition.new("Group#7", group: true)
    FrameFakes.place(group, id: 30, parent: @model, matrix: F.translation(10, 0, 0))
    @model.register(FakeFace.new(31, group))
    result = H::Materials.set_material("id" => "31", "material" => "red")
    expected = { "min" => [254.0, 0.0, 0.0], "max" => [279.4, 25.4, 0.0] }
    %w[min max].each do |key|
      expected[key].each_with_index do |v, i|
        assert_in_delta v, result["bbox_mm"][key][i], 1e-6, "#{key}[#{i}] of #{result['bbox_mm'].inspect}"
      end
    end
    assert_equal "face", result["type"]
  end
end
