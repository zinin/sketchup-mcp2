# mcp_for_sketchup/mcp_for_sketchup/core/logger.rb
require "time"

module MCPforSketchUp
  module Core
    module Logger
      # User-visible identifier prepended to every log line so multiple
      # extensions sharing the SketchUp Ruby console can be distinguished.
      # Required by warehouse reviewer note 2.
      LINE_PREFIX = "[MCPforSU]".freeze

      def self.log(level, msg)
        return if Config.level_value_for(level) < Config.level_value
        line = "[#{Time.now.utc.iso8601}] #{LINE_PREFIX} [#{level}] #{msg}"
        _emit(line)
      end

      def self.log_tool(tool, status, extra = nil, client_label: nil)
        body = "tool=#{tool} status=#{status}"
        body << " client=#{client_label}" if client_label
        body << " #{extra}" if extra
        log("INFO", body)
      end

      def self.log_error(tool, exception, client_label: nil)
        body = "tool=#{tool}"
        body << " client=#{client_label}" if client_label
        body << " class=#{exception.class.name} msg=#{exception.message}"
        log("ERROR", body)
        return unless Config.log_level == "DEBUG" && exception.backtrace
        # Backtrace continuation lines carry the prefix (CONCERN-1) but no
        # timestamp — they continue the preceding ERROR record rather than
        # standing as independent log events.
        exception.backtrace.first(3).each { |bt| _emit("#{LINE_PREFIX}     #{bt}") }
      end

      # Single emission point. Task 5 extends this with the log-to-file
      # branch (`append_to_file(line) if Config.log_to_file`) — keep that
      # extension here so the prefix invariant is preserved for file output
      # too.
      def self._emit(line)
        _emit_console(line)
        append_to_file(line) if Config.log_to_file
      end

      def self.append_to_file(line)
        path = Config.log_file_path
        return if path.nil? || path.empty?
        # Expand the path (review F4b): the validator accepts ~/relative paths
        # via File.expand_path but persists the raw string, and File.open does
        # NOT expand `~` — so a tilde path would otherwise fail on every write.
        # Explicit UTF-8 external encoding (review F5): without it File.open uses
        # the platform default (e.g. Windows-1252 locale), so a non-ASCII log
        # line (Cyrillic model names, exception messages) would raise
        # Encoding::UndefinedConversionError and be silently dropped by the
        # rescue below. `line` is already UTF-8.
        File.open(File.expand_path(path), "a:UTF-8") { |f| f.puts(line) }
      rescue StandardError => e
        # Best-effort. Logging must never break the data path. Surface the
        # failure as a one-shot DEBUG line in the console without re-entering
        # append_to_file (we explicitly call _emit_console directly here).
        _emit_console("[#{Time.now.utc.iso8601}] #{LINE_PREFIX} [DEBUG] " \
                      "log file write failed (#{e.class}: #{e.message}); " \
                      "reverting to console only for this line")
      end

      def self._emit_console(line)
        if defined?(SKETCHUP_CONSOLE) && SKETCHUP_CONSOLE
          SKETCHUP_CONSOLE.write(line + "\n")
        else
          $stdout.puts(line)
        end
      end
      private_class_method :_emit, :append_to_file, :_emit_console
    end
  end
end
