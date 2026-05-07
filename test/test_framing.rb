# test/test_framing.rb
require "minitest/autorun"
require_relative "../su_mcp/su_mcp/core/errors"
require_relative "../su_mcp/su_mcp/core/config"
require_relative "../su_mcp/su_mcp/core/framing"

class TestEncodeFrame < Minitest::Test
  F = SU_MCP::Core::Framing
  E = SU_MCP::Core::StructuredError

  def test_short_body
    frame = F.encode_frame("ABC")
    # 3 bytes body, length prefix = uint32 BE
    assert_equal [0, 0, 0, 3, 0x41, 0x42, 0x43], frame.bytes
  end

  def test_empty_body_raises
    # Symmetric with FrameReader: zero-length frames are rejected on decode,
    # so encoding one would produce a frame the peer immediately rejects.
    err = assert_raises(E) { F.encode_frame("") }
    assert_equal(-32600, err.code)
    assert_match(/empty body/, err.message)
  end

  def test_utf8_body
    body = "ёж"  # 4 bytes UTF-8: 0xD1 0x91 0xD0 0xB6
    frame = F.encode_frame(body)
    assert_equal [0, 0, 0, 4, 0xD1, 0x91, 0xD0, 0xB6], frame.bytes
  end

  def test_response_too_large_raises
    body = "x" * (SU_MCP::Core::Config::MAX_MESSAGE_SIZE + 1)
    err = assert_raises(E) { F.encode_frame(body) }
    assert_equal(-32600, err.code)
    assert_match(/response too large/, err.message)
  end

  def test_at_limit_succeeds
    body = "x" * SU_MCP::Core::Config::MAX_MESSAGE_SIZE
    frame = F.encode_frame(body)
    assert_equal SU_MCP::Core::Config::MAX_MESSAGE_SIZE + 4, frame.bytesize
  end
end
