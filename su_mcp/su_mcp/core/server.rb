# su_mcp/su_mcp/core/server.rb
require "json"
require "socket"

module SU_MCP
  module Core
    class Server
      TIMER_INTERVAL          = 0.1     # seconds between ticks
      READ_CHUNK              = 64 * 1024
      READ_MAX_ITERATIONS     = 50      # ≈3.2MB max drained per tick (50 × 64KB)
      # 30s оказался слишком агрессивен для интерактивных LLM-сессий: между
      # двумя tool-call'ами легко проходит больше времени (генерация модели,
      # ввод пользователя). Python-сторона дополнительно умеет reconnect+retry
      # один раз при stale-socket — это даёт «belt-and-suspenders».
      IDLE_DEADLINE_S         = 300.0   # without progress → reset_client
      WRITE_SELECT_TIMEOUT_S  = 1.0     # if writer not ready within this → reset

      def initialize
        @server = nil
        @client = nil
        @reader = nil
        @running = false
        @timer_id = nil
        @processing = false
        @last_progress_at = nil
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
        reset_client  # closes @client cleanly
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
        return if @processing  # reentrance guard (timer schedules ticks even while previous in-flight)
        @processing = true
        begin
          if @client.nil?
            accept_one_client
            return
          end
          enforce_idle_deadline!
          # idle deadline may have just reset @client — skip read attempt this
          # tick to avoid noisy NoMethodError → caught-by-outer-rescue path.
          return if @client.nil?
          read_pending_chunks
        rescue StandardError => e
          Logger.log_error("server.timer", e)
          reset_client
        ensure
          @processing = false
        end
      end

      def accept_one_client
        ready = IO.select([@server], nil, nil, 0)
        return unless ready
        @client = @server.accept_nonblock
        @reader = Framing::FrameReader.new
        @last_progress_at = Time.now
        Logger.log_tool("server", "client_connected")
      rescue IO::WaitReadable, Errno::ECONNABORTED
        # nothing pending or transient Windows abort; retry on next tick
      end

      def enforce_idle_deadline!
        return unless @last_progress_at
        return if Time.now - @last_progress_at < IDLE_DEADLINE_S
        Logger.log_tool("server", "idle_timeout", "after #{IDLE_DEADLINE_S}s without progress")
        reset_client
      end

      def read_pending_chunks
        iterations = 0
        loop do
          if iterations >= READ_MAX_ITERATIONS
            # Bounded — process the rest on next tick. Don't block SketchUp UI.
            return
          end
          chunk = @client.read_nonblock(READ_CHUNK)
          @last_progress_at = Time.now
          # FrameReader#feed may yield several decoded bodies in one chunk
          # (pipelined frames). If any handle_frame triggers reset_client
          # (parse error, write timeout, broken pipe), the remaining frames
          # must NOT execute — their handlers would mutate the model with no
          # live client to receive a response.
          @reader.feed(chunk).each do |body|
            handle_frame(body)
            return if @client.nil?
          end
          iterations += 1
        end
      rescue IO::WaitReadable
        # buffer drained; wait for next tick
      rescue EOFError, Errno::ECONNRESET, Errno::EPIPE
        Logger.log_tool("server", "client_disconnected")
        reset_client
      rescue StructuredError => e
        # framing error (zero-length / oversize) — stream is desynced.
        send_transport_error(e, nil)
        reset_client
      end

      def handle_frame(body)
        request = nil  # initialize before parse so rescue below is safe even on JSON errors
        request = JSON.parse(body)
        response = Handlers::Dispatch.handle(request)
        return if response.nil?  # JSON-RPC notification — no reply
        write_response(response)
      rescue JSON::ParserError => e
        # Cannot trust stream after parse error; drop the client.
        Logger.log_error("server.parse", e)
        send_transport_error(StructuredError.new(-32700, "parse error: #{e.message}"), nil)
        reset_client
      rescue StandardError => e
        # Handler-level catch-all (defensive — Dispatch already wraps everything).
        Logger.log_error("server.handler", e)
        rid = request.is_a?(Hash) ? request["id"] : nil
        err_response = Errors.build_error_response(-32603, e.message,
          Errors.exception_to_data(e, "?", {}), rid)
        write_response(err_response)
      end

      def write_response(response)
        body = encode_response_body(response)
        frame = Framing.encode_frame(body)
        # Probe writability before blocking write — protects against client
        # that stops reading (full kernel buffer would otherwise hang us).
        ready = IO.select(nil, [@client], nil, WRITE_SELECT_TIMEOUT_S)
        unless ready
          Logger.log_tool("server", "write_timeout")
          reset_client
          return
        end
        @client.write(frame)
        @client.flush
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError
        # client gone mid-write — drop it, server stays up
        reset_client
      end

      # JSON.generate may raise on unencodable values (e.g. binary strings,
      # NaN/Infinity, ill-formed UTF-8) — raised once, the caller would have
      # no response to send and the client would hang waiting for one.
      # Fall back to a generic -32603 envelope referencing the original id.
      def encode_response_body(response)
        JSON.generate(response)
      rescue JSON::GeneratorError, Encoding::UndefinedConversionError => e
        Logger.log_error("server.encode", e)
        rid = response.is_a?(Hash) ? response["id"] : nil
        # Sanitize e.message so this fallback can't itself trip on ill-formed
        # bytes inherited from the original response (which is what brought
        # us here in the first place).
        safe_msg = e.message.encode("utf-8", invalid: :replace, undef: :replace)
        JSON.generate(Errors.build_error_response(-32603,
          "response not serializable: #{e.class.name}",
          { "error" => safe_msg }, rid))
      end

      def send_transport_error(structured_error, request_id)
        return unless @client
        response = Errors.build_error_response(structured_error.code,
                                               structured_error.message,
                                               structured_error.data,
                                               request_id)
        write_response(response)
      rescue StandardError => e
        Logger.log_error("server.send_transport_error", e)
      end

      def reset_client
        if @client
          begin
            @client.close
          rescue StandardError
            # ignore
          end
        end
        @client = nil
        @reader = nil
        @last_progress_at = nil
      end
    end
  end
end
