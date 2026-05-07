# su_mcp/su_mcp/core/errors.rb
require "json"
require "time"

module SU_MCP
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
