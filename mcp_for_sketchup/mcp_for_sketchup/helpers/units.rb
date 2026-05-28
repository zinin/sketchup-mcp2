# su_mcp/su_mcp/helpers/units.rb
module MCPforSketchUp
  module Helpers
    module Units
      MM = 25.4

      def self.mm_to_inch(v)
        v / MM
      end

      def self.inch_to_mm(v)
        v * MM
      end
    end
  end
end
