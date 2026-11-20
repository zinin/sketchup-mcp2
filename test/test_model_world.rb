# test/test_model_world.rb
# Block A (M-03, M-17, part of M-19): the read-only tools in world
# coordinates.
#
# get_component_info and get_selection walk up the entity's parents
# (Frames.placement) instead of searching from the model root, so a nested
# entity's box is world in every edit state: while a group is open SketchUp
# reports the open instance with an identity transformation and its
# contents in world coordinates (spec §3), and the walk gives the same box.
# list_components and find_components keep their traversal; every row
# carries `shared`, and a component row its `definition`. find_components
# matches a component's definition name; get_model_info reports the open
# edit path.
#
# Scenes come from test/support/frame_fakes.rb; a FakeModel is the model
# (top-level entities, lookup by id, selection, open path), and
# Entities.active_model! is stubbed per test (SingletonStubs).
require "minitest/autorun"
require "set"

require_relative "support/singleton_stubs"
require_relative "support/frame_fakes"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/units"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/entities"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/geometry"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/operation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/frames"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/model"

class TestModelWorld < Minitest::Test
  include SingletonStubs

  M  = MCPforSketchUp::Handlers::Model
  F  = MCPforSketchUp::Helpers::Frames
  EH = MCPforSketchUp::Helpers::Entities

  Layer = Struct.new(:name)
  LAYER = Layer.new("Layer0")

  # The outer group's placement in the model: moved 10" along X, turned 90°
  # about Z. The inner group's unit box inside it lands at x 9..10", y 0..1".
  OUTER = F.multiply(F.translation(10, 0, 0), F.rotation([0, 0, 0], 2, 90))
  NESTED_BBOX = { "min" => [228.6, 0.0, 0.0], "max" => [254.0, 25.4, 25.4] }.freeze

  class FakeModel
    attr_accessor :entities, :selection, :active_path

    def initialize
      @entities = []
      @selection = []
      @active_path = nil
      @by_id = {}
    end

    def register(entity)
      @by_id[entity.entityID] = entity
    end

    def find_entity_by_id(id)
      @by_id[id]
    end

    def path
      ""
    end

    def title
      ""
    end

    def bounds
      FrameFakes.bounds([0, 0, 0], [1, 1, 1])
    end

    def layers
      [LAYER]
    end
  end

  def setup
    @model = FakeModel.new
    model = @model
    stub_singleton(EH, :active_model!) { model }
  end

  def assert_bbox_mm(expected, actual, tol = 1e-6)
    refute_nil actual
    %w[min max].each do |key|
      expected[key].each_with_index do |v, i|
        assert_in_delta v, actual[key][i], tol, "#{key}[#{i}] of #{actual.inspect}"
      end
    end
  end

  def unit_box
    FrameFakes.bounds([0, 0, 0], [1, 1, 1])
  end

  # A placement of `definition` (whose bounds, in its own frame, default to
  # `bounds`) at `matrix`, with its bounds in the parent's frame the box of
  # the definition's through the matrix, as SketchUp reports them; the
  # Layer0 tag; registered by id and, at the top level, listed among the
  # model's entities.
  def place(definition, id:, parent:, matrix: FrameFakes::IDENTITY, name: "", bounds: unit_box)
    definition.bounds ||= bounds
    placed = FrameFakes.place(definition, id: id, parent: parent, matrix: matrix, name: name)
    placed.bounds = FrameFakes.bounds(*F.world_box(definition.bounds, matrix))
    placed.layer = LAYER
    @model.register(placed)
    @model.entities << placed if parent.equal?(@model)
    placed
  end

  # Group "Outer" (id 1) at OUTER, with group "Inner" (id 2) inside it. Open,
  # SketchUp reports Outer with an identity transformation and Inner's
  # transformation (so its bounds too) in world coordinates.
  def nested_scene(open: false)
    outer_def = FrameFakes::Definition.new("Group#1", group: true)
    outer = place(outer_def, id: 1, parent: @model, matrix: open ? FrameFakes::IDENTITY : OUTER, name: "Outer")
    inner = place(FrameFakes::Definition.new("Group#2", group: true),
                  id: 2, parent: outer_def, matrix: open ? OUTER : FrameFakes::IDENTITY, name: "Inner")
    @model.active_path = [outer] if open
    [outer, inner]
  end

  # Component "Leg" placed twice (ids 1 at x 10", 2 at x 20"), with group
  # "part" (id 3) inside its definition.
  def leg_scene
    leg = FrameFakes::Definition.new("Leg")
    a = place(leg, id: 1, parent: @model, matrix: F.translation(10, 0, 0))
    b = place(leg, id: 2, parent: @model, matrix: F.translation(20, 0, 0))
    part = place(FrameFakes::Definition.new("Group#3", group: true), id: 3, parent: leg, name: "part")
    [a, b, part]
  end

  def test_get_component_info_reports_world_bbox_through_parents
    nested_scene
    info = M.get_component_info("id" => "2")
    assert_bbox_mm NESTED_BBOX, info["bbox_mm"]
    assert_equal 1, info["depth"]
    assert_equal false, info["shared"]
    assert_equal "Inner", info["name"]
    refute info.key?("definition"), "a group row carries no definition"
  end

  def test_component_info_agrees_open_and_closed
    nested_scene(open: true)
    info = M.get_component_info("id" => "2")
    assert_bbox_mm NESTED_BBOX, info["bbox_mm"]
    assert_equal 1, info["depth"]
  end

  def test_shared_child_reports_the_first_placement
    leg_scene
    info = M.get_component_info("id" => "3")
    assert_equal true, info["shared"]
    assert_bbox_mm({ "min" => [254.0, 0.0, 0.0], "max" => [279.4, 25.4, 25.4] }, info["bbox_mm"])
  end

  def test_component_info_names_the_definition_of_a_component
    leg_scene
    info = M.get_component_info("id" => "1")
    assert_equal "Leg", info["definition"]
    assert_equal false, info["shared"], "a top-level placement is not shared: its own definition does not count"
    assert_equal 0, info["depth"]
  end

  def test_list_rows_carry_shared_and_definition
    leg_scene
    rows = M.list_components("recursive" => true)["components"]
    assert_equal [[1, "component", false, "Leg"], [3, "group", true, nil],
                  [2, "component", false, "Leg"], [3, "group", true, nil]],
                 rows.map { |r| [r["id"], r["type"], r["shared"], r["definition"]] }
    refute rows[1].key?("definition"), "a group row carries no definition"
    assert_bbox_mm({ "min" => [254.0, 0.0, 0.0], "max" => [279.4, 25.4, 25.4] }, rows[1]["bbox_mm"])
    assert_bbox_mm({ "min" => [508.0, 0.0, 0.0], "max" => [533.4, 25.4, 25.4] }, rows[3]["bbox_mm"])
  end

  def test_find_components_matches_a_definition_name
    place(FrameFakes::Definition.new("Oak Chair"), id: 1, parent: @model)
    place(FrameFakes::Definition.new("Table"), id: 2, parent: @model, name: "dining")
    rows = M.find_components("name" => "chair")["components"]
    assert_equal [1], rows.map { |r| r["id"] }
    assert_equal "Oak Chair", rows[0]["definition"]
  end

  def test_group_definition_names_are_not_matched
    place(FrameFakes::Definition.new("Group#3", group: true), id: 1, parent: @model)
    assert_equal 0, M.find_components("name" => "group#")["total"]
  end

  def test_concise_rows_keep_shared_and_definition
    leg_scene
    rows = M.list_components("recursive" => true, "response_format" => "concise")["components"]
    assert_equal %w[definition depth id layer name shared type], rows[0].keys.sort
    assert_equal %w[depth id layer name shared type], rows[1].keys.sort
  end

  def test_get_selection_reports_world_bbox_and_shared
    _outer, inner = nested_scene
    face = FrameFakes::Leaf.new(9, parent: inner.definition)
    @model.selection = [inner, face]
    rows = M.get_selection({})["entities"]
    assert_equal M.get_component_info("id" => "2"), rows[0]
    assert_bbox_mm NESTED_BBOX, rows[0]["bbox_mm"]
    assert_equal({ "id" => 9, "type" => "face" }, rows[1])
  end

  def test_get_model_info_reports_the_open_path
    nested_scene(open: true)
    assert_equal [{ "id" => 1, "name" => "Outer", "shared" => false }], M.get_model_info({})["editing"]
    @model.active_path = nil
    assert_equal [], M.get_model_info({})["editing"]
  end

  # Final review, Important #1, through the handler: a group turned 30°
  # inside a group turned 30° has one box, open or closed (SketchUp boxes
  # an instance as its definition's bounds through its transformation).
  def turned_scene(open:)
    turn = F.rotation([0, 0, 0], 2, 30)
    outer_def = FrameFakes::Definition.new("Group#1", group: true)
    outer = place(outer_def, id: 1, parent: @model, matrix: open ? FrameFakes::IDENTITY : turn, name: "Outer")
    own = open ? F.multiply(turn, turn) : turn
    inner_def = FrameFakes::Definition.new("Group#2", group: true, bounds: unit_box)
    inner = place(inner_def, id: 2, parent: outer_def, matrix: own, name: "Inner")
    @model.active_path = [outer] if open
    inner
  end

  def test_component_info_agrees_open_and_closed_under_two_turns
    turned_scene(open: false)
    closed = M.get_component_info("id" => "2")["bbox_mm"]
    setup
    turned_scene(open: true)
    open = M.get_component_info("id" => "2")["bbox_mm"]
    assert_bbox_mm open, closed
    width = (Math.cos(Math::PI / 3) + Math.sin(Math::PI / 3)) * 25.4
    assert_in_delta width, closed["max"][0] - closed["min"][0], 1e-6
  end

  # Final review, Important #2: a component placed many times (screws,
  # windows) must not cost a scan of its instances per placement.
  class CountingDefinition < FrameFakes::Definition
    attr_reader :reads

    def instances
      @reads = (@reads || 0) + 1
      super
    end

    def reset_reads
      @reads = 0
    end
  end

  def test_recursive_listing_reads_each_definitions_instances_once
    leg = CountingDefinition.new("Leg")
    5.times { |i| place(leg, id: 10 + i, parent: @model, matrix: F.translation(10 * i, 0, 0)) }
    place(FrameFakes::Definition.new("Group#3", group: true), id: 3, parent: leg, name: "part")
    leg.reset_reads
    rows = M.list_components("recursive" => true, "limit" => 500)["components"]
    assert_equal 10, rows.length
    assert_operator leg.reads, :<=, 1, "definition.instances read once per definition, not once per placement"
  end
end
