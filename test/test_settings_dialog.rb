# test/test_settings_dialog.rb
require "minitest/autorun"
require "json"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/config"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/logger"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/net"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/application"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/ui/settings_dialog"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/ui/settings_validator"
require_relative "support/config_reset"
require_relative "support/singleton_stubs"

# --- Minimal SketchUp API stubs for the on_save eval-confirm tests below. ---
# on_save defers work via UI.start_timer and persists via Config.update!
# (writer: Sketchup). Stub just that slice, guarded with `unless defined?` /
# `respond_to?` so this file runs standalone (`ruby test/test_settings_dialog.rb`)
# AND under run_all.rb, where test_application.rb may already define UI/Sketchup.
module UI; end unless defined?(UI)
unless UI.respond_to?(:start_timer)
  # Run the deferred block inline so the two-phase confirm flow is observable
  # without a real SketchUp event loop.
  def UI.start_timer(_seconds, _repeat = false, &blk)
    blk.call if blk
    nil
  end
end
SKETCHUP_CONSOLE = nil unless defined?(SKETCHUP_CONSOLE)
# SketchUp's messagebox constants (MB_YESNO = 4, IDYES = 6), for the confirms.
MB_YESNO = 4 unless defined?(MB_YESNO)
IDYES    = 6 unless defined?(IDYES)

module Sketchup; end unless defined?(Sketchup)
unless Sketchup.respond_to?(:mcp_test_write_result)
  # write_default returns a per-test-controllable result, so a test can drive
  # Config.update! down both its success path and its raise (write→false) path.
  Sketchup.singleton_class.send(:attr_accessor, :mcp_test_write_result)
  Sketchup.mcp_test_write_result = true
  def Sketchup.write_default(_section, _key, _value)
    mcp_test_write_result
  end
end

# Focused on the pure function js_safe_json. (on_save's eval-confirm flow is
# covered separately below via the UI/Sketchup stubs above; show / build_dialog
# construct a real UI::HtmlDialog and still require integration tests.)
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
# `eval_enabled?` predicate, NOT the raw accessor — so an unread pref
# resolves to the effective default, never leaking `nil` to the UI.
class TestSettingsDialogLoadStatePayload < Minitest::Test
  S = MCPforSketchUp::UI::SettingsDialog

  def setup
    ConfigReset.reset_all!
    MCPforSketchUp::Core::Config.host         = "127.0.0.1"
    MCPforSketchUp::Core::Config.port         = 9876
    MCPforSketchUp::Core::Config.log_level    = "INFO"
  end

  def teardown
    ConfigReset.reset_all!
  end

  # Предикатная гарантия (iter-1 CRITICAL-2): :eval_enabled в payload берётся
  # из `eval_enabled?`, а не из сырого аксессора — не прочитанный pref обязан
  # прийти в UI как эффективное булево, иначе чекбокс останется в
  # неопределённом состоянии.
  def test_eval_enabled_is_effective_default_not_nil_when_unset
    assert_nil MCPforSketchUp::Core::Config.eval_enabled,
               "precondition: raw accessor should be nil (nothing loaded yet)"

    payload = S.load_state_payload
    assert_equal MCPforSketchUp::Core::Config::DEFAULTS[:eval_enabled],
                 payload[:eval_enabled],
                 "must be the effective default (eval_enabled?), not the raw nil accessor"
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

  # Spec §7.1, §7.3: the dialog shows the token, and warns about a host that is
  # not loopback from the first paint (Core::Net, the server's check).
  def test_payload_carries_the_token_and_the_loopback_flag
    MCPforSketchUp::Core::Config.token = "0123456789abcdef" * 4
    MCPforSketchUp::Core::Config.host  = "192.168.1.5"
    payload = S.load_state_payload
    assert_equal "0123456789abcdef" * 4, payload[:token]
    assert_equal false, payload[:host_loopback]
    MCPforSketchUp::Core::Config.host = "127.0.0.1"
    assert_equal true, S.load_state_payload[:host_loopback]
  end
end

