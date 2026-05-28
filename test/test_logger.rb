# test/test_logger.rb — verifies client_label: keyword extension to Logger.
require "minitest/autorun"
require "stringio"

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/config"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/logger"

class TestLogger < Minitest::Test
  def setup
    MCPforSketchUp::Core::Config.host      = "127.0.0.1"
    MCPforSketchUp::Core::Config.port      = 9876
    MCPforSketchUp::Core::Config.log_level = "INFO"
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

  def captured_lines
    @captured.string.lines.map(&:chomp)
  end

  def test_log_tool_without_client_label_is_unchanged
    MCPforSketchUp::Core::Logger.log_tool("create_component", "ok")
    assert_match(/tool=create_component status=ok\z/, last_line)
  end

  def test_log_tool_with_extra_positional_still_works
    MCPforSketchUp::Core::Logger.log_tool("create_component", "ok", "bbox_mm=[1,2,3]")
    assert_match(/tool=create_component status=ok bbox_mm=\[1,2,3\]\z/, last_line)
  end

  def test_log_tool_with_client_label_prepends_segment
    MCPforSketchUp::Core::Logger.log_tool("server", "client_connected",
      client_label: "#0[127.0.0.1:54321]")
    assert_match(/tool=server status=client_connected client=#0\[127\.0\.0\.1:54321\]\z/, last_line)
  end

  def test_log_tool_with_label_and_extra
    MCPforSketchUp::Core::Logger.log_tool("server", "client_disconnected",
      "reason=write_timeout",
      client_label: "#0[127.0.0.1:54321]")
    assert_match(
      /tool=server status=client_disconnected client=#0\[127\.0\.0\.1:54321\] reason=write_timeout\z/,
      last_line)
  end

  def test_log_error_without_client_label_is_unchanged
    err = RuntimeError.new("boom")
    MCPforSketchUp::Core::Logger.log_error("server.timer", err)
    assert_match(/tool=server\.timer class=RuntimeError msg=boom\z/, last_line)
  end

  def test_log_error_with_client_label_prepends_segment
    err = RuntimeError.new("boom")
    MCPforSketchUp::Core::Logger.log_error("server.parse", err,
      client_label: "#1[127.0.0.1:54321]")
    assert_match(
      /tool=server\.parse client=#1\[127\.0\.0\.1:54321\] class=RuntimeError msg=boom\z/,
      last_line)
  end

  def test_log_line_includes_extension_prefix
    MCPforSketchUp::Core::Logger.log("INFO", "hello")
    assert_match(/ \[MCPforSU\] \[INFO\] hello\z/, last_line)
  end

  def test_default_log_level_is_warn_in_config_defaults
    assert_equal "WARN", MCPforSketchUp::Core::Config::DEFAULTS[:log_level]
  end

  def test_log_error_backtrace_lines_carry_prefix
    prev_level = MCPforSketchUp::Core::Config.log_level
    MCPforSketchUp::Core::Config.log_level = "DEBUG"
    begin
      raise "boom"
    rescue StandardError => e
      MCPforSketchUp::Core::Logger.log_error("test_tag", e)
    end
    bt_lines = captured_lines.grep(/test_logger\.rb/)  # backtrace mentions this file
    refute_empty bt_lines, "expected backtrace lines in captured output"
    bt_lines.each do |line|
      assert_includes line, "[MCPforSU]",
        "backtrace line missing prefix: #{line.inspect}"
    end
  ensure
    MCPforSketchUp::Core::Config.log_level = prev_level
  end
end
