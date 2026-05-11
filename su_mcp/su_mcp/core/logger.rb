# su_mcp/su_mcp/core/logger.rb
require "time"

module SU_MCP
  module Core
    module Logger
      def self.log(level, msg)
        return if Config.level_value_for(level) < Config.level_value
        line = "[#{Time.now.utc.iso8601}] [#{level}] #{msg}"
        write(line)
      end

      def self.log_tool(tool, status, extra = nil)
        log("INFO", "tool=#{tool} status=#{status}#{extra ? " " + extra : ""}")
      end

      def self.log_error(tool, exception)
        log("ERROR", "tool=#{tool} class=#{exception.class.name} msg=#{exception.message}")
        return unless Config.log_level == "DEBUG" && exception.backtrace
        exception.backtrace.first(3).each { |bt| write("    #{bt}") }
      end

      def self.write(line)
        if defined?(SKETCHUP_CONSOLE) && SKETCHUP_CONSOLE
          SKETCHUP_CONSOLE.write(line + "\n")
        else
          $stdout.puts(line)
        end
      end
    end
  end
end
