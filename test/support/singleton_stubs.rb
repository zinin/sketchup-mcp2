# test/support/singleton_stubs.rb
# Shared helper: replace a module's singleton method for one test and put the
# original back afterwards.
#
#   require_relative "support/singleton_stubs"
#
#   class TestX < Minitest::Test
#     include SingletonStubs
#
#     def setup
#       model = Object.new  # a stub body runs with self == the stubbed module
#       stub_singleton(Entities, :active_model!) { model }
#     end
#   end
#
# The list of stubs belongs to the helper. It is created in Minitest's
# before_setup hook, ahead of the class's own setup, and the stubs are put back
# in after_teardown, newest first. Minitest runs that hook even when setup, the
# test or teardown raised, so a setup that fails halfway cannot leak a stub or
# make teardown trip over a missing list, and the class needs no setup or
# teardown of its own for this (nor a super call in one that it has).
module SingletonStubs
  def before_setup
    @stubs = []
    super
  end

  def after_teardown
    restore_stubs
    super
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

  # How many stubs are in place now. A helper that stubs for the length of a
  # block takes this first and passes it to restore_stubs in an ensure.
  def stub_mark
    @stubs.size
  end

  # Puts back the stubs added after the first `keep`, newest first: the
  # original Method, or nothing for a method that did not exist.
  def restore_stubs(keep = 0)
    while @stubs.size > keep
      mod, name, original = @stubs.pop
      mod.singleton_class.send(:remove_method, name)
      mod.define_singleton_method(name, original) if original
    end
  end
end
