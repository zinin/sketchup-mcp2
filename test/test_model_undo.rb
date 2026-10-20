# test/test_model_undo.rb
# M-08: undo goes through SketchUp's Edit -> Undo action.
#
# Sketchup::Model has no #undo, so Handlers::Model.undo dispatches
# Sketchup.send_action("editUndo:"), which pops one entry off the undo stack
# the handlers' start_operation / commit_operation build. No test ran undo at
# all: a handler that called a model method (a NoMethodError live) or sent
# another action passed every test. With no active model there is nothing to
# undo: the handler must raise -32603 and send no action.
#
# Fakes: Sketchup.send_action records what it is sent. Entities.active_model!
# answers a bare Object, which has no #undo either; the no-model test leaves
# the real one in place and makes Sketchup.active_model answer nil. The stubs
# are per test and restored by SingletonStubs; under run_all test_view.rb
# defines a send_action of its own, which that restore puts back.
require "minitest/autorun"

require_relative "support/singleton_stubs"

# Guarded: other files define their own Sketchup stub, and under run_all every
# file loads before any test runs.
module Sketchup; end unless defined?(Sketchup)

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/units"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/entities"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/model"

class TestModelUndo < Minitest::Test
  include SingletonStubs

  M  = MCPforSketchUp::Handlers::Model
  EH = MCPforSketchUp::Helpers::Entities

  def setup
    @send_action_calls = []
    # A stub body runs with self == the stubbed module, hence the local.
    calls = @send_action_calls
    stub_singleton(Sketchup, :send_action) do |action|
      calls << action
      true
    end
  end

  def test_undo_dispatches_edit_undo
    stub_singleton(EH, :active_model!) { Object.new }

    assert_equal({ "ok" => true }, M.undo({}))
    assert_equal ["editUndo:"], @send_action_calls
  end

  def test_undo_without_a_model_raises_and_sends_nothing
    stub_singleton(Sketchup, :active_model) { nil }

    err = assert_raises(MCPforSketchUp::Core::StructuredError) { M.undo({}) }

    assert_equal(-32603, err.code)
    assert_empty @send_action_calls, "with no model there is nothing to undo: no action may be sent"
  end
end
