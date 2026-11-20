# test/support/auth_vectors.rb
# One handshake's values, computed with Ruby's OpenSSL::HMAC and Python's hmac
# and pinned in both test suites (tests/conftest.py holds the same ones), so the
# Ruby and Python halves of the handshake cannot drift apart. The proofs are
# HMAC-SHA256 keyed with TOKEN over "sketchup-mcp/1/<role>" + CLIENT_NONCE +
# SERVER_NONCE.
module AuthVectors
  TOKEN        = ("0123456789abcdef" * 4).freeze
  CLIENT_NONCE = ("a" * 64).freeze
  SERVER_NONCE = ("b" * 64).freeze
  SERVER_PROOF = "a1069e0a855573049322f60ceb171ea5e84780060a85dbd060bcbbec96df272d".freeze
  CLIENT_PROOF = "c968a257091ddea88a25001b219ab21a1609e2d5991b92adb3445c5bfdc7e279".freeze
end
