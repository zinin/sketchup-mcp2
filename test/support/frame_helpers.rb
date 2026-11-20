# test/support/frame_helpers.rb — shared length-prefix frame encode/decode,
# and the client's half of the handshake (spec §7.2).
require "json"
require_relative "auth_vectors"

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

  # Step 1 of the handshake, with AuthVectors' client nonce. client_nonce: nil
  # leaves the nonce out, as a client that predates authentication does.
  def hello_frame(id: 0, version: MCPforSketchUp::Core::Compat::MIN_PYTHON,
                  client_nonce: AuthVectors::CLIENT_NONCE)
    params = { "client_version" => version }
    params["client_nonce"] = client_nonce unless client_nonce.nil?
    fr("jsonrpc" => "2.0", "method" => "hello", "params" => params, "id" => id)
  end

  # Step 2, with the proof AuthVectors' token gives for its two nonces.
  def auth_frame(id: 0, client_proof: AuthVectors::CLIENT_PROOF)
    fr("jsonrpc" => "2.0", "method" => "auth",
       "params" => { "client_proof" => client_proof }, "id" => id)
  end

  # Both steps in one chunk: the server answers each in turn, hello first.
  def handshake_frames
    hello_frame + auth_frame
  end

  # Makes the server's half match AuthVectors: its token, and the nonce it
  # draws. The test class includes SingletonStubs, which puts Auth.nonce back.
  def use_auth_vectors
    MCPforSketchUp::Core::Config.token = AuthVectors::TOKEN
    stub_singleton(MCPforSketchUp::Core::Auth, :nonce) { AuthVectors::SERVER_NONCE }
  end
end
