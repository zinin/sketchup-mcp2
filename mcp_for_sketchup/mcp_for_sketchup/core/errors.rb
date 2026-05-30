# mcp_for_sketchup/mcp_for_sketchup/core/errors.rb
require "json"
require "time"

module MCPforSketchUp
  module Core
    class StructuredError < StandardError
      attr_reader :code, :data

      def initialize(code, message, data = nil)
        @code = code
        @data = data || {}
        super(message)
      end
    end

    module Errors
      PARAMS_TRUNCATE_AT = 512  # bytes of UTF-8 JSON

      def self.build_error_response(code, message, data, request_id)
        {
          "jsonrpc" => "2.0",
          "error"   => { "code" => code, "message" => message, "data" => data },
          "id"      => request_id
        }
      end

      def self.exception_to_data(exception, tool, params)
        {
          "tool"      => tool,
          "params"    => truncate_params(params),
          "timestamp" => Time.now.utc.iso8601,
          "backtrace" => (exception.backtrace || []).first(3)
        }
      end

      def self.truncate_params(params)
        json = JSON.generate(params)
        return params if json.bytesize <= PARAMS_TRUNCATE_AT
        truncated = safe_byte_truncate(json, PARAMS_TRUNCATE_AT) + "...<truncated>"
        { "_truncated" => truncated }
      rescue JSON::GeneratorError, Encoding::UndefinedConversionError => e
        # The params themselves are un-encodable (e.g. a non-JSON object, or a
        # string with invalid bytes). Error formatting must never itself crash —
        # fall back to a safe marker rather than letting build_error_response
        # propagate a second exception. Mirrors server.rb#encode_response_body.
        { "_unserializable" => "#{e.class.name}: #{e.message.to_s.scrub("?")}" }
      end

      def self.safe_byte_truncate(s, n)
        truncated = s.byteslice(0, n)
        until truncated.valid_encoding?
          truncated = truncated.byteslice(0, truncated.bytesize - 1)
        end
        truncated.force_encoding(Encoding::UTF_8)
      end
    end
  end
end
