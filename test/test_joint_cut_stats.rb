# test/test_joint_cut_stats.rb
#
# Behavioural tests for the boolean-cut failure tracking added to joints.rb
# (codex review). The four joint builders must NOT report success for a joint
# that produced no geometry: a COMPLETE no-op (every Group#subtract returned
# nil) now raises, and partial failures are surfaced via joint_cut_stats. We
# exercise the tracking helpers in isolation with a duck-typed cutter — the
# full geometry path needs a live SketchUp model.
require "minitest/autorun"

# joints.rb aliases these at load time (V/E/U). The cut-tracking helpers under
# test don't touch them, so empty stubs suffice; reopening is harmless if the
# real helper modules are also loaded by another test in the same process.
module MCPforSketchUp
  module Helpers
    module Validation; end
    module Entities; end
    module Units; end
  end
end
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/joints"

class TestJointCutStats < Minitest::Test
  J = MCPforSketchUp::Handlers::Joints
  StructuredError = MCPforSketchUp::Core::StructuredError

  # Duck-typed stand-in for a SketchUp Group: #subtract returns the configured
  # value (nil = failed boolean cut, anything else = the new cut group).
  FakeCutter = Struct.new(:result) do
    def subtract(_target)
      result
    end
  end

  def setup
    J.reset_joint_stats!
  end

  def test_subtract_tracked_counts_success
    out = J.subtract_tracked(FakeCutter.new(:new_group), :board)
    assert_equal :new_group, out, "must return the subtract result unchanged"
    assert_equal({ "attempted" => 1, "failed" => 0 }, J.joint_cut_stats)
  end

  def test_subtract_tracked_counts_failure
    out = J.subtract_tracked(FakeCutter.new(nil), :board)
    assert_nil out
    assert_equal({ "attempted" => 1, "failed" => 1 }, J.joint_cut_stats)
  end

  def test_assert_some_cut_raises_when_every_cut_failed
    J.subtract_tracked(FakeCutter.new(nil), :b)
    J.subtract_tracked(FakeCutter.new(nil), :b)
    err = assert_raises(StructuredError) { J.assert_some_cut!("Finger Joint") }
    assert_equal(-32603, err.code)
    assert_match(/no geometry/, err.message)
    assert_match(/Finger Joint/, err.message)
  end

  def test_assert_some_cut_passes_on_partial_success
    J.subtract_tracked(FakeCutter.new(:ok), :b)
    J.subtract_tracked(FakeCutter.new(nil), :b)   # one ok, one failed
    J.assert_some_cut!("Finger Joint")            # must NOT raise on partial
    assert_equal({ "attempted" => 2, "failed" => 1 }, J.joint_cut_stats)
  end

  def test_assert_some_cut_is_noop_when_nothing_attempted
    # Defensive: a joint that performed zero subtracts must not raise.
    J.assert_some_cut!("Mortise and Tenon")
    assert_equal({ "attempted" => 0, "failed" => 0 }, J.joint_cut_stats)
  end
end
