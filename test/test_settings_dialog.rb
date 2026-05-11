# test/test_settings_dialog.rb
require "minitest/autorun"
require "json"
require_relative "../su_mcp/su_mcp/core/config"
require_relative "../su_mcp/su_mcp/ui/settings_dialog"

# Focused on the only pure function in SettingsDialog: js_safe_json.
# show / on_load_state / on_save depend on UI::HtmlDialog (SketchUp Ruby API),
# which is not available outside SketchUp; covering them requires integration
# tests, not unit tests.
class TestSettingsDialogJsSafeJson < Minitest::Test
  S = SU_MCP::UI::SettingsDialog

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
