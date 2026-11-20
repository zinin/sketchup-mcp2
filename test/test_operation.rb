# test/test_operation.rb
# M-16: Helpers::Operation.run is the one place a mutating handler opens,
# commits and aborts its undo step.
#
# The block builds the response, so the response exists before
# commit_operation (commit has been seen to invalidate the proxies of
# solid-operation results). An exception in the block — a StandardError or
# one outside StandardError — and a commit_operation that raises abort the
# operation, and the exception goes on to the caller. A block left by
# return, break or throw is aborted too, and -32603 is raised in place of
# the jump: the handler would otherwise answer with a success for edits that
# were rolled back. `next` finishes the block normally. An abort that raises
# in turn is logged at DEBUG and never hides the original error.
#
# Fakes: a recording model whose log holds [:start, label, disable_ui],
# :commit and :abort, plus whatever the block appends. Core::Logger.log is
# stubbed per test (SingletonStubs puts the original back), so the file
# needs neither the logger nor the config.
require "minitest/autorun"

require_relative "support/singleton_stubs"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"

module MCPforSketchUp
  module Core
    module Logger; end
  end
end

require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/operation"

class TestOperation < Minitest::Test
  include SingletonStubs

  Op = MCPforSketchUp::Helpers::Operation

  class RecordingModel
    attr_reader :log

    def initialize
      @log = []
    end

    def start_operation(name, disable_ui)
      @log << [:start, name, disable_ui]
      true
    end

    def commit_operation
      @log << :commit
      true
    end

    def abort_operation
      @log << :abort
      true
    end
  end

  def setup
    @model = RecordingModel.new
    @logged = []
    logged = @logged
    stub_singleton(MCPforSketchUp::Core::Logger, :log) { |level, msg| logged << [level, msg] }
  end

  def test_run_commits_after_the_block_and_returns_its_value
    value = Op.run(@model, "Label") { @model.log << :built; 42 }
    assert_equal 42, value
    assert_equal [[:start, "Label", true], :built, :commit], @model.log
  end

  def test_run_aborts_on_a_standard_error_and_reraises
    err = assert_raises(RuntimeError) { Op.run(@model, "L") { raise "boom" } }
    assert_equal "boom", err.message
    assert_equal [[:start, "L", true], :abort], @model.log
  end

  def test_run_aborts_on_an_exception_outside_standard_error
    boom = Class.new(Exception)
    assert_raises(boom) { Op.run(@model, "L") { raise boom } }
    assert_equal [[:start, "L", true], :abort], @model.log
  end

  # ---------- a block left by a jump ----------

  def assert_left_early(&jump)
    err = assert_raises(MCPforSketchUp::Core::StructuredError, &jump)
    assert_equal(-32603, err.code)
    assert_equal "internal error: 'L' left its undo step before it finished (a return, break or " \
                 "throw inside Operation.run), so its changes were rolled back", err.message
    assert_equal [[:start, "L", true], :abort], @model.log
  end

  # A handler that returns from inside its block.
  def return_from_the_block
    Op.run(@model, "L") { return :early }
    :late
  end

  def test_a_return_out_of_the_block_aborts_and_raises
    assert_left_early { return_from_the_block }
  end

  def test_a_break_out_of_the_block_aborts_and_raises
    assert_left_early { Op.run(@model, "L") { break :early } }
  end

  def test_a_throw_out_of_the_block_aborts_and_raises
    assert_left_early { catch(:out) { Op.run(@model, "L") { throw :out } } }
  end

  def test_next_finishes_the_block_and_commits
    early = true
    value = Op.run(@model, "L") do
      next :early if early

      :late
    end
    assert_equal :early, value
    assert_equal [[:start, "L", true], :commit], @model.log
  end

  def test_run_aborts_when_commit_raises
    @model.define_singleton_method(:commit_operation) { log << :commit; raise "commit failed" }
    err = assert_raises(RuntimeError) { Op.run(@model, "L") { 1 } }
    assert_equal "commit failed", err.message
    assert_equal [[:start, "L", true], :commit, :abort], @model.log
  end

  def test_a_failing_abort_does_not_hide_the_original_error
    @model.define_singleton_method(:abort_operation) { raise "abort failed" }
    err = assert_raises(RuntimeError) { Op.run(@model, "L") { raise "original" } }
    assert_equal "original", err.message
    assert_equal 1, @logged.length
    level, msg = @logged.first
    assert_equal "DEBUG", level
    assert_includes msg, "Operation.safe_abort"
    assert_includes msg, "abort failed"
  end
end
