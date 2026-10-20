# test/test_singleton_stubs.rb
# The stub helper that the stub-based tests share (test/support/singleton_stubs.rb).
#
# Those tests only ever see it work: a stub that is put back, in a test that
# passed. What they cannot show is the part that matters when something goes
# wrong. A setup that raises halfway must still get its stubs put back, and
# must not make teardown trip over a list that was never created. A method
# stubbed twice must come back as it was before the first stub, which only
# newest-first order achieves.
#
# Each case runs a real Minitest test of a throwaway class through its whole
# life cycle (setup, test, teardown hooks) and looks at the module it stubbed.
# The class is taken out of Minitest's list of runnables, so the suite does not
# run it a second time.
require "minitest/autorun"

require_relative "support/singleton_stubs"

class TestSingletonStubs < Minitest::Test
  # What the throwaway tests stub: one method that exists, one that does not.
  module Target
    def self.value
      :original
    end
  end

  # Runs one test of a class that includes SingletonStubs, with `setup` and the
  # test body as given, and returns Minitest's Result for it.
  def run_stubbing_test(setup: nil, &body)
    klass = Class.new(Minitest::Test)
    Minitest::Runnable.runnables.delete(klass)
    klass.include(SingletonStubs)
    klass.define_method(:setup, &setup) if setup
    klass.define_method(:test_it, &body)
    klass.new("test_it").run
  end

  def test_a_stub_is_in_place_during_the_test_and_put_back_after
    seen = nil
    result = run_stubbing_test do
      stub_singleton(Target, :value) { :stubbed }
      seen = Target.value
    end

    assert_predicate result, :passed?
    assert_equal :stubbed, seen
    assert_equal :original, Target.value
  end

  def test_a_setup_that_fails_halfway_still_gets_its_stubs_put_back
    result = run_stubbing_test(setup: lambda do
      stub_singleton(Target, :value) { :stubbed }
      raise "setup failed"
    end) { flunk "the test must not run after a failed setup" }

    assert_equal 1, result.failures.size
    assert_equal "setup failed", result.failures.first.error.message,
      "teardown must not add an error of its own"
    assert_equal :original, Target.value
  end

  def test_a_setup_that_fails_before_any_stub_adds_no_error_of_its_own
    # The list of stubs exists before the class's setup runs, so teardown has
    # something to go through even then.
    result = run_stubbing_test(setup: -> { raise "setup failed" }) do
      flunk "the test must not run after a failed setup"
    end

    assert_equal 1, result.failures.size
    assert_equal "setup failed", result.failures.first.error.message,
      "teardown must not add an error of its own"
  end

  def test_a_test_that_raises_still_gets_its_stubs_put_back
    result = run_stubbing_test do
      stub_singleton(Target, :value) { :stubbed }
      raise "test failed"
    end

    assert_equal 1, result.failures.size
    assert_equal :original, Target.value
  end

  def test_a_method_stubbed_twice_comes_back_as_it_was
    run_stubbing_test do
      stub_singleton(Target, :value) { :first }
      stub_singleton(Target, :value) { :second }
    end

    assert_equal :original, Target.value
  end

  def test_a_method_that_did_not_exist_is_removed_again
    seen = nil
    run_stubbing_test do
      stub_singleton(Target, :extra) { :stubbed }
      seen = Target.extra
    end

    assert_equal :stubbed, seen
    refute_respond_to Target, :extra
  end

  def test_restore_stubs_with_a_mark_keeps_the_older_stubs
    inside = after = nil
    run_stubbing_test do
      stub_singleton(Target, :extra) { :older }
      mark = stub_mark
      stub_singleton(Target, :value) { :newer }
      inside = Target.value
      restore_stubs(mark)
      after = [Target.value, Target.extra]
    end

    assert_equal :newer, inside
    assert_equal %i[original older], after
    refute_respond_to Target, :extra, "the older stub goes back at teardown"
  end
end
