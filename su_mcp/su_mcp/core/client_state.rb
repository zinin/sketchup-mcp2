# su_mcp/su_mcp/core/client_state.rb
module SU_MCP
  module Core
    class ClientState
      attr_reader   :id, :sock, :reader, :label, :pending_write_bytes
      attr_accessor :handshaked, :client_version, :close_after_response,
                    :pending_write_deadline_at

      def initialize(id, sock)
        @id                        = id
        @sock                      = sock
        @reader                    = Framing::FrameReader.new
        @label                     = "##{id}[#{peer_label(sock)}]"
        @handshaked                = false
        @client_version            = nil
        @close_after_response      = false
        @pending_write_bytes       = String.new(encoding: Encoding::ASCII_8BIT)
        @pending_write_deadline_at = nil
      end

      def closed?
        @sock.closed?
      end

      # Append bytes to the pending-write buffer. Always coerced to ASCII_8BIT
      # so concatenation with other binary frames cannot trigger an encoding
      # error. Returns the new buffer size.
      def append_pending_write(bytes)
        @pending_write_bytes << bytes.b
        @pending_write_bytes.bytesize
      end

      # Drop the leading `n` bytes from the pending-write buffer (after a
      # successful partial write_nonblock). Re-allocates in ASCII_8BIT so
      # subsequent appends keep the binary encoding invariant.
      def consume_pending_write(n)
        return if n <= 0
        if n >= @pending_write_bytes.bytesize
          @pending_write_bytes = String.new(encoding: Encoding::ASCII_8BIT)
        else
          rest = @pending_write_bytes.byteslice(n..-1) ||
                 String.new(encoding: Encoding::ASCII_8BIT)
          @pending_write_bytes = String.new(rest, encoding: Encoding::ASCII_8BIT)
        end
      end

      def pending_write_empty?
        @pending_write_bytes.bytesize == 0
      end

      private

      def peer_label(sock)
        peer = sock.peeraddr
        "#{peer[2]}:#{peer[1]}"
      rescue StandardError
        "unknown"
      end
    end
  end
end
