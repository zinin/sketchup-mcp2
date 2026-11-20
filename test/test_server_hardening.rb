# test/test_server_hardening.rb
# Block C (spec §7.4): the server loop under floods and broken peers.
#
#   * M-15: a client is no longer read once 32 of its frames wait in the
#     queue; at most 16 connections are accepted per tick; connections refused
#     past MAX_CLIENTS make one log line per tick, not one each.
#   * M-13: the write deadline closes a client only when a write makes no
#     progress. A socket that is writable again is written to, however late
#     the loop comes back to it (a long tool call can hold the UI thread past
#     WRITE_DEADLINE_S).
#   * M-14: a response that JSON cannot encode (nested too deep) is answered
#     with an error instead of escaping the tick.
#
# Fakes: FakeSocket / FakeServer drive the tick; use_auth_vectors lets
# handshake_frames complete the handshake. Core::Logger.log is stubbed per test
# to record [level, line].
require "minitest/autorun"
require "json"

require_relative "support/singleton_stubs"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/compat"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/config"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/logger"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/auth"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/framing"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/client_state"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/server"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/dispatch"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/system"
require_relative "support/fake_socket"
require_relative "support/frame_helpers"

class TestServerHardening < Minitest::Test
  include FrameHelpers
  include SingletonStubs

  S = MCPforSketchUp::Core::Server

  def setup
    MCPforSketchUp::Core::Config.host      = "127.0.0.1"
    MCPforSketchUp::Core::Config.port      = 9876
    MCPforSketchUp::Core::Config.log_level = "ERROR"
    use_auth_vectors
    @logged = []
    logged = @logged
    stub_singleton(MCPforSketchUp::Core::Logger, :log) { |level, msg| logged << [level, msg] }
  end

  def server_with(fake_server)
    srv = S.new
    srv.instance_variable_set(:@server, fake_server)
    srv.instance_variable_set(:@running, true)
    srv
  end

  def clients(srv)
    srv.instance_variable_get(:@clients)
  end

  def gv_frame(id)
    fr("jsonrpc" => "2.0", "method" => "tools/call",
       "params" => { "name" => "get_version", "arguments" => {} }, "id" => id)
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # A handshaked client, then 40 frames, one per read.
  def flooding_client
    sock = FakeSocket.new(read_chunks: [handshake_frames])
    srv = server_with(FakeServer.new([sock]))
    srv.send(:on_timer_tick)
    state = clients(srv)[sock]
    assert state.handshaked, "precondition: the handshake completed"
    40.times { |i| sock.push_read(gv_frame(i + 1)) }
    [srv, state, sock]
  end

  # ---------- M-15: per-client queue, accepts per tick, rejections ----------

  def test_a_client_stops_being_read_at_its_queue_cap
    srv, state, = flooding_client
    srv.send(:drain_reads_all_clients)
    assert_equal 32, S::PER_CLIENT_QUEUE_MAX
    assert_equal S::PER_CLIENT_QUEUE_MAX, state.queued_frames
  end

  def test_capped_frames_are_all_answered_in_order
    srv, _state, sock = flooding_client
    3.times { srv.send(:on_timer_tick) }
    assert_equal [0, 0] + (1..40).to_a, all_frames(sock.written).map { |f| f["id"] }
  end

  def test_accepts_are_capped_per_tick
    srv = server_with(FakeServer.new(Array.new(20) { FakeSocket.new }))
    srv.send(:on_timer_tick)
    assert_equal 16, S::ACCEPTS_PER_TICK_MAX
    assert_equal S::ACCEPTS_PER_TICK_MAX, clients(srv).size
    srv.send(:on_timer_tick)
    assert_equal 20, clients(srv).size, "the rest waited in the backlog for the next tick"
  end

  def test_rejections_log_one_line_per_tick
    srv = server_with(FakeServer.new(Array.new(5) { FakeSocket.new }))
    S::MAX_CLIENTS.times do |i|
      sock = FakeSocket.new
      clients(srv)[sock] = MCPforSketchUp::Core::ClientState.new(i, sock)
    end
    srv.send(:accept_pending_clients)
    lines = @logged.map(&:last).grep(/status=client_rejected/)
    assert_equal 1, lines.length, lines.inspect
    assert_includes lines[0], "reason=max_clients limit=#{S::MAX_CLIENTS} count=5"
    assert_equal S::MAX_CLIENTS, clients(srv).size
  end

  # ---------- M-13: the write deadline ----------

  def registered_client
    sock = FakeSocket.new
    srv = S.new
    state = MCPforSketchUp::Core::ClientState.new(0, sock)
    clients(srv)[sock] = state
    state.append_pending_write(fr("jsonrpc" => "2.0", "result" => {}, "id" => 1))
    [srv, state, sock]
  end

  def test_a_late_writable_socket_is_written_not_closed
    srv, state, sock = registered_client
    state.pending_write_deadline_at = now - 1.0
    srv.send(:flush_pending_write, state)
    refute sock.closed?, "the socket took the bytes: no stall, no timeout"
    assert state.pending_write_empty?
    assert_nil state.pending_write_deadline_at
    assert_equal [1], all_frames(sock.written).map { |f| f["id"] }
  end

  def test_a_stalled_socket_past_its_deadline_is_closed
    srv, state, sock = registered_client
    sock.stub_write_pending(times: 1)
    state.pending_write_deadline_at = now - 1.0
    srv.send(:flush_pending_write, state)
    assert sock.closed?
    assert(@logged.any? { |level, line| level == "WARN" && line.include?("status=write_timeout") },
           @logged.inspect)
  end

  def test_a_stalled_socket_before_its_deadline_stays_open
    srv, state, sock = registered_client
    sock.stub_write_pending(times: 1)
    state.pending_write_deadline_at = now + 5.0
    srv.send(:flush_pending_write, state)
    refute sock.closed?
    refute state.pending_write_empty?
  end

  # ---------- M-14: a response JSON cannot encode ----------

  def test_nesting_error_while_encoding_answers_with_an_error
    deep = (1..120).reduce([]) { |acc, _| [acc] }
    body = S.new.send(:encode_response_body, "jsonrpc" => "2.0", "result" => deep, "id" => 7)
    answer = JSON.parse(body)
    assert_equal(-32603, answer["error"]["code"])
    assert_includes answer["error"]["message"], "JSON::NestingError"
    assert_equal 7, answer["id"]
  end
end
