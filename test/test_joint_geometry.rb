# test/test_joint_geometry.rb
#
# Pure joint geometry in handlers/joints.rb (contact area of two boards, the
# joint box inside it, axis-alignment and volume post-checks). No SketchUp:
# the functions work on plain numbers and are unit-agnostic.
require "minitest/autorun"

# joints.rb aliases V/E/U at load time. Validation and Units are real; the
# rest of the load-time surface is not needed here, so Entities stays empty
# (reopening is harmless if another test loads the real one in the same
# process).
module MCPforSketchUp
  module Helpers
    module Entities; end
  end
end

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/units"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/operation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/joints"

class TestJointGeometry < Minitest::Test
  J = MCPforSketchUp::Handlers::Joints
  StructuredError = MCPforSketchUp::Core::StructuredError

  LEG = [[0, 0, 0], [50, 50, 300]]

  def assert_refused(pattern)
    err = assert_raises(StructuredError) { yield }
    assert_equal(-32602, err.code)
    assert_match(pattern, err.message)
  end

  def assert_box(expected, actual)
    expected.flatten.zip(actual.flatten).each do |e, a|
      assert_in_delta e, a, 1e-9, "box #{actual.inspect} != #{expected.inspect}"
    end
  end

  def test_contact_along_x_tenon_on_plus_side            # the §3 centred probe
    c = J.contact_area(LEG, [[50, 15, 110], [250, 35, 190]])
    assert_equal({ axis: 0, side: 1, plane: 50, cross: [1, 2], lo: [15, 110], hi: [35, 190] }, c)
  end

  def test_contact_along_y_tenon_on_minus_side
    c = J.contact_area([[0, 0, 0], [100, 100, 20]], [[20, -50, 0], [80, 0, 20]])
    assert_equal({ axis: 1, side: -1, plane: 0, cross: [0, 2], lo: [20, 0], hi: [80, 20] }, c)
  end

  def test_contact_along_z_tenon_on_top
    c = J.contact_area([[0, 0, 0], [200, 200, 50]], [[75, 75, 50], [125, 125, 250]])
    assert_equal({ axis: 2, side: 1, plane: 50, cross: [0, 1], lo: [75, 75], hi: [125, 125] }, c)
  end

  def test_gap_within_tolerance_counts_as_touching
    assert_equal 0, J.contact_area(LEG, [[50.0005, 15, 110], [250, 35, 190]])[:axis]
  end

  def test_gap_beyond_tolerance_is_refused
    assert_refused(/do not touch/) { J.contact_area(LEG, [[50.002, 15, 110], [250, 35, 190]]) }
    assert_refused(/do not touch/) { J.contact_area(LEG, [[60, 15, 110], [250, 35, 190]]) }
  end

  def test_overlapping_boards_are_refused
    assert_refused(/overlap/) { J.contact_area(LEG, [[40, 15, 110], [250, 35, 190]]) }
    # The message names the axis of the smallest overlap and its depth in mm.
    mm10 = 10 / 25.4
    assert_refused(/overlap by 10\.00 mm along X/) do
      J.contact_area(LEG, [[50 - mm10, 15, 110], [250, 35, 190]])
    end
    mm5 = 5 / 25.4
    assert_refused(/overlap by 5\.00 mm along Z/) do
      J.contact_area(LEG, [[10, 10, 300 - mm5], [40, 40, 400]])
    end
  end

  def test_edge_contact_is_refused
    assert_refused(/edge/) { J.contact_area(LEG, [[50, 50, 110], [250, 70, 190]]) }
  end

  def test_joint_box_centred_on_the_contact_area         # the §3 centred probe
    c = J.contact_area(LEG, [[50, 15, 110], [250, 35, 190]])
    assert_box [[30, 20, 130], [50, 30, 170]], J.joint_box(c, 10, 40, 20, [0, 0, 0])
  end

  def test_joint_box_on_the_minus_side
    c = J.contact_area([[0, 0, 0], [100, 100, 20]], [[20, -50, 0], [80, 0, 20]])
    assert_box [[40, 0, 5], [60, 15, 15]], J.joint_box(c, 20, 10, 15, [0, 0, 0])
  end

  def test_joint_box_for_the_offset_rail                 # the §3 offset probe
    c = J.contact_area(LEG, [[50, 0, 200], [250, 20, 280]])
    assert_box [[30, 5, 220], [50, 15, 260]], J.joint_box(c, 10, 40, 20, [0, 0, 0])
  end

  def test_joint_box_may_reach_the_contact_edge          # offset along x is ignored
    c = J.contact_area(LEG, [[50, 15, 110], [250, 35, 190]])
    assert_box [[30, 25, 150], [50, 35, 190]], J.joint_box(c, 10, 40, 20, [99, 5, 20])
  end

  def test_joint_box_past_the_edge_is_refused
    c = J.contact_area(LEG, [[50, 15, 110], [250, 35, 190]])
    assert_refused(/does not fit/) { J.joint_box(c, 10, 40, 20, [0, 0, 21]) }
    assert_refused(/does not fit/) { J.joint_box(c, 30, 40, 20, [0, 0, 0]) }
  end

  def test_axis_aligned
    assert J.axis_aligned?([[1, 0, 0], [0, 1, 0], [0, 0, 1]])
    assert J.axis_aligned?([[0, 1, 0], [-1, 0, 0], [0, 0, 1]])        # 90° about Z
    assert J.axis_aligned?([[2, 0, 0], [0, 3, 0], [0, 0, 0.5]])       # scaled
    refute J.axis_aligned?([[0.7071, 0.7071, 0], [-0.7071, 0.7071, 0], [0, 0, 1]])
  end

  def test_volume_clean_joint
    assert_nil J.joint_volume_problem(8000, 8000, 750_000, 742_000, 320_000, 328_000)
  end

  def test_volume_through_mortise_is_fine                # the leg loses w × h × thickness
    assert_nil J.joint_volume_problem(5000, 8000, 750_000, 745_000, 320_000, 328_000)
  end

  def test_volume_pocket_meeting_an_earlier_one_is_refused # the cut frees 4 000 of 8 000
    assert_match(/\Amortise board lost/, J.joint_volume_problem(8000, 8000, 742_000, 738_000, 320_000, 328_000))
  end

  def test_volume_problems
    assert_match(/mortise board/, J.joint_volume_problem(8000, 8000, 750_000, 750_000, 320_000, 328_000)) # empty cut
    assert_match(/mortise board/, J.joint_volume_problem(8000, 8000, 750_000, 741_000, 320_000, 328_000)) # too much
    assert_match(/tenon board/,   J.joint_volume_problem(8000, 8000, 750_000, 742_000, 320_000, 320_000)) # no tenon
    assert_match(/tenon board/,   J.joint_volume_problem(8000, 8000, 750_000, 742_000, 320_000, 327_990)) # short
  end

  # A change is stated as a non-negative amount, and never as a negative
  # zero. Volumes in in³, chosen so that the mm³ are round numbers.
  def test_volume_problems_state_the_change_as_a_non_negative_amount
    in3 = ->(mm3) { mm3 / 25.4**3 }
    empty_cut = J.joint_volume_problem(in3[8000], in3[8000], in3[750_000], in3[750_000], in3[320_000], in3[328_000])
    assert_equal "mortise board lost 0.0 mm³ (expected a loss of 8000.0 mm³)", empty_cut
    # Measured a hair larger than before, within the tolerance: still no -0.0.
    assert_equal "mortise board lost 0.0 mm³ (expected a loss of 8000.0 mm³)",
                 J.joint_volume_problem(in3[8000], in3[8000], in3[750_000], in3[750_000.04], in3[320_000], in3[328_000])
    # Less than the cut: the box met an earlier pocket.
    assert_equal "mortise board lost 4000.0 mm³ (expected a loss of 8000.0 mm³)",
                 J.joint_volume_problem(in3[8000], in3[8000], in3[750_000], in3[746_000], in3[320_000], in3[328_000])
    assert_match(/mortise board lost 9000\.0 mm³/,
                 J.joint_volume_problem(in3[8000], in3[8000], in3[750_000], in3[741_000], in3[320_000], in3[328_000]))
    assert_match(/mortise board gained 100\.0 mm³/,
                 J.joint_volume_problem(in3[8000], in3[8000], in3[750_000], in3[750_100], in3[320_000], in3[328_000]))
    assert_equal("tenon board gained 0.0 mm³ (expected a gain of 8000.0 mm³)",
                 J.joint_volume_problem(in3[8000], in3[8000], in3[750_000], in3[742_000], in3[320_000], in3[320_000]))
    assert_match(/tenon board lost 100\.0 mm³/,
                 J.joint_volume_problem(in3[8000], in3[8000], in3[750_000], in3[742_000], in3[320_000], in3[319_900]))
  end
end
