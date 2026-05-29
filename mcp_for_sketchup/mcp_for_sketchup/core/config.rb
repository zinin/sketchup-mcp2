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
        # Sentinel-nil preserved for eval_enabled; the helper only fires for
        # values that are neither nil nor a native boolean (iter-2 CONCERN-3).
        self.eval_enabled  = raw_eval.nil? ? nil : coerce_bool_pref(:eval_enabled, raw_eval, default: nil)
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
        Logger.log("WARN", "config: non-boolean #{key} pref value #{value.inspect}; falling back to #{default.inspect}")
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
      # (see SettingsValidator). Runtime is mutated BEFORE persistence; the
      # write_default loop is then sequential and stops on the first failure.
      #
      # Trade-offs of this order (chosen deliberately):
      #   - Current session always sees the new values consistently — important
      #     for log_level, which applies immediately without a server restart.
      #   - If write_default returns false on the Nth key (N ∈ {1,2,3}),
      #     runtime has all three new values, but on disk: keys 1..N-1 are new
      #     and keys N..3 are old. The raise surfaces a "_general" UI error.
      #   - After a SketchUp restart, load_from_defaults! reads each pref
      #     independently → the session sees a mixed old/new state. The UI
      #     reflects that mix on next open (state is read from prefs, not
      #     from runtime), so the user can correct it explicitly.
      #
      # A truly atomic alternative would either roll back runtime (loses
      # log_level immediacy) or pack the three values into one pref key
      # (breaks schema + needs migration). Both were judged not worth the
      # cost given write_default false is a vanishingly-rare fault (corrupt
      # prefs, disk full). The raise path is covered by FailingWriter tests
      # in test_config.rb.
      def self.update!(host:, port:, log_level:,
                       eval_enabled: nil, log_to_file: nil, log_file_path: nil,
                       writer: Sketchup)
        port_int = port.to_i
        self.host           = host
        self.port           = port_int
        self.log_level      = log_level
        self.eval_enabled   = !!eval_enabled   unless eval_enabled.nil?
        self.log_to_file    = !!log_to_file    unless log_to_file.nil?
        self.log_file_path  = log_file_path    unless log_file_path.nil?

        writes = [
          ["host",          host],
          ["port",          port_int],
          ["log_level",     log_level],
        ]
        writes << ["eval_enabled",  self.eval_enabled]   unless eval_enabled.nil?
        writes << ["log_to_file",   self.log_to_file]    unless log_to_file.nil?
        writes << ["log_file_path", self.log_file_path]  unless log_file_path.nil?
        writes.each do |key, value|
          raise "Sketchup.write_default failed for #{key}" unless writer.write_default(SECTION, key, value)
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
          Core::BuildProfile::EVAL_ENABLED_BY_DEFAULT
        else
          false
        end
      end

      def self.level_value
        level_value_for(@log_level)
      end

      def self.level_value_for(name)
        LEVELS.fetch(name, LEVELS["INFO"])
      end
    end
  end
end
