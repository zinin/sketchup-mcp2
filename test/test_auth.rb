# test/test_auth.rb
# M-06 (spec §7.2): Core::Auth — the token, the nonces and the HMAC proofs.
#
# Both ends of the handshake compute the proofs. The vector in
# test/support/auth_vectors.rb is pinned here and in tests/test_auth.py, so
# the Ruby and Python halves cannot drift apart.
require "minitest/autorun"

require_relative "support/auth_vectors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/auth"

class TestAuth < Minitest::Test
  A = MCPforSketchUp::Core::Auth
  V = AuthVectors
  HEX64 = /\A[0-9a-f]{64}\z/

  def test_proofs_match_the_cross_language_vector
    assert_equal V::SERVER_PROOF, A.proof(V::TOKEN, "server", V::CLIENT_NONCE, V::SERVER_NONCE)
    assert_equal V::CLIENT_PROOF, A.proof(V::TOKEN, "client", V::CLIENT_NONCE, V::SERVER_NONCE)
  end

  def test_generated_token_and_nonce_are_64_hex
    [A.generate_token, A.nonce].each { |value| assert_match HEX64, value }
    refute_equal A.generate_token, A.generate_token
    refute_equal A.nonce, A.nonce
  end

  def test_hex64_rejects_other_shapes
    assert A.hex64?(V::TOKEN)
    [nil, "A" * 64, "a" * 63, "a" * 65, "g" * 64, 64, "#{'a' * 64}\n"].each do |value|
      refute A.hex64?(value), "#{value.inspect} is not 64 lowercase hex characters"
    end
  end

  # OpenSSL.fixed_length_secure_compare raises on unequal lengths; a proof of
  # the wrong length must come back false, never as an exception.
  def test_secure_equal_is_false_for_different_lengths
    refute A.secure_equal?("ab", "abc")
    refute A.secure_equal?(nil, "a")
    refute A.secure_equal?("a", nil)
    refute A.secure_equal?(V::SERVER_PROOF, V::CLIENT_PROOF)
    assert A.secure_equal?(V::SERVER_PROOF, V::SERVER_PROOF.dup)
  end

  def test_proof_needs_a_known_role
    assert_raises(ArgumentError) { A.proof(V::TOKEN, "admin", V::CLIENT_NONCE, V::SERVER_NONCE) }
  end
end
