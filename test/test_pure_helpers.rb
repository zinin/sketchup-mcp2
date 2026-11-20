# test/test_pure_helpers.rb
# T-23: тривиально тестируемые без SketchUp чистые хелперы не были покрыты
# вовсе: pick_color (materials), filter_edges (operations).
require "minitest/autorun"

unless defined?(Sketchup)
  module Sketchup
    class Group; end
    class ComponentInstance; end
  end
end
module Sketchup
  # Guarded: реальный API даёт Sketchup::Color; в юнит-среде достаточно
  # RGB-контейнера.
  unless const_defined?(:Color)
    class Color
      attr_reader :rgb
      def initialize(*rgb)
        @rgb = rgb
      end
    end
  end
  unless const_defined?(:Face)
    class Face; end
  end
  unless const_defined?(:Edge)
    class Edge; end
  end
end

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
module MCPforSketchUp
  module Helpers
    module Validation; end
    module Entities; end
    module Geometry; end
    module Units; end
  end
end
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/operation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/materials"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/operations"

class TestPureHelpers < Minitest::Test
  MAT = MCPforSketchUp::Handlers::Materials
  OPS = MCPforSketchUp::Handlers::Operations

  # ---------- pick_color ----------

  def test_pick_color_named_case_insensitive
    assert_equal [184, 134, 72], MAT.pick_color("Wood").rgb
    assert_equal [255, 0, 0],    MAT.pick_color("red").rgb
  end

  def test_pick_color_hex
    assert_equal [160, 80, 48], MAT.pick_color("#a05030").rgb
  end

  def test_pick_color_invalid_raises_32602
    err = assert_raises(MCPforSketchUp::Core::StructuredError) { MAT.pick_color("#XYZ") }
    assert_equal(-32602, err.code)
    err = assert_raises(MCPforSketchUp::Core::StructuredError) { MAT.pick_color("mahogany") }
    assert_equal(-32602, err.code)
  end

  # ---------- filter_edges ----------

  def test_filter_edges_selects_by_positional_index
    edges = %w[e0 e1 e2 e3]
    assert_equal %w[e1 e3], OPS.filter_edges(edges, [1, 3])
    assert_equal [],        OPS.filter_edges(edges, [])
    assert_equal %w[e0],    OPS.filter_edges(edges, [0, 99])  # несуществующий индекс молча пропущен
  end
end
