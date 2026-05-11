# su_mcp/su_mcp/core/config.rb
module SU_MCP
  module Core
    module Config
      SECTION = "SU_MCP"

      DEFAULTS = {
        host:      "127.0.0.1",
        port:      9876,
        log_level: "INFO",
      }.freeze

      LEVELS           = { "DEBUG" => 0, "INFO" => 1, "WARN" => 2, "ERROR" => 3 }.freeze
      MAX_MESSAGE_SIZE = 64 * 1024 * 1024  # 64 MiB; matches Python side

      class << self
        attr_accessor :host, :port, :log_level
      end

      def self.load_from_defaults!(reader = Sketchup)
        self.host      = reader.read_default(SECTION, "host",      DEFAULTS[:host]).to_s
        self.port      = reader.read_default(SECTION, "port",      DEFAULTS[:port]).to_i
        self.log_level = reader.read_default(SECTION, "log_level", DEFAULTS[:log_level]).to_s.upcase
      end

      # Caller is responsible for passing pre-validated, normalized values
      # (see SettingsValidator). Runtime is mutated BEFORE persistence so any
      # write_default failure leaves the current session consistent and old
      # prefs intact (partial persistence is acceptable — UI re-loads on next
      # open and reflects what actually got persisted).
      def self.update!(host:, port:, log_level:, writer: Sketchup)
        self.host      = host
        self.port      = port.to_i
        self.log_level = log_level
        writer.write_default(SECTION, "host",      host)
        writer.write_default(SECTION, "port",      port.to_i)
        writer.write_default(SECTION, "log_level", log_level)
      end

      # One-time UI nudge for users migrating from the old ENV-based config.
      # Shown when at least one of the legacy ENV vars is set, no prefs have
      # been saved yet, and we haven't already shown this dialog.
      def self.show_migration_banner!(reader: Sketchup, writer: Sketchup, ui: ::UI)
        return if reader.read_default(SECTION, "migration_notified", false)
        legacy_env_present =
          %w[SKETCHUP_MCP_HOST SKETCHUP_MCP_PORT SKETCHUP_MCP_LOG_LEVEL].any? { |v| ENV[v] }
        return unless legacy_env_present
        prefs_empty =
          reader.read_default(SECTION, "host", nil).nil? &&
          reader.read_default(SECTION, "port", nil).nil? &&
          reader.read_default(SECTION, "log_level", nil).nil?
        return unless prefs_empty
        ui.messagebox(
          "MCP Server settings have moved to Plugins → MCP Server → Settings…\n\n" \
          "Please open Settings and re-enter your configuration. " \
          "Environment variables (SKETCHUP_MCP_HOST/PORT/LOG_LEVEL) are no longer read by the SketchUp extension."
        )
        writer.write_default(SECTION, "migration_notified", true)
      end

      def self.level_value
        level_value_for(@log_level)
      end

      def self.level_value_for(name)
        LEVELS.fetch(name, LEVELS["INFO"])
      end
    end
  end
end
