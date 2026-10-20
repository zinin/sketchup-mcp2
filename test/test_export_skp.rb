# test/test_export_skp.rb
#
# Behavioural tests for MCPforSketchUp::Handlers::Export — a .skp export of an
# untitled model is refused (M-05, reversing T-27).
#
# Empirically (SketchUp 2026): Model#save_copy RAISES "Model must be saved
# before copying" on an UNTITLED model (path == ""), and Model#save re-points
# the open document to the target path and clears its dirty flag. T-27 exported
# an untitled model with save and returned a `warning` for the agent to relay,
# but the document was then bound to %TEMP%/sketchup_exports/…: the user's next
# Ctrl+S wrote there, a temp cleanup could delete the only copy, and nothing
# guaranteed the user heard the warning. Now Export.export raises -32602 before
# build_export_path (no file, no directory) and asks for File → Save first. A
# titled model uses save_copy, which leaves the document's path and dirty flag
# alone. Other formats never touch the document and are unaffected.
#
# We drive Export.export with a duck-typed model that records the calls made on
# it and whose `path` is configurable — no live SketchUp process needed.
# build_export_path is stubbed: the real one creates a temp directory.
require "minitest/autorun"

require_relative "support/singleton_stubs"

# export.rb aliases these at load time (V/E). Export.export calls
# require_enum and active_model!, which with_export_stubs supplies, so empty
# modules suffice (mirrors test_joint_cut_stats.rb).
module MCPforSketchUp
  module Helpers
    module Validation; end
    module Entities; end
  end
end
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/export"

class TestExportSaveSkp < Minitest::Test
  include SingletonStubs

  X = MCPforSketchUp::Handlers::Export
  V = MCPforSketchUp::Helpers::Validation
  E = MCPforSketchUp::Helpers::Entities
  StructuredError = MCPforSketchUp::Core::StructuredError

  # The message is all the agent has to act on, so it is pinned whole.
  REFUSAL = "cannot export .skp: the model has never been saved, and saving it to a " \
            "temp file would re-point the open document there. Ask the user to save " \
            "the model in SketchUp first (File → Save), or export another format."

  # Duck-typed stand-in for a Sketchup::Model. Records every save/export call
  # with its arguments, so an empty `calls` proves nothing was written; `path`
  # is whatever the test configures.
  class FakeModel
    attr_reader :path, :calls

    def initialize(path)
      @path  = path
      @calls = []
    end

    def save(p)
      @calls << [:save, p]
      true
    end

    def save_copy(p)
      @calls << [:save_copy, p]
      true
    end

    def export(p, options)
      @calls << [:export, p, options]
      true
    end
  end

  def setup
    @built_formats = []  # the formats build_export_path was asked for
  end

  # What the stubbed build_export_path returns; nothing is written there.
  def export_path_for(format)
    "/tmp/sketchup_export_test.#{format}"
  end

  # Stubs the three collaborators of Export.export for the length of the
  # block: format validation passes the value through, the active model is
  # `model`, and build_export_path records the format it was asked for in
  # @built_formats instead of creating a temp directory. The stubs are put back
  # when the block ends, however it ends. A stub body runs with self == the
  # stubbed module, hence the locals.
  def with_export_stubs(model)
    mark     = stub_mark
    built    = @built_formats
    path_for = method(:export_path_for)
    stub_singleton(V, :require_enum) { |params, key, _allowed| params[key] }
    stub_singleton(E, :active_model!) { model }
    stub_singleton(X, :build_export_path) do |format|
      built << format
      path_for.call(format)
    end
    yield
  ensure
    restore_stubs(mark)
  end

  def assert_skp_export_refused(model)
    err = with_export_stubs(model) do
      assert_raises(StructuredError) { X.export({ "format" => "skp" }) }
    end

    assert_equal(-32602, err.code)
    assert_equal REFUSAL, err.message
    assert_empty model.calls,
      "nothing may be saved: save would re-point the open document to a temp path"
    assert_empty @built_formats,
      "the refusal must come before build_export_path, which creates a temp directory"
  end

  def test_untitled_skp_export_is_refused
    assert_skp_export_refused(FakeModel.new(""))  # never-saved / untitled
  end

  def test_nil_path_skp_export_is_refused
    # Defensive: a nil path (no document) is untitled too — the guard uses
    # path.to_s.empty?.
    assert_skp_export_refused(FakeModel.new(nil))
  end

  def test_titled_model_uses_save_copy
    model  = FakeModel.new("/Users/me/project.skp")  # titled document
    result = with_export_stubs(model) { X.export({ "format" => "skp" }) }

    assert_equal [[:save_copy, export_path_for("skp")]], model.calls,
      "titled model must use save_copy (save would re-point path + clear dirty = data loss)"
    assert_equal({ "path" => export_path_for("skp"), "format" => "skp" }, result,
      "the response is {path, format} only: no warning key any more")
    assert_equal ["skp"], @built_formats
  end

  # save_skp is save_copy and nothing else, whatever the model's path: the
  # untitled case is refused in export, before this runs, and a branch added
  # here that saved such a model would re-point the open document. Called
  # directly, because export never reaches save_skp with an untitled model.
  def test_save_skp_only_calls_save_copy
    ["/Users/me/project.skp", "", nil].each do |path|
      model = FakeModel.new(path)

      assert_equal true, X.save_skp(model, "/tmp/out.skp"), "the result of save_copy (path #{path.inspect})"
      assert_equal [[:save_copy, "/tmp/out.skp"]], model.calls, "path #{path.inspect}"
    end
  end

  def test_export_stubs_are_put_back_when_the_block_ends
    # Whatever the three methods were before: the real ones when other files
    # have loaded the helpers (run_all), nothing on the empty modules above.
    stubbed = { V => :require_enum, E => :active_model!, X => :build_export_path }
    current = -> { stubbed.map { |mod, name| mod.respond_to?(name) ? mod.method(name) : nil } }
    before = current.call

    assert_raises(RuntimeError) { with_export_stubs(FakeModel.new("")) { raise "boom" } }

    assert_equal before, current.call
  end

  def test_untitled_obj_export_still_works
    model  = FakeModel.new("")  # only a .skp export needs a saved model
    result = with_export_stubs(model) { X.export({ "format" => "obj" }) }

    assert_equal({ "path" => export_path_for("obj"), "format" => "obj" }, result)
    assert_equal [[:export, export_path_for("obj")]], model.calls.map { |c| c.first(2) },
      "obj goes through Model#export with the built path; no save of any kind"
    assert_equal ["obj"], @built_formats
  end
end
