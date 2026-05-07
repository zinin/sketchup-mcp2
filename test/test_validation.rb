# test/test_validation.rb
require "minitest/autorun"
require_relative "../su_mcp/su_mcp/core/errors"
require_relative "../su_mcp/su_mcp/helpers/validation"

class TestValidationRequireString < Minitest::Test
  V = SU_MCP::Helpers::Validation
  E = SU_MCP::Core::StructuredError

  def test_present_string
    assert_equal "x", V.require_string({ "k" => "x" }, "k")
  end

  def test_nil_raises
    err = assert_raises(E) { V.require_string({}, "k") }
    assert_equal(-32602, err.code)
    assert_match(/missing required field: k/, err.message)
  end

  def test_non_string_raises
    err = assert_raises(E) { V.require_string({ "k" => 123 }, "k") }
    assert_match(/must be a string/, err.message)
  end

  def test_empty_string_raises
    err = assert_raises(E) { V.require_string({ "k" => "" }, "k") }
    assert_match(/must not be empty/, err.message)
  end
end

class TestValidationRequirePositive < Minitest::Test
  V = SU_MCP::Helpers::Validation
  E = SU_MCP::Core::StructuredError

  def test_positive_int
    assert_equal 5, V.require_positive({ "k" => 5 }, "k")
  end

  def test_positive_float
    assert_in_delta 0.5, V.require_positive({ "k" => 0.5 }, "k"), 1e-9
  end

  def test_zero_raises
    err = assert_raises(E) { V.require_positive({ "k" => 0 }, "k") }
    assert_match(/must be > 0/, err.message)
  end

  def test_negative_raises
    err = assert_raises(E) { V.require_positive({ "k" => -1 }, "k") }
    assert_match(/must be > 0/, err.message)
  end

  def test_string_raises
    err = assert_raises(E) { V.require_positive({ "k" => "5" }, "k") }
    assert_match(/must be a number/, err.message)
  end

  def test_nil_raises
    err = assert_raises(E) { V.require_positive({}, "k") }
    assert_match(/missing required field/, err.message)
  end
end

class TestValidationRequireEnum < Minitest::Test
  V = SU_MCP::Helpers::Validation
  E = SU_MCP::Core::StructuredError

  def test_in_list
    assert_equal "cube", V.require_enum({ "type" => "cube" }, "type", %w[cube cylinder])
  end

  def test_not_in_list
    err = assert_raises(E) { V.require_enum({ "type" => "x" }, "type", %w[cube cylinder]) }
    assert_match(/must be one of/, err.message)
    assert_match(/cylinder/, err.message)
  end

  def test_missing
    err = assert_raises(E) { V.require_enum({}, "type", %w[cube]) }
    assert_match(/missing required field/, err.message)
  end
end

class TestValidationRequireCoords3 < Minitest::Test
  V = SU_MCP::Helpers::Validation
  E = SU_MCP::Core::StructuredError

  def test_three_numbers
    assert_equal [1, 2, 3], V.require_coords3({ "p" => [1, 2, 3] }, "p")
  end

  def test_three_floats
    assert_equal [1.5, 2.5, 3.5], V.require_coords3({ "p" => [1.5, 2.5, 3.5] }, "p")
  end

  def test_zero_allowed
    assert_equal [0, 0, 0], V.require_coords3({ "p" => [0, 0, 0] }, "p")
  end

  def test_wrong_length_raises
    err = assert_raises(E) { V.require_coords3({ "p" => [1, 2] }, "p") }
    assert_match(/3-element array/, err.message)
  end

  def test_non_array_raises
    err = assert_raises(E) { V.require_coords3({ "p" => "abc" }, "p") }
    assert_match(/3-element array/, err.message)
  end

  def test_non_numeric_element_raises
    err = assert_raises(E) { V.require_coords3({ "p" => [1, "x", 3] }, "p") }
    assert_match(/must be a number/, err.message)
  end
