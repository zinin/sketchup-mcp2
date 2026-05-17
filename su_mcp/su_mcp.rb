require 'sketchup'
require 'extensions'

module SU_MCP
  unless file_loaded?(__FILE__)
    ext = SketchupExtension.new('Sketchup MCP Server', 'su_mcp/main')
    ext.description = 'Model Context Protocol server for Sketchup'
    ext.version     = '0.1.0'
    ext.copyright   = '2026'
    ext.creator     = 'Alexander Zinin'
    
    Sketchup.register_extension(ext, true)
    
    file_loaded(__FILE__)
  end
end 