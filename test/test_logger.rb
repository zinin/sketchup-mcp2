# test/test_logger.rb — verifies client_label: keyword extension to Logger.
require "minitest/autorun"
require "stringio"

require_relative "../su_mcp/su_mcp/core/config"
require_relative "../su_mcp/su_mcp/core/logger"

class TestLogger < Minitest::Test
  def setup
    SU_MCP::Core::Config.host      = "127.0.0.1"
    SU_MCP::Core::Config.port      = 9876
    SU_MCP::Core::Config.log_level = "INFO"
    @captured = StringIO.new
    @orig_stdout = $stdout
    $stdout = @captured
  end

  def teardown
    $stdout = @orig_stdout
  end

  def last_line
    @captured.string.lines.last.to_s.chomp
  end

  def test_log_tool_without_client_label_is_unchanged
    SU_MCP::Core::Logger.log_tool("create_component", "ok")
    assert_match(/tool=create_component status=ok\z/, last_line)
  end

  def test_log_tool_with_extra_positional_still_works
    SU_MCP::Core::Logger.log_tool("create_component", "ok", "bbox_mm=[1,2,3]")
    assert_match(/tool=create_component status=ok bbox_mm=\[1,2,3\]\z/, last_line)
  end

  def test_log_tool_with_client_label_prepends_segment
    SU_MCP::Core::Logger.log_tool("server", "client_connected",
      client_label: "#0[127.0.0.1:54321]")
    assert_match(/tool=server status=client_connected client=#0\[127\.0\.0\.1:54321\]\z/, last_line)
  end

  def test_log_tool_with_label_and_extra
    SU_MCP::Core::Logger.log_tool("server", "client_disconnected",
      "reason=write_timeout",
      client_label: "#0[127.0.0.1:54321]")
    assert_match(
      /tool=server status=client_disconnected client=#0\[127\.0\.0\.1:54321\] reason=write_timeout\z/,
      last_line)
  end

  def test_log_error_without_client_label_is_unchanged
    err = RuntimeError.new("boom")
    SU_MCP::Core::Logger.log_error("server.timer", err)
    assert_match(/tool=server\.timer class=RuntimeError msg=boom\z/, last_line)
  end

  def test_log_error_with_client_label_prepends_segment
    err = RuntimeError.new("boom")
    SU_MCP::Core::Logger.log_error("server.parse", err,
      client_label: "#1[127.0.0.1:54321]")
    assert_match(
      /tool=server\.parse client=#1\[127\.0\.0\.1:54321\] class=RuntimeError msg=boom\z/,
      last_line)
  end
end
