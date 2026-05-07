# su_mcp/su_mcp/core/application.rb
module SU_MCP
  module Core
    module Application
      @server  = nil
      @running = false

      def self.running?
        @running
      end

      def self.start
        return if @running
        begin
          @server = Server.new
          @server.start
          @running = true
          Sketchup.status_text = "MCP Server: running on :#{Config::PORT}"
          Logger.log_tool("application", "started", "port=#{Config::PORT}")
        rescue StandardError => e
          Logger.log_error("application.start", e)
          UI.messagebox("MCP Server failed to start:\n\n#{e.message}\n\n" \
                        "Check Plugins → MCP Server → Show Log for details.")
          @server = nil
          @running = false
        end
      end

      def self.stop
        return unless @running
        @server&.stop
        @server = nil
        @running = false
        Sketchup.status_text = "MCP Server: stopped"
        Logger.log_tool("application", "stopped")
      end

      def self.restart
        stop if @running
        start
      end

      def self.show_log
        return unless defined?(SKETCHUP_CONSOLE) && SKETCHUP_CONSOLE
        SKETCHUP_CONSOLE.show
      end
    end
  end
end
