# mcp_for_sketchup/mcp_for_sketchup/ui/settings_validator.rb
module MCPforSketchUp
  module UI
    module SettingsValidator
      VALID_LEVELS    = %w[DEBUG INFO WARN ERROR].freeze
      MAX_HOST_LENGTH = 253
      # Characters allowed in host. Covers IPv4 dotted-decimal, IPv6
      # unbracketed (colons), hostnames (letters/digits/dots/dashes).
      HOST_CHARSET    = /\A[A-Za-z0-9._\-:]+\z/

      # Validates a {"host", "port", "log_level"} hash (string keys, as parsed
      # from JSON sent by the HtmlDialog).
      #
      # Returns:
      #   {ok: true,  errors: {}, normalized: {host:, port:, log_level:, eval_enabled:, log_to_file:, log_file_path:}}
      #   {ok: false, errors: {host?: msg, port?: msg, log_level?: msg}}
      def self.validate(payload)
        return { ok: false, errors: { _general: "Bad payload format" } } unless payload.is_a?(Hash)

        errors = {}
        host       = payload["host"].to_s
        port_raw   = payload["port"].to_s
        level_raw  = payload["log_level"].to_s

        if host.empty?
          errors[:host] = "Host must not be empty"
        elsif host =~ /\s/
          errors[:host] = "Host must not contain whitespace"
        elsif host.length > MAX_HOST_LENGTH
          errors[:host] = "Host too long (max #{MAX_HOST_LENGTH} characters)"
        elsif host !~ HOST_CHARSET
          errors[:host] = "Host contains invalid characters"
        end

        port_int = port_raw =~ /\A\d+\z/ ? port_raw.to_i : nil
        if port_int.nil? || port_int < 1 || port_int > 65535
          errors[:port] = "Port must be a number between 1 and 65535"
        end

        level = level_raw.upcase
        unless VALID_LEVELS.include?(level)
          errors[:log_level] = "Invalid log level"
        end

        eval_enabled = truthy?(payload["eval_enabled"])
        log_to_file  = truthy?(payload["log_to_file"])
        log_path     = payload["log_file_path"].to_s

        if log_to_file
          if log_path.empty?
            errors[:log_file_path] = "Log file path must not be empty when 'Log to file' is enabled"
          else
            # Iter-1 CONCERN-5: design §5.2 requires the parent directory to exist
            # before enabling log-to-file. We do NOT auto-create user-facing log
            # directories — surface the misconfiguration here so the dialog
            # rejects the Save instead of silently swallowing every write.
            # File.expand_path raises ArgumentError on malformed paths (NUL
            # byte, invalid encoding). The validator's contract is to return
            # structured errors, never raise — so guard it and surface the
            # failure on the log_file_path field instead of bubbling up to a
            # generic _general internal-error in the dialog.
            begin
              parent = File.dirname(File.expand_path(log_path))
            rescue ArgumentError => e
              parent = nil
              errors[:log_file_path] = "Invalid log file path: #{e.message}"
            end
            if parent && !Dir.exist?(parent)
              errors[:log_file_path] = "Log file parent directory does not exist: #{parent}"
            end
          end
        end

        if errors.empty?
          {
            ok: true,
            errors: {},
            normalized: {
              host:           host,
              port:           port_int,
              log_level:      level,
              eval_enabled:   eval_enabled,
              log_to_file:    log_to_file,
              log_file_path:  log_path,
            },
          }
        else
          { ok: false, errors: errors }
        end
      end

      # Accept the strings "true"/"false" (used by the HTML dialog) as well
      # as native booleans (used by Ruby callers and tests). Anything else
      # — including the empty string and nil — is false. Strict by design:
      # we don't accept "1"/"yes"/"on" forms; the dialog is the only producer.
      # iter-2 SUGGESTION-3: nil normalises to `false` here because the
      # dialog never sends nil. Semantically a missing pref means «unset»,
      # not «false» — that distinction matters at the Config layer (sentinel-
      # nil → BuildProfile fallback) but not in this validator, which only
      # sees fully-populated dialog payloads. Don't reuse this helper from
      # Config code.
      def self.truthy?(value)
        return value if value == true || value == false
        value.to_s == "true"
      end
    end
  end
end
