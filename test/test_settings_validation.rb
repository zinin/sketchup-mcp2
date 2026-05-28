# test/test_settings_validation.rb
require "minitest/autorun"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/ui/settings_validator"

class TestSettingsValidator < Minitest::Test
  V = MCPforSketchUp::UI::SettingsValidator

  def test_accepts_valid_payload
    result = V.validate("host" => "127.0.0.1", "port" => "9876", "log_level" => "INFO")
    assert result[:ok]
    assert_empty result[:errors]
    assert_equal "127.0.0.1", result[:normalized][:host]
    assert_equal 9876,        result[:normalized][:port]
    assert_equal "INFO",      result[:normalized][:log_level]
  end

  def test_accepts_bind_all_host
    result = V.validate("host" => "0.0.0.0", "port" => "9876", "log_level" => "INFO")
    assert result[:ok]
  end

  def test_accepts_localhost_string
    result = V.validate("host" => "localhost", "port" => "9876", "log_level" => "INFO")
    assert result[:ok]
  end

  def test_rejects_empty_host
    result = V.validate("host" => "", "port" => "9876", "log_level" => "INFO")
    refute result[:ok]
    assert_match(/empty/i, result[:errors][:host])
  end

  def test_rejects_host_with_whitespace
    result = V.validate("host" => "127.0.0.1 ", "port" => "9876", "log_level" => "INFO")
    refute result[:ok]
    assert_match(/whitespace/i, result[:errors][:host])
  end

  def test_rejects_host_too_long
    result = V.validate("host" => "a" * 254, "port" => "9876", "log_level" => "INFO")
    refute result[:ok]
    assert_match(/long/i, result[:errors][:host])
  end

  def test_rejects_host_with_invalid_characters
    result = V.validate("host" => "127.0.0.1/foo", "port" => "9876", "log_level" => "INFO")
    refute result[:ok]
    assert_match(/invalid characters/i, result[:errors][:host])
  end

  def test_accepts_ipv6_unbracketed
    result = V.validate("host" => "::1", "port" => "9876", "log_level" => "INFO")
    assert result[:ok]
  end

  def test_rejects_non_numeric_port
    result = V.validate("host" => "127.0.0.1", "port" => "abc", "log_level" => "INFO")
    refute result[:ok]
    assert_includes result[:errors][:port], "1 and 65535"
  end

  def test_rejects_port_zero
    result = V.validate("host" => "127.0.0.1", "port" => "0", "log_level" => "INFO")
    refute result[:ok]
    assert_includes result[:errors][:port], "1 and 65535"
  end

  def test_rejects_port_above_max
    result = V.validate("host" => "127.0.0.1", "port" => "65536", "log_level" => "INFO")
    refute result[:ok]
    assert_includes result[:errors][:port], "1 and 65535"
  end

  def test_rejects_unknown_log_level
    result = V.validate("host" => "127.0.0.1", "port" => "9876", "log_level" => "TRACE")
    refute result[:ok]
    assert_match(/invalid/i, result[:errors][:log_level])
  end

  def test_accepts_lowercase_log_level_and_normalizes
    result = V.validate("host" => "127.0.0.1", "port" => "9876", "log_level" => "debug")
    assert result[:ok]
    assert_equal "DEBUG", result[:normalized][:log_level]
  end

  def test_normalizes_port_string_to_integer
    result = V.validate("host" => "127.0.0.1", "port" => "443", "log_level" => "INFO")
    assert result[:ok]
    assert_kind_of Integer, result[:normalized][:port]
    assert_equal 443, result[:normalized][:port]
  end

  def test_rejects_non_hash_payload
    [nil, [], "string", 42, true].each do |bad|
      result = V.validate(bad)
      refute result[:ok], "expected #{bad.inspect} to be rejected"
      assert_equal "Bad payload format", result[:errors][:_general]
    end
  end

  def test_rejects_port_float_string
    result = V.validate("host" => "127.0.0.1", "port" => "9876.0", "log_level" => "INFO")
    refute result[:ok]
    assert_includes result[:errors][:port], "1 and 65535"
  end

  def test_rejects_port_with_surrounding_whitespace
    result = V.validate("host" => "127.0.0.1", "port" => "  9876  ", "log_level" => "INFO")
    refute result[:ok]
    assert_includes result[:errors][:port], "1 and 65535"
  end

  def test_rejects_host_with_null_byte
    result = V.validate("host" => "127.0.0.1\x00", "port" => "9876", "log_level" => "INFO")
    refute result[:ok]
    assert_match(/invalid characters/i, result[:errors][:host])
  end
end
