# mcp_for_sketchup/mcp_for_sketchup/core/auth.rb
require "openssl"
require "securerandom"

module MCPforSketchUp
  module Core
    # M-06 (spec §7.1–7.2): the token and the challenge–response proofs.
    #
    # The token is 32 random bytes written as 64 lowercase hex characters;
    # Config keeps it in SketchUp's preferences. In the handshake each side
    # proves it knows the token without sending it: HMAC-SHA256 keyed with the
    # token's 64 ASCII characters, over the label "sketchup-mcp/1/<role>"
    # followed by the client nonce and the server nonce, all ASCII hex with no
    # separator. The Python client (src/sketchup_mcp/auth.py) computes the
    # same proofs; both test suites pin one vector (test/support/auth_vectors.rb).
    module Auth
      HEX64 = /\A[0-9a-f]{64}\z/
      ROLES = %w[server client].freeze

      def self.generate_token
        SecureRandom.hex(32)
      end

      def self.nonce
        SecureRandom.hex(32)
      end

      # True only for a String of 64 lowercase hex characters: a token, a
      # nonce or a proof.
      def self.hex64?(value)
        value.is_a?(String) && HEX64.match?(value)
      end

      # role: "server" (the plugin proves it knows the token) or "client".
      def self.proof(token, role, client_nonce, server_nonce)
        raise ArgumentError, "role must be one of #{ROLES.join(', ')}, got #{role.inspect}" unless ROLES.include?(role)
        OpenSSL::HMAC.hexdigest("SHA256", token, "sketchup-mcp/1/#{role}#{client_nonce}#{server_nonce}")
      end

      # Constant time for equal lengths. OpenSSL.fixed_length_secure_compare
      # raises on unequal lengths, so those are false before it is called (a
      # proof's length is no secret).
      def self.secure_equal?(a, b)
        return false unless a.is_a?(String) && b.is_a?(String)
        return false unless a.bytesize == b.bytesize
        OpenSSL.fixed_length_secure_compare(a, b)
      end
    end
  end
end
