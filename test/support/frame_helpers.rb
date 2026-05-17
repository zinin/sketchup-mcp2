# test/support/frame_helpers.rb — shared length-prefix frame encode/decode.
require "json"

module FrameHelpers
  def fr(obj)
    body = JSON.generate(obj)
    [body.bytesize].pack("N") + body
  end

  def all_frames(bytes)
    bytes = bytes.dup.force_encoding(Encoding::ASCII_8BIT)
    out = []
    until bytes.empty?
      len = bytes.byteslice(0, 4).unpack1("N")
      out << JSON.parse(bytes.byteslice(4, len))
      bytes = bytes.byteslice(4 + len..-1) || ""
    end
    out
  end
end
