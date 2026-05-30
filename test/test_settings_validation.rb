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

  def test_rejects_host_with_internal_whitespace
    # Edge whitespace is now stripped (see test_strips_host_edge_whitespace); an
    # INTERNAL space — e.g. an accidental "host port" paste — is still rejected.
    result = V.validate("host" => "127.0.0.1 8080", "port" => "9876", "log_level" => "INFO")
    refute result[:ok]
    assert_match(/whitespace/i, result[:errors][:host])
  end

  def test_strips_host_edge_whitespace
    # A copy-pasted address with leading/trailing whitespace is trimmed and
    # accepted; the normalized (persisted) host carries no whitespace.
    result = V.validate("host" => "  127.0.0.1  ", "port" => "9876", "log_level" => "INFO")
    assert result[:ok]
    assert_equal "127.0.0.1", result[:normalized][:host]
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

  # --- new v0.2.0 fields ---

  def test_normalizes_eval_enabled_true_string
    result = V.validate("host" => "127.0.0.1", "port" => "9876", "log_level" => "WARN",
                        "eval_enabled" => "true")
    assert result[:ok]
    assert_equal true, result[:normalized][:eval_enabled]
  end

  def test_normalizes_eval_enabled_false_string
    result = V.validate("host" => "127.0.0.1", "port" => "9876", "log_level" => "WARN",
                        "eval_enabled" => "false")
    assert result[:ok]
    assert_equal false, result[:normalized][:eval_enabled]
  end

  def test_eval_enabled_default_is_false_when_missing
    result = V.validate("host" => "127.0.0.1", "port" => "9876", "log_level" => "WARN")
    assert result[:ok]
    assert_equal false, result[:normalized][:eval_enabled]
  end

  def test_log_to_file_normalizes_boolean
    result = V.validate("host" => "127.0.0.1", "port" => "9876", "log_level" => "WARN",
                        "log_to_file" => "true", "log_file_path" => "/tmp/x.log")
    assert result[:ok]
    assert_equal true,         result[:normalized][:log_to_file]
    assert_equal "/tmp/x.log", result[:normalized][:log_file_path]
  end

  def test_log_to_file_true_requires_non_empty_path
    result = V.validate("host" => "127.0.0.1", "port" => "9876", "log_level" => "WARN",
                        "log_to_file" => "true", "log_file_path" => "")
    refute result[:ok]
    assert_match(/path/i, result[:errors][:log_file_path])
  end

  def test_log_to_file_false_allows_empty_path
    result = V.validate("host" => "127.0.0.1", "port" => "9876", "log_level" => "WARN",
                        "log_to_file" => "false", "log_file_path" => "")
    assert result[:ok]
    assert_equal false, result[:normalized][:log_to_file]
  end

  def test_log_to_file_true_rejects_path_whose_parent_dir_is_missing
    result = V.validate("host" => "127.0.0.1", "port" => "9876", "log_level" => "WARN",
                        "log_to_file" => "true", "log_file_path" => "/nonexistent_dir_xyz/app.log")
    refute result[:ok]
    assert_match(/parent directory does not exist/i, result[:errors][:log_file_path])
  end

  def test_log_to_file_true_rejects_log_path_with_null_byte
    # File.expand_path raises ArgumentError on a NUL byte; the validator must
    # surface it as a structured log_file_path error rather than raising, which
    # would otherwise bubble up as a generic _general internal error in the
    # dialog (review F4a).
    result = V.validate("host" => "127.0.0.1", "port" => "9876", "log_level" => "WARN",
                        "log_to_file" => "true", "log_file_path" => "/tmp/a\x00b.log")
    refute result[:ok]
    assert_match(/invalid log file path/i, result[:errors][:log_file_path])
  end
end
