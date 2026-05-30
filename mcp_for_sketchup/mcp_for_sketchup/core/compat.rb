# mcp_for_sketchup/mcp_for_sketchup/core/compat.rb
module MCPforSketchUp
  module Core
    module Compat
      # SERVER_VERSION mirrors the wire-field `server_version` and avoids
      # shadowing Ruby's global `::RUBY_VERSION` (the interpreter version).
      # This is the SketchUp PLUGIN version, bumped at release time.
      SERVER_VERSION = "0.2.0"
      MIN_PYTHON   = "0.2.0"
      MAX_PYTHON   = "0.2.0"

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
      # unparseable, or outside [MIN_PYTHON, MAX_PYTHON].
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
        max = parse(MAX_PYTHON)
        if (cv <=> min) < 0
          raise MCPforSketchUp::Core::StructuredError.new(-32001, msg_python_too_old(client_version))
        end
        if (cv <=> max) > 0
          raise MCPforSketchUp::Core::StructuredError.new(-32001, msg_python_too_new(client_version))
        end
      end

      def self.msg_python_too_old(cv)
        "sketchup-mcp2 v#{cv} is too old for SketchUp plugin v#{SERVER_VERSION} " \
        "(requires v#{MIN_PYTHON}..v#{MAX_PYTHON}). Handshake rejected. " \
        "Run: uv pip install --upgrade sketchup-mcp2. " \
        "Call `get_version` to inspect handshake state."
      end

      def self.msg_python_too_new(cv)
        "sketchup-mcp2 v#{cv} is newer than SketchUp plugin v#{SERVER_VERSION} " \
        "supports (max v#{MAX_PYTHON}). Handshake rejected. " \
        "Reinstall mcp_for_sketchup_v#{MAX_PYTHON}-warehouse.rbz (or the " \
        "-github variant for eval_ruby) from the GitHub release. " \
        "Call `get_version` to inspect handshake state."
      end

      def self.msg_python_missing
        "sketchup-mcp2 client pre-dates version-compat checking. " \
        "Handshake rejected. " \
        "Run: uv pip install --upgrade sketchup-mcp2. " \
        "Call `get_version` to inspect handshake state."
      end
    end
  end
end
