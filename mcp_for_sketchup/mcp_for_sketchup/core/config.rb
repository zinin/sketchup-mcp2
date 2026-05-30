# mcp_for_sketchup/mcp_for_sketchup/core/config.rb
require "tmpdir"

module MCPforSketchUp
  module Core
    module Config
      SECTION = "MCPforSketchUp"

      DEFAULTS = {
        host:           "127.0.0.1",
        port:           9876,
        log_level:      "WARN",
        eval_enabled:   nil,  # sentinel — unset pref triggers BuildProfile fallback (spec §4.2 + iter-1 CRITICAL-1)
        log_to_file:    false,
        log_file_path:  File.join(Dir.tmpdir, "mcp_for_sketchup.log").freeze,
      }.freeze

      LEVELS           = { "DEBUG" => 0, "INFO" => 1, "WARN" => 2, "ERROR" => 3 }.freeze
      MAX_MESSAGE_SIZE = 64 * 1024 * 1024  # 64 MiB; matches Python side

      # Validation primitives — kept locally so load_from_defaults! has no
      # dependency on ui/settings_validator (which is loaded later). The dialog
      # layer enforces these same rules with user-visible error messages.
      MAX_HOST_LENGTH = 253
      HOST_CHARSET    = /\A[A-Za-z0-9._\-:]+\z/

      class << self
        attr_accessor :host, :port, :log_level,
                      :eval_enabled, :log_to_file, :log_file_path
      end

      # Read persisted prefs into runtime state. Untrusted input — fall back
      # to DEFAULTS and emit a WARN if a value fails validation, so the plugin
      # can still boot when prefs are corrupt or were written by a different
      # version. update! is the trusted producer; this guards against external
      # tampering and version drift.
      def self.load_from_defaults!(reader = Sketchup)
        raw_host  = reader.read_default(SECTION, "host",      DEFAULTS[:host]).to_s
        raw_port  = reader.read_default(SECTION, "port",      DEFAULTS[:port])
        raw_level = reader.read_default(SECTION, "log_level", DEFAULTS[:log_level]).to_s.upcase
        # Sentinel-nil: pass explicit nil so read_default returns nil when key is absent.
        # That distinguishes «pref unset» (falls back to BuildProfile) from explicit `false`.
        # See spec §4.2 + iter-1 CRITICAL-1.
        raw_eval  = reader.read_default(SECTION, "eval_enabled",  nil)
        raw_l2f   = reader.read_default(SECTION, "log_to_file",   DEFAULTS[:log_to_file])
        raw_lpath = reader.read_default(SECTION, "log_file_path", DEFAULTS[:log_file_path]).to_s

        self.host          = valid_host?(raw_host)   ? raw_host       : warn_invalid_pref(:host,      raw_host)
        self.port          = valid_port?(raw_port)   ? raw_port.to_i  : warn_invalid_pref(:port,      raw_port)
        self.log_level     = LEVELS.key?(raw_level)  ? raw_level      : warn_invalid_pref(:log_level, raw_level)
        # Absent pref (raw_eval.nil?) stays the nil sentinel → BuildProfile
        # fallback. A present-but-non-boolean value (tampered/corrupt pref) is
        # NOT «unset»: it fails CLOSED to false (default: false), so the
        # arbitrary-code gate never falls through to a truthy build default —
        # the github variant bakes EVAL_ENABLED_BY_DEFAULT=true and would
        # otherwise silently RE-OPEN. coerce_bool_pref still never `!!`-coerces a
        # non-boolean truthy (iter-2 CONCERN-3 + codex 6th-review).
        self.eval_enabled  = raw_eval.nil? ? nil : coerce_bool_pref(:eval_enabled, raw_eval, default: false)
        self.log_to_file   = coerce_bool_pref(:log_to_file, raw_l2f, default: DEFAULTS[:log_to_file])
        self.log_file_path = raw_lpath.empty? ? DEFAULTS[:log_file_path] : raw_lpath
      end

      # Boolean-pref coercion guard (iter-2 CONCERN-3). Returns `value`
      # only when it is a native boolean; otherwise falls back to `default`
      # and emits a one-shot WARN naming the offending key + value. Keeps
      # the sentinel-nil path explicit at the call site — callers that
      # want nil-pass-through must check `value.nil?` themselves.
      def self.coerce_bool_pref(key, value, default:)
        return value if value == true || value == false
        # Guard defined?(Logger) like warn_invalid_pref: this can run before
        # core/logger is loaded (early boot) or in a unit test that requires
        # only config.rb — a diagnostic log must never break the fallback.
        if defined?(Logger)
          Logger.log("WARN", "config: non-boolean #{key} pref value #{value.inspect}; falling back to #{default.inspect}")
        end
        default
      end
      private_class_method :coerce_bool_pref

      def self.valid_host?(host)
        !host.empty? && host !~ /\s/ && host.length <= MAX_HOST_LENGTH && host =~ HOST_CHARSET
      end

      def self.valid_port?(port)
        port.to_s =~ /\A\d+\z/ && (1..65535).cover?(port.to_i)
      end

      def self.warn_invalid_pref(key, bad_value)
        if defined?(Logger)
          Logger.log("WARN", "config: invalid persisted #{key}=#{bad_value.inspect}, falling back to default")
        end
        DEFAULTS[key]
      end

      # Caller is responsible for passing pre-validated, normalized values
      # (see SettingsValidator). Runtime is mutated optimistically, then the
      # write_default loop persists sequentially. On the happy path this gives
      # log_level immediate effect without a server restart.
      #
      # Atomicity (review F1): the whole body is wrapped so that if any
      # write_default returns false, ALL runtime fields roll back to their
      # pre-call snapshot before the raise propagates. This is mandatory for
      # eval_enabled — the arbitrary-code-execution gate must fail CLOSED and
      # can never be left open in-session after a save that errored. On disk a
      # partial write may still leave the NON-security keys (host/port/log_level/
      # log_to_file/log_file_path) in a mixed new/old state; that is reconciled
      # on the next SketchUp restart when load_from_defaults! re-reads each pref.
      # eval_enabled is exempt: it is persisted LAST (see the writes array
      # below) so it never reaches disk unless every other key already
      # succeeded — the gate is fail-closed on disk too, not just in-session.
      # write_default==false is a vanishingly-rare fault (corrupt prefs, disk
      # full); the rollback + raise paths are covered by FailingWriter tests in
      # test_config.rb.
      def self.update!(host:, port:, log_level:,
                       eval_enabled: nil, log_to_file: nil, log_file_path: nil,
                       writer: Sketchup)
        port_int = port.to_i
        # Snapshot runtime so a mid-loop persistence failure rolls back cleanly
        # (review F1). eval_enabled — the arbitrary-code-execution gate — must
        # fail CLOSED: never left open in-session when the save reported an error.
        snapshot = {
          host: @host, port: @port, log_level: @log_level,
          eval_enabled: @eval_enabled, log_to_file: @log_to_file,
          log_file_path: @log_file_path,
        }
        begin
          self.host           = host
          self.port           = port_int
          self.log_level      = log_level
          # Strict `== true` for the arbitrary-code gate, never `!!` (which would
          # coerce a contract-violating non-boolean truthy like the string "false"
          # to true and PERSIST the open gate). Defense in depth mirroring the
          # fail-closed read paths; log_to_file is not a gate so `!!` is fine.
          self.eval_enabled   = (eval_enabled == true) unless eval_enabled.nil?
          self.log_to_file    = !!log_to_file    unless log_to_file.nil?
          self.log_file_path  = log_file_path    unless log_file_path.nil?

          writes = [
            ["host",          host],
            ["port",          port_int],
            ["log_level",     log_level],
          ]
          writes << ["log_to_file",   self.log_to_file]    unless log_to_file.nil?
          writes << ["log_file_path", self.log_file_path]  unless log_file_path.nil?
          # eval_enabled is persisted LAST so a mid-loop write_default failure
          # can never leave eval=true on disk after the runtime rolled back to
          # closed: any earlier failure aborts before this write (gate keeps its
          # prior closed value), and if this write itself fails it is likewise
          # never persisted. Disk-level fail-closed for the code-exec gate.
          writes << ["eval_enabled",  self.eval_enabled]   unless eval_enabled.nil?
          writes.each do |key, value|
            raise "Sketchup.write_default failed for #{key}" unless writer.write_default(SECTION, key, value)
          end
        rescue StandardError
          # Roll back ALL runtime fields to the pre-call snapshot so a partial
          # persist never leaves a mixed in-session state — in particular
          # eval_enabled can't be left open after a failed save (review F1).
          self.host          = snapshot[:host]
          self.port          = snapshot[:port]
          self.log_level     = snapshot[:log_level]
          self.eval_enabled  = snapshot[:eval_enabled]
          self.log_to_file   = snapshot[:log_to_file]
          self.log_file_path = snapshot[:log_file_path]
          raise
        end
      end

      # eval_enabled? returns the effective gate state. If a runtime pref
      # has been read (eval_enabled != nil), use it. Otherwise, fall back to
      # the build-time default — present as Core::BuildProfile when the
      # plugin was built from package.rb; absent in tests / dev runs (the
      # safer warehouse default of `false` then applies).
      def self.eval_enabled?
        unless @eval_enabled.nil?
          return @eval_enabled
        end
        # iter-2 SUGGESTION-2: `const_defined?(:X, false)` skips inherited
        # constants (e.g. anything reachable through Object). Without the
        # `false` flag a stray top-level `BuildProfile` or
        # `EVAL_ENABLED_BY_DEFAULT` constant defined by some other plugin
        # in the shared Ruby namespace would mask our intent.
        if Core.const_defined?(:BuildProfile, false) &&
           Core::BuildProfile.const_defined?(:EVAL_ENABLED_BY_DEFAULT, false)
          # Strict identity check — the arbitrary-code gate must fail CLOSED.
          # `!!X` would be WRONG here: in Ruby `!!"false"` and `!!1` are both
          # `true`, so a build bug that baked a truthy non-boolean into
          # build_profile.rb would OPEN the gate. Only a literal `true` enables
          # eval; every other value (the string "false", an Integer, …) resolves
          # to false. Mirrors the strictness of the runtime-pref read path, which
          # rejects non-booleans in coerce_bool_pref instead of coercing them
          # truthy (codex 4th-review review).
          Core::BuildProfile::EVAL_ENABLED_BY_DEFAULT == true
        else
          false
        end
      end

      def self.level_value
        level_value_for(@log_level)
      end

      def self.level_value_for(name)
        # Fall back to the DEFAULTS log level (WARN) — not a hardcoded INFO —
        # so an unexpected/invalid level can never resolve to a MORE verbose
        # level than the configured default. Unreachable in practice
        # (load_from_defaults!/update! validate against LEVELS), but the
        # fallback stays conservative + consistent with DEFAULTS (deepseek review).
        LEVELS.fetch(name, LEVELS[DEFAULTS[:log_level]])
      end
    end
  end
end
