# mcp_for_sketchup/mcp_for_sketchup/core/compat.rb
module MCPforSketchUp
  module Core
    module Compat
      # SERVER_VERSION mirrors the wire-field `server_version` and avoids
      # shadowing Ruby's global `::RUBY_VERSION` (the interpreter version).
      # This is the SketchUp PLUGIN version, bumped at release time.
      SERVER_VERSION = "0.4.0"

      # Oldest sketchup-mcp2 client this plugin works with — mirror of
      # compat.py::MIN_RUBY. There is no upper bound: the newer side of a pair
      # knows what changed, so the newer side rejects the older one. Moves only
      # when this plugin needs a newer client (a contract break raises both
      # floors to that release, as in 0.3.0; a one-sided requirement raises this
      # one alone). A hotfix leaves it put. Releases up to 0.3.1 cap the
      # counterpart at their own version, so 0.4.0, the first release under
      # this rule, ships both sides and raises both floors to its own version.
      MIN_PYTHON   = "0.4.0"

      # Shared by every message that tells the user to upgrade the client.
      # `uvx` — the setup README documents — keeps running its cached version
      # until asked for `@latest`; the pip command covers pip installs.
      UPGRADE_CLIENT_HINT =
        "Upgrade the client: run `uvx sketchup-mcp2@latest` once " \
        "(or `uv pip install --upgrade sketchup-mcp2` for a pip install), " \
        "then restart the MCP client."

      PART_RE = /\A[0-9]+\z/.freeze

      # Parse "X.Y.Z" → [X, Y, Z] (Integers). Raise ArgumentError on any
      # other shape. Strict: each component must match /\A[0-9]+\z/ (ASCII
      # only — Ruby's \d is ASCII-by-default, but [0-9]+ is explicit so
      # this stays visually parallel to Python's compat.py _PART_RE).
      # Integer() alone would accept "+1", "0x10", etc.
      def self.parse(v)
        unless v.is_a?(String)
          raise ArgumentError, "version must be a string, got #{v.class}"
        end
        parts = v.split(".")
        unless parts.length == 3 && parts.all? { |p| PART_RE.match?(p) }
          raise ArgumentError, "version must be 'X.Y.Z' (numeric), got #{v.inspect}"
        end
        parts.map { |p| Integer(p, 10) }
      end

      # Raise MCPforSketchUp::Core::StructuredError(-32001) if client_version is nil,
      # unparseable, or older than MIN_PYTHON. A newer client always passes.
      def self.check_python_version(client_version)
        if client_version.nil?
          raise MCPforSketchUp::Core::StructuredError.new(-32001, msg_python_missing)
        end
        begin
          cv = parse(client_version)
        rescue ArgumentError
          raise MCPforSketchUp::Core::StructuredError.new(
            -32001,
            "unparseable client_version #{client_version.inspect}; " \
              "expected X.Y.Z (numeric). " \
              "Call `get_version` to inspect handshake state."
          )
        end
        min = parse(MIN_PYTHON)
        if (cv <=> min) < 0
          raise MCPforSketchUp::Core::StructuredError.new(-32001, msg_python_too_old(client_version))
        end
      end

      # Names the floor — mirror of compat.py::_msg_ruby_too_old. With no upper
      # bound, any client at or above MIN_PYTHON works.
      def self.msg_python_too_old(cv)
        "sketchup-mcp2 v#{cv} is too old for SketchUp plugin v#{SERVER_VERSION} " \
        "(needs client v#{MIN_PYTHON} or newer). Handshake rejected. " \
        "#{UPGRADE_CLIENT_HINT} " \
        "Call `get_version` to inspect handshake state."
      end

      def self.msg_python_missing
        "sketchup-mcp2 client pre-dates version-compat checking. " \
        "Handshake rejected. " \
        "#{UPGRADE_CLIENT_HINT} " \
        "Call `get_version` to inspect handshake state."
      end
    end
  end
end
