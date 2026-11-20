# test/test_framing.rb
require "minitest/autorun"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/config"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/framing"

class TestEncodeFrame < Minitest::Test
  F = MCPforSketchUp::Core::Framing
  E = MCPforSketchUp::Core::StructuredError

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
    body = "x" * (MCPforSketchUp::Core::Config::MAX_MESSAGE_SIZE + 1)
    err = assert_raises(E) { F.encode_frame(body) }
    assert_equal(-32600, err.code)
    assert_match(/response too large/, err.message)
  end

  def test_at_limit_succeeds
    body = "x" * MCPforSketchUp::Core::Config::MAX_MESSAGE_SIZE
    frame = F.encode_frame(body)
    assert_equal MCPforSketchUp::Core::Config::MAX_MESSAGE_SIZE + 4, frame.bytesize
  end
end

class TestFrameReaderCap < Minitest::Test
  R = MCPforSketchUp::Core::Framing::FrameReader
  E = MCPforSketchUp::Core::StructuredError
  C = MCPforSketchUp::Core::Config

  def header(len)
    [len].pack("N")
  end

  # M-15: until the handshake completes a frame may be 4 KiB. The header alone
  # is refused, before any of the body is buffered; the server lifts the cap
  # when auth succeeds.
  def test_max_frame_is_settable
    reader = R.new(max_frame: C::PRE_HANDSHAKE_MAX_MESSAGE_SIZE)
    assert_equal 4096, reader.max_frame
    err = assert_raises(E) { reader.feed(header(4097)) }
    assert_equal(-32600, err.code)
    assert_equal "message too large before the handshake: 4097 bytes (cap 4096)", err.message

    lifted = R.new(max_frame: C::PRE_HANDSHAKE_MAX_MESSAGE_SIZE)
    lifted.max_frame = C::MAX_MESSAGE_SIZE
    assert_equal [], lifted.feed(header(5000)), "accepted: it waits for the body"
  end

  def test_default_cap_is_the_message_size
    assert_equal C::MAX_MESSAGE_SIZE, R.new.max_frame
  end
end
