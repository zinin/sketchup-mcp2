# test/test_server_handshake.rb — the connect-time handshake (spec §7.2).
#
# Two round trips before any tool runs:
#   1. hello {client_version, client_nonce} → the version check first (-32001),
#      then {server_version, server_nonce, server_proof};
#   2. auth {client_proof} → {client_id}, or -32003 "authentication failed".
# Each proof is HMAC-SHA256 over both nonces keyed with the token, so neither
# end sends the token. Every refusal before step 2 completes is answered, then
# the socket is closed; the answer carries no backtrace. Until the handshake
# completes a frame may be at most 4 KiB, and the 30 s pre-handshake deadline
# covers both steps.
#
# Fakes: FakeSocket / FakeServer drive the server's tick; use_auth_vectors
# gives the server AuthVectors' token and server nonce, so the proofs are the
# pinned ones. Core::Logger.log is stubbed per test to record [level, line].
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

class TestServerHandshake < Minitest::Test
  include FrameHelpers
  include SingletonStubs

  C      = MCPforSketchUp::Core::Config
  Compat = MCPforSketchUp::Core::Compat
  V      = AuthVectors

  def setup
    C.host      = "127.0.0.1"
    C.port      = 9876
    C.log_level = "ERROR"
    use_auth_vectors
    @logged = []
    logged = @logged
    stub_singleton(MCPforSketchUp::Core::Logger, :log) { |level, msg| logged << [level, msg] }
  end

  def run_one_tick(fake_server)
    srv = MCPforSketchUp::Core::Server.new
    srv.instance_variable_set(:@server, fake_server)
    srv.instance_variable_set(:@running, true)
    srv.send(:on_timer_tick)
    srv
  end

  def tick(srv)
    srv.send(:on_timer_tick)
  end

  def state_of(srv)
    srv.instance_variable_get(:@clients).values.first
  end

  # The frames the server wrote to a client that sent `bytes` in one chunk.
  def answers_to(bytes)
    sock = FakeSocket.new(read_chunks: [bytes])
    srv = run_one_tick(FakeServer.new([sock]))
    [all_frames(sock.written), sock, srv]
  end

  def warnings
    @logged.select { |level, _| level == "WARN" }.map(&:last)
  end

  def tool_call(id, name: "get_version")
    fr("jsonrpc" => "2.0", "method" => "tools/call",
       "params" => { "name" => name, "arguments" => {} }, "id" => id)
  end

  # ---------- the exchange ----------

  def test_hello_answers_with_the_server_nonce_and_proof
    frames, sock, srv = answers_to(hello_frame)
    assert_equal 1, frames.size
    assert_equal({ "server_version" => Compat::SERVER_VERSION,
                   "server_nonce"   => V::SERVER_NONCE,
                   "server_proof"   => V::SERVER_PROOF }, frames[0]["result"])
    assert_equal 0, frames[0]["id"]
    refute sock.closed?
    refute state_of(srv).handshaked, "hello alone does not complete the handshake"
  end

  def test_handshake_completes_with_the_right_client_proof
    frames, sock, srv = answers_to(handshake_frames)
    state = state_of(srv)
    assert_equal 2, frames.size
    assert_equal({ "client_id" => state.id }, frames[1]["result"])
    assert_equal 0, frames[1]["id"]
    refute sock.closed?
    assert state.handshaked
    assert_equal Compat::MIN_PYTHON, state.client_version
    assert_equal C::MAX_MESSAGE_SIZE, state.reader.max_frame, "the frame cap is lifted"
    assert(@logged.any? { |_, line| line.include?("status=handshake_ok") })
  end

  # A real client waits for the hello reply, checks the server's proof, and
  # only then sends auth.
  def test_handshake_split_across_ticks_completes
    sock = FakeSocket.new(read_chunks: [hello_frame])
    srv = run_one_tick(FakeServer.new([sock]))
    sock.push_read(auth_frame)
    tick(srv)
    assert state_of(srv).handshaked
    assert_equal 2, all_frames(sock.written).size
  end

  # No upper bound: a client released after this plugin (a Python-only
  # hotfix) completes the handshake.
  def test_newer_client_version_completes_the_handshake
    frames, _sock, srv = answers_to(hello_frame(version: "99.0.0") + auth_frame)
    refute frames.any? { |f| f.key?("error") }, frames.inspect
    assert state_of(srv).handshaked
    assert_equal "99.0.0", state_of(srv).client_version
  end

  # A future client may send more hello params; the plugin reads only its own.
  def test_hello_with_extra_params_completes_the_handshake
    params = { "client_version" => Compat::MIN_PYTHON, "client_nonce" => V::CLIENT_NONCE,
               "client_package_version" => "99.0.0" }
    hello = fr("jsonrpc" => "2.0", "method" => "hello", "params" => params, "id" => 0)
    frames, _sock, srv = answers_to(hello + auth_frame)
    refute frames.any? { |f| f.key?("error") }, frames.inspect
    assert state_of(srv).handshaked
  end

  def test_tools_call_works_after_the_handshake
    frames, sock, = answers_to(handshake_frames + tool_call(1))
    assert_equal [0, 0, 1], frames.map { |f| f["id"] }
    refute frames[2].key?("error")
    refute frames[2].key?("server_version"), "only the hello reply carries server_version"
    refute sock.closed?
  end

  # ---------- authentication ----------

  def test_wrong_client_proof_fails_authentication
    frames, sock, srv = answers_to(hello_frame + auth_frame(client_proof: "0" * 64))
    assert_equal 2, frames.size
    assert_equal(-32003, frames[1]["error"]["code"])
    assert_equal "authentication failed", frames[1]["error"]["message"]
    assert sock.closed?, "the socket is closed once the refusal is written"
    assert_nil state_of(srv), "the client is no longer tracked"
    assert(warnings.any? { |line| line.include?("status=auth_failed") }, warnings.inspect)
    @logged.each do |_, line|
      [V::TOKEN, V::CLIENT_PROOF, "0" * 64].each { |secret| refute_includes line, secret }
    end
  end

  # fixed_length_secure_compare raises on unequal lengths; the refusal must
  # still be -32003, not an internal error.
  def test_short_client_proof_fails_authentication
    frames, sock, = answers_to(hello_frame + auth_frame(client_proof: "c968"))
    assert_equal(-32003, frames[1]["error"]["code"])
    assert sock.closed?
  end

  def test_non_string_client_proof_is_refused
    auth = fr("jsonrpc" => "2.0", "method" => "auth", "params" => { "client_proof" => 5 }, "id" => 0)
    frames, sock, = answers_to(hello_frame + auth)
    assert_equal(-32602, frames[1]["error"]["code"])
    assert_equal "auth requires params.client_proof (string)", frames[1]["error"]["message"]
    assert sock.closed?
  end

  def test_tool_call_after_hello_is_refused
    frames, sock, = answers_to(hello_frame + tool_call(1))
    assert_equal(-32600, frames[1]["error"]["code"])
    assert_equal "expected 'auth' after 'hello' (got: \"tools/call\")", frames[1]["error"]["message"]
    assert sock.closed?
  end

  def test_second_hello_is_refused
    frames, sock, = answers_to(hello_frame + hello_frame)
    assert_equal(-32600, frames[1]["error"]["code"])
    assert_includes frames[1]["error"]["message"], "expected 'auth'"
    assert sock.closed?
  end

  def test_auth_before_hello_is_refused
    frames, sock, = answers_to(auth_frame)
    assert_equal(-32600, frames[0]["error"]["code"])
    assert_includes frames[0]["error"]["message"], "first method must be 'hello'"
    assert sock.closed?
  end

  def test_notification_after_hello_closes_silently
    notification = fr("jsonrpc" => "2.0", "method" => "auth", "params" => { "client_proof" => V::CLIENT_PROOF })
    frames, sock, = answers_to(hello_frame + notification)
    assert_equal 1, frames.size, "only the hello reply"
    assert sock.closed?
  end

  # ---------- hello refusals ----------

  def test_hello_without_client_nonce_is_an_old_client
    frames, sock, = answers_to(hello_frame(client_nonce: nil))
    error = frames[0]["error"]
    assert_equal(-32001, error["code"])
    assert_equal Compat.msg_python_unauthenticated(Compat::MIN_PYTHON), error["message"]
    assert_includes error["message"], "pre-dates socket authentication"
    assert_includes error["message"], Compat::UPGRADE_CLIENT_HINT
    assert sock.closed?
  end

  def test_malformed_client_nonce_is_refused
    frames, sock, = answers_to(hello_frame(client_nonce: "z" * 64))
    assert_equal(-32602, frames[0]["error"]["code"])
    assert_equal "hello requires params.client_nonce (64 lowercase hex characters)", frames[0]["error"]["message"]
    assert sock.closed?
  end

  # Spec §7.2: the version check comes first, so a client too old to send a
  # nonce hears that it must upgrade.
  def test_old_client_version_is_refused_before_the_nonce_is_read
    frames, sock, = answers_to(hello_frame(version: "0.0.1", client_nonce: nil))
    assert_equal(-32001, frames[0]["error"]["code"])
    assert_equal Compat.msg_python_too_old("0.0.1"), frames[0]["error"]["message"]
    assert sock.closed?
  end

  def test_hello_with_missing_client_version_is_refused
    hello = fr("jsonrpc" => "2.0", "method" => "hello", "params" => {}, "id" => 0)
    frames, sock, = answers_to(hello)
    assert_equal(-32602, frames[0]["error"]["code"])
    assert sock.closed?
  end

  def test_hello_with_non_hash_params_is_refused
    hello = fr("jsonrpc" => "2.0", "method" => "hello", "params" => "not a hash", "id" => 0)
    frames, sock, = answers_to(hello)
    assert_equal(-32602, frames[0]["error"]["code"])
    assert sock.closed?
  end

  def test_tool_call_before_hello_is_refused
    frames, sock, = answers_to(tool_call(1))
    assert_equal(-32600, frames[0]["error"]["code"])
    assert_includes frames[0]["error"]["message"], "first method must be 'hello'"
    assert sock.closed?
  end

  def test_pre_handshake_notification_closes_silently_no_response
    notification = fr("jsonrpc" => "2.0", "method" => "tools/call",
                      "params" => { "name" => "get_version", "arguments" => {} })
    _frames, sock, = answers_to(notification)
    assert sock.closed?
    assert_equal "", sock.written, "no response bytes expected for a pre-handshake notification"
  end

  def test_server_without_a_token_refuses_hello
    C.token = nil
    frames, sock, = answers_to(hello_frame)
    assert_equal(-32603, frames[0]["error"]["code"])
    assert_equal "the plugin has no token; restart SketchUp to create one", frames[0]["error"]["message"]
    assert sock.closed?
  end

  # M-31: a client that has not authenticated learns nothing of the plugin's
  # source from a refusal.
  def test_rejections_before_the_handshake_carry_no_backtrace
    [hello_frame(version: "0.0.1"), hello_frame(client_nonce: nil),
     hello_frame + auth_frame(client_proof: "0" * 64), tool_call(1)].each do |bytes|
      frames, = answers_to(bytes)
      data = frames.last["error"]["data"]
      refute data.key?("backtrace"), "#{frames.last['error']['message']}: #{data.inspect}"
    end
  end

  def test_rejection_is_logged_at_warn
    answers_to(hello_frame(version: "0.0.1"))
    assert(warnings.any? { |line| line.include?("status=handshake_rejected") && line.include?("code=-32001") },
           warnings.inspect)
  end

  # ---------- frame cap and deadline ----------

  # M-15: the header alone is refused; the body is never buffered.
  def test_frame_over_4_kib_before_the_handshake_is_refused_at_its_header
    frames, sock, = answers_to([4097].pack("N"))
    assert_equal(-32600, frames[0]["error"]["code"])
    assert_includes frames[0]["error"]["message"], "before the handshake"
    assert_includes frames[0]["error"]["message"], "cap 4096"
    assert sock.closed?
  end

  def test_large_frame_after_the_handshake_is_accepted
    sock = FakeSocket.new(read_chunks: [handshake_frames])
    srv = run_one_tick(FakeServer.new([sock]))
    sock.push_read(tool_call("x" * 5000))
    tick(srv)
    frames = all_frames(sock.written)
    assert_equal 3, frames.size
    assert_equal "x" * 5000, frames[2]["id"]
    refute frames[2].key?("error")
    refute sock.closed?
  end

  # The 30 s deadline covers the whole exchange: hello alone does not stop it.
  def test_hello_without_auth_is_closed_at_the_deadline
    sock = FakeSocket.new(read_chunks: [hello_frame])
    srv = run_one_tick(FakeServer.new([sock]))
    state = state_of(srv)
    state.instance_variable_set(:@connected_at, state.connected_at - 31)
    tick(srv)
    assert sock.closed?
    assert(warnings.any? { |line| line.include?("status=pre_handshake_timeout") }, warnings.inspect)
  end

  # ---------- isolation ----------

  def test_other_clients_unaffected_by_one_clients_handshake_failure
    a = FakeSocket.new(read_chunks: [hello_frame + auth_frame(client_proof: "0" * 64)])
    b = FakeSocket.new(read_chunks: [handshake_frames])
    srv = run_one_tick(FakeServer.new([a, b]))
    assert a.closed?
    refute b.closed?
    assert srv.instance_variable_get(:@clients).values.first.handshaked
    refute all_frames(b.written).any? { |f| f.key?("error") }
  end

  def test_handshake_rejection_with_epipe_still_closes_client
    sock = FakeSocket.new(read_chunks: [hello_frame(version: "0.0.0")])
    srv = MCPforSketchUp::Core::Server.new
    srv.instance_variable_set(:@server, FakeServer.new([sock]))
    srv.instance_variable_set(:@running, true)
    sock.define_singleton_method(:write_nonblock) { |_| raise Errno::EPIPE, "synthetic" }
    tick(srv)
    assert sock.closed?, "a rejected client is closed even when the write raises EPIPE"
  end
end
