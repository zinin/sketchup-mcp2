# su_mcp/su_mcp/core/application.rb
require "uri"  # iter-1 CONCERN-5 / iter-2 CRITICAL-3
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
          begin
            @server&.stop
          rescue StandardError => stop_err
            Logger.log("DEBUG",
              "Application.start cleanup: server.stop raised: #{stop_err.class}: #{stop_err.message}")
          end
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
        if MCPforSketchUp::Core::Config.log_to_file &&
           File.exist?(MCPforSketchUp::Core::Config.log_file_path)
          ::UI.openURL(file_uri_for(MCPforSketchUp::Core::Config.log_file_path))
        elsif defined?(SKETCHUP_CONSOLE) && SKETCHUP_CONSOLE
          SKETCHUP_CONSOLE.show
        end
      end

      # iter-2 CRITICAL-3: build a RFC-8089-style `file://` URL safely
      # across Linux/macOS POSIX paths and Windows drive-letter paths.
      # Steps: expand the path, normalise backslashes to forward slashes
      # (Windows), prefix a leading slash for drive-letter paths so the
      # result becomes `file:///C:/…`, then URI-escape the whole thing
      # so spaces / non-ASCII characters render correctly in the OS
      # default-handler call.
      def self.file_uri_for(path)
        encoded = File.expand_path(path).gsub('\\', '/')
        encoded = "/#{encoded}" if encoded =~ /\A[A-Za-z]:/   # Windows drive letter
        encoded = URI::DEFAULT_PARSER.escape(encoded)
        "file://#{encoded}"
      end
      private_class_method :file_uri_for
    end
  end
end
