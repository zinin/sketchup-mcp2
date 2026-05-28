# test/test_build_profile_fixture.rb
# iter-1 SUGGESTION-2: covers the eval_enabled? fall-through to
# Core::BuildProfile::EVAL_ENABLED_BY_DEFAULT for the github variant.
require "minitest/autorun"
require "tempfile"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/config"
require_relative "support/config_reset"

class TestBuildProfileFixture < Minitest::Test
  def setup
    ConfigReset.reset_all!
    @tmp = Tempfile.new(["build_profile", ".rb"])
    @tmp.write(<<~RUBY)
      module MCPforSketchUp
        module Core
          module BuildProfile
            VARIANT                 = "github".freeze
            EVAL_ENABLED_BY_DEFAULT = true
          end
        end
      end
    RUBY
    @tmp.close
    # iter-2 SUGGESTION-5: `load` (not `require`) because we re-define the
    # same constant per setup; `require` would memoise the first definition
    # and silently skip subsequent reload attempts (so later tests would
    # observe stale BuildProfile bodies from earlier tests).
    load @tmp.path
  end

  def teardown
    if MCPforSketchUp::Core.const_defined?(:BuildProfile)
      MCPforSketchUp::Core.send(:remove_const, :BuildProfile)
    end
    @tmp.unlink
  end

  def test_eval_enabled_question_mark_returns_true_when_pref_unset_and_build_profile_true
    MCPforSketchUp::Core::Config.eval_enabled = nil
    assert MCPforSketchUp::Core::Config.eval_enabled?
  end

  def test_pref_overrides_build_profile
    MCPforSketchUp::Core::Config.eval_enabled = false
    refute MCPforSketchUp::Core::Config.eval_enabled?
  end
end
