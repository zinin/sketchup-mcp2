# test/test_client_state.rb — unit tests for ClientState struct.
require "minitest/autorun"
require "socket"

require_relative "../su_mcp/su_mcp/core/framing"
require_relative "../su_mcp/su_mcp/core/client_state"

class FakeSockForState
  def initialize(peer = ["AF_INET", 54321, "127.0.0.1", "127.0.0.1"], raise_peeraddr: false)
    @peer = peer
    @raise_peeraddr = raise_peeraddr
    @closed = false
  end
  def peeraddr
    raise SocketError, "unconnected" if @raise_peeraddr
    @peer
  end
  def close; @closed = true; end
  def closed?; @closed; end
end

class TestClientState < Minitest::Test
  def test_initialize_assigns_id_and_sock
    sock = FakeSockForState.new
    state = SU_MCP::Core::ClientState.new(7, sock)
    assert_equal 7, state.id
    assert_same sock, state.sock
  end

  def test_initialize_creates_fresh_frame_reader
    sock = FakeSockForState.new
    state = SU_MCP::Core::ClientState.new(0, sock)
    assert_kind_of SU_MCP::Core::Framing::FrameReader, state.reader
  end

  def test_label_format_is_id_and_peer
    sock = FakeSockForState.new(["AF_INET", 12345, "192.168.1.10", "192.168.1.10"])
    state = SU_MCP::Core::ClientState.new(3, sock)
    assert_equal "#3[192.168.1.10:12345]", state.label
  end

  def test_label_falls_back_to_unknown_when_peeraddr_raises
    sock = FakeSockForState.new(raise_peeraddr: true)
    state = SU_MCP::Core::ClientState.new(0, sock)
    assert_equal "#0[unknown]", state.label
  end

  def test_handshake_state_starts_false_and_is_mutable
    state = SU_MCP::Core::ClientState.new(0, FakeSockForState.new)
    refute state.handshaked
    assert_nil state.client_version
    state.handshaked = true
    state.client_version = "0.2.0"
    assert state.handshaked
    assert_equal "0.2.0", state.client_version
  end

  def test_closed_delegates_to_sock
    sock = FakeSockForState.new
    state = SU_MCP::Core::ClientState.new(0, sock)
    refute state.closed?
    sock.close
    assert state.closed?
  end

  # Addendum A: close_after_response accessor
  def test_close_after_response_starts_false_and_is_mutable
    state = SU_MCP::Core::ClientState.new(0, FakeSockForState.new)
    refute state.close_after_response
    state.close_after_response = true
    assert state.close_after_response
  end
end
