# test/test_config.rb
require "minitest/autorun"
require_relative "../su_mcp/su_mcp/core/config"

class TestConfig < Minitest::Test
  C = SU_MCP::Core::Config

  def test_max_message_size_constant
    assert_equal 64 * 1024 * 1024, C::MAX_MESSAGE_SIZE
  end

  def test_levels_table
    assert_equal 0, C::LEVELS["DEBUG"]
    assert_equal 1, C::LEVELS["INFO"]
    assert_equal 2, C::LEVELS["WARN"]
    assert_equal 3, C::LEVELS["ERROR"]
  end

  def test_defaults_when_env_empty
    cfg = C.read_env({})
    assert_equal 9876, cfg[:port]
    assert_equal "127.0.0.1", cfg[:host]
    assert_equal "INFO", cfg[:log_level]
  end

  def test_port_from_env
    cfg = C.read_env({ "SKETCHUP_MCP_PORT" => "8080" })
    assert_equal 8080, cfg[:port]
  end

  def test_host_from_env
    cfg = C.read_env({ "SKETCHUP_MCP_HOST" => "0.0.0.0" })
    assert_equal "0.0.0.0", cfg[:host]
  end

  def test_log_level_uppercased
    cfg = C.read_env({ "SKETCHUP_MCP_LOG_LEVEL" => "debug" })
    assert_equal "DEBUG", cfg[:log_level]
  end

  def test_level_value_known
    assert_equal 0, C.level_value_for("DEBUG")
    assert_equal 3, C.level_value_for("ERROR")
  end

  def test_level_value_unknown_falls_back_to_info
    assert_equal 1, C.level_value_for("FOO")
  end
end
