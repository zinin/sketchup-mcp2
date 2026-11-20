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
        eval_enabled:   true,
        log_to_file:    false,
        log_file_path:  File.join(Dir.tmpdir, "mcp_for_sketchup.log").freeze,
      }.freeze

      LEVELS           = { "DEBUG" => 0, "INFO" => 1, "WARN" => 2, "ERROR" => 3 }.freeze
      MAX_MESSAGE_SIZE = 64 * 1024 * 1024  # 64 MiB; matches Python side
      # M-15: the cap on a frame until the client completes the handshake —
      # hello and auth are a few hundred bytes, so nothing larger is buffered
      # for a client that has not proved it knows the token.
      PRE_HANDSHAKE_MAX_MESSAGE_SIZE = 4 * 1024

      # Validation primitives — kept locally so load_from_defaults! has no
      # dependency on ui/settings_validator (which is loaded later). The dialog
      # layer enforces these same rules with user-visible error messages.
      MAX_HOST_LENGTH = 253
      HOST_CHARSET    = /\A[A-Za-z0-9._\-:]+\z/

      # M-06 (spec §7.1): the preference that keeps the MCP token. The token is
      # made by Auth.generate_token, never typed: the challenge-response in the
      # handshake is only as strong as the token.
      TOKEN_KEY = "auth_token"

      class << self
        attr_accessor :host, :port, :log_level,
                      :eval_enabled, :log_to_file, :log_file_path, :token
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
        raw_eval  = reader.read_default(SECTION, "eval_enabled",  DEFAULTS[:eval_enabled])
        raw_l2f   = reader.read_default(SECTION, "log_to_file",   DEFAULTS[:log_to_file])
        raw_lpath = reader.read_default(SECTION, "log_file_path", DEFAULTS[:log_file_path]).to_s

        self.host          = valid_host?(raw_host)   ? raw_host       : warn_invalid_pref(:host,      raw_host)
        self.port          = valid_port?(raw_port)   ? raw_port.to_i  : warn_invalid_pref(:port,      raw_port)
        self.log_level     = LEVELS.key?(raw_level)  ? raw_level      : warn_invalid_pref(:log_level, raw_level)
        # An absent pref arrives here as DEFAULTS[:eval_enabled] — the ordinary
        # opt-out model. A present-but-non-boolean value (tampered/corrupt pref)
        # is different: it fails CLOSED to `false` rather than resolving to the
        # open default, because an unreadable value is no basis for enabling
        # arbitrary code execution and the user recovers with one checkbox.
        # coerce_bool_pref never `!!`-coerces a non-boolean truthy such as the
        # string "false" (iter-2 CONCERN-3 + codex 6th-review).
        self.eval_enabled  = coerce_bool_pref(:eval_enabled, raw_eval, default: false)
        self.log_to_file   = coerce_bool_pref(:log_to_file, raw_l2f, default: DEFAULTS[:log_to_file])
        self.log_file_path = raw_lpath.empty? ? DEFAULTS[:log_file_path] : raw_lpath
      end

      # Boolean-pref coercion guard (iter-2 CONCERN-3). Returns `value`
      # only when it is a native boolean; otherwise falls back to `default`
      # and emits a one-shot WARN naming the offending key + value.
      def self.coerce_bool_pref(key, value, default:)
        return value if value == true || value == false
        # Guard defined?(Core::Logger) like warn_invalid_pref: this can run
        # before core/logger is loaded (early boot) or in a unit test that
        # requires only config.rb — a diagnostic log must never break the
        # fallback. T-19: именно Core::Logger — голое defined?(Logger) находило
        # stdlib ::Logger, загруженный пользовательским кодом (паттерн client_state.rb).
        if defined?(Core::Logger)
          Logger.log("WARN", "config: non-boolean #{key} pref value #{value.inspect}; falling back to #{default.inspect}")
        end
        default
      end
      private_class_method :coerce_bool_pref

      # Called once when the plugin loads (main.rb). Keeps a valid saved token;
      # a missing or malformed one is replaced by a new token, which is saved.
      # When the save fails the new token still serves this session, and the
      # next start makes another. The token never reaches a log line.
      def self.load_token!(store = Sketchup)
        saved = store.read_default(SECTION, TOKEN_KEY, nil)
        if Auth.hex64?(saved)
          self.token = saved
          return saved
        end
        log_warning("config: the saved #{TOKEN_KEY} is not a valid token; making a new one") unless saved.nil?
        self.token = Auth.generate_token
        unless store.write_default(SECTION, TOKEN_KEY, token)
          log_warning("config: could not save the MCP token; a new one will be made at the next start")
        end
        token
      end

      # Settings → Regenerate. The new token is saved before it takes effect: an
      # unsaved one would give way to the old token at the next start, and the
      # old token would work again. So a failed save raises and keeps the old one.
      def self.regenerate_token!(store = Sketchup)
        fresh = Auth.generate_token
        raise "Sketchup.write_default failed for #{TOKEN_KEY}" unless store.write_default(SECTION, TOKEN_KEY, fresh)
        self.token = fresh
      end

      # Guarded like warn_invalid_pref: config.rb can run before core/logger is
      # loaded, or in a test that loads config.rb alone.
      def self.log_warning(message)
        Logger.log("WARN", message) if defined?(Core::Logger)
      end
      private_class_method :log_warning

      def self.valid_host?(host)
        !host.empty? && host !~ /\s/ && host.length <= MAX_HOST_LENGTH && host =~ HOST_CHARSET
      end

      def self.valid_port?(port)
        port.to_s =~ /\A\d+\z/ && (1..65535).cover?(port.to_i)
      end

      def self.warn_invalid_pref(key, bad_value)
        if defined?(Core::Logger)
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

      # eval_enabled? returns the effective gate state. A pref that has been
      # read wins; `nil` means load_from_defaults! has not run yet — early boot,
      # or a unit test that sets nothing — and the shipped default applies.
      #
      # Be aware this REVERSED the failure direction in 0.3.1, and the reversal
      # is deliberate rather than incidental. Through 0.3.0 the nil branch fell
      # through to Core::BuildProfile and, with no build profile present (tests,
      # dev runs), to `false` — the gate failed CLOSED on unknown state. Now it
      # resolves to DEFAULTS[:eval_enabled], which ships `true`, so the same
      # branch fails OPEN. Nothing in a loaded plugin reaches it: main.rb:44
      # loads the modules and main.rb:47 calls load_from_defaults! immediately,
      # and if that raised, the module body aborts — no menu is installed and
      # Application never exists to be started. So the reversal is unreachable
      # in the field, not merely unlikely.
      #
      # It stops being unreachable the moment a caller can consult the gate
      # before prefs are loaded — a server start moved out of main.rb, say. Do
      # not let that land without deciding this again: the guarantees the gate
      # actually rests on live elsewhere and are untouched (a corrupt pref fails
      # closed via coerce_bool_pref(default: false); update! demands a literal
      # `true`; eval_enabled is persisted last so a partial write cannot leave
      # it open on disk), but none of them covers this branch.
      def self.eval_enabled?
        return @eval_enabled unless @eval_enabled.nil?
        DEFAULTS[:eval_enabled]
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
