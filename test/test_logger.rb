# test/test_logger.rb — verifies client_label: keyword extension to Logger.
require "minitest/autorun"
require "stringio"

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/config"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/logger"
require_relative "support/config_reset"

class TestLogger < Minitest::Test
  def setup
    ConfigReset.reset_all!
    MCPforSketchUp::Core::Config.host      = "127.0.0.1"
    MCPforSketchUp::Core::Config.port      = 9876
    MCPforSketchUp::Core::Config.log_level = "INFO"
    @captured = StringIO.new
    @orig_stdout = $stdout
    $stdout = @captured
  end

  def teardown
    $stdout = @orig_stdout
    MCPforSketchUp::Core::Config.log_to_file = false
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

  def test_log_to_file_disabled_does_not_create_file
    require "tempfile"
    path = Tempfile.new("mcp_test_log").path
    File.delete(path) if File.exist?(path)
    MCPforSketchUp::Core::Config.log_to_file = false
    MCPforSketchUp::Core::Config.log_file_path = path
    MCPforSketchUp::Core::Logger.log("INFO", "should not be in file")
    refute File.exist?(path), "log file should not be created when log_to_file=false"
  end

  def test_log_to_file_enabled_writes_to_path
    require "tempfile"
    path = Tempfile.new("mcp_test_log").path
    File.delete(path) if File.exist?(path)
    MCPforSketchUp::Core::Config.log_to_file = true
    MCPforSketchUp::Core::Config.log_file_path = path
    begin
      MCPforSketchUp::Core::Logger.log("WARN", "hello from file mode")
      assert File.exist?(path), "log file should be created when log_to_file=true"
      contents = File.read(path)
      assert_match(/\[MCPforSU\] \[WARN\] hello from file mode/, contents)
    ensure
      File.delete(path) if File.exist?(path)
    end
  end

  def test_log_to_file_append_semantics
    require "tempfile"
    path = Tempfile.new("mcp_test_log").path
    File.delete(path) if File.exist?(path)
    MCPforSketchUp::Core::Config.log_to_file = true
    MCPforSketchUp::Core::Config.log_file_path = path
    begin
      MCPforSketchUp::Core::Logger.log("WARN", "first")
      MCPforSketchUp::Core::Logger.log("WARN", "second")
      lines = File.readlines(path).map(&:chomp)
      assert_equal 2, lines.length, "expected 2 lines, got #{lines.length}"
      assert_match(/first/,  lines[0])
      assert_match(/second/, lines[1])
    ensure
      File.delete(path) if File.exist?(path)
    end
  end

  def test_log_to_file_failure_falls_back_silently
    # Read-only path → File.open(append) raises. Logger must catch and
    # continue to console without raising upward.
    # iter-2 CONCERN-10: also pin the one-shot DEBUG fallback line that
    # design §5.2 promises — otherwise a future refactor could swallow the
    # exception without surfacing any diagnostic, and the test would still
    # pass vacuously.
    MCPforSketchUp::Core::Config.log_to_file  = true
    MCPforSketchUp::Core::Config.log_file_path = "/nonexistent/dir/x.log"
    prev_level = MCPforSketchUp::Core::Config.log_level
    MCPforSketchUp::Core::Config.log_level = "DEBUG"
    captured = StringIO.new
    orig_stdout = $stdout
    $stdout = captured
    begin
      MCPforSketchUp::Core::Logger.log("WARN", "ok")  # must not raise
    rescue StandardError => e
      flunk "Logger.log raised: #{e.class}: #{e.message}"
    ensure
      $stdout = orig_stdout
      MCPforSketchUp::Core::Config.log_level = prev_level
    end
    assert_includes captured.string, "[MCPforSU] [DEBUG] log file write failed",
      "expected design §5.2 one-shot DEBUG fallback line; got #{captured.string.inspect}"
  end
end