# Spec §7.1: Regenerate asks, saves a new token, closes every client and shows
# the new token; a failed save keeps the old token, and its clients. Spec §7.3:
# the host warning comes from the Ruby loopback check, which JavaScript cannot
# run (names must be resolved).
class TestSettingsDialogToken < Minitest::Test
  include SingletonStubs

  S   = MCPforSketchUp::UI::SettingsDialog
  C   = MCPforSketchUp::Core::Config
  A   = MCPforSketchUp::Core::Application
  OLD = ("0123456789abcdef" * 4).freeze
  NEW = ("f" * 64).freeze

  class FakeDialog
    attr_reader :scripts

    def initialize
      @scripts = []
    end

    def execute_script(script)
      @scripts << script
    end

    def script_text
      @scripts.join("\n")
    end
  end

  def setup
    ConfigReset.reset_all!
    C.host          = "127.0.0.1"
    C.port          = 9876
    C.log_level     = "INFO"
    C.log_to_file   = false
    C.log_file_path = ""
    C.eval_enabled  = false
    C.token         = OLD
    @disconnected = []
    disconnected = @disconnected
    stub_singleton(A, :disconnect_clients) { |reason| disconnected << reason }
  end

  def teardown
    ConfigReset.reset_all!
  end

  def regenerate(answer:, &save)
    save ||= -> { C.token = NEW }
    stub_singleton(S, :confirm_regenerate) { answer }
    stub_singleton(C, :regenerate_token!, &save)
    dialog = FakeDialog.new
    S.on_regenerate_token(dialog)
    dialog
  end

  def test_regenerate_yes_saves_disconnects_and_refreshes
    dialog = regenerate(answer: true)
    assert_equal NEW, C.token
    assert_equal ["token_regenerated"], @disconnected
    assert_includes dialog.script_text, 'window.onTokenResult({"ok":true})'
    assert_includes dialog.script_text, "window.applyState("
    assert_includes dialog.script_text, NEW, "the dialog shows the new token"
  end

  def test_regenerate_no_changes_nothing
    dialog = regenerate(answer: false)
    assert_equal OLD, C.token
    assert_empty @disconnected
    assert_empty dialog.scripts
  end

  def test_regenerate_save_failure_reports_and_keeps_the_token
    dialog = regenerate(answer: true) { raise "Sketchup.write_default failed for auth_token" }
    assert_equal OLD, C.token
    assert_empty @disconnected, "the old token still works, so its clients stay"
    assert_includes dialog.script_text,
      'window.onTokenResult({"ok":false,"error":"Could not save the new token: Sketchup.write_default failed for auth_token"})'
  end

  def test_regenerate_confirm_says_who_is_disconnected
    text = nil
    stub_singleton(::UI, :messagebox) { |message, *_| text = message; ::IDYES }
    assert S.confirm_regenerate
    assert_includes text, "Every connected MCP client is disconnected now"
    assert_includes text, "SKETCHUP_MCP_TOKEN"
  end

  def test_check_host_answers_on_host_check
    dialog = FakeDialog.new
    S.on_check_host(dialog, "192.168.1.5")
    assert_equal ['window.onHostCheck({"host":"192.168.1.5","loopback":false})'], dialog.scripts
  end

  def test_eval_confirm_mentions_the_token
    text = nil
    stub_singleton(::UI, :messagebox) { |message, *_| text = message; ::IDYES }
    assert S.confirm_eval_enable
    assert_includes text, "any MCP client that has the token"
    assert_includes text, "the traffic itself is not encrypted"
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

