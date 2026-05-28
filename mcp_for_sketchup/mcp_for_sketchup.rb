require 'sketchup'
require 'extensions'

module MCPforSketchUp
  unless file_loaded?(__FILE__)
    ext = SketchupExtension.new('MCP Server for SketchUp', 'mcp_for_sketchup/main')
    ext.description = 'Model Context Protocol server for SketchUp'
    ext.version     = '0.1.0'
    ext.copyright   = '2026'
    ext.creator     = 'Alexander Zinin'

    Sketchup.register_extension(ext, true)

    file_loaded(__FILE__)
  end
end
