# su_mcp/su_mcp/core/config.rb
module SU_MCP
  module Core
    module Config
      LEVELS = { "DEBUG" => 0, "INFO" => 1, "WARN" => 2, "ERROR" => 3 }.freeze
      MAX_MESSAGE_SIZE = 64 * 1024 * 1024  # 64 MiB, synchronous with Python

      # Read ENV into a snapshot hash. Used at module load and in tests.
      def self.read_env(env = ENV)
        {
          port:      (env["SKETCHUP_MCP_PORT"] || "9876").to_i,
          host:       env["SKETCHUP_MCP_HOST"] || "127.0.0.1",
          log_level: (env["SKETCHUP_MCP_LOG_LEVEL"] || "INFO").upcase
        }
      end

      _snapshot = read_env
      PORT      = _snapshot[:port]
      HOST      = _snapshot[:host]
      LOG_LEVEL = _snapshot[:log_level]

      def self.level_value
        level_value_for(LOG_LEVEL)
      end

      def self.level_value_for(name)
        LEVELS.fetch(name, LEVELS["INFO"])
      end
    end
  end
end
