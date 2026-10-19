# test/test_param_bounds.rb
# M-07: the parameters that size the work of one call are bounded on the Ruby
# side too: fillet_edges segments 1..32, create_component segments 3..128. A
# direct TCP client bypasses the Python schema, and segments = 10**9 would run
# unbounded on SketchUp's UI thread. (create_dovetail num_tails and
# create_finger_joint num_fingers: test_joints_validation.rb.)
#
# Validation runs before any model access. Entities.active_model! is stubbed
# to raise a marker: a call that gets past validation fails with it, a refused
# one raises -32602 first. The original method goes back in teardown; one that
# did not exist is removed again.
require "minitest/autorun"

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/units"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/geometry"

module MCPforSketchUp
  module Helpers
    module Entities; end
  end
end

require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/geometry"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/operations"

class TestParamBounds < Minitest::Test
  OPS = MCPforSketchUp::Handlers::Operations
  GEO = MCPforSketchUp::Handlers::Geometry
  EH  = MCPforSketchUp::Helpers::Entities
  StructuredError = MCPforSketchUp::Core::StructuredError

  MARKER = "validation passed"

  def setup
    @original_active_model = EH.respond_to?(:active_model!) ? EH.method(:active_model!) : nil
    # Removing before redefining keeps `ruby -w` free of "method redefined".
    EH.singleton_class.send(:remove_method, :active_model!) if @original_active_model
    EH.define_singleton_method(:active_model!) { raise MARKER }
  end

  def teardown
    EH.singleton_class.send(:remove_method, :active_model!)
    EH.define_singleton_method(:active_model!, @original_active_model) if @original_active_model
  end

  def fillet(segments)
    OPS.fillet_edges("entity_id" => 1, "radius" => 5.0, "segments" => segments)
  end

  def sphere(extra = {})
    GEO.create_component({ "type" => "sphere", "dimensions" => [100.0, 100.0, 100.0] }.merge(extra))
  end

  def assert_refused
    err = assert_raises(StructuredError) { yield }
    assert_equal(-32602, err.code)
    assert_match(/segments/, err.message)
  end

  def assert_passes_validation
    err = assert_raises(RuntimeError) { yield }
    assert_equal MARKER, err.message
  end

  # ---------- fillet_edges: segments 1..32 ----------

  def test_fillet_segments_above_32_rejected
    assert_refused { fillet(33) }
  end

  def test_fillet_segments_below_1_rejected
    assert_refused { fillet(0) }
  end

  def test_fillet_segments_1_passes_validation
    assert_passes_validation { fillet(1) }
  end

  def test_fillet_segments_32_passes_validation
    assert_passes_validation { fillet(32) }
  end

  # ---------- create_component: segments 3..128 ----------

  def test_create_component_segments_above_128_rejected
    assert_refused { sphere("segments" => 129) }
  end

  def test_create_component_segments_below_3_rejected
    assert_refused { sphere("segments" => 2) }
  end

  def test_create_component_segments_3_passes_validation
    assert_passes_validation { sphere("segments" => 3) }
  end

  def test_create_component_segments_128_passes_validation
    assert_passes_validation { sphere("segments" => 128) }
  end

  # A cube has no segments: the absent default is not range-checked.
  def test_create_component_cube_without_segments_passes_validation
    assert_passes_validation do
      GEO.create_component("type" => "cube", "dimensions" => [100.0, 100.0, 100.0])
    end
  end
end
