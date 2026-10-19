# test/test_eval_gate.rb
# M-08: the eval gate, and the confirm that opens it.
#
# eval_ruby runs arbitrary Ruby, so two things guard it, and a mutant of each
# passed every test:
#   * Eval.eval_ruby must refuse with -32010 BEFORE it evaluates anything. With
#     the check moved below the eval, a closed gate still ran the code while
#     the client was told "disabled".
#   * Settings' confirm_eval_enable must be true only when the user answers
#     Yes. Every on_save test stubs it, so its body never ran and a confirm
#     that always said yes went unnoticed.
#
# The gate tests call Eval.eval_ruby with code that sets a global, so whether
# the code ran is observable. The global and Config.eval_enabled go back in
# teardown. The confirm tests run the REAL confirm_eval_enable against a
# stubbed ::UI.messagebox that answers from a queue and records what it was
# shown as [text, buttons] in @messageboxes, which is where a test that pins
# the warning's wording reads it. The stub is saved and restored in teardown.
require "minitest/autorun"

# Guarded: other files define their own UI stub, and under run_all every file
# loads before any test runs. The values are SketchUp's.
module UI; end unless defined?(UI)
MB_YESNO = 4 unless defined?(MB_YESNO)
IDYES    = 6 unless defined?(IDYES)
IDNO     = 7 unless defined?(IDNO)

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/config"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/eval"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/ui/settings_dialog"

class TestEvalGate < Minitest::Test
  Config          = MCPforSketchUp::Core::Config
  Eval            = MCPforSketchUp::Handlers::Eval
  StructuredError = MCPforSketchUp::Core::StructuredError

  def setup
    @saved_eval = Config.eval_enabled   # the raw accessor: nil is "never read"
    $mcp_eval_probe = nil
  end

  def teardown
    Config.eval_enabled = @saved_eval
    $mcp_eval_probe = nil
  end

  # The code sets a global, so a closed gate that evaluated before it refused
  # shows here, not only in the error code.
  def test_closed_gate_does_not_run_the_code
    Config.eval_enabled = false

    err = assert_raises(StructuredError) { Eval.eval_ruby("code" => "$mcp_eval_probe = :ran") }

    assert_equal(-32010, err.code)
    assert_nil $mcp_eval_probe, "a refused call must not have evaluated the code"
  end

  def test_open_gate_runs_the_code
    Config.eval_enabled = true

    Eval.eval_ruby("code" => "$mcp_eval_probe = :ran")

    assert_equal :ran, $mcp_eval_probe
  end
end

class TestConfirmEvalEnable < Minitest::Test
  SettingsDialog = MCPforSketchUp::UI::SettingsDialog

  def setup
    @stubs = []
    @messageboxes = []   # [text, buttons] of every box shown
    @answers = []        # what the next boxes answer, oldest first
    # A stub body runs with self == the stubbed module, hence the locals.
    shown, answers = @messageboxes, @answers
    stub_singleton(::UI, :messagebox) do |text, buttons = nil|
      shown << [text, buttons]
      answers.shift
    end
  end

  def teardown
    @stubs.reverse_each do |mod, name, original|
      mod.singleton_class.send(:remove_method, name)
      mod.define_singleton_method(name, original) if original
    end
  end

  # Replaces mod.name for one test. The original Method goes back in
  # teardown; a method that did not exist is removed again. Removing before
  # redefining keeps `ruby -w` free of "method redefined" warnings.
  def stub_singleton(mod, name, &body)
    original = mod.respond_to?(name) ? mod.method(name) : nil
    mod.singleton_class.send(:remove_method, name) if original
    @stubs << [mod, name, original]
    mod.define_singleton_method(name, &body)
  end

  # What the real confirm_eval_enable returns when the user answers `answer`.
  def confirm_answering(answer)
    @answers << answer
    SettingsDialog.confirm_eval_enable
  end

  def test_confirm_eval_enable_is_true_only_on_yes
    assert_equal true,  confirm_answering(::IDYES)
    assert_equal false, confirm_answering(::IDNO)
    assert_equal false, confirm_answering(nil)   # a box that answers nothing is not a Yes

    text, buttons = @messageboxes.last
    assert_equal ::MB_YESNO, buttons, "the confirm must ask Yes or No"
    assert_includes text, "filesystem", "the confirm must say what eval grants"
  end
end
