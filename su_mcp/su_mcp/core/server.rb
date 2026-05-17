# su_mcp/su_mcp/core/server.rb
require "json"
require "socket"

module SU_MCP
  module Core
    class Server
      TIMER_INTERVAL          = 0.1     # seconds between ticks
      READ_CHUNK              = 64 * 1024
      READ_MAX_ITERATIONS     = 50      # per client per tick
      WRITE_SELECT_TIMEOUT_S  = 1.0     # write probe (per client per write)
      ACCEPT_ABORTED_MAX      = 10      # defensive cap on ECONNABORTED churn

      def initialize
        @server         = nil
        @clients        = {}    # sock => ClientState
        @frame_queue    = []    # [[ClientState, body_bytes], ...]
        @next_client_id = 0
        @running        = false
        @timer_id       = nil
        @processing     = false
      end

      def start
        return if @running
        @server = TCPServer.new(Config.host, Config.port)
        @running = true
        @timer_id = ::UI.start_timer(TIMER_INTERVAL, true) { on_timer_tick }
      end

      def stop
        @running = false
        ::UI.stop_timer(@timer_id) if @timer_id
        @timer_id = nil
        @clients.values.each { |state| close_client(state, "server_stop") }
        if @server
          begin
            @server.close
          rescue StandardError
            # ignore — best-effort cleanup
          end
        end
        @server = nil
      end

      private

      def on_timer_tick
        return unless @running
        return if @processing
        @processing = true
        begin
          accept_pending_clients
          drain_reads_all_clients
          process_frame_queue
        rescue StandardError => e
          # Server-level error — log only. Do NOT reset clients.
          Logger.log_error("server.timer", e)
        ensure
          @processing = false
        end
      end

      def accept_pending_clients
        aborted = 0
        loop do
          begin
            sock = @server.accept_nonblock
          rescue IO::WaitReadable
            return
          rescue Errno::ECONNABORTED
            aborted += 1
            return if aborted >= ACCEPT_ABORTED_MAX
            next
          end
          begin
            sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true)
          rescue StandardError => e
            # accept succeeded but the socket is unusable. Close it; do NOT
            # register — registered-or-closed is the invariant we keep.
            begin
              sock.close
            rescue StandardError
              # best-effort
            end
            Logger.log_error("server.accept_setsockopt", e)
            next
          end
          state = ClientState.new(@next_client_id, sock)
          @next_client_id += 1
          @clients[sock] = state
          Logger.log_tool("server", "client_connected", client_label: state.label)
        end
      end

      # Global FIFO: `@clients` is a Hash, whose iteration order in Ruby 1.9+
      # is the *insertion order* (i.e. the order in which TCP accept assigned
      # each client). For each client we drain reads in that order, appending
      # decoded frames to `@frame_queue` as they become available. The
      # resulting dispatch order is therefore "FIFO by (accept-order, then
      # decoded-frame arrival within that client)". This is deliberate — see
      # design §5.3 / §13.1 for the rationale (round-robin reads were
      # considered and explicitly rejected).
      def drain_reads_all_clients
        # snapshot — close_client may modify @clients mid-iteration
        @clients.values.each do |state|
          drain_one_client(state)
        end
      end

      def drain_one_client(state)
        return if state.closed?
        iterations = 0
        loop do
          if iterations >= READ_MAX_ITERATIONS
            return    # process the rest on next tick
          end
          chunk = state.sock.read_nonblock(READ_CHUNK)
          state.reader.feed(chunk).each do |body|
            @frame_queue << [state, body]
          end
          iterations += 1
        end
      rescue IO::WaitReadable
        # kernel buffer drained; move on
      rescue EOFError, Errno::ECONNRESET, Errno::EPIPE
        close_client(state, "client_disconnected")
      rescue StructuredError => e
        # framing error (zero-length / oversize) — stream desynced.
        send_transport_error(state, e, nil)
        close_client(state, "framing_error: #{e.message}")
      end

      def process_frame_queue
        until @frame_queue.empty?
          state, body = @frame_queue.shift
          next if state.closed?

          response = handle_frame(state, body)
          if response
            write_response(state, response)
          end
        end
      end

      def handle_frame(state, body)
        request = JSON.parse(body)
        Handlers::Dispatch.handle(request)
      rescue JSON::ParserError => e
        Logger.log_error("server.parse", e, client_label: state.label)
        # JSON-RPC §5.1: parse-error responses use id=null.
        send_transport_error(state,
          StructuredError.new(-32700, "parse error: #{e.message}"), nil)
        close_client(state, "parse_error")
        nil
      rescue StandardError => e
        Logger.log_error("server.handler", e, client_label: state.label)
        rid = request.is_a?(Hash) ? request["id"] : nil
        Errors.build_error_response(-32603, e.message,
          Errors.exception_to_data(e, "?", {}), rid)
      end

      def write_response(state, response)
        body = encode_response_body(response)
        frame = Framing.encode_frame(body)
        unless io_select_writable?(state.sock)
          Logger.log_tool("server", "write_timeout",
            client_label: state.label)
          close_client(state, "write_timeout")
          return
        end
        state.sock.write(frame)
        state.sock.flush
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError
        close_client(state, "write_failed")
      end

      # Indirection lets test code stub IO.select cleanly.
      def io_select_writable?(sock)
        IO.select(nil, [sock], nil, WRITE_SELECT_TIMEOUT_S)
      end

      def encode_response_body(response)
        response["server_version"] = Core::Compat::SERVER_VERSION if response.is_a?(Hash)
        JSON.generate(response)
      rescue JSON::GeneratorError, Encoding::UndefinedConversionError => e
        Logger.log_error("server.encode", e)
        rid = response.is_a?(Hash) ? response["id"] : nil
        safe_msg = e.message.encode("utf-8", invalid: :replace, undef: :replace)
        fallback = Errors.build_error_response(-32603,
          "response not serializable: #{e.class.name}",
          { "error" => safe_msg }, rid)
        fallback["server_version"] = Core::Compat::SERVER_VERSION
        JSON.generate(fallback)
      end

      def send_transport_error(state, structured_error, request_id)
        return if state.closed?
        response = Errors.build_error_response(structured_error.code,
                                               structured_error.message,
                                               structured_error.data,
                                               request_id)
        write_response(state, response)
      rescue StandardError => e
        Logger.log_error("server.send_transport_error", e,
          client_label: state.label)
      end

      def close_client(state, reason)
        # Idempotent. `@clients` membership is the source of truth for
        # "still tracked"; `state.closed?` only decides whether sock.close
        # is needed. A second call (e.g. drain_one_client after a
        # write_response rescue already evicted the client) is a no-op
        # and does NOT log a duplicate "client_disconnected" line.
        return unless @clients.key?(state.sock)
        @clients.delete(state.sock)
        begin
          state.sock.close unless state.closed?
        rescue StandardError
          # best-effort
        end
        Logger.log_tool("server", "client_disconnected",
          "reason=#{reason}",
          client_label: state.label)
      end
    end
  end
end