end

class TestValidationRequireDimensions3 < Minitest::Test
  V = SU_MCP::Helpers::Validation
  E = SU_MCP::Core::StructuredError

  def test_all_positive
    assert_equal [1, 2, 3], V.require_dimensions3({ "d" => [1, 2, 3] }, "d")
  end

  def test_zero_raises
    err = assert_raises(E) { V.require_dimensions3({ "d" => [1, 0, 3] }, "d") }
    assert_match(/must be > 0/, err.message)
  end

  def test_negative_raises
    err = assert_raises(E) { V.require_dimensions3({ "d" => [-1, 1, 1] }, "d") }
    assert_match(/must be > 0/, err.message)
  end
end

class TestValidationRequireId < Minitest::Test
  V = SU_MCP::Helpers::Validation
  E = SU_MCP::Core::StructuredError

  def test_integer
    assert_equal 42, V.require_id({ "id" => 42 })
  end

  def test_string_integer
    assert_equal 42, V.require_id({ "id" => "42" })
  end

  def test_non_numeric_string_raises
    err = assert_raises(E) { V.require_id({ "id" => "abc" }) }
    assert_match(/must be an integer ID/, err.message)
  end

  def test_missing_raises
    err = assert_raises(E) { V.require_id({}) }
    assert_match(/missing required field/, err.message)
  end

  def test_custom_key
    assert_equal 7, V.require_id({ "target_id" => 7 }, "target_id")
  end
end

class TestValidationOptional < Minitest::Test
  V = SU_MCP::Helpers::Validation
  E = SU_MCP::Core::StructuredError

  def test_optional_coords3_missing
    assert_nil V.optional_coords3({}, "p")
  end

  def test_optional_coords3_present_validates
    assert_equal [1, 2, 3], V.optional_coords3({ "p" => [1, 2, 3] }, "p")
  end

  def test_optional_coords3_present_invalid_raises
    err = assert_raises(E) { V.optional_coords3({ "p" => [1, 2] }, "p") }
    assert_match(/3-element array/, err.message)
  end

  def test_optional_positive_default
    assert_equal 24, V.optional_positive({}, "k", 24)
  end

  def test_optional_positive_present
    assert_equal 32, V.optional_positive({ "k" => 32 }, "k")
  end

  def test_optional_int_positive_default
    assert_equal 16, V.optional_int_positive({}, "k", 16)
  end

  def test_optional_int_positive_float_raises
    err = assert_raises(E) { V.optional_int_positive({ "k" => 1.5 }, "k") }
    assert_match(/must be an integer/, err.message)
  end

  def test_optional_bool_default
    assert_equal false, V.optional_bool({}, "k")
    assert_equal true,  V.optional_bool({}, "k", true)
  end

  def test_optional_bool_true
    assert_equal true, V.optional_bool({ "k" => true }, "k")
  end

  def test_optional_bool_false
    assert_equal false, V.optional_bool({ "k" => false }, "k")
  end

  def test_optional_bool_string_false_raises
    err = assert_raises(E) { V.optional_bool({ "k" => "false" }, "k") }
    assert_match(/must be a boolean/, err.message)
  end

  def test_optional_bool_string_true_raises
    err = assert_raises(E) { V.optional_bool({ "k" => "true" }, "k") }
    assert_match(/must be a boolean/, err.message)
  end

  def test_optional_bool_zero_raises
    err = assert_raises(E) { V.optional_bool({ "k" => 0 }, "k") }
    assert_match(/must be a boolean/, err.message)
  end

  def test_optional_bool_one_raises
    err = assert_raises(E) { V.optional_bool({ "k" => 1 }, "k") }
    assert_match(/must be a boolean/, err.message)
  end

  def test_optional_bool_nil_string_raises
    err = assert_raises(E) { V.optional_bool({ "k" => "" }, "k") }
    assert_match(/must be a boolean/, err.message)
  end
end
