# test/test_state_machine.rb
require "minitest/autorun"
require_relative "../su_mcp/su_mcp/core/errors"
require_relative "../su_mcp/su_mcp/core/config"
require_relative "../su_mcp/su_mcp/core/framing"

class TestFrameReader < Minitest::Test
  F = SU_MCP::Core::Framing
  E = SU_MCP::Core::StructuredError

  def make_frame(body)
    F.encode_frame(body)
  end

  def test_one_frame_one_chunk
    r = F::FrameReader.new
    out = r.feed(make_frame("hello"))
    assert_equal ["hello"], out.map { |b| b.force_encoding("UTF-8") }
  end

  def test_two_frames_one_chunk
    r = F::FrameReader.new
    out = r.feed(make_frame("a") + make_frame("bc"))
    assert_equal ["a", "bc"], out.map { |b| b.force_encoding("UTF-8") }
  end

  def test_byte_by_byte_feed
    r = F::FrameReader.new
    frame = make_frame("hi")
    out = []
    frame.bytes.each { |b| out += r.feed(b.chr.b) }
    assert_equal ["hi"], out.map { |b| b.force_encoding("UTF-8") }
  end

  def test_partial_header_then_rest
    r = F::FrameReader.new
    frame = make_frame("xyz")
    assert_equal [], r.feed(frame.byteslice(0, 2))   # half of header
    assert_equal [], r.feed(frame.byteslice(2, 1))   # third byte of header
    out = r.feed(frame.byteslice(3, frame.bytesize - 3))  # last header byte + body
    assert_equal ["xyz"], out.map { |b| b.force_encoding("UTF-8") }
  end

  def test_partial_body_then_rest
    r = F::FrameReader.new
    frame = make_frame("abcdef")
    out = []
    out += r.feed(frame.byteslice(0, 5))   # full header + 1 byte body
    assert_equal [], out
    out += r.feed(frame.byteslice(5, frame.bytesize - 5))
    assert_equal ["abcdef"], out.map { |b| b.force_encoding("UTF-8") }
  end

  def test_zero_length_frame_raises
    r = F::FrameReader.new
    err = assert_raises(E) { r.feed([0, 0, 0, 0].pack("C*")) }
    assert_equal(-32600, err.code)
    assert_match(/zero-length frame/, err.message)
  end

  def test_oversize_frame_raises
    r = F::FrameReader.new
    too_big = SU_MCP::Core::Config::MAX_MESSAGE_SIZE + 1
    err = assert_raises(E) { r.feed([too_big].pack("N")) }
    assert_equal(-32600, err.code)
    assert_match(/message too large/, err.message)
  end

  def test_empty_feed_returns_empty
    r = F::FrameReader.new
    assert_equal [], r.feed("".b)
    assert_equal [], r.feed("".b)
  end

  def test_independent_readers
    r1 = F::FrameReader.new
    r2 = F::FrameReader.new
    assert_equal [], r1.feed(make_frame("a").byteslice(0, 2))
    out = r2.feed(make_frame("b"))
    assert_equal ["b"], out.map { |b| b.force_encoding("UTF-8") }
  end
end
