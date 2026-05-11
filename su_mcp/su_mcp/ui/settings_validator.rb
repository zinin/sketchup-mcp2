# su_mcp/su_mcp/ui/settings_validator.rb
module SU_MCP
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
      #   {ok: true,  errors: {}, normalized: {host:, port:, log_level:}}
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

        if errors.empty?
          { ok: true, errors: {}, normalized: { host: host, port: port_int, log_level: level } }
        else
          { ok: false, errors: errors }
        end
      end
    end
  end
end
