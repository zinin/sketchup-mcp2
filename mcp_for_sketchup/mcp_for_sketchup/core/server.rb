# mcp_for_sketchup/mcp_for_sketchup/core/server.rb
require "json"
require "socket"

module MCPforSketchUp
  module Core
    class Server
      TIMER_INTERVAL            = 0.1     # seconds between ticks
      READ_CHUNK                = 64 * 1024
      READ_MAX_ITERATIONS       = 50      # per client per tick
      ACCEPT_ABORTED_MAX        = 10      # defensive cap on ECONNABORTED churn
      WRITE_DEADLINE_S          = 5.0     # cumulative drain deadline per pending-write
      PENDING_WRITE_MAX_BYTES   = 16 * 1024 * 1024  # 16 MiB per-client buffer cap
      MAX_CLIENTS               = 64      # refuse connections beyond this (review F3)

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
          rescue StandardError => e
            Logger.log("DEBUG",
              "Server.stop: tcpserver close raised: #{e.class}: #{e.message}")
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
          flush_pending_writes_all_clients
          drain_reads_all_clients
          process_frame_queue
        rescue StandardError => e
          # Server-level error — log only. Do NOT reset clients.
          Logger.log_error("server.timer", e)
        ensure
          @processing = false
        end
      end

      # Iterate `@clients.values` (Hash#values returns a snapshot — same
      # pattern as drain_reads_all_clients) and try to drain any in-flight
      # writes. Per-client errors close only the offending client.
      def flush_pending_writes_all_clients
        @clients.values.each do |state|
          flush_pending_write(state)
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
          # Refuse connections beyond MAX_CLIENTS to bound FD/memory use when
          # bound to a non-loopback host (review F3). Close without registering
          # — keeps the registered-or-closed invariant.
          if @clients.size >= MAX_CLIENTS
            begin
              sock.close
            rescue StandardError => e
              Logger.log("DEBUG",
                "Server.accept: over-cap close raised: #{e.class}: #{e.message}")
            end
            Logger.log_tool("server", "client_rejected",
              "reason=max_clients limit=#{MAX_CLIENTS}")
            next
          end
          begin
            sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true)
          rescue StandardError => e
            # accept succeeded but the socket is unusable. Close it; do NOT
            # register — registered-or-closed is the invariant we keep.
            begin
              sock.close
            rescue StandardError => close_err
              Logger.log("DEBUG",
                "Server.accept: post-setsockopt-failure close raised: #{close_err.class}: #{close_err.message}")
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
        # `Hash#values` returns a fresh array — iteration is safe even when
        # drain_one_client triggers close_client, which mutates @clients.
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
      rescue StandardError => e
        # Defense-in-depth: any other unexpected exception (e.g. SystemCallError
        # from a bad fd, encoding error, etc.) must close the offending client
        # so the per-client isolation invariant holds — otherwise the bad
        # state stays in @clients and the same error fires every tick.
        Logger.log_error("server.drain", e, client_label: state.label)
        close_client(state, "drain_error: #{e.class.name}")
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

        if !state.handshaked
          is_notification = request.is_a?(Hash) && !request.key?("id")
          if is_notification
            # JSON-RPC §4.1: notifications never receive a response. Pre-handshake
            # notifications are a protocol violation; close silently.
            close_client(state, "pre_handshake_notification")
            return nil
          end
          handle_pre_handshake(state, request)
        else
          Handlers::Dispatch.handle(request)
        end
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

      def handle_pre_handshake(state, request)
        unless request.is_a?(Hash) && request["jsonrpc"] == "2.0"
          return reject_handshake(state, request,
            StructuredError.new(-32600, "invalid envelope (pre-handshake)"))
        end
        method = request["method"]

        unless method == "hello"
          return reject_handshake(state, request,
            StructuredError.new(-32600,
              "first method must be 'hello' (got: #{method.inspect})"))
        end

        params = request["params"]
        unless params.is_a?(Hash) && params["client_version"].is_a?(String)
          return reject_handshake(state, request,
            StructuredError.new(-32602,
              "hello requires params.client_version (string)"))
        end

        begin
          Core::Compat.check_python_version(params["client_version"])
        rescue StructuredError => e
          return reject_handshake(state, request, e)
        end

        state.handshaked     = true
        state.client_version = params["client_version"]
        Logger.log_tool("server", "handshake_ok",
          "client_version=#{state.client_version}",
          client_label: state.label)

        # Build a raw JSON-RPC envelope inline — do NOT use
        # Handlers::Dispatch.build_success_response. That wrapper turns
        # `result` into the MCP `tools/call` shape
        # `{content:[{type:text,text:...}], isError:false}`, which would
        # break the Python client's `result.server_version` / `result.client_id`
        # reads on the handshake response.
        {
          "jsonrpc" => "2.0",
          "result"  => {
            "server_version" => Core::Compat::SERVER_VERSION,
            "client_id"      => state.id,
          },
          "id"      => request["id"],
        }
      end

      def reject_handshake(state, request, structured_error)
        rid = request.is_a?(Hash) ? request["id"] : nil
        Logger.log_tool("server", "handshake_rejected",
          "code=#{structured_error.code} msg=#{structured_error.message}",
          client_label: state.label)
        state.close_after_response = true
        Errors.build_error_response(structured_error.code,
          structured_error.message,
          Errors.exception_to_data(structured_error, "hello", {}), rid)
      end

      def write_response(state, response)
        return if state.closed?
        body  = encode_response_body(response)
        frame =
          begin
            Framing.encode_frame(body)
          rescue StructuredError => e
            # Body exceeded the 64 MiB framing cap (or was unexpectedly empty).
            # Per the per-client isolation invariant we still owe the caller a
            # response. Try a small fallback envelope; if that won't encode
            # either, close this client and continue serving the rest.
            Logger.log_error("server.encode_frame", e, client_label: state.label)
            rid = response.is_a?(Hash) ? response["id"] : nil
            fallback = Errors.build_error_response(-32603,
              "response too large for transport",
              Errors.exception_to_data(e, "?", {}), rid)
            begin
              Framing.encode_frame(JSON.generate(fallback))
            rescue StandardError
              close_client(state, "encode_frame_failed")
              return
            end
          end

        # Append to the per-client buffer and try to drain immediately.
        # Overflow guard: cap the cumulative pending bytes per client to
        # protect against pathological accumulation when many handlers
        # reply faster than the client can read. The cap applies to
        # ACCUMULATION only — a single frame is already bounded by the framing
        # layer (Config::MAX_MESSAGE_SIZE, 64 MiB), so it must always be allowed
        # onto an EMPTY buffer; otherwise a legitimate large reply (e.g. a
        # get_viewport_screenshot PNG, up to ~43 MiB base64) would be wrongly
        # force-closed. Fire only when a backlog already exists.
        backlog   = state.pending_write_bytes.bytesize
        projected = backlog + frame.bytesize
        if backlog > 0 && projected > PENDING_WRITE_MAX_BYTES
          Logger.log_tool("server", "pending_write_overflow",
            "limit=#{PENDING_WRITE_MAX_BYTES} projected=#{projected} backlog=#{backlog}",
            client_label: state.label)
          close_client(state, "pending_write_overflow")
          return
        end
        state.append_pending_write(frame)
        if state.pending_write_deadline_at.nil?
          state.pending_write_deadline_at = Time.now + WRITE_DEADLINE_S
        end
        # Attempt to drain right now — avoids wasting one tick when the
        # kernel send-buffer is ready.
        flush_pending_write(state)
      end

      # Cooperative non-blocking drain of the per-client pending-write buffer.
      # Called both from write_response (right after appending a new frame)
      # and from flush_pending_writes_all_clients (each tick). On full drain
      # honours close_after_response (used by handshake rejection).
      def flush_pending_write(state)
        return if state.closed?
        return if state.pending_write_empty?

        if state.pending_write_deadline_at &&
           Time.now > state.pending_write_deadline_at
          Logger.log_tool("server", "write_timeout",
            client_label: state.label)
          close_client(state, "write_timeout")
          return
        end

        loop do
          n = state.sock.write_nonblock(state.pending_write_bytes)
          state.consume_pending_write(n)
          if state.pending_write_empty?
            state.pending_write_deadline_at = nil
            if state.close_after_response
              close_client(state, "handshake_rejected")
            end
            return
          end
          # Defensive: if write_nonblock claimed success but wrote zero bytes,
          # break out to avoid a tight loop. Treat it like WaitWritable —
          # retry next tick.
          return if n <= 0
        end
      rescue IO::WaitWritable
        # Kernel send-buffer full — preserve buffer + deadline; retry next tick.
        return
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError
        close_client(state, "write_failed")
      rescue StandardError => e
        # Defense-in-depth: any other unexpected exception (encoding error
        # on a misbehaving socket, etc.) must close the offending client so
        # the per-client isolation invariant holds.
        Logger.log_error("server.flush_pending_write", e, client_label: state.label)
        close_client(state, "write_error: #{e.class.name}")
      end

      def encode_response_body(response)
        JSON.generate(response)
      rescue JSON::GeneratorError, Encoding::UndefinedConversionError => e
        Logger.log_error("server.encode", e)
        rid = response.is_a?(Hash) ? response["id"] : nil
        safe_msg = e.message.encode("utf-8", invalid: :replace, undef: :replace)
        fallback = Errors.build_error_response(-32603,
          "response not serializable: #{e.class.name}",
          { "error" => safe_msg }, rid)
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
        rescue StandardError => e
          Logger.log("DEBUG",
            "Server.close_client: sock close raised: #{e.class}: #{e.message}")
        end
        Logger.log_tool("server", "client_disconnected",
          "reason=#{reason}",
          client_label: state.label)
      end
    end
  end
end