# on_save's two-phase eval-confirm flow (settings_dialog.rb:107-138) is the
# security boundary that gates Ruby evaluation. Codex (4th external review)
# flagged it as having no automated coverage. These tests drive the three
# branches — decline, confirm, and an exception inside the deferred timer —
# using the synchronous UI.start_timer stub above and a per-test confirm answer,
# asserting the gate's fail-closed guarantees rather than only the happy path.
class TestSettingsDialogOnSaveEvalConfirm < Minitest::Test
  S = MCPforSketchUp::UI::SettingsDialog
  C = MCPforSketchUp::Core::Config

  # Duck-typed dialog: records execute_script payloads and close().
  class FakeDialog
    attr_reader :scripts, :closed
    def initialize
      @scripts = []
      @closed  = false
    end

    def execute_script(script)
      @scripts << script
    end

    def close
      @closed = true
    end

    def script_text
      @scripts.join("\n")
    end
  end

  def setup
    ConfigReset.reset_all!
    C.host          = "127.0.0.1"
    C.port          = 9876
    C.log_level     = "INFO"
    C.log_to_file   = false
    C.log_file_path = ""
    C.eval_enabled  = false        # gate OFF ⇒ saving eval=on is an off→on transition
    Sketchup.mcp_test_write_result = true
    S.instance_variable_set(:@dialog, nil)
  end

  def teardown
    ConfigReset.reset_all!
    Sketchup.mcp_test_write_result = true
    S.instance_variable_set(:@dialog, nil)
  end

  # Valid dialog payload that asks to enable eval.
  def eval_on_payload
    JSON.generate(
      "host"          => "127.0.0.1",
      "port"          => 9876,
      "log_level"     => "INFO",
      "eval_enabled"  => true,
      "log_to_file"   => false,
      "log_file_path" => "",
    )
  end

  # Temporarily force confirm_eval_enable's answer, restoring the original after.
  def with_confirm_answer(answer)
    original = S.method(:confirm_eval_enable)
    S.define_singleton_method(:confirm_eval_enable) { answer }
    yield
  ensure
    S.define_singleton_method(:confirm_eval_enable, original)
  end

  def test_declining_the_confirm_keeps_the_gate_closed_and_reverts_ui
    dialog = FakeDialog.new
    with_confirm_answer(false) { S.on_save(dialog, eval_on_payload) }

    assert_equal false, C.eval_enabled, "declining must leave the eval gate closed"
    refute C.eval_enabled?,             "eval_enabled? must stay false after a decline"
    assert_includes dialog.script_text, "Cancelled",
      "the user must see that nothing was saved"
    assert_includes dialog.script_text, "applyState",
      "the form must be reverted to the saved state"
    refute dialog.closed, "the dialog must stay open after a decline"
  end

  def test_confirming_opens_the_gate_and_persists
    dialog = FakeDialog.new
    with_confirm_answer(true) { S.on_save(dialog, eval_on_payload) }

    assert_equal true, C.eval_enabled, "confirming must open the eval gate"
    assert_includes dialog.script_text, "\"ok\":true",
      "a successful save result must be pushed to the dialog"
    refute_includes dialog.script_text, "_general",
      "no internal error should be reported on a successful save"
    assert dialog.closed, "the dialog should close after a successful save"
  end

  def test_exception_in_timer_is_rescued_and_gate_fails_closed
    dialog = FakeDialog.new
    # Make Config.update! raise (write_default → false on the first key) AFTER the
    # user confirmed, exercising the in-timer rescue (settings_dialog.rb:133).
    Sketchup.mcp_test_write_result = false

    capture_io do
      with_confirm_answer(true) do
        # Must not propagate out of on_save — the in-timer rescue handles it.
        S.on_save(dialog, eval_on_payload)
      end
    end

    assert_equal false, C.eval_enabled,
      "a failed persist must roll back — the eval gate must never be left open"
    assert_includes dialog.script_text, "Internal error",
      "the failure must surface to the dialog as a general error"
    assert_includes dialog.script_text, "applyState",
      "the form must be reverted after an error"
  end

  def test_no_confirm_is_shown_when_eval_is_already_enabled
    C.eval_enabled = true   # already on ⇒ saving eval=on is NOT an off→on transition
    dialog = FakeDialog.new

    confirm_shown = false
    original = S.method(:confirm_eval_enable)
    S.define_singleton_method(:confirm_eval_enable) { confirm_shown = true; true }
    begin
      S.on_save(dialog, eval_on_payload)
    ensure
      S.define_singleton_method(:confirm_eval_enable, original)
    end

    refute confirm_shown, "no security confirm should appear when eval is already enabled"
    assert_equal true, C.eval_enabled, "eval stays enabled"
    assert dialog.closed, "the dialog should close after a normal save"
  end

  # Штатный путь поставки 0.3.1: pref не сохраняли ни разу, сырой аксессор nil,
  # эффективное состояние берётся из DEFAULTS[:eval_enabled]. Перехода off→on
  # поэтому нет, и блокирующий confirm не показывается — ни на свежей установке,
  # ни при апгрейде поверх сборки, где гейт был закрыт. Раньше это покрывалось
  # только для load_state_payload; здесь пиннится сама ветка confirm'а, чтобы
  # возврат nil-ветки eval_enabled? в fail-closed не прошёл молча.
  def test_no_confirm_is_shown_when_the_pref_was_never_saved
    C.eval_enabled = nil    # ничего не загружено ⇒ действует shipped default
    assert C.eval_enabled?, "precondition: непрочитанный pref обязан дать открытый дефолт"
    dialog = FakeDialog.new

    confirm_shown = false
    original = S.method(:confirm_eval_enable)
    S.define_singleton_method(:confirm_eval_enable) { confirm_shown = true; true }
    begin
      S.on_save(dialog, eval_on_payload)
    ensure
      S.define_singleton_method(:confirm_eval_enable, original)
    end

    refute confirm_shown,
      "несохранённый pref резолвится в открытый дефолт, поэтому сохранение " \
      "eval=on переходом off→on не является и confirm не показывает"
    assert_equal true, C.eval_enabled, "гейт остаётся открытым"
    assert dialog.closed, "the dialog should close after a normal save"
  end
