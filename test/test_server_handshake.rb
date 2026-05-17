# test/test_server_handshake.rb — connect-time hello handshake.
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

class TestServerHandshake < Minitest::Test
  include FrameHelpers

  COMPAT_PYTHON = SU_MCP::Core::Compat::MIN_PYTHON

  def setup
    SU_MCP::Core::Config.host      = "127.0.0.1"
    SU_MCP::Core::Config.port      = 9876
    SU_MCP::Core::Config.log_level = "ERROR"
    @orig_io_select_writable = SU_MCP::Core::Server.instance_method(:io_select_writable?)
  end

  def teardown
    SU_MCP::Core::Server.send(:define_method, :io_select_writable?, @orig_io_select_writable)
  end

  def run_one_tick(fake_server)
    srv = SU_MCP::Core::Server.new
    srv.instance_variable_set(:@server, fake_server)
    srv.instance_variable_set(:@running, true)
    SU_MCP::Core::Server.class_eval do
      def io_select_writable?(_sock); true; end
    end
    srv.send(:on_timer_tick)
    srv
  end

  def hello_frame(version: COMPAT_PYTHON, id: 0, params_override: :default)
    params =
      if params_override == :default
        { "client_version" => version }
      else
        params_override
      end
    fr("jsonrpc" => "2.0", "method" => "hello", "params" => params, "id" => id)
  end

  # ---------- happy path ----------

  def test_hello_with_compatible_version_succeeds
    sock = FakeSocket.new(read_chunks: [hello_frame])
    fs = FakeServer.new([sock])
    srv = run_one_tick(fs)
    frames = all_frames(sock.written)
    assert_equal 1, frames.size
    assert_equal 0, frames[0]["id"]
    refute frames[0].key?("error")
    assert_equal SU_MCP::Core::Compat::SERVER_VERSION, frames[0]["result"]["server_version"]
    refute_nil frames[0]["result"]["client_id"]
    refute sock.closed?
    state = srv.instance_variable_get(:@clients).values.first
    assert state.handshaked
    assert_equal COMPAT_PYTHON, state.client_version
  end

  def test_post_handshake_tools_call_works_after_hello
    chunks = [
      hello_frame(id: 0),
      fr("jsonrpc" => "2.0", "method" => "tools/call",
         "params" => { "name" => "get_version", "arguments" => {} },
         "id" => 1),
    ]
    sock = FakeSocket.new(read_chunks: [chunks.join])
    fs = FakeServer.new([sock])
    run_one_tick(fs)
    frames = all_frames(sock.written)
    assert_equal 2, frames.size
    assert_equal 0, frames[0]["id"]
    assert_equal 1, frames[1]["id"]
    refute frames[1].key?("error")
  end

  # Addendum F: positive + negative server_version assertion
  def test_handshake_reply_carries_server_version_post_handshake_does_not
    chunks = [
      hello_frame(id: 0),
      fr("jsonrpc" => "2.0", "method" => "tools/call",
         "params" => { "name" => "get_version", "arguments" => {} },
         "id" => 1),
    ]
    sock = FakeSocket.new(read_chunks: [chunks.join])
    fs = FakeServer.new([sock])
    run_one_tick(fs)
    frames = all_frames(sock.written)
    assert_equal SU_MCP::Core::Compat::SERVER_VERSION,
      frames[0]["result"]["server_version"],
      "handshake reply must carry server_version"
    refute frames[1].key?("server_version"),
      "post-handshake response must not carry server_version"
  end

  # ---------- rejection paths ----------

  def test_hello_with_incompatible_version_returns_minus_32001_and_closes
    bad = hello_frame(version: "0.0.0", id: 0)
    sock = FakeSocket.new(read_chunks: [bad])
    fs = FakeServer.new([sock])
    run_one_tick(fs)
    frames = all_frames(sock.written)
    assert_equal 1, frames.size
    assert_equal(-32001, frames[0]["error"]["code"])
    assert sock.closed?, "client must be closed after version rejection"
  end

  def test_non_hello_first_method_returns_minus_32600_and_closes
    bad = fr("jsonrpc" => "2.0", "method" => "tools/call",
             "params" => { "name" => "get_version", "arguments" => {} },
             "id" => 1)
    sock = FakeSocket.new(read_chunks: [bad])
    fs = FakeServer.new([sock])
    run_one_tick(fs)
    frames = all_frames(sock.written)
    assert_equal 1, frames.size
    assert_equal(-32600, frames[0]["error"]["code"])
    assert_includes frames[0]["error"]["message"], "first method must be 'hello'"
    assert sock.closed?
  end

  def test_hello_with_missing_client_version_returns_minus_32602_and_closes
    bad = hello_frame(params_override: {})
    sock = FakeSocket.new(read_chunks: [bad])
    fs = FakeServer.new([sock])
    run_one_tick(fs)
    frames = all_frames(sock.written)
    assert_equal 1, frames.size
    assert_equal(-32602, frames[0]["error"]["code"])
    assert sock.closed?
  end

  def test_hello_with_non_hash_params_returns_minus_32602_and_closes
    bad = fr("jsonrpc" => "2.0", "method" => "hello",
             "params" => "not a hash", "id" => 0)
    sock = FakeSocket.new(read_chunks: [bad])
    fs = FakeServer.new([sock])
    run_one_tick(fs)
    frames = all_frames(sock.written)
    assert_equal(-32602, frames[0]["error"]["code"])
    assert sock.closed?
  end

  def test_pre_handshake_notification_closes_silently_no_response
    notif = fr("jsonrpc" => "2.0", "method" => "tools/call",
               "params" => { "name" => "get_version", "arguments" => {} })
    sock = FakeSocket.new(read_chunks: [notif])
    fs = FakeServer.new([sock])
    run_one_tick(fs)
    assert sock.closed?
    assert_equal "", sock.written, "no response bytes expected for pre-handshake notification"
  end

  def test_other_clients_unaffected_by_one_clients_handshake_failure
    bad_a = fr("jsonrpc" => "2.0", "method" => "tools/call",
               "params" => { "name" => "get_version", "arguments" => {} },
               "id" => 1)
    good_b = hello_frame(id: 0)
    a = FakeSocket.new(read_chunks: [bad_a])
    b = FakeSocket.new(read_chunks: [good_b])
    fs = FakeServer.new([a, b])
    run_one_tick(fs)
    assert a.closed?
    refute b.closed?
    frames_b = all_frames(b.written)
    assert_equal 0, frames_b[0]["id"]
    refute frames_b[0].key?("error")
  end

  # Addendum F: handshake rejection + write EPIPE still closes the client
  def test_handshake_rejection_with_epipe_still_closes_client
    bad = hello_frame(version: "0.0.0", id: 0)
    sock = FakeSocket.new(read_chunks: [bad])
    fs = FakeServer.new([sock])
    srv = SU_MCP::Core::Server.new
    srv.instance_variable_set(:@server, fs)
    srv.instance_variable_set(:@running, true)
    SU_MCP::Core::Server.class_eval do
      def io_select_writable?(_sock); true; end
    end
    sock.define_singleton_method(:write) { |_| raise Errno::EPIPE, "synthetic" }
    srv.send(:on_timer_tick)
    assert sock.closed?, "rejected client must be closed even when write raises EPIPE"
  end
end
