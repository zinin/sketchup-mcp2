# su_mcp/su_mcp/core/client_state.rb
module SU_MCP
  module Core
    class ClientState
      attr_reader   :id, :sock, :reader, :label
      attr_accessor :handshaked, :client_version, :close_after_response

      def initialize(id, sock)
        @id                   = id
        @sock                 = sock
        @reader               = Framing::FrameReader.new
        @label                = "##{id}[#{peer_label(sock)}]"
        @handshaked           = false
        @client_version       = nil
        @close_after_response = false
      end

      def closed?
        @sock.closed?
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