end

# The warning under the "Enable Ruby evaluation" checkbox (#eval-warning in
# settings.html) is what the user reads before saving the setting on or off. It
# is HTML, so nothing else runs it; the confirm shown on an off→on save is
# pinned the same way in test_eval_gate.rb (TestConfirmEvalEnable). Its
# wording stays true to what the gate does: who can reach the port, what they
# get, and that it is on until the user unchecks it.
class TestSettingsHtmlEvalWarning < Minitest::Test
  S = MCPforSketchUp::UI::SettingsDialog
  C = MCPforSketchUp::Core::Config

  # The text of the #eval-warning div, tags dropped and whitespace collapsed.
  def eval_warning_text
    html = File.read(S::HTML_PATH, encoding: "UTF-8")
    div = html[%r{<div[^>]*\bid="eval-warning"[^>]*>(.*?)</div>}m, 1]
    refute_nil div, "settings.html has no #eval-warning div"
    div.gsub(/<[^>]*>/, "").gsub(/\s+/, " ").strip
  end

  # Block C: a client needs the token, so the gate is open to any MCP client
  # that has it — not to any process that reaches the port.
  def test_eval_warning_says_who_can_connect_and_what_they_get
    text = eval_warning_text
    assert_match(/any MCP client that has the token/, text, "the warning must say who can use the gate")
    assert_match(/arbitrary Ruby/, text, "the warning must say what the gate lets run")
    assert_match(/file and shell access/, text, "the warning must say what eval grants")
  end

  # Spec §7.1: the token row is read-only (the user copies or regenerates it,
  # never types it), and the host warning asks Ruby (spec §7.3).
  def test_the_token_row_and_the_host_check
    html = File.read(S::HTML_PATH, encoding: "UTF-8")
    assert_match(/<input type="text" id="token" readonly/, html)
    assert_match(/id="btn-copy-token"/, html)
    assert_match(/id="btn-regenerate-token"/, html)
    assert_includes html, "sketchup.regenerate_token()"
    assert_includes html, "sketchup.check_host("
    refute_includes html, "isWildcard", "the wildcard-only JavaScript check is gone"
  end

  def test_eval_warning_states_the_shipped_default
    state = C::DEFAULTS[:eval_enabled] ? "ON" : "OFF"
    assert_includes eval_warning_text, "#{state} by default",
      "the warning must state the default of Config::DEFAULTS[:eval_enabled] (#{state})"
  end
end
