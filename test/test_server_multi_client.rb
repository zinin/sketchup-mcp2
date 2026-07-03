# test/test_server_multi_client.rb — Server multi-client unit tests.
# Uses FakeSocket + FakeServer to drive the tick. FakeSocket#write_nonblock
# accepts all bytes synchronously by default; per-test stubs simulate partial
# writes or IO::WaitWritable backpressure.
require "minitest/autorun"
require "json"

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/compat"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/config"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/logger"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/framing"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/client_state"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/server"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/dispatch"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/system"
require_relative "support/fake_socket"
require_relative "support/frame_helpers"

class TestServerMultiClient < Minitest::Test
  include FrameHelpers

  # Prepend this to read_chunks of any test that wants to drive
  # post-handshake traffic. The server now requires the first frame
  # from any client to be a JSON-RPC `hello` carrying client_version.
  def hello_frame
    fr("jsonrpc" => "2.0", "method" => "hello",
       "params" => { "client_version" => MCPforSketchUp::Core::Compat::MIN_PYTHON },
       "id" => 0)
  end

  def setup
    MCPforSketchUp::Core::Config.host      = "127.0.0.1"
    MCPforSketchUp::Core::Config.port      = 9876
    MCPforSketchUp::Core::Config.log_level = "ERROR"   # silence INFO chatter
  end

  # Build a Server with a FakeServer in place of TCPServer and run a
  # single tick. Returns the server instance for further inspection.
  def run_one_tick(fake_server)
    srv = MCPforSketchUp::Core::Server.new
    srv.instance_variable_set(:@server, fake_server)
    srv.instance_variable_set(:@running, true)
    srv.send(:on_timer_tick)
    srv
  end

  # ---------- Accept loop ----------

  def test_accept_drains_backlog_in_one_tick
    fs = FakeServer.new
    a = FakeSocket.new
    b = FakeSocket.new
    fs.queue_accept(a)
    fs.queue_accept(b)
    srv = run_one_tick(fs)
    assert_equal 2, srv.instance_variable_get(:@clients).size
  end

  def test_each_accepted_client_gets_unique_monotonic_id
    fs = FakeServer.new
    fs.queue_accept(FakeSocket.new)
    fs.queue_accept(FakeSocket.new)
    fs.queue_accept(FakeSocket.new)
    srv = run_one_tick(fs)
    ids = srv.instance_variable_get(:@clients).values.map(&:id).sort
    assert_equal [0, 1, 2], ids
  end

  def test_accept_refuses_connections_beyond_max_clients
    # Review F3: accept must refuse (close, not register) connections beyond
    # MAX_CLIENTS so a flood of opens can't exhaust FDs/memory on a non-loopback
    # bind. Drive accept_pending_clients directly with @clients pre-filled to
    # the cap — no need for MAX_CLIENTS real sockets.
    max = MCPforSketchUp::Core::Server::MAX_CLIENTS
    srv = MCPforSketchUp::Core::Server.new
    clients = srv.instance_variable_get(:@clients)
    max.times do |i|
      s = FakeSocket.new
      clients[s] = MCPforSketchUp::Core::ClientState.new(i, s)
    end

    overflow = FakeSocket.new
    fs = FakeServer.new([overflow])
    srv.instance_variable_set(:@server, fs)
    srv.send(:accept_pending_clients)

    assert overflow.closed?, "connection beyond MAX_CLIENTS must be closed"
    assert_equal max, clients.size, "over-cap connection must NOT be registered"
    refute clients.key?(overflow), "over-cap socket must not be tracked"
  end

  # ---------- Single-client dispatch (sanity post-rewrite) ----------

  def test_single_client_dispatches_get_version
    req = fr("jsonrpc" => "2.0", "method" => "tools/call",
             "params" => { "name" => "get_version", "arguments" => {} },
             "id" => 1)
    sock = FakeSocket.new(read_chunks: [hello_frame + req])
    fs = FakeServer.new([sock])
    run_one_tick(fs)
    frames = all_frames(sock.written)
    assert_equal 2, frames.size                # hello reply + get_version reply
    assert_equal 0, frames[0]["id"]            # hello id
    assert_equal 1, frames[1]["id"]            # get_version id
    refute_nil frames[1]["result"]
  end

  # ---------- Global FIFO across clients ----------

  def test_fifo_across_two_clients_each_one_frame
    req_a = fr("jsonrpc" => "2.0", "method" => "tools/call",
               "params" => { "name" => "get_version", "arguments" => {} },
               "id" => 100)
    req_b = fr("jsonrpc" => "2.0", "method" => "tools/call",
               "params" => { "name" => "get_version", "arguments" => {} },
               "id" => 200)
    a = FakeSocket.new(read_chunks: [hello_frame + req_a])
    b = FakeSocket.new(read_chunks: [hello_frame + req_b])
    fs = FakeServer.new([a, b])
    run_one_tick(fs)
    # hello reply (id=0) + get_version reply
    assert_equal [0, 100], all_frames(a.written).map { |f| f["id"] }
    assert_equal [0, 200], all_frames(b.written).map { |f| f["id"] }
  end

  def test_pipelined_frames_from_one_client_processed_before_next_client
    a_chunks = (1..3).map { |i|
      fr("jsonrpc" => "2.0", "method" => "tools/call",
         "params" => { "name" => "get_version", "arguments" => {} },
         "id" => i)
    }
    b_chunk = fr("jsonrpc" => "2.0", "method" => "tools/call",
                 "params" => { "name" => "get_version", "arguments" => {} },
                 "id" => 99)
    a = FakeSocket.new(read_chunks: [hello_frame + a_chunks.join])
    b = FakeSocket.new(read_chunks: [hello_frame + b_chunk])
    fs = FakeServer.new([a, b])
    run_one_tick(fs)
    assert_equal [0, 1, 2, 3], all_frames(a.written).map { |f| f["id"] }
    assert_equal [0, 99],      all_frames(b.written).map { |f| f["id"] }
  end

  # ---------- Per-client error isolation ----------

  def test_eof_on_one_client_does_not_close_others
    a = FakeSocket.new
    a.push_eof
    b_req = fr("jsonrpc" => "2.0", "method" => "tools/call",
               "params" => { "name" => "get_version", "arguments" => {} },
               "id" => 1)
    b = FakeSocket.new(read_chunks: [hello_frame + b_req])
    fs = FakeServer.new([a, b])
    srv = run_one_tick(fs)
    assert a.closed?, "A should be closed on EOF"
    refute b.closed?, "B should remain connected"
    assert_equal [0, 1], all_frames(b.written).map { |f| f["id"] }
  end

  def test_parse_error_on_one_client_closes_only_that_client
    bad = "garbage{{{not-json"
    bad_frame = [bad.bytesize].pack("N") + bad
    # A: parse error in the framing/json layer closes A — no hello path applies.
    a = FakeSocket.new(read_chunks: [bad_frame])
    b_req = fr("jsonrpc" => "2.0", "method" => "tools/call",
               "params" => { "name" => "get_version", "arguments" => {} },
               "id" => 7)
    b = FakeSocket.new(read_chunks: [hello_frame + b_req])
    fs = FakeServer.new([a, b])
    run_one_tick(fs)
    assert a.closed?
    refute b.closed?
    frames_a = all_frames(a.written)
    assert_equal 1, frames_a.size
    assert_equal(-32700, frames_a[0]["error"]["code"])
    assert_equal [0, 7], all_frames(b.written).map { |f| f["id"] }
  end

  def test_framing_oversize_closes_only_that_client
    over = MCPforSketchUp::Core::Config::MAX_MESSAGE_SIZE + 1
    bad_frame = [over].pack("N")
    # A: framing error closes A before any handshake; no hello needed.
    a = FakeSocket.new(read_chunks: [bad_frame])
    b_req = fr("jsonrpc" => "2.0", "method" => "tools/call",
               "params" => { "name" => "get_version", "arguments" => {} },
               "id" => 9)
    b = FakeSocket.new(read_chunks: [hello_frame + b_req])
    fs = FakeServer.new([a, b])
    run_one_tick(fs)
    assert a.closed?
    refute b.closed?
    assert_equal [0, 9], all_frames(b.written).map { |f| f["id"] }
  end

  def test_disconnect_mid_queue_skips_remaining_pending_frames
    a_chunks = (1..3).map { |i|
      fr("jsonrpc" => "2.0", "method" => "tools/call",
         "params" => { "name" => "get_version", "arguments" => {} },
         "id" => i)
    }
    a = FakeSocket.new(read_chunks: [hello_frame + a_chunks.join])
    fs = FakeServer.new([a])
    srv = MCPforSketchUp::Core::Server.new
    srv.instance_variable_set(:@server, fs)
    srv.instance_variable_set(:@running, true)

    # Wrap write_response so it closes A right after the first *post-handshake*
    # write. Hello reply (id=0) is allowed through; A1 (id=1) is the trigger;
    # A2 and A3 should be skipped because state.closed? becomes true.
    closed_after = nil
    orig = MCPforSketchUp::Core::Server.instance_method(:write_response)
    MCPforSketchUp::Core::Server.send(:define_method, :write_response) do |state, response|
      orig.bind(self).call(state, response)
      if closed_after.nil? && response["id"] != 0
        closed_after = response["id"]
        send(:close_client, state, "test_force_close")
      end
    end

    begin
      srv.send(:on_timer_tick)
    ensure
      MCPforSketchUp::Core::Server.send(:define_method, :write_response, orig)
    end

    assert_equal [0, 1], all_frames(a.written).map { |f| f["id"] },
      "hello reply + A1 reply only — A2 and A3 skipped after force_close"
    assert a.closed?
  end

  def test_server_level_error_in_tick_does_not_reset_clients
    fs = FakeServer.new
    def fs.accept_nonblock
      raise StandardError, "synthetic"
    end
    sock = FakeSocket.new
    srv = MCPforSketchUp::Core::Server.new
    srv.instance_variable_set(:@server, fs)
    srv.instance_variable_set(:@running, true)
    state = MCPforSketchUp::Core::ClientState.new(0, sock)
    srv.instance_variable_get(:@clients)[sock] = state

    srv.send(:on_timer_tick)
    refute sock.closed?, "existing client must NOT be reset by server-level error"
    assert_equal 1, srv.instance_variable_get(:@clients).size
  end

  # ----- Addendum B: setsockopt-leak case -----
  def test_setsockopt_failure_closes_sock_and_skips_registration
    sock = FakeSocket.new
    def sock.setsockopt(*_); raise StandardError, "synthetic setsockopt"; end
    fs = FakeServer.new([sock])
    srv = run_one_tick(fs)
    assert sock.closed?, "sock with failing setsockopt must be closed"
    assert_equal 0, srv.instance_variable_get(:@clients).size
  end

  # ----- Task 7 subsumed: SO_KEEPALIVE assertion test -----
  def test_so_keepalive_enabled_on_accepted_clients
    sock = FakeSocket.new
    fs = FakeServer.new([sock])
    run_one_tick(fs)
    assert_includes sock.sockopts,
      [Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true],
      "every accepted client must have SO_KEEPALIVE enabled"
  end

  # ----- Addendum E: framing oversize delivers envelope BEFORE close -----
  def test_framing_oversize_writes_envelope_before_close
    over = MCPforSketchUp::Core::Config::MAX_MESSAGE_SIZE + 1
    bad_frame = [over].pack("N")
    a = FakeSocket.new(read_chunks: [bad_frame])
    fs = FakeServer.new([a])
    run_one_tick(fs)
    frames = all_frames(a.written)
    assert_equal 1, frames.size
    assert_equal(-32600, frames[0]["error"]["code"])
    assert a.closed?
  end

  # ----- Addendum E: partial-frame EOF (header only, no body) -----
  def test_partial_frame_eof_closes_client
    header_only = [100].pack("N")
    a = FakeSocket.new(read_chunks: [header_only])
    a.push_eof
    fs = FakeServer.new([a])
    run_one_tick(fs)
    assert a.closed?
  end

  # ----- Addendum E: frame split across two ticks -----
  def test_frame_split_across_ticks_dispatches_after_completion
    req = fr("jsonrpc" => "2.0", "method" => "tools/call",
             "params" => { "name" => "get_version", "arguments" => {} },
             "id" => 1)
    prefix = req.byteslice(0, 10)
    suffix = req.byteslice(10..-1)
    # Hello arrives complete in tick 1; the tools/call frame is split.
    a = FakeSocket.new(read_chunks: [hello_frame + prefix])
    fs = FakeServer.new([a])
    srv = MCPforSketchUp::Core::Server.new
    srv.instance_variable_set(:@server, fs)
    srv.instance_variable_set(:@running, true)
    srv.send(:on_timer_tick)
    # Only the hello reply lands in tick 1 — the tools/call is still incomplete.
    assert_equal [0], all_frames(a.written).map { |f| f["id"] },
      "only the hello reply should be written before the partial frame completes"
    a.push_read(suffix)
    srv.send(:on_timer_tick)
    frames = all_frames(a.written)
    assert_equal [0, 1], frames.map { |f| f["id"] }
  end

  # ---------- D3: non-blocking write path ----------

  def test_write_completes_in_single_tick_when_kernel_ready
    # FakeSocket#write_nonblock accepts all bytes by default — buffer should
    # drain to empty before the tick returns.
    req = fr("jsonrpc" => "2.0", "method" => "tools/call",
             "params" => { "name" => "get_version", "arguments" => {} },
             "id" => 1)
    sock = FakeSocket.new(read_chunks: [hello_frame + req])
    fs = FakeServer.new([sock])
    srv = run_one_tick(fs)

    state = srv.instance_variable_get(:@clients).values.first
    assert state.pending_write_empty?,
      "pending_write_bytes should be empty after a single ready tick"
    assert_nil state.pending_write_deadline_at,
      "deadline must be cleared once the buffer drains"
    assert_equal [0, 1], all_frames(sock.written).map { |f| f["id"] }
  end

  def test_write_resumes_across_ticks_when_partial
    # Cap the first write_nonblock to 8 bytes, then signal WaitWritable.
    # The hello reply (~100+ bytes) cannot drain in a single tick.
    sock = FakeSocket.new(read_chunks: [hello_frame])
    sock.stub_partial_write(max_bytes_per_call: 8, calls: 1)
    fs = FakeServer.new([sock])
    srv = run_one_tick(fs)

    state = srv.instance_variable_get(:@clients).values.first
    refute state.pending_write_empty?,
      "8 bytes per partial write should leave the rest in the buffer"
    refute_nil state.pending_write_deadline_at,
      "deadline must remain set until the buffer fully drains"
    # No complete frame yet — only 8 bytes flushed to the wire.
    assert_equal 8, sock.written.bytesize

    # Remove the cap and tick again — flush_pending_writes_all_clients
    # should drain the remainder.
    sock.instance_variable_set(:@partial_write_max_bytes, nil)
    srv.send(:on_timer_tick)
    assert state.pending_write_empty?
    assert_nil state.pending_write_deadline_at
    frames = all_frames(sock.written)
    assert_equal 1, frames.size
    assert_equal 0, frames[0]["id"]
  end

  def test_write_deadline_closes_client_after_timeout
    sock = FakeSocket.new(read_chunks: [hello_frame])
    fs = FakeServer.new([sock])
    srv = MCPforSketchUp::Core::Server.new
    srv.instance_variable_set(:@server, fs)
    srv.instance_variable_set(:@running, true)

    # Tick once with WaitWritable stuck on every call — populates the buffer
    # and sets the deadline, but writes nothing.
    sock.stub_write_pending(times: 100)
    srv.send(:on_timer_tick)

    state = srv.instance_variable_get(:@clients).values.first
    refute state.pending_write_empty?
    refute_nil state.pending_write_deadline_at,
      "deadline should be set after first append"

    # Push the deadline into the past — the next flush must close the client.
    state.pending_write_deadline_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1.0
    srv.send(:on_timer_tick)

    assert sock.closed?, "client should be closed after the deadline elapses"
    refute srv.instance_variable_get(:@clients).key?(sock),
      "closed client must be removed from @clients"
  end

  def test_write_failure_isolates_to_offending_client
    req_a = fr("jsonrpc" => "2.0", "method" => "tools/call",
               "params" => { "name" => "get_version", "arguments" => {} },
               "id" => 100)
    req_b = fr("jsonrpc" => "2.0", "method" => "tools/call",
               "params" => { "name" => "get_version", "arguments" => {} },
               "id" => 200)
    a = FakeSocket.new(read_chunks: [hello_frame + req_a])
    b = FakeSocket.new(read_chunks: [hello_frame + req_b])
    # A raises EPIPE on every write_nonblock — B is normal.
    a.define_singleton_method(:write_nonblock) { |_| raise Errno::EPIPE, "synthetic" }
    fs = FakeServer.new([a, b])
    srv = run_one_tick(fs)

    assert a.closed?, "A should be closed when write_nonblock raises EPIPE"
    refute b.closed?, "B must remain connected"
    refute srv.instance_variable_get(:@clients).key?(a)
    assert_equal [0, 200], all_frames(b.written).map { |f| f["id"] },
      "B receives both hello reply + get_version reply"
  end

  def test_pending_write_overflow_closes_client
    # Build a server with one accepted client whose state is pre-populated
    # such that the next write would tip the buffer past the 16 MiB cap.
    sock = FakeSocket.new
    fs = FakeServer.new([sock])
    srv = MCPforSketchUp::Core::Server.new
    srv.instance_variable_set(:@server, fs)
    srv.instance_variable_set(:@running, true)
    srv.send(:accept_pending_clients)
    state = srv.instance_variable_get(:@clients).values.first

    cap     = MCPforSketchUp::Core::Server::PENDING_WRITE_MAX_BYTES
    near    = "x" * (cap - 64)   # just below the cap; can't trigger overflow alone
    state.append_pending_write("h" * 8)   # малый head (T-13.3) — near ниже становится ХВОСТОМ
    state.append_pending_write(near)
    state.pending_write_deadline_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60   # don't deadline during test

    # Crafting an overflow: ask write_response to encode a typical small
    # response — the projected buffer (~near + frame_bytes) overshoots cap.
    response = { "jsonrpc" => "2.0",
                 "result" => { "padding" => "y" * 200 },
                 "id" => 1 }
    srv.send(:write_response, state, response)

    assert sock.closed?, "client should be closed on pending_write_overflow"
    refute srv.instance_variable_get(:@clients).key?(sock)
  end

  def test_single_oversized_frame_on_empty_buffer_is_not_overflow
    # Review #8: the pending-write cap guards ACCUMULATION only. A single frame
    # is already bounded by the framing layer (MAX_MESSAGE_SIZE, 64 MiB), so a
    # legitimate large reply (e.g. a get_viewport_screenshot PNG, ~43 MiB
    # base64) that exceeds PENDING_WRITE_MAX_BYTES (16 MiB) but fits the frame
    # cap must be ACCEPTED onto an empty buffer, not force-closed.
    sock = FakeSocket.new
    fs = FakeServer.new([sock])
    srv = MCPforSketchUp::Core::Server.new
    srv.instance_variable_set(:@server, fs)
    srv.instance_variable_set(:@running, true)
    srv.send(:accept_pending_clients)
    state = srv.instance_variable_get(:@clients).values.first
    assert state.pending_write_empty?, "precondition: buffer starts empty"

    cap = MCPforSketchUp::Core::Server::PENDING_WRITE_MAX_BYTES
    big = "y" * (cap + 1024 * 1024)   # frame > 16 MiB pending cap, well under 64 MiB frame cap
    response = { "jsonrpc" => "2.0", "result" => { "png_base64" => big }, "id" => 1 }
    srv.send(:write_response, state, response)

    refute sock.closed?,
      "a single frame over the 16 MiB pending cap (but under the 64 MiB frame cap) must NOT be force-closed"
    assert srv.instance_variable_get(:@clients).key?(sock),
      "client must remain registered after a single large frame"
    assert state.pending_write_empty?,
      "FakeSocket accepts all bytes synchronously → the big frame drains in the same call"
  end

  def test_forward_progress_extends_write_deadline
    # Review #7: the write deadline is an IDLE timeout, not a cumulative cap.
    # A partial write that makes forward progress (n > 0) but doesn't fully
    # drain must PUSH the deadline out, so a slow-but-progressing transfer is
    # never force-closed mid-flush.
    sock = FakeSocket.new
    fs = FakeServer.new([sock])
    srv = MCPforSketchUp::Core::Server.new
    srv.instance_variable_set(:@server, fs)
    srv.instance_variable_set(:@running, true)
    srv.send(:accept_pending_clients)
    state = srv.instance_variable_get(:@clients).values.first

    # Buffer enough that an 8-byte/call partial write can't drain it in one go.
    state.append_pending_write("z" * 4096)
    # Set a near-future deadline (not yet expired) we can prove gets extended.
    original_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
    state.pending_write_deadline_at = original_deadline
    # Each flush call writes 8 bytes then signals WaitWritable (calls: 1).
    sock.stub_partial_write(max_bytes_per_call: 8, calls: 1)

    srv.send(:flush_pending_write, state)

    refute sock.closed?, "forward progress must not close the client"
    refute state.pending_write_empty?, "buffer should still hold the remainder"
    assert_operator state.pending_write_deadline_at, :>, original_deadline,
      "the deadline must be extended after forward progress (idle-timeout semantics)"
  end

  # ---------- T-13.1: error-envelope переживает занятый send-буфер ----------

  def oversize_header
    [MCPforSketchUp::Core::Config::MAX_MESSAGE_SIZE + 1].pack("N")
  end

  def test_framing_error_envelope_survives_busy_write_buffer
    # Клиент: hello + framing-ошибка (oversize header), при этом первый
    # write_nonblock упирается в WaitWritable. Раньше close_client следовал
    # сразу за send_transport_error — недоставленный envelope умирал вместе
    # с сокетом. Теперь: чтение глушится, закрытие — ПОСЛЕ полного дренажа
    # (механизм close_after_response).
    #
    # NB: hello успел декодироваться ДО ошибочного заголовка, но его ответ
    # НЕ отправляется — process_frame_queue скипает фреймы клиента с
    # close_after_response (стрим рассинхронизирован). Клиент получает
    # ровно один фрейм: error-envelope.
    sock = FakeSocket.new(read_chunks: [hello_frame, oversize_header])
    sock.stub_write_pending(times: 1)
    fs = FakeServer.new([sock])
    srv = run_one_tick(fs)

    refute sock.closed?,
      "tick 1: клиент с недоставленным error-envelope не должен быть закрыт"

    srv.send(:on_timer_tick)   # tick 2: буфер дренируется → закрытие
    assert sock.closed?, "tick 2: после доставки envelope клиент закрывается"
    frames = all_frames(sock.written)
    assert_equal 1, frames.size, "ровно один фрейм — error-envelope"
    assert_equal(-32600, frames[0]["error"]["code"])
    assert_nil frames[0]["id"]
  end

  def test_parse_error_envelope_survives_busy_write_buffer
    # Здесь оба фрейма ДЕКОДИРУЮТСЯ (framing цел), hello диспатчится до
    # ошибки → его ответ тоже в буфере. Бюджет WaitWritable = 2: первый
    # флаш hello-ответа и флаш error-envelope оба упираются в занятый
    # буфер, tick 2 дренирует всё разом.
    garbage = "not json at all"
    bad_frame = [garbage.bytesize].pack("N") + garbage
    sock = FakeSocket.new(read_chunks: [hello_frame, bad_frame])
    sock.stub_write_pending(times: 2)
    fs = FakeServer.new([sock])
    srv = run_one_tick(fs)

    refute sock.closed?, "tick 1: envelope ещё в буфере — не закрывать"
    srv.send(:on_timer_tick)
    assert sock.closed?
    frames = all_frames(sock.written)
    assert_equal 2, frames.size, "hello-ответ + parse-error envelope"
    assert_equal 0, frames[0]["id"]
    assert_equal(-32700, frames.last["error"]["code"])
  end

  # ---------- T-13.2: кап диспатча/тик + backpressure ----------

  def gv_frame(id)
    fr("jsonrpc" => "2.0", "method" => "tools/call",
       "params" => { "name" => "get_version", "arguments" => {} },
       "id" => id)
  end

  def test_dispatch_capped_per_tick_preserving_fifo
    # 1 hello + 60 запросов одним chunk'ом: раньше все 61 диспатчились за
    # один тик (флуд мелких фреймов морозит UI SketchUp). Теперь — не больше
    # DISPATCH_MAX_PER_TICK за тик, остаток уходит на следующий, FIFO цел.
    payload = hello_frame + (1..60).map { |i| gv_frame(i) }.join
    sock = FakeSocket.new(read_chunks: [payload])
    fs = FakeServer.new([sock])
    srv = run_one_tick(fs)

    cap = MCPforSketchUp::Core::Server::DISPATCH_MAX_PER_TICK
    tick1 = all_frames(sock.written)
    assert_equal cap, tick1.size,
      "tick 1 обязан диспатчить ровно DISPATCH_MAX_PER_TICK (#{cap}) фреймов"

    srv.send(:on_timer_tick)
    tick2 = all_frames(sock.written)
    assert_equal 61, tick2.size, "tick 2 дорабатывает остаток"
    assert_equal [0] + (1..60).to_a, tick2.map { |f| f["id"] }, "FIFO сохранён"
  end

  def test_read_backpressure_when_frame_queue_saturated
    # Очередь фреймов забита (>= FRAME_QUEUE_SOFT_MAX) — новые чтения из
    # сокетов откладываются (kernel-буфер удержит данные, TCP даст естественный
    # backpressure). Раньше чтение продолжалось без ограничений.
    sock = FakeSocket.new(read_chunks: [hello_frame])
    fs = FakeServer.new([sock])
    srv = MCPforSketchUp::Core::Server.new
    srv.instance_variable_set(:@server, fs)
    srv.instance_variable_set(:@running, true)

    dead = FakeSocket.new
    dead.close
    dummy = MCPforSketchUp::Core::ClientState.new(999, dead)
    soft_max = MCPforSketchUp::Core::Server::FRAME_QUEUE_SOFT_MAX
    srv.instance_variable_set(:@frame_queue, Array.new(soft_max) { [dummy, "{}"] })

    srv.send(:on_timer_tick)
    assert_equal "", sock.written.b,
      "tick 1: при забитой очереди клиента читать нельзя — hello не должен быть обработан"

    srv.send(:on_timer_tick)   # очередь освободилась (закрытые dummy-фреймы скипнуты)
    frames = all_frames(sock.written)
    assert_equal 1, frames.size, "tick 2: hello обработан после разгрузки очереди"
    assert_equal 0, frames[0]["id"]
  end

  def test_flood_stops_reading_mid_drain_once_queue_saturated
    # P-06 (ревью): guard только на ВХОДЕ в фазу чтения недостаточен — один
    # клиент за один тик мог накачать очередь сильно выше SOFT_MAX. Чтение
    # обязано останавливаться и ПОСРЕДИ дренажа: второй chunk не читается,
    # когда первый уже насытил очередь.
    soft_max = MCPforSketchUp::Core::Server::FRAME_QUEUE_SOFT_MAX
    flood = (1..(soft_max + 50)).map { |i| gv_frame(i) }.join
    marker = gv_frame(99_999)
    sock = FakeSocket.new(read_chunks: [hello_frame + flood, marker])
    fs = FakeServer.new([sock])
    srv = run_one_tick(fs)
    queue_ids = srv.instance_variable_get(:@frame_queue)
                   .map { |_st, body| JSON.parse(body)["id"] }
    answered_ids = all_frames(sock.written).map { |f| f["id"] }
    refute_includes queue_ids + answered_ids, 99_999,
      "marker-фрейм из второго chunk не должен быть прочитан: очередь насыщена первым"
  end

  # ---------- T-13.3: overflow-guard считает хвост, не head-фрейм ----------

  # P-15 (решение ревью): временная подмена константы через remove_const/
  # const_set принята ОСОЗНАННО — ensure выполняется и при упавшем ассерте
  # (Minitest::Assertion — обычное исключение), пара remove+set не генерирует
  # warning; альтернатива (аксессор в проде ради теста) отклонена.
  def with_pending_write_cap(bytes)
    srv_class = MCPforSketchUp::Core::Server
    original = srv_class::PENDING_WRITE_MAX_BYTES
    srv_class.send(:remove_const, :PENDING_WRITE_MAX_BYTES)
    srv_class.const_set(:PENDING_WRITE_MAX_BYTES, bytes)
    yield
  ensure
    srv_class.send(:remove_const, :PENDING_WRITE_MAX_BYTES)
    srv_class.const_set(:PENDING_WRITE_MAX_BYTES, original)
  end

  def response_of_size(id, target_bytes)
    pad = "x" * target_bytes
    { "jsonrpc" => "2.0", "result" => { "pad" => pad }, "id" => id }
  end

  def test_overflow_guard_ignores_draining_head_frame
    with_pending_write_cap(400) do
      sock = FakeSocket.new
      # Head-фрейм уйдёт в буфер целиком; дренаж — по 10 байт за вызов,
      # бюджет 1 вызов на тик (дальше WaitWritable) → head «дренируется» долго.
      sock.stub_partial_write(max_bytes_per_call: 10, calls: 1)
      state = MCPforSketchUp::Core::ClientState.new(0, sock)
      srv = MCPforSketchUp::Core::Server.new
      srv.instance_variable_get(:@clients)[sock] = state

      # 1) Большой head (≈600 байт > cap 400) допущен на ПУСТОЙ буфер.
      srv.send(:write_response, state, response_of_size(1, 550))
      refute sock.closed?, "head-фрейм на пустой буфер допускается всегда"

      # 2) Малый фрейм при недодренированном head: раньше backlog>0 и
      #    projected>cap закрывали клиента. Теперь хвост (без head) = 0+small.
      srv.send(:write_response, state, response_of_size(2, 50))
      refute sock.closed?,
        "малый фрейм за большим head не должен приговаривать клиента (T-13.3)"

      # 3) Патологическое накопление ХВОСТА за head'ом всё ещё режется капом.
      srv.send(:write_response, state, response_of_size(3, 550))
      assert sock.closed?, "хвост сверх капа — закрытие остаётся в силе"
    end
  end

  def test_client_state_tracks_head_frame_remaining
    sock = FakeSocket.new
    state = MCPforSketchUp::Core::ClientState.new(0, sock)
    state.append_pending_write("A" * 100)     # head на пустой буфер
    assert_equal 100, state.head_frame_remaining
    state.append_pending_write("B" * 40)      # хвост head не трогает
    assert_equal 100, state.head_frame_remaining
    state.consume_pending_write(60)
    assert_equal 40, state.head_frame_remaining
    state.consume_pending_write(60)           # head дожат (40) + 20 из хвоста
    assert_equal 0, state.head_frame_remaining
  end

  # ---------- T-13.4: write-deadline на монотонных часах ----------

  def test_write_deadline_uses_monotonic_clock
    # Wall-clock Time.now прыгает (NTP-коррекция, перевод часов) — idle-дедлайн
    # на нём ложно закрывает/вечно держит клиента. Монотонные секунды — Float.
    sock = FakeSocket.new
    sock.stub_write_pending(times: 1)
    state = MCPforSketchUp::Core::ClientState.new(0, sock)
    srv = MCPforSketchUp::Core::Server.new
    srv.instance_variable_get(:@clients)[sock] = state
    srv.send(:write_response, state, response_of_size(1, 10))
    assert_kind_of Float, state.pending_write_deadline_at,
      "deadline должен быть монотонным Float, а не Time"
  end

  # ---------- T-13.5: pre-handshake дедлайн ----------

  def test_silent_pre_handshake_client_closed_after_deadline
    # 64 молчаливых коннекта (без hello) навсегда исчерпывали MAX_CLIENTS —
    # DoS на exposed-bind. Не завершившие handshake за PRE_HANDSHAKE_DEADLINE_S
    # закрываются.
    sock = FakeSocket.new   # молчит: ни hello, ни байта
    fs = FakeServer.new([sock])
    srv = run_one_tick(fs)
    state = srv.instance_variable_get(:@clients)[sock]
    refute_nil state, "клиент зарегистрирован"
    refute sock.closed?, "свежий клиент жив"

    # Состариваем подключение за дедлайн.
    aged = state.connected_at -
           MCPforSketchUp::Core::Server::PRE_HANDSHAKE_DEADLINE_S - 1.0
    state.instance_variable_set(:@connected_at, aged)
    srv.send(:on_timer_tick)
    assert sock.closed?, "молчаливый pre-handshake клиент закрыт по дедлайну"
    refute srv.instance_variable_get(:@clients).key?(sock)
  end

  def test_handshaked_client_not_touched_by_pre_handshake_deadline
    sock = FakeSocket.new(read_chunks: [hello_frame])
    fs = FakeServer.new([sock])
    srv = run_one_tick(fs)
    state = srv.instance_variable_get(:@clients)[sock]
    aged = state.connected_at -
           MCPforSketchUp::Core::Server::PRE_HANDSHAKE_DEADLINE_S - 1.0
    state.instance_variable_set(:@connected_at, aged)
    srv.send(:on_timer_tick)
    refute sock.closed?, "handshake завершён — дедлайн не применяется"
  end

  def test_pre_handshake_sweep_spares_client_draining_reject_envelope
    # P-07 (ревью): клиент с framing-error-envelope в pending-write
    # (close_after_response, T-13.1) закрывается механизмом close-after-drain
    # со СВОИМ дедлайном (WRITE_DEADLINE_S) — pre-handshake свип не должен
    # убивать его раньше доставки envelope.
    sock = FakeSocket.new(read_chunks: [oversize_header])
    sock.stub_write_pending(times: 1)
    fs = FakeServer.new([sock])
    srv = run_one_tick(fs)   # framing-ошибка → envelope в буфере, close_after_response
    state = srv.instance_variable_get(:@clients)[sock]
    refute_nil state, "клиент ещё жив: envelope не доставлен"
    aged = state.connected_at -
           MCPforSketchUp::Core::Server::PRE_HANDSHAKE_DEADLINE_S - 1.0
    state.instance_variable_set(:@connected_at, aged)
    srv.send(:on_timer_tick)   # свип обязан пропустить; дренаж доставит envelope
    frames = all_frames(sock.written)
    assert_equal 1, frames.size,
      "error-envelope обязан быть доставлен, а не срезан pre-handshake свипом"
    assert_equal(-32600, frames[0]["error"]["code"])
  end
end
