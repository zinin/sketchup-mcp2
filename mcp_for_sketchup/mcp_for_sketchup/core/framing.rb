# su_mcp/su_mcp/core/framing.rb
module MCPforSketchUp
  module Core
    module Framing
      def self.encode_frame(body)
        body_bytes = body.b
        if body_bytes.bytesize == 0
          raise StructuredError.new(-32600, "empty body — refusing to encode zero-length frame")
        end
        if body_bytes.bytesize > Config::MAX_MESSAGE_SIZE
          raise StructuredError.new(-32600,
            "response too large: #{body_bytes.bytesize} bytes (cap #{Config::MAX_MESSAGE_SIZE})")
        end
        [body_bytes.bytesize].pack("N") + body_bytes
      end

      class FrameReader
        def initialize
          @buffer = String.new(encoding: Encoding::ASCII_8BIT)
          @state = :reading_header
          @expected_length = nil
        end

        # Accept the next chunk of bytes; return an array of completed bodies
        # (0, 1, or N if multiple frames arrived in one chunk).
        def feed(bytes)
          @buffer << bytes.b
          completed = []
          loop do
            case @state
            when :reading_header
              break if @buffer.bytesize < 4
              @expected_length = @buffer.byteslice(0, 4).unpack1("N")
              validate_length!(@expected_length)
              @buffer = @buffer.byteslice(4..-1) || String.new(encoding: Encoding::ASCII_8BIT)
              @state = :reading_body
            when :reading_body
              break if @buffer.bytesize < @expected_length
              body = @buffer.byteslice(0, @expected_length)
              @buffer = @buffer.byteslice(@expected_length..-1) ||
                        String.new(encoding: Encoding::ASCII_8BIT)
              @state = :reading_header
              @expected_length = nil
              completed << body
            end
          end
          completed
        end

        private

        def validate_length!(len)
          raise StructuredError.new(-32600, "received zero-length frame") if len == 0
          if len > Config::MAX_MESSAGE_SIZE
            raise StructuredError.new(-32600,
              "message too large: #{len} bytes (cap #{Config::MAX_MESSAGE_SIZE})")
          end
        end
      end
    end
  end
end
