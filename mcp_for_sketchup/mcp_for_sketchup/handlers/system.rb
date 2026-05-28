# su_mcp/su_mcp/handlers/system.rb
module MCPforSketchUp
  module Handlers
    module System
      # Returns the Ruby-side compat metadata. Used by the MCP tool
      # `get_version` (Python wrapper computes the `compatible` flag).
      def self.get_version(_params)
        {
          ruby_version:           MCPforSketchUp::Core::Compat::SERVER_VERSION,
          min_compatible_python:  MCPforSketchUp::Core::Compat::MIN_PYTHON,
          max_compatible_python:  MCPforSketchUp::Core::Compat::MAX_PYTHON,
        }
      end
    end
  end
end
