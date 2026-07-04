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
      WRITE_DEADLINE_S          = 5.0     # idle (no-forward-progress) drain deadline
      PENDING_WRITE_MAX_BYTES   = 16 * 1024 * 1024  # 16 MiB per-client buffer cap
      MAX_CLIENTS               = 64      # refuse connections beyond this (review F3)
      # T-13.2: связка капов (M-08 ревью). Чтение (READ_MAX_ITERATIONS=50
      # НА КЛИЕНТА) может опережать глобальный диспатч (50 НА ТИК); при
      # TIMER_INTERVAL 0.1 с потолок ~500 диспатчей/с — за глаза для
      # односкетчаповых нагрузок. Разница поглощается очередью до
      # FRAME_QUEUE_SOFT_MAX (~5 тиков разгрузки), дальше чтение
      # приостанавливается и TCP-окно передаёт backpressure клиенту.
      # Стоп чтения ГЛОБАЛЬНЫЙ (все сокеты) — осознанно: очередь одна,
      # FIFO-порядок важнее fairness чтения; kernel-буферы данные удержат.
      DISPATCH_MAX_PER_TICK     = 50      # фреймов за тик; флуд мелких фреймов не должен морозить UI (T-13.2)
      FRAME_QUEUE_SOFT_MAX      = 256     # очередь насыщена — чтение приостанавливается (T-13.2, P-06)
      PRE_HANDSHAKE_DEADLINE_S  = 30.0    # коннект без валидного hello закрывается (T-13.5)

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
        # Server-side trail for the LAN-exposure risk the Settings dialog already
        # warns about in its UI. Fires once, here at the actual bind site, so a
        # non-loopback bind (e.g. 0.0.0.0) leaves a WARN in the console/log even
        # if the server was started from the menu rather than the dialog.
        warn_if_exposed_bind(Config.host)
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

      # Loopback hosts that keep the server reachable only from this machine.
      # Anything else (0.0.0.0, ::, an explicit LAN IP, …) is reachable by other
      # hosts on the network and warrants the exposure warning.
      LOOPBACK_HOSTS = ["127.0.0.1", "::1", "localhost"].freeze

      def loopback_host?(host)
        h = host.to_s.strip.downcase
        LOOPBACK_HOSTS.include?(h) || h.start_with?("127.")
      end

      # T-13.4: все дедлайны — на монотонных часах; wall-clock (Time.now)
      # прыгает при NTP-коррекции и переводе времени.
      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Concise server-log echo of the UI's host-security warning. Emitted at
      # bind for any non-loopback host: such a bind exposes the unauthenticated
      # MCP server — including eval_ruby (arbitrary Ruby) — to the LAN.
      def warn_if_exposed_bind(host)
        return if loopback_host?(host)
        Logger.log("WARN",
          "bound to non-loopback host #{host} — the MCP server (incl. eval_ruby: " \
          "arbitrary Ruby) is reachable by other machines on the network with NO " \
          "authentication. Use 127.0.0.1 unless this is a trusted isolated network.")
      end

      def on_timer_tick
        return unless @running
        return if @processing
        @processing = true
        begin
          accept_pending_clients
          close_pre_handshake_stragglers
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

      # T-13.5: коннект, не приславший валидный hello за
      # PRE_HANDSHAKE_DEADLINE_S, закрывается. Без этого 64 молчаливых
      # TCP-коннекта навсегда исчерпывают слоты MAX_CLIENTS (DoS при
      # exposed-bind; до дедлайна слоты, естественно, заняты — 30 с и есть
      # граница этой уязвимости). 30 с заведомо щедро: hello уходит первым
      # же фреймом сразу после connect(), даже WAN-RTT на порядки меньше.
      # Wire-протокол не меняется — это чисто серверный таймер.
      def close_pre_handshake_stragglers
        now = monotonic_now
        @clients.values.each do |state|
          next if state.handshaked
          # P-07: клиент с reject/error-envelope в буфере доживает до
          # доставки — его закроет close-after-drain (свой WRITE_DEADLINE_S).
          next if state.close_after_response
          next if now - state.connected_at < PRE_HANDSHAKE_DEADLINE_S
          Logger.log_tool("server", "pre_handshake_timeout",
            client_label: state.label)
          close_client(state, "pre_handshake_timeout")
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
        # T-13.2: backpressure. Очередь и так забита — оставляем данные в
        # kernel-буфере (TCP-окно заполнится, клиент притормозит сам). FIFO
        # не страдает: недочитанное придёт в том же порядке следующим тиком.
        return if @frame_queue.length >= FRAME_QUEUE_SOFT_MAX
        # `Hash#values` returns a fresh array — iteration is safe even when
        # drain_one_client triggers close_client, which mutates @clients.
        @clients.values.each do |state|
          drain_one_client(state)
        end
      end

      def drain_one_client(state)
        return if state.closed?
        # T-13.1: решение о закрытии принято (framing/parse-ошибка) — стрим
        # рассинхронизирован, новые чтения бессмысленны до close-after-drain.
        return if state.close_after_response
        iterations = 0
        loop do
          if iterations >= READ_MAX_ITERATIONS
            return    # process the rest on next tick
          end
          chunk = state.sock.read_nonblock(READ_CHUNK)
          state.reader.feed(chunk).each do |body|
            @frame_queue << [state, body]
          end
          # P-06: стоп посреди дренажа, как только очередь насыщена; перелёт
          # ограничен фреймами ОДНОГО read_nonblock-куска (≤64 KiB), а не
          # всем бюджетом READ_MAX_ITERATIONS.
          break if @frame_queue.length >= FRAME_QUEUE_SOFT_MAX
          iterations += 1
        end
      rescue IO::WaitReadable
        # kernel buffer drained; move on
      rescue EOFError, Errno::ECONNRESET, Errno::EPIPE
        close_client(state, "client_disconnected")
      rescue StructuredError => e
        # framing error (zero-length / oversize) — stream desynced. T-13.1:
        # НЕ закрывать сразу — при занятом send-буфере error-envelope молча
        # терялся. Глушим чтение (guard выше), закрываемся после полного
        # дренажа буфера — механизм close_after_response, как у
        # reject_handshake.
        state.close_reason = "framing_error: #{e.message}"
        state.close_after_response = true
        send_transport_error(state, e, nil)
      rescue StandardError => e
        # Defense-in-depth: any other unexpected exception (e.g. SystemCallError
        # from a bad fd, encoding error, etc.) must close the offending client
        # so the per-client isolation invariant holds — otherwise the bad
        # state stays in @clients and the same error fires every tick.
        Logger.log_error("server.drain", e, client_label: state.label)
        close_client(state, "drain_error: #{e.class.name}")
      end

      def process_frame_queue
        dispatched = 0
        until @frame_queue.empty?
          # T-13.2: кап на тик. shift с головы + return сохраняют FIFO —
          # остаток обрабатывается следующим тиком, UI SketchUp дышит.
          return if dispatched >= DISPATCH_MAX_PER_TICK
          state, body = @frame_queue.shift
          next if state.closed? || state.close_after_response

          response = handle_frame(state, body)
          if response
            write_response(state, response)
          end
          dispatched += 1
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
        state.close_reason = "parse_error"
        state.close_after_response = true
        send_transport_error(state,
          StructuredError.new(-32700, "parse error: #{e.message}"), nil)
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
        # Overflow guard (T-13.3): кап применяется к ХВОСТУ за пределами ещё
        # дренирующегося head-фрейма. Head, допущенный на пустой буфер, уже
        # ограничен framing-капом (64 MiB) и не приговаривает клиента: раньше
        # один легитимный >16 MiB ответ (например ~43 MiB скриншот) плюс ЛЮБОЙ
        # следующий фрейм закрывали соединение. Патологическое накопление
        # хвоста по-прежнему режется. Осознанный trade-off: фрейм крупнее
        # PENDING_WRITE_MAX_BYTES при ЛЮБОМ непустом бэклоге (даже если head
        # ещё дренируется) всё равно закрывает клиента — исключение только для
        # head, допущенного на ПУСТОЙ буфер; конвейеризация двух >16 MiB
        # ответов не поддерживается by design.
        backlog      = state.pending_write_bytes.bytesize
        tail_backlog = backlog - state.head_frame_remaining
        projected    = tail_backlog + frame.bytesize
        if backlog > 0 && projected > PENDING_WRITE_MAX_BYTES
          Logger.log_tool("server", "pending_write_overflow",
            "limit=#{PENDING_WRITE_MAX_BYTES} projected_tail=#{projected} backlog=#{backlog}",
            client_label: state.label)
          close_client(state, "pending_write_overflow")
          return
        end
        state.append_pending_write(frame)
        if state.pending_write_deadline_at.nil?
          state.pending_write_deadline_at = monotonic_now + WRITE_DEADLINE_S
        end
        # Attempt to drain right now — avoids wasting one tick when the
        # kernel send-buffer is ready.
        flush_pending_write(state)
      end

      # Cooperative non-blocking drain of the per-client pending-write buffer.
      # Called both from write_response (right after appending a new frame)
      # and from flush_pending_writes_all_clients (each tick). On full drain
      # honours close_after_response (used by handshake rejection).
      #
      # The deadline is an IDLE timeout, not a total-transfer cap (review #7):
      # it bounds how long the buffer may go with NO forward progress. Every
      # time write_nonblock actually moves bytes we push the deadline out by
      # WRITE_DEADLINE_S, so a legitimately slow-but-progressing client (e.g. a
      # ~43 MiB screenshot trickling over a slow link) is NOT force-closed
      # mid-flush — only a genuinely stalled peer (send-buffer full, no drain
      # for WRITE_DEADLINE_S) is.
      def flush_pending_write(state)
        return if state.closed?
        return if state.pending_write_empty?

        if state.pending_write_deadline_at &&
           monotonic_now > state.pending_write_deadline_at
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
              close_client(state, state.close_reason || "handshake_rejected")
            end
            return
          end
          # Forward progress: bytes left the buffer but it isn't empty yet.
          # Extend the idle deadline so a slow-but-moving transfer survives —
          # only a stall (no progress for WRITE_DEADLINE_S) trips the timeout.
          if n > 0
            state.pending_write_deadline_at = monotonic_now + WRITE_DEADLINE_S
          else
            # Defensive: write_nonblock claimed success but wrote zero bytes.
            # Break out to avoid a tight loop; treat it like WaitWritable —
            # retry next tick (deadline preserved, so a true stall still fires).
            return
          end
        end
      rescue IO::WaitWritable
        # Kernel send-buffer full — preserve buffer + deadline; retry next tick.
        # No forward progress here, so the deadline is deliberately NOT extended.
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
