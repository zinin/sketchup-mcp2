# test/test_units.rb
require "minitest/autorun"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/units"

class TestUnits < Minitest::Test
  U = MCPforSketchUp::Helpers::Units

  def test_mm_constant
    assert_equal 25.4, U::MM
  end

  def test_mm_to_inch_round_trip
    assert_in_delta 1.0, U.mm_to_inch(25.4), 1e-9
    assert_in_delta 25.4, U.inch_to_mm(1.0), 1e-9
  end

  def test_mm_to_inch_zero
    assert_equal 0.0, U.mm_to_inch(0)
    assert_equal 0.0, U.inch_to_mm(0)
  end

  def test_mm_to_inch_negative
    assert_in_delta(-1.0, U.mm_to_inch(-25.4), 1e-9)
  end
end
