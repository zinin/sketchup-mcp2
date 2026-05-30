# test/test_settings_dialog.rb
require "minitest/autorun"
require "json"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/config"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/logger"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/application"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/ui/settings_dialog"
require_relative "support/config_reset"

# Focused on the only pure function in SettingsDialog: js_safe_json.
# show / on_load_state / on_save depend on UI::HtmlDialog (SketchUp Ruby API),
# which is not available outside SketchUp; covering them requires integration
# tests, not unit tests.
class TestSettingsDialogJsSafeJson < Minitest::Test
  S = MCPforSketchUp::UI::SettingsDialog

  def test_passes_through_plain_payload
    out = S.js_safe_json({ host: "127.0.0.1", port: 9876, log_level: "INFO" })
    assert_equal(
      { "host" => "127.0.0.1", "port" => 9876, "log_level" => "INFO" },
      JSON.parse(out)
    )
  end

  def test_escapes_script_close_to_prevent_html_breakout
    # Without escaping `</`, embedding the JSON literal inside <script>…</script>
    # could prematurely close the script tag. We turn `</` into `<\/`.
    out = S.js_safe_json({ payload: "</script>" })
    refute_includes out, "</script>"
    assert_includes out, "<\\/script>"
    # Still valid JSON.
    assert_equal "</script>", JSON.parse(out)["payload"]
  end

  def test_escapes_line_separator_u2028
    out = S.js_safe_json({ s: "before after" })
    refute_includes out, " "
    assert_includes out, "\\u2028"
  end

  def test_escapes_paragraph_separator_u2029
    out = S.js_safe_json({ s: "before after" })
    refute_includes out, " "
    assert_includes out, "\\u2029"
  end

  def test_handles_nested_arrays_and_hashes
    payload = { errors: { host: "bad", _general: ["one", "two"] }, ok: false }
    parsed  = JSON.parse(S.js_safe_json(payload))
    assert_equal false,        parsed["ok"]
    assert_equal "bad",        parsed["errors"]["host"]
    assert_equal %w[one two],  parsed["errors"]["_general"]
  end
end

# load_state_payload is a pure data-builder (no UI::HtmlDialog dependency),
# so it is unit-testable. It reads Config + Application state. The key
# guarantee (iter-1 CRITICAL-2): :eval_enabled is sourced from the
# `eval_enabled?` predicate, NOT the raw accessor — so a sentinel-nil
# unset pref resolves to the effective `false`, never leaks `nil` to the UI.
class TestSettingsDialogLoadStatePayload < Minitest::Test
  S = MCPforSketchUp::UI::SettingsDialog

  def setup
    ConfigReset.reset_all!
    # Order-independence: ensure no BuildProfile lingers from another test
    # file in the same run_all.rb process, so eval_enabled? falls through to
    # the safe warehouse default of `false`.
    if MCPforSketchUp::Core.const_defined?(:BuildProfile)
      MCPforSketchUp::Core.send(:remove_const, :BuildProfile)
    end
    MCPforSketchUp::Core::Config.host         = "127.0.0.1"
    MCPforSketchUp::Core::Config.port         = 9876
    MCPforSketchUp::Core::Config.log_level    = "INFO"
  end

  def teardown
    ConfigReset.reset_all!
  end

  # CRITICAL-2 predicate: unset pref (nil) + no BuildProfile => effective
  # false, never nil. Proves load_state_payload uses eval_enabled?, not the
  # raw `eval_enabled` accessor (which would be nil here).
  def test_eval_enabled_is_effective_false_not_nil_when_unset
    assert_nil MCPforSketchUp::Core::Config.eval_enabled,
               "precondition: raw accessor should be nil (sentinel-unset)"
    refute MCPforSketchUp::Core.const_defined?(:BuildProfile),
           "precondition: no BuildProfile loaded"

    payload = S.load_state_payload
    assert_equal false, payload[:eval_enabled],
                 "must be effective `false` (eval_enabled?), not the raw nil accessor"
    refute_nil payload[:eval_enabled]
  end

  # The new logging fields must be present in the payload so applyState can
  # populate the log_to_file checkbox and log_file_path input.
  def test_payload_includes_new_logging_keys
    MCPforSketchUp::Core::Config.log_to_file   = true
    MCPforSketchUp::Core::Config.log_file_path = "/tmp/mcp.log"

    payload = S.load_state_payload
    assert payload.key?(:log_to_file),   "payload must include :log_to_file"
    assert payload.key?(:log_file_path), "payload must include :log_file_path"
    assert_equal true,           payload[:log_to_file]
    assert_equal "/tmp/mcp.log", payload[:log_file_path]
  end
end

# close_dialog_safely (review #3): resets the @dialog singleton even when
# dialog.close raises, so the next show() never probes .visible? on a dead
# object. Driven directly with a duck-typed dialog (no UI::HtmlDialog needed).
class TestSettingsDialogCloseSafely < Minitest::Test
  S = MCPforSketchUp::UI::SettingsDialog

  # Duck-typed dialog: records whether close was called; optionally raises.
  class FakeDialog
    attr_reader :closed
    def initialize(raise_on_close: false)
      @raise_on_close = raise_on_close
      @closed = false
    end

    def close
      @closed = true
      raise "boom from close" if @raise_on_close
    end
  end

  def teardown
    # Don't leak the stubbed @dialog into other SettingsDialog tests.
    S.instance_variable_set(:@dialog, nil)
  end

  def test_resets_dialog_and_swallows_exception_when_close_raises
    dialog = FakeDialog.new(raise_on_close: true)
    S.instance_variable_set(:@dialog, dialog)

    # Must not propagate the exception out of the timer callback.
    S.send(:close_dialog_safely, dialog)

    assert dialog.closed, "close should still have been attempted"
    assert_nil S.instance_variable_get(:@dialog),
      "@dialog must be reset to nil even when close raised (ensure block)"
  end

  def test_closes_and_resets_dialog_on_success
    dialog = FakeDialog.new(raise_on_close: false)
    S.instance_variable_set(:@dialog, dialog)

    S.send(:close_dialog_safely, dialog)

    assert dialog.closed, "close should have been called"
    assert_nil S.instance_variable_get(:@dialog), "@dialog must be reset to nil"
  end
end
