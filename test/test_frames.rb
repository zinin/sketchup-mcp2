# test/test_frames.rb
# Block A (M-03): Helpers::Frames — the 4×4 matrices behind world
# coordinates, the walk from an entity up its parents, and what makes an
# entity shared.
#
# Matrices are 16 Floats, column-major like Geom::Transformation#to_a; the
# layout tests pin the values SketchUp 2027 gave live for a 90° rotation
# about Z and for scaling([1,2,3], 1,2,3). The walk runs over
# test/support/frame_fakes.rb: a plain Object is the model, Definitions are
# the definitions between it and the entity.
require "minitest/autorun"

require_relative "support/frame_fakes"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/units"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/geometry"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/entities"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/frames"

class TestFrames < Minitest::Test
  F  = MCPforSketchUp::Helpers::Frames
  SE = MCPforSketchUp::Core::StructuredError

  SHARED_ADVICE =
    "so changing it would change every copy. To change all copies, edit the definition through " \
    "eval_ruby; to change one copy, make it unique first (Make Unique in SketchUp, or make_unique " \
    "through eval_ruby), then use the new ids of the entities inside it (list_components with " \
    "recursive=true)"

  def assert_matrix(expected, actual, tol = 1e-9)
    assert_equal 16, actual.length
    expected.each_with_index do |v, i|
      assert_in_delta v, actual[i], tol, "element #{i} of #{actual.inspect}"
    end
  end

  def assert_point(expected, actual, tol = 1e-9)
    assert_equal 3, actual.length
    expected.each_with_index { |v, i| assert_in_delta v, actual[i], tol, "axis #{i} of #{actual.inspect}" }
  end

  def assert_box(expected, actual, tol = 1e-9)
    assert_point expected[0], actual[0], tol
    assert_point expected[1], actual[1], tol
  end

  def assert_bbox_mm(expected, actual, tol = 1e-6)
    refute_nil actual
    assert_equal %w[max min], actual.keys.sort
    assert_point expected["min"], actual["min"], tol
    assert_point expected["max"], actual["max"], tol
  end

  # ---------- pure matrix math ----------

  def test_rotation_has_sketchups_layout
    assert_matrix [0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1], F.rotation([0, 0, 0], 2, 90)
  end

  def test_scaling_has_sketchups_layout
    assert_matrix [1, 0, 0, 0, 0, 2, 0, 0, 0, 0, 3, 0, 0, -2, -6, 1], F.scaling([1, 2, 3], 1, 2, 3)
  end

  def test_multiply_applies_the_right_matrix_first
    m = F.multiply(F.translation(1, 0, 0), F.rotation([0, 0, 0], 2, 90))
    assert_point [1, 1, 0], F.apply(m, [1, 0, 0])
  end

  def test_rotation_turns_about_its_center
    assert_point [0, 1, 0], F.apply(F.rotation([1, 1, 0], 2, 180), [2, 1, 0])
  end

  def test_rotations_about_x_and_y_are_right_handed
    assert_point [0, 0, 1], F.apply(F.rotation([0, 0, 0], 0, 90), [0, 1, 0])
    assert_point [0, 0, -1], F.apply(F.rotation([0, 0, 0], 1, 90), [1, 0, 0])
  end

  def test_inverse_undoes_an_affine_matrix
    m = F.multiply(F.translation(5, -2, 7),
                   F.multiply(F.rotation([1, 2, 3], 0, 30), F.scaling([0, 0, 0], 2, 1, 0.5)))
    assert_matrix F::IDENTITY, F.multiply(F.inverse(m), m)
    assert_matrix F::IDENTITY, F.multiply(m, F.inverse(m))
  end

  def test_inverse_refuses_a_singular_matrix
    err = assert_raises(SE) { F.inverse(F.scaling([0, 0, 0], 1, 0, 1)) }
    assert_equal(-32603, err.code)
    assert_includes err.message, "cannot be inverted"
  end

  def test_determinant_is_the_volume_scale
    assert_in_delta 8.0, F.determinant(F.multiply(F.translation(3, 4, 5), F.scaling([1, 1, 1], 2, 2, 2))), 1e-12
    assert_in_delta(-1.0, F.determinant(F.scaling([0, 0, 0], -1, 1, 1)), 1e-12)
  end

  def test_identity_is_recognised_within_tolerance
    assert F.identity?(F::IDENTITY)
    assert F.identity?(F.rotation([0, 0, 0], 2, 360))
    refute F.identity?(F.translation(0, 0, 1e-6))
  end

  def test_normalize_divides_by_w
    assert_equal [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0, 2.0, 3.0, 1.0],
                 F.normalize([2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2, 0, 2, 4, 6, 2])
  end

  def test_normalize_makes_floats_of_a_unit_w_matrix
    values = F.normalize([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 7, 8, 9, 1])
    assert values.all? { |v| v.is_a?(Float) }
    assert_equal [7.0, 8.0, 9.0], values[12, 3]
  end

  def test_conjugate_performs_the_world_move_in_the_parent_frame
    parent = F.multiply(F.translation(100, 0, 0), F.rotation([0, 0, 0], 2, 90))
    local  = F.conjugate(F.translation(10, 0, 0), parent)
    assert_point F.apply(parent, [3, 4, 5]).zip([10, 0, 0]).map(&:sum),
                 F.apply(parent, F.apply(local, [3, 4, 5]))
  end

  def test_world_box_of_a_rotated_box
    box = F.world_box(FrameFakes.bounds([0, 0, 0], [2, 1, 1]), F.rotation([0, 0, 0], 2, 90))
    assert_box [[-1, 0, 0], [0, 2, 1]], box
  end

  def test_world_box_through_a_scaled_parent
    m = F.multiply(F.translation(10, 0, 0), F.scaling([0, 0, 0], 2, 1, 1))
    assert_box [[10, 0, 0], [12, 1, 1]], F.world_box(FrameFakes.bounds([0, 0, 0], [1, 1, 1]), m)
  end

  def test_center_of_a_box
    assert_point [1, 2, 3], F.center([[0, 0, 0], [2, 4, 6]])
  end

  # ---------- the walk ----------

  def model
    @model ||= Object.new
  end

  def test_top_level_entity_has_identity_and_no_sharing
    group = FrameFakes.place(FrameFakes::Definition.new("Group#1", group: true), id: 1, parent: model)
    p = F.placement(group)
    assert_equal F::IDENTITY, p.matrix
    assert_equal 0, p.depth
    assert_nil p.shared
  end

  def test_nested_entity_multiplies_its_parents_outermost_first
    outer_m = F.multiply(F.translation(100, 0, 0), F.rotation([0, 0, 0], 2, 90))
    inner_m = F.translation(0, 0, 20)
    outer_def = FrameFakes::Definition.new("Group#1", group: true)
    FrameFakes.place(outer_def, id: 1, parent: model, matrix: outer_m, name: "Outer")
    inner_def = FrameFakes::Definition.new("Group#2", group: true)
    FrameFakes.place(inner_def, id: 2, parent: outer_def, matrix: inner_m, name: "Inner")
    face = FrameFakes::Leaf.new(3, parent: inner_def)
    p = F.placement(face)
    assert_matrix F.multiply(outer_m, inner_m), p.matrix
    assert_equal 2, p.depth
    assert_nil p.shared
  end

  def test_a_definition_placed_twice_makes_its_contents_shared
    leg = FrameFakes::Definition.new("Leg")
    FrameFakes.place(leg, id: 1, parent: model, matrix: F.translation(10, 0, 0))
    FrameFakes.place(leg, id: 2, parent: model, matrix: F.translation(20, 0, 0))
    p = F.placement(FrameFakes::Leaf.new(3, parent: leg))
    assert_equal({ label: "component 'Leg'", copies: 2 }, p.shared)
    assert_matrix F.translation(10, 0, 0), p.matrix
    assert_equal 1, p.depth
  end

  def test_the_entitys_own_definition_does_not_count
    top = FrameFakes::Definition.new("Group#4", group: true)
    first = FrameFakes.place(top, id: 1, parent: model, name: "Top")
    FrameFakes.place(top, id: 2, parent: model, name: "Top")
    assert_nil F.placement(first).shared
  end

  def test_copies_come_from_the_holding_definition
    chair = FrameFakes::Definition.new("Chair")
    FrameFakes.place(chair, id: 1, parent: model)
    FrameFakes.place(chair, id: 2, parent: model)
    seat = FrameFakes::Definition.new("Seat", used: 4)
    FrameFakes.place(seat, id: 3, parent: chair)
    p = F.placement(FrameFakes::Leaf.new(4, parent: seat))
    assert_equal({ label: "component 'Chair'", copies: 4 }, p.shared)
    assert_equal 2, p.depth
  end

  def test_copied_group_is_labelled_by_its_instance_name
    named = FrameFakes::Definition.new("Group#5", group: true)
    FrameFakes.place(named, id: 1, parent: model, name: "Top")
    FrameFakes.place(named, id: 2, parent: model, name: "Top copy")
    assert_equal "group 'Top'", F.label_of(named)
    unnamed = FrameFakes::Definition.new("Group#6", group: true)
    FrameFakes.place(unnamed, id: 3, parent: model)
    assert_equal "an unnamed group", F.label_of(unnamed)
    assert_equal "component 'Oak Chair'", F.label_of(FrameFakes::Definition.new("Oak Chair"))
  end

  def test_an_unplaced_definition_ends_the_walk
    loose = FrameFakes::Definition.new("Loose")
    p = F.placement(FrameFakes::Leaf.new(1, parent: loose))
    assert_equal F::IDENTITY, p.matrix
    assert_equal 0, p.depth
    assert_nil p.shared
  end

  def test_a_walk_past_max_depth_is_refused
    looped = FrameFakes::Definition.new("Looped")
    FrameFakes.place(looped, id: 1, parent: looped)
    err = assert_raises(SE) { F.placement(FrameFakes::Leaf.new(2, parent: looped)) }
    assert_equal(-32603, err.code)
    assert_includes err.message, "#{F::MAX_DEPTH}"
  end

  def shared_leg_leaf(used: nil)
    leg = FrameFakes::Definition.new("Leg", used: used)
    FrameFakes.place(leg, id: 1, parent: model)
    FrameFakes.place(leg, id: 2, parent: model)
    FrameFakes::Leaf.new(7, parent: leg)
  end

  def test_require_unshared_refuses_with_the_copy_count
    err = assert_raises(SE) { F.require_unshared!(shared_leg_leaf, "entity 7") }
    assert_equal(-32602, err.code)
    assert_equal "entity 7 is inside component 'Leg', which is placed 2 times in the model, #{SHARED_ADVICE}",
                 err.message
  end

  def test_require_unshared_names_a_copy_outside_the_model
    err = assert_raises(SE) { F.require_unshared!(shared_leg_leaf(used: 1), "entity 7") }
    assert_equal "entity 7 is inside component 'Leg', which is shared with a copy that is not placed " \
                 "in the model, #{SHARED_ADVICE}", err.message
  end

  def test_require_unshared_returns_the_placement
    outer = FrameFakes::Definition.new("Group#1", group: true)
    FrameFakes.place(outer, id: 1, parent: model, matrix: F.translation(5, 0, 0))
    p = F.require_unshared!(FrameFakes::Leaf.new(2, parent: outer), "entity 2")
    assert_instance_of F::Placement, p
    assert_matrix F.translation(5, 0, 0), p.matrix
  end

  # ---------- boxes in mm ----------

  def test_bbox_mm_maps_bounds_through_the_matrix
    assert_bbox_mm({ "min" => [25.4, 0.0, 0.0], "max" => [50.8, 50.8, 101.6] },
                   F.bbox_mm(FrameFakes.bounds([0, 0, 0], [1, 2, 4]), F.translation(1, 0, 0)))
  end

  def test_bbox_mm_is_nil_for_empty_bounds
    assert_nil F.bbox_mm(FrameFakes.bounds([1, 1, 1], [0, 0, 0]), F::IDENTITY)
  end

  def test_world_bbox_mm_walks_the_entitys_parents
    group = FrameFakes::Definition.new("Group#1", group: true)
    FrameFakes.place(group, id: 1, parent: model, matrix: F.translation(10, 0, 0))
    face = FrameFakes::Leaf.new(2, parent: group, bounds: FrameFakes.bounds([0, 0, 0], [1, 1, 0]))
    assert_bbox_mm({ "min" => [254.0, 0.0, 0.0], "max" => [279.4, 25.4, 0.0] }, F.world_bbox_mm(face))
  end

  # ---------- the open edit path ----------

  OpenModel = Struct.new(:active_path)

  def open_path
    outer_def = FrameFakes::Definition.new("Group#1", group: true)
    outer = FrameFakes.place(outer_def, id: 1, parent: model, name: "Outer")
    leg = FrameFakes::Definition.new("Leg")
    first = FrameFakes.place(leg, id: 2, parent: outer_def)
    FrameFakes.place(leg, id: 3, parent: model)
    [outer, first]
  end

  def test_editing_lists_the_open_path
    assert_equal [{ "id" => 1, "name" => "Outer", "shared" => false },
                  { "id" => 2, "name" => "Leg", "shared" => true }],
                 F.editing(OpenModel.new(open_path))
  end

  def test_editing_is_empty_when_nothing_is_open
    assert_equal [], F.editing(OpenModel.new(nil))
    assert_equal [], F.editing(OpenModel.new([]))
  end

  def test_require_open_path_unshared_refuses_inside_a_shared_component
    err = assert_raises(SE) { F.require_open_path_unshared!(OpenModel.new(open_path)) }
    assert_equal(-32602, err.code)
    assert_equal "component 'Leg' is open for editing and is placed 2 times in the model, so a new " \
                 "object would appear in every copy. Close it, or make the open copy unique first " \
                 "(Make Unique in SketchUp, or make_unique through eval_ruby), then retry", err.message
  end

  def test_require_open_path_unshared_passes_a_unique_path
    outer_def = FrameFakes::Definition.new("Group#1", group: true)
    outer = FrameFakes.place(outer_def, id: 1, parent: model, name: "Outer")
    assert_nil F.require_open_path_unshared!(OpenModel.new([outer]))
    assert_nil F.require_open_path_unshared!(OpenModel.new(nil))
  end
end
