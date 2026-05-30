# test/test_export_skp.rb
#
# Behavioural tests for MCPforSketchUp::Handlers::Export.save_skp — the helper
# that picks Model#save vs Model#save_copy for a .skp export (codex Critical).
#
# Empirically (SketchUp 2026): save_copy RAISES "Model must be saved before
# copying" on an UNTITLED model (path == ""), while save on a TITLED document
# re-points model.path and clears the dirty flag = silent data loss. So:
#   untitled (empty path) → save; titled (non-empty path) → save_copy.
#
# We drive save_skp with a duck-typed model that records which method was
# called and whose `path` is configurable — no live SketchUp process needed.
require "minitest/autorun"

# export.rb aliases these at load time (V/E). save_skp does not touch them, so
# empty stubs suffice (mirrors test_joint_cut_stats.rb).
module MCPforSketchUp
  module Helpers
    module Validation; end
    module Entities; end
  end
end
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/export"

class TestExportSaveSkp < Minitest::Test
  X = MCPforSketchUp::Handlers::Export

  # Duck-typed stand-in for a Sketchup::Model. Records the last save method
  # called + its argument; `path` is whatever the test configures.
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
  end

  def test_untitled_model_uses_save_not_save_copy
    model = FakeModel.new("")  # never-saved / untitled
    X.save_skp(model, "/tmp/x.skp")
    assert_equal [[:save, "/tmp/x.skp"]], model.calls,
      "untitled model must use save (save_copy would raise 'Model must be saved before copying')"
  end

  def test_nil_path_is_treated_as_untitled
    # Defensive: a nil path (no document) must also route to save, not
    # save_copy — save_skp uses path.to_s.empty?.
    model = FakeModel.new(nil)
    X.save_skp(model, "/tmp/x.skp")
    assert_equal [[:save, "/tmp/x.skp"]], model.calls
  end

  def test_titled_model_uses_save_copy_not_save
    model = FakeModel.new("/Users/me/project.skp")  # titled document
    X.save_skp(model, "/tmp/x.skp")
    assert_equal [[:save_copy, "/tmp/x.skp"]], model.calls,
      "titled model must use save_copy (save would re-point path + clear dirty = data loss)"
  end
end
