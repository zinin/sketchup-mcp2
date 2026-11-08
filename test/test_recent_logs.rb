require "minitest/autorun"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/config"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/logger"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/ui/settings_dialog"
require_relative "support/config_reset"

class TestRecentLogs < Minitest::Test
  L = MCPforSketchUp::Core::Logger

  def setup
    ConfigReset.reset_all!
    MCPforSketchUp::Core::Config.log_level = "DEBUG"
    MCPforSketchUp::Core::Config.log_to_file = false
    @cursor = L.recent_logs[:cursor]
  end

  def teardown
    ConfigReset.reset_all!
  end

  def test_cursor_delivers_new_entries_once_with_severity
    capture_io { L.log("WARN", "live warning") }
    payload = L.recent_logs(@cursor)

    assert_equal(1, payload[:entries].size)
    assert_equal("WARN", payload[:entries].first[:level])
    assert_includes(payload[:entries].first[:text], "live warning")
    assert_empty(L.recent_logs(payload[:cursor])[:entries])
  end

  def test_history_and_entry_size_are_bounded
    capture_io { 205.times { |i| L.log("INFO", "event #{i} " + "x" * 5000) } }
    payload = L.recent_logs(@cursor)

    assert_equal(200, payload[:entries].size)
    assert_includes(payload[:entries].first[:text], "event 5 ")
    assert(payload[:entries].all? { |entry| entry[:text].length <= 4000 })
    assert_equal(@cursor + 205, payload[:cursor])
  end

  def test_saved_severity_filter_applies_before_capture
    MCPforSketchUp::Core::Config.log_level = "ERROR"
    capture_io do
      L.log("INFO", "hidden")
      L.log("ERROR", "visible")
    end

    assert_equal(["ERROR"], L.recent_logs(@cursor)[:entries].map { |entry| entry[:level] })
  end

  def test_invalid_cursor_can_recover
    assert_kind_of(Array, L.recent_logs("invalid")[:entries])
    assert_kind_of(Array, L.recent_logs(-1)[:entries])
  end

  def test_dialog_serializes_log_text_without_executing_markup
    capture_io { L.log("ERROR", "</script><script>alert(1)</script>") }
    scripts = []
    dialog = Object.new
    dialog.define_singleton_method(:execute_script) { |script| scripts << script }
    MCPforSketchUp::UI::SettingsDialog.on_load_logs(dialog, @cursor)

    refute_includes(scripts.first, "</script>")
    assert_includes(scripts.first, "window.appendLogs(")
  end

  def test_a_closed_dialog_does_not_raise
    dialog = Object.new
    dialog.define_singleton_method(:execute_script) { |_script| raise IOError, "closed" }

    assert_nil(MCPforSketchUp::UI::SettingsDialog.on_load_logs(dialog, @cursor))
  end
end
