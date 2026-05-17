# test/test_server_multi_client.rb — Server multi-client unit tests.
# Uses FakeSocket + FakeServer + monkey-patched IO.select to drive the tick.
require "minitest/autorun"
require "json"

require_relative "../su_mcp/su_mcp/core/errors"
require_relative "../su_mcp/su_mcp/core/compat"
require_relative "../su_mcp/su_mcp/core/config"
require_relative "../su_mcp/su_mcp/core/logger"
require_relative "../su_mcp/su_mcp/core/framing"
require_relative "../su_mcp/su_mcp/core/client_state"
require_relative "../su_mcp/su_mcp/core/server"
require_relative "../su_mcp/su_mcp/handlers/dispatch"
require_relative "../su_mcp/su_mcp/handlers/system"
require_relative "support/fake_socket"
require_relative "support/frame_helpers"

class TestServerMultiClient < Minitest::Test
  include FrameHelpers

  # Prepend this to read_chunks of any test that wants to drive
  # post-handshake traffic. The server now requires the first frame
  # from any client to be a JSON-RPC `hello` carrying client_version.
  def hello_frame
    fr("jsonrpc" => "2.0", "method" => "hello",
       "params" => { "client_version" => SU_MCP::Core::Compat::MIN_PYTHON },
       "id" => 0)
  end

  def setup
    SU_MCP::Core::Config.host      = "127.0.0.1"
    SU_MCP::Core::Config.port      = 9876
    SU_MCP::Core::Config.log_level = "ERROR"   # silence INFO chatter

    # Always-ready writes; per-test override when testing write_timeout.
    @orig_io_select_writable = SU_MCP::Core::Server.instance_method(:io_select_writable?)
  end

  def teardown
    SU_MCP::Core::Server.send(:define_method, :io_select_writable?, @orig_io_select_writable)
  end

  # Build a Server with a FakeServer in place of TCPServer and run a
  # single tick. Returns the server instance for further inspection.
  def run_one_tick(fake_server)
    srv = SU_MCP::Core::Server.new
    srv.instance_variable_set(:@server, fake_server)
    srv.instance_variable_set(:@running, true)

    # Force IO.select to always be ready for writes during this tick.
    SU_MCP::Core::Server.class_eval do
      def io_select_writable?(_sock); true; end
    end

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
    over = SU_MCP::Core::Config::MAX_MESSAGE_SIZE + 1
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
    srv = SU_MCP::Core::Server.new
    srv.instance_variable_set(:@server, fs)
    srv.instance_variable_set(:@running, true)

    SU_MCP::Core::Server.class_eval do
      def io_select_writable?(_sock); true; end
    end

    # Wrap write_response so it closes A right after the first *post-handshake*
    # write. Hello reply (id=0) is allowed through; A1 (id=1) is the trigger;
    # A2 and A3 should be skipped because state.closed? becomes true.
    closed_after = nil
    orig = SU_MCP::Core::Server.instance_method(:write_response)
    SU_MCP::Core::Server.send(:define_method, :write_response) do |state, response|
      orig.bind(self).call(state, response)
      if closed_after.nil? && response["id"] != 0
        closed_after = response["id"]
        send(:close_client, state, "test_force_close")
      end
    end

    begin
      srv.send(:on_timer_tick)
    ensure
      SU_MCP::Core::Server.send(:define_method, :write_response, orig)
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
    srv = SU_MCP::Core::Server.new
    srv.instance_variable_set(:@server, fs)
    srv.instance_variable_set(:@running, true)
    state = SU_MCP::Core::ClientState.new(0, sock)
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
    over = SU_MCP::Core::Config::MAX_MESSAGE_SIZE + 1
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
    srv = SU_MCP::Core::Server.new
    srv.instance_variable_set(:@server, fs)
    srv.instance_variable_set(:@running, true)
    SU_MCP::Core::Server.class_eval do
      def io_select_writable?(_sock); true; end
    end
    srv.send(:on_timer_tick)
    # Only the hello reply lands in tick 1 — the tools/call is still incomplete.
    assert_equal [0], all_frames(a.written).map { |f| f["id"] },
      "only the hello reply should be written before the partial frame completes"
    a.push_read(suffix)
    srv.send(:on_timer_tick)
    frames = all_frames(a.written)
    assert_equal [0, 1], frames.map { |f| f["id"] }
  end
end
