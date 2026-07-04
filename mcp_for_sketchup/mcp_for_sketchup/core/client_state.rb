# mcp_for_sketchup/mcp_for_sketchup/core/client_state.rb
module MCPforSketchUp
  module Core
    class ClientState
      attr_reader   :id, :sock, :reader, :label, :pending_write_bytes,
                    :head_frame_remaining, :connected_at
      attr_accessor :handshaked, :client_version, :close_after_response,
                    :pending_write_deadline_at, :close_reason, :queued_frames

      def initialize(id, sock)
        @id                        = id
        @sock                      = sock
        @reader                    = Framing::FrameReader.new
        @label                     = "##{id}[#{peer_label(sock)}]"
        @handshaked                = false
        @client_version            = nil
        @close_after_response      = false
        @close_reason              = nil
        @pending_write_bytes       = String.new(encoding: Encoding::ASCII_8BIT)
        @pending_write_deadline_at = nil
        @head_frame_remaining      = 0
        # T-13.5: монотонная отметка подключения — pre-handshake дедлайн.
        @connected_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        # Финальное ревью (композиция T-13.2×T-13.5): сколько фреймов этого
        # клиента сейчас ждут в глобальной @frame_queue. Sweep «молчунов» по
        # этому счётчику отличает клиента, чей hello уже декодирован и просто
        # ждёт диспатч-капа за чужим флудом, от действительно молчащего.
        @queued_frames = 0
      end

      def closed?
        @sock.closed?
      end

      # Append bytes to the pending-write buffer. Always coerced to ASCII_8BIT
      # so concatenation with other binary frames cannot trigger an encoding
      # error. Returns the new buffer size.
      #
      # T-13.3: фрейм, лёгший на ПУСТОЙ буфер, становится head'ом — его размер
      # запоминается, чтобы overflow-guard сервера применял кап только к
      # хвосту за ним (head уже ограничен framing-капом 64 MiB).
      def append_pending_write(bytes)
        payload = bytes.b
        @head_frame_remaining = payload.bytesize if @pending_write_bytes.bytesize == 0
        @pending_write_bytes << payload
        @pending_write_bytes.bytesize
      end

      # Drop the leading `n` bytes from the pending-write buffer (after a
      # successful partial write_nonblock). Re-allocates in ASCII_8BIT so
      # subsequent appends keep the binary encoding invariant.
      def consume_pending_write(n)
        return if n <= 0
        consumed_from_head = [n, @head_frame_remaining].min
        @head_frame_remaining -= consumed_from_head
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
      rescue StandardError => e
        MCPforSketchUp::Core::Logger.log("DEBUG",
          "ClientState#peer_label: peer probe raised: " \
          "#{e.class}: #{e.message}")
        "unknown"
      end
    end
  end
end
