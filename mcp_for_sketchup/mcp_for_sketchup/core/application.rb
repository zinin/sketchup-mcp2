# su_mcp/su_mcp/core/application.rb
module MCPforSketchUp
  module Core
    module Application
      @server         = nil
      @running        = false
      @running_config = nil

      # The Server class is resolved lazily so tests can swap in a stub.
      def self.server_class
        @server_class ||= Server
      end

      def self.server_class=(klass)
        @server_class = klass
      end

      def self.running?
        @running
      end

      # Snapshot of {host, port, log_level} the live server was started with.
      # Returns nil if no server is running.
      def self.running_config
        @running_config
      end

      def self.start
        return if @running
        begin
          @server = server_class.new
          @server.start
          @running = true
          @running_config = {
            host:      Config.host,
            port:      Config.port,
            log_level: Config.log_level
          }.freeze
          Sketchup.status_text = "MCP Server: running on #{Config.host}:#{Config.port}"
          Logger.log_tool("application", "started", "host=#{Config.host} port=#{Config.port}")
        rescue StandardError => e
          Logger.log_error("application.start", e)
          ::UI.messagebox("MCP Server failed to start:\n\n#{e.message}\n\n" \
                          "Check Plugins → MCP Server → Show Log for details.")
          @server&.stop rescue nil
          @server = nil
          @running = false
          @running_config = nil
        end
      end

      def self.stop
        return unless @running
        @server&.stop
        @server = nil
        @running = false
        @running_config = nil
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
