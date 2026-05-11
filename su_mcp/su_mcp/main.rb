# su_mcp/su_mcp/main.rb
require "sketchup"
require "json"
require "socket"
require "fileutils"
require "time"
require "tmpdir"

module SU_MCP
  PLUGIN_ROOT = File.dirname(__FILE__)

  # Load order: core/config + core/errors first (they have NO module-level
  # references and provide constants used by everyone). helpers/units before
  # logger (logger uses Config). Then helpers (validation/entities reference
  # Core::StructuredError on module load). Then framing (uses Config+Errors).
  # Then handlers (depend on helpers + core). Server and application last.
  LOAD_ORDER = %w[
    core/config
    core/errors
    helpers/units
    core/logger
    helpers/validation
    helpers/entities
    helpers/geometry
    core/framing
    handlers/dispatch
    handlers/geometry
    handlers/operations
    handlers/joints
    handlers/materials
    handlers/export
    handlers/model
    handlers/eval
    core/server
    core/application
    ui/settings_validator
    ui/settings_dialog
  ].freeze

  LOAD_ORDER.each { |path| Sketchup.require(File.join(PLUGIN_ROOT, path)) }

  # Hydrate Config from SketchUp preferences (replaces ENV-based config).
  SU_MCP::Core::Config.load_from_defaults!
  # One-time messagebox for users coming from the ENV-based config.
  SU_MCP::Core::Config.show_migration_banner!

  def self.install_menu
    menu = ::UI.menu("Plugins").add_submenu("MCP Server")

    start_item = menu.add_item("Start Server") { SU_MCP::Core::Application.start }
    menu.set_validation_proc(start_item) {
      SU_MCP::Core::Application.running? ? MF_GRAYED : MF_ENABLED
    }

    stop_item = menu.add_item("Stop Server") { SU_MCP::Core::Application.stop }
    menu.set_validation_proc(stop_item) {
      SU_MCP::Core::Application.running? ? MF_ENABLED : MF_GRAYED
    }

    menu.add_item("Restart Server") { SU_MCP::Core::Application.restart }
    menu.add_separator
    menu.add_item("Settings...") { SU_MCP::UI::SettingsDialog.show }
    menu.add_item("Show Log") { SU_MCP::Core::Application.show_log }
    menu.add_item("Show Status") {
      state =
        if SU_MCP::Core::Application.running?
          rc = SU_MCP::Core::Application.running_config
          "running on #{rc[:host]}:#{rc[:port]}"
        else
          "stopped"
        end
      SU_MCP::Core::Logger.log_tool("application", "status", state)
      Sketchup.status_text = "MCP Server: #{state}"
    }
  end

  unless file_loaded?(__FILE__)
    install_menu
    file_loaded(__FILE__)
  end
end
