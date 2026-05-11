# SketchUp Menu Settings UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Ruby ENV-based configuration (host/port/log_level) with a SketchUp menu-driven `UI::HtmlDialog` persisted via `Sketchup.write_default`.

**Architecture:** Refactor `Core::Config` constants into mutable accessors loaded from SketchUp prefs at plugin boot. Add a singleton HtmlDialog opened from the Plugins menu. Validation lives in a pure Ruby module testable without SketchUp; the Ruby↔JS bridge uses `add_action_callback` with three actions (`load_state`, `save`, `cancel`). Application captures a runtime snapshot of the config it was started with, so the dialog can show "saved values differ — restart needed".

**Tech Stack:** Ruby (SketchUp Ruby API 2017+), `UI::HtmlDialog`, `Sketchup.read_default`/`write_default`, minitest. No JS build step, no external HTML dependencies.

---

## File structure

**Created:**
- `su_mcp/su_mcp/ui/settings_validator.rb` — pure validation module
- `su_mcp/su_mcp/ui/settings_dialog.rb` — singleton wrapping UI::HtmlDialog + callbacks
- `su_mcp/su_mcp/ui/settings.html` — single-page HTML/CSS/JS
- `test/test_settings_validation.rb` — minitest for validator

**Modified:**
- `su_mcp/su_mcp/core/config.rb` — full rewrite (const → accessors, ENV removed)
- `su_mcp/su_mcp/core/server.rb` (line 26)
- `su_mcp/su_mcp/core/application.rb` (lines 18-19 + new `running_config` snapshot)
- `su_mcp/su_mcp/core/logger.rb` (line 19)
- `su_mcp/su_mcp/main.rb` (LOAD_ORDER additions, menu entry, boot-time load)
- `test/test_config.rb` — remove ENV tests, add reader/writer-based tests
- `CLAUDE.md`, `README.md` — update Configuration section

**Unchanged:**
- `su_mcp/package.rb` (FileUtils.cp_r picks up new `ui/` directory)
- `su_mcp/su_mcp/core/framing.rb` (MAX_MESSAGE_SIZE stays a constant)
- `test/test_state_machine.rb` (only refs `Config::MAX_MESSAGE_SIZE`)
- Everything under `src/sketchup_mcp/` (Python side ENV-driven, by design)

---

## Task 1: Refactor `Core::Config` — accessors + load/update API + tests

**Files:**
- Rewrite: `su_mcp/su_mcp/core/config.rb`
- Rewrite: `test/test_config.rb`

- [ ] **Step 1: Rewrite `test/test_config.rb` to define the new API**

Replace the entire file with:

```ruby
# test/test_config.rb
require "minitest/autorun"
require_relative "../su_mcp/su_mcp/core/config"

class StubReader
  def initialize(data = {})
    @data = data
  end

  def read_default(_section, key, default)
    @data.fetch(key, default)
  end
end

class StubWriter
  attr_reader :writes

  def initialize
    @writes = []
  end

  def write_default(section, key, value)
    @writes << [section, key, value]
  end
end

class TestConfig < Minitest::Test
  C = SU_MCP::Core::Config

  def setup
    C.host = nil
    C.port = nil
    C.log_level = nil
  end

  def test_section_constant
    assert_equal "SU_MCP", C::SECTION
  end

  def test_max_message_size_constant
    assert_equal 64 * 1024 * 1024, C::MAX_MESSAGE_SIZE
  end

  def test_levels_table
    assert_equal 0, C::LEVELS["DEBUG"]
    assert_equal 1, C::LEVELS["INFO"]
    assert_equal 2, C::LEVELS["WARN"]
    assert_equal 3, C::LEVELS["ERROR"]
  end

  def test_defaults_hash
    assert_equal "127.0.0.1", C::DEFAULTS[:host]
    assert_equal 9876,        C::DEFAULTS[:port]
    assert_equal "INFO",      C::DEFAULTS[:log_level]
  end

  def test_load_from_defaults_with_empty_prefs
    C.load_from_defaults!(StubReader.new)
    assert_equal "127.0.0.1", C.host
    assert_equal 9876,        C.port
    assert_equal "INFO",      C.log_level
  end

  def test_load_from_defaults_reads_all_three_keys
    reader = StubReader.new(
      "host"      => "0.0.0.0",
      "port"      => 8080,
      "log_level" => "DEBUG"
    )
    C.load_from_defaults!(reader)
    assert_equal "0.0.0.0", C.host
    assert_equal 8080,      C.port
    assert_equal "DEBUG",   C.log_level
  end

  def test_load_from_defaults_coerces_port_to_integer
    reader = StubReader.new("port" => "1234")
    C.load_from_defaults!(reader)
    assert_equal 1234, C.port
    assert_kind_of Integer, C.port
  end

  def test_load_from_defaults_upcases_log_level
    reader = StubReader.new("log_level" => "debug")
    C.load_from_defaults!(reader)
    assert_equal "DEBUG", C.log_level
  end

  def test_update_persists_to_writer
    writer = StubWriter.new
    C.update!(host: "10.0.0.5", port: 9999, log_level: "WARN", writer: writer)
    assert_equal ["SU_MCP", "host",      "10.0.0.5"], writer.writes[0]
    assert_equal ["SU_MCP", "port",      9999       ], writer.writes[1]
    assert_equal ["SU_MCP", "log_level", "WARN"     ], writer.writes[2]
  end

  def test_update_mutates_runtime_state
    writer = StubWriter.new
    C.update!(host: "10.0.0.5", port: "9999", log_level: "WARN", writer: writer)
    assert_equal "10.0.0.5", C.host
    assert_equal 9999,       C.port
    assert_equal "WARN",     C.log_level
  end

  def test_level_value_uses_current_log_level
    C.log_level = "ERROR"
    assert_equal 3, C.level_value
  end

  def test_level_value_for_known
    assert_equal 0, C.level_value_for("DEBUG")
    assert_equal 3, C.level_value_for("ERROR")
  end

  def test_level_value_for_unknown_falls_back_to_info
    assert_equal 1, C.level_value_for("FOO")
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby test/test_config.rb`
Expected: failure — old `Config::PORT`/`HOST`/`LOG_LEVEL` constants gone, `Config.host` accessors not defined yet, or `Config.load_from_defaults!` undefined. Multiple `NoMethodError`/`NameError`.

- [ ] **Step 3: Rewrite `su_mcp/su_mcp/core/config.rb`**

Replace entire file with:

```ruby
# su_mcp/su_mcp/core/config.rb
module SU_MCP
  module Core
    module Config
      SECTION = "SU_MCP"

      DEFAULTS = {
        host:      "127.0.0.1",
        port:      9876,
        log_level: "INFO",
      }.freeze

      LEVELS           = { "DEBUG" => 0, "INFO" => 1, "WARN" => 2, "ERROR" => 3 }.freeze
      MAX_MESSAGE_SIZE = 64 * 1024 * 1024  # 64 MiB; matches Python side

      class << self
        attr_accessor :host, :port, :log_level
      end

      def self.load_from_defaults!(reader = Sketchup)
        self.host      = reader.read_default(SECTION, "host",      DEFAULTS[:host])
        self.port      = reader.read_default(SECTION, "port",      DEFAULTS[:port]).to_i
        self.log_level = reader.read_default(SECTION, "log_level", DEFAULTS[:log_level]).to_s.upcase
      end

      def self.update!(host:, port:, log_level:, writer: Sketchup)
        writer.write_default(SECTION, "host",      host)
        writer.write_default(SECTION, "port",      port.to_i)
        writer.write_default(SECTION, "log_level", log_level)
        self.host      = host
        self.port      = port.to_i
        self.log_level = log_level
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby test/test_config.rb`
Expected: PASS — all 13 tests green.

- [ ] **Step 5: Commit**

```bash
git add su_mcp/su_mcp/core/config.rb test/test_config.rb
git commit -m "refactor: replace Config ENV/const reading with accessors + load/update API

Constants PORT/HOST/LOG_LEVEL become mutable accessors. ENV reading
removed; load_from_defaults! reads from injected reader (Sketchup by
default), update! writes via injected writer. Tests use StubReader/
StubWriter to run without SketchUp."
```

---

## Task 2: Switch all `Config::CONST` consumers to method form

Each consumer is one or two simple substitutions. We run the full Ruby test suite after the edits to make sure nothing else broke.

**Files:**
- Modify: `su_mcp/su_mcp/core/server.rb`
- Modify: `su_mcp/su_mcp/core/application.rb`
- Modify: `su_mcp/su_mcp/core/logger.rb`
- Modify: `su_mcp/su_mcp/main.rb`

- [ ] **Step 1: Update `core/server.rb` line 26**

Change:
```ruby
        @server = TCPServer.new(Config::HOST, Config::PORT)
```
to:
```ruby
        @server = TCPServer.new(Config.host, Config.port)
```

- [ ] **Step 2: Update `core/application.rb` lines 18-19**

Change:
```ruby
          Sketchup.status_text = "MCP Server: running on :#{Config::PORT}"
          Logger.log_tool("application", "started", "port=#{Config::PORT}")
```
to:
```ruby
          Sketchup.status_text = "MCP Server: running on :#{Config.port}"
          Logger.log_tool("application", "started", "port=#{Config.port}")
```

- [ ] **Step 3: Update `core/logger.rb` line 19**

Change:
```ruby
        return unless Config::LOG_LEVEL == "DEBUG" && exception.backtrace
```
to:
```ruby
        return unless Config.log_level == "DEBUG" && exception.backtrace
```

- [ ] **Step 4: Update `main.rb` line 58**

Change:
```ruby
        ? "running on :#{SU_MCP::Core::Config::PORT}" \
```
to:
```ruby
        ? "running on :#{SU_MCP::Core::Config.port}" \
```

- [ ] **Step 5: Run all Ruby tests**

Run: `ruby test/run_all.rb`
Expected: all tests PASS. `framing.rb` still uses `Config::MAX_MESSAGE_SIZE` (constant kept), so framing tests stay green. `test_state_machine.rb` uses the same constant; stays green.

- [ ] **Step 6: Verify no leftover `Config::HOST`/`PORT`/`LOG_LEVEL` refs**

Run: `grep -rn -E "Config::(HOST|PORT|LOG_LEVEL)" su_mcp/ test/`
Expected: no output (zero matches). If any match remains, fix it before committing.

- [ ] **Step 7: Commit**

```bash
git add su_mcp/su_mcp/core/server.rb su_mcp/su_mcp/core/application.rb \
        su_mcp/su_mcp/core/logger.rb su_mcp/su_mcp/main.rb
git commit -m "refactor: switch Config consumers to accessor methods

server.rb, application.rb, logger.rb, main.rb now call Config.host/.port/
.log_level instead of the deleted Config::HOST/PORT/LOG_LEVEL constants."
```

---

## Task 3: Wire boot-time load + Application.running_config snapshot

The settings dialog needs to show the values the server was *running* with, not just the saved values — so `Application` captures a snapshot at `start`.

**Files:**
- Modify: `su_mcp/su_mcp/core/application.rb`
- Modify: `su_mcp/su_mcp/main.rb`

- [ ] **Step 1: Add `running_config` to `Application`**

Replace the entire `su_mcp/su_mcp/core/application.rb` file with:

```ruby
# su_mcp/su_mcp/core/application.rb
module SU_MCP
  module Core
    module Application
      @server         = nil
      @running        = false
      @running_config = nil

      def self.running?
        @running
      end

      # Snapshot of {host, port, log_level} the live server was started with.
      # Returns nil if no server is running.
      def self.running_config
        @running_config
      end

      def self.start
        return if @running
        begin
          @server = Server.new
          @server.start
          @running = true
          @running_config = {
            host:      Config.host,
            port:      Config.port,
            log_level: Config.log_level
          }
          Sketchup.status_text = "MCP Server: running on :#{Config.port}"
          Logger.log_tool("application", "started", "port=#{Config.port}")
        rescue StandardError => e
          Logger.log_error("application.start", e)
          UI.messagebox("MCP Server failed to start:\n\n#{e.message}\n\n" \
                        "Check Plugins → MCP Server → Show Log for details.")
          @server = nil
          @running = false
          @running_config = nil
        end
      end

      def self.stop
        return unless @running
        @server&.stop
        @server = nil
        @running = false
        @running_config = nil
        Sketchup.status_text = "MCP Server: stopped"
        Logger.log_tool("application", "stopped")
      end

      def self.restart
        stop if @running
        start
      end

      def self.show_log
        return unless defined?(SKETCHUP_CONSOLE) && SKETCHUP_CONSOLE
        SKETCHUP_CONSOLE.show
      end
    end
  end
end
```

- [ ] **Step 2: Add boot-time `load_from_defaults!` call in `main.rb`**

In `su_mcp/su_mcp/main.rb`, find:
```ruby
  LOAD_ORDER.each { |path| Sketchup.require(File.join(PLUGIN_ROOT, path)) }
```
Replace with:
```ruby
  LOAD_ORDER.each { |path| Sketchup.require(File.join(PLUGIN_ROOT, path)) }

  # Hydrate Config from SketchUp preferences (replaces ENV-based config).
  SU_MCP::Core::Config.load_from_defaults!
```

- [ ] **Step 3: Syntax-check both files**

Run:
```bash
ruby -c su_mcp/su_mcp/core/application.rb
ruby -c su_mcp/su_mcp/main.rb
```
Expected: `Syntax OK` for both.

- [ ] **Step 4: Run the full Ruby test suite**

Run: `ruby test/run_all.rb`
Expected: all tests PASS (no new tests, but nothing broken).

- [ ] **Step 5: Commit**

```bash
git add su_mcp/su_mcp/core/application.rb su_mcp/su_mcp/main.rb
git commit -m "feat: boot-time Config load + Application.running_config snapshot

main.rb calls Config.load_from_defaults! once after modules are required.
Application captures {host,port,log_level} at start so the upcoming
settings dialog can show 'saved differs from running'."
```

---

## Task 4: `SettingsValidator` module (TDD)

Pure validation. No SketchUp deps. Returns `{ok:, errors:[, normalized:]}`.

**Files:**
- Create: `test/test_settings_validation.rb`
- Create: `su_mcp/su_mcp/ui/settings_validator.rb`

- [ ] **Step 1: Create `test/test_settings_validation.rb`**

```ruby
# test/test_settings_validation.rb
require "minitest/autorun"
require_relative "../su_mcp/su_mcp/ui/settings_validator"

class TestSettingsValidator < Minitest::Test
  V = SU_MCP::UI::SettingsValidator

  def test_accepts_valid_payload
    result = V.validate("host" => "127.0.0.1", "port" => "9876", "log_level" => "INFO")
    assert result[:ok]
    assert_empty result[:errors]
    assert_equal "127.0.0.1", result[:normalized][:host]
    assert_equal 9876,        result[:normalized][:port]
    assert_equal "INFO",      result[:normalized][:log_level]
  end

  def test_accepts_bind_all_host
    result = V.validate("host" => "0.0.0.0", "port" => "9876", "log_level" => "INFO")
    assert result[:ok]
  end

  def test_accepts_localhost_string
    result = V.validate("host" => "localhost", "port" => "9876", "log_level" => "INFO")
    assert result[:ok]
  end

  def test_rejects_empty_host
    result = V.validate("host" => "", "port" => "9876", "log_level" => "INFO")
    refute result[:ok]
    assert_match(/empty/i, result[:errors][:host])
  end

  def test_rejects_host_with_whitespace
    result = V.validate("host" => "127.0.0.1 ", "port" => "9876", "log_level" => "INFO")
    refute result[:ok]
    assert_match(/whitespace/i, result[:errors][:host])
  end

  def test_rejects_host_too_long
    result = V.validate("host" => "a" * 254, "port" => "9876", "log_level" => "INFO")
    refute result[:ok]
    assert_match(/long/i, result[:errors][:host])
  end

  def test_rejects_non_numeric_port
    result = V.validate("host" => "127.0.0.1", "port" => "abc", "log_level" => "INFO")
    refute result[:ok]
    assert_includes result[:errors][:port], "1 and 65535"
  end

  def test_rejects_port_zero
    result = V.validate("host" => "127.0.0.1", "port" => "0", "log_level" => "INFO")
    refute result[:ok]
    assert_includes result[:errors][:port], "1 and 65535"
  end

  def test_rejects_port_above_max
    result = V.validate("host" => "127.0.0.1", "port" => "65536", "log_level" => "INFO")
    refute result[:ok]
    assert_includes result[:errors][:port], "1 and 65535"
  end

  def test_rejects_unknown_log_level
    result = V.validate("host" => "127.0.0.1", "port" => "9876", "log_level" => "TRACE")
    refute result[:ok]
    assert_match(/invalid/i, result[:errors][:log_level])
  end

  def test_accepts_lowercase_log_level_and_normalizes
    result = V.validate("host" => "127.0.0.1", "port" => "9876", "log_level" => "debug")
    assert result[:ok]
    assert_equal "DEBUG", result[:normalized][:log_level]
  end

  def test_normalizes_port_string_to_integer
    result = V.validate("host" => "127.0.0.1", "port" => "443", "log_level" => "INFO")
    assert result[:ok]
    assert_kind_of Integer, result[:normalized][:port]
    assert_equal 443, result[:normalized][:port]
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `ruby test/test_settings_validation.rb`
Expected: cannot load `settings_validator` — `LoadError` / `cannot load such file`.

- [ ] **Step 3: Create `su_mcp/su_mcp/ui/settings_validator.rb`**

```ruby
# su_mcp/su_mcp/ui/settings_validator.rb
module SU_MCP
  module UI
    module SettingsValidator
      VALID_LEVELS = %w[DEBUG INFO WARN ERROR].freeze
      MAX_HOST_LENGTH = 253

      # Validates a {"host", "port", "log_level"} hash (string keys, as parsed
      # from JSON sent by the HtmlDialog).
      #
      # Returns:
      #   {ok: true,  errors: {}, normalized: {host:, port:, log_level:}}
      #   {ok: false, errors: {host?: msg, port?: msg, log_level?: msg}}
      def self.validate(payload)
        errors = {}
        host       = payload["host"].to_s
        port_raw   = payload["port"].to_s
        level_raw  = payload["log_level"].to_s

        if host.empty?
          errors[:host] = "Host must not be empty"
        elsif host =~ /\s/
          errors[:host] = "Host must not contain whitespace"
        elsif host.length > MAX_HOST_LENGTH
          errors[:host] = "Host too long (max #{MAX_HOST_LENGTH} characters)"
        end

        port_int = Integer(port_raw, exception: false)
        if port_int.nil? || port_int < 1 || port_int > 65535
          errors[:port] = "Port must be a number between 1 and 65535"
        end

        level = level_raw.upcase
        unless VALID_LEVELS.include?(level)
          errors[:log_level] = "Invalid log level"
        end

        if errors.empty?
          { ok: true, errors: {}, normalized: { host: host, port: port_int, log_level: level } }
        else
          { ok: false, errors: errors }
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby test/test_settings_validation.rb`
Expected: PASS — all 12 tests green.

- [ ] **Step 5: Wire into `test/run_all.rb`**

Read `test/run_all.rb`. If it uses `Dir["test_*.rb"]` (glob) the new test is picked up automatically; if it lists files explicitly, add `require_relative "test_settings_validation"`.

Run: `ruby test/run_all.rb`
Expected: all tests PASS (the new 12 tests appear in the count).

- [ ] **Step 6: Commit**

```bash
git add su_mcp/su_mcp/ui/settings_validator.rb test/test_settings_validation.rb test/run_all.rb
git commit -m "feat: add SettingsValidator with input normalization

Pure module validating host/port/log_level from the upcoming HtmlDialog.
Returns {ok, errors[, normalized]} — normalized has port as Integer and
log_level upcased, ready to pass to Config.update!."
```

(If `run_all.rb` did not need editing, drop it from the `git add` line.)

---

## Task 5: `settings.html` — UI shell

Single self-contained HTML file. No build step. The JS only handles DOM wiring and the three IPC actions (`load_state`, `save`, `cancel`).

**Files:**
- Create: `su_mcp/su_mcp/ui/settings.html`

- [ ] **Step 1: Create the file**

Write `su_mcp/su_mcp/ui/settings.html` with:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>MCP Server Settings</title>
  <style>
    body { font-family: -apple-system, "Segoe UI", Arial, sans-serif; font-size: 13px; margin: 16px; color: #222; }
    .row { display: flex; align-items: center; margin-bottom: 4px; }
    .row label { width: 110px; }
    .row input, .row select { flex: 1; padding: 4px 6px; font-size: 13px; box-sizing: border-box; }
    .error { color: #c00; font-size: 11px; margin: 0 0 8px 110px; min-height: 14px; }
    .status { border-top: 1px solid #ccc; padding-top: 10px; margin-top: 14px; font-size: 12px; color: #444; }
    .status.hidden { display: none; }
    .warning { color: #c80; margin-top: 4px; }
    .buttons { text-align: right; margin-top: 16px; }
    button { padding: 6px 14px; margin-left: 8px; font-size: 13px; }
  </style>
</head>
<body>
  <div class="row">
    <label for="host">Host</label>
    <input type="text" id="host" autocomplete="off" spellcheck="false">
  </div>
  <div class="error" id="host-error"></div>

  <div class="row">
    <label for="port">Port</label>
    <input type="text" id="port" autocomplete="off" spellcheck="false">
  </div>
  <div class="error" id="port-error"></div>

  <div class="row">
    <label for="log_level">Log Level</label>
    <select id="log_level">
      <option>DEBUG</option>
      <option>INFO</option>
      <option>WARN</option>
      <option>ERROR</option>
    </select>
  </div>
  <div class="error" id="log_level-error"></div>

  <div id="status" class="status hidden">
    <div id="status-line"></div>
    <div id="status-hint" class="warning"></div>
  </div>

  <div class="buttons">
    <button id="btn-cancel">Cancel</button>
    <button id="btn-save">Save</button>
  </div>

  <script>
    function clearErrors() {
      ['host', 'port', 'log_level'].forEach(function (k) {
        document.getElementById(k + '-error').textContent = '';
      });
    }

    function showErrors(errors) {
      Object.keys(errors).forEach(function (k) {
        var el = document.getElementById(k + '-error');
        if (el) el.textContent = errors[k];
      });
    }

    window.applyState = function (state) {
      document.getElementById('host').value      = state.host;
      document.getElementById('port').value      = state.port;
      document.getElementById('log_level').value = state.log_level;

      var status = document.getElementById('status');
      var line   = document.getElementById('status-line');
      var hint   = document.getElementById('status-hint');

      if (state.running && state.current) {
        status.classList.remove('hidden');
        line.textContent = 'Status: running on ' + state.current.host + ':' + state.current.port;
        var savedDiffers =
          state.current.host !== state.host ||
          String(state.current.port) !== String(state.port);
        hint.textContent = savedDiffers
          ? '(saved settings differ — restart needed to apply)'
          : '';
      } else {
        status.classList.add('hidden');
      }
    };

    window.onSaveResult = function (result) {
      clearErrors();
      if (!result.ok) {
        showErrors(result.errors || {});
      }
      // ok === true → Ruby owns the next step (close dialog or restart prompt)
    };

    document.getElementById('btn-save').addEventListener('click', function () {
      clearErrors();
      var payload = {
        host:      document.getElementById('host').value,
        port:      document.getElementById('port').value,
        log_level: document.getElementById('log_level').value
      };
      sketchup.save(JSON.stringify(payload));
    });

    document.getElementById('btn-cancel').addEventListener('click', function () {
      sketchup.cancel();
    });

    // Pull initial state from Ruby once DOM is ready.
    sketchup.load_state();
  </script>
</body>
</html>
```

- [ ] **Step 2: Verify file exists and is non-empty**

Run: `wc -l su_mcp/su_mcp/ui/settings.html`
Expected: line count around 90-100. (Sanity check that the write succeeded.)

- [ ] **Step 3: Commit**

```bash
git add su_mcp/su_mcp/ui/settings.html
git commit -m "feat: add settings.html — UI shell for HtmlDialog

Single self-contained HTML with host/port/log_level fields, status block
shown only when server is running, and three IPC calls: load_state on
DOM ready, save on Save click, cancel on Cancel click."
```

---

## Task 6: `SettingsDialog` Ruby class — IPC + Save flow

Singleton wrapping `UI::HtmlDialog`. Wires three callbacks. Owns the post-Save restart prompt.

**Files:**
- Create: `su_mcp/su_mcp/ui/settings_dialog.rb`

- [ ] **Step 1: Create the file**

```ruby
# su_mcp/su_mcp/ui/settings_dialog.rb
require "json"

module SU_MCP
  module UI
    module SettingsDialog
      HTML_PATH = File.join(File.dirname(__FILE__), "settings.html").freeze
      DIALOG_TITLE  = "MCP Server Settings"
      DIALOG_PREFS  = "SU_MCP_SettingsDialog".freeze

      @dialog = nil

      # Idempotent: bring existing dialog to front instead of opening a second one.
      def self.show
        if @dialog && @dialog.visible?
          @dialog.bring_to_front
          return
        end
        @dialog = build_dialog
        @dialog.show
      end

      def self.build_dialog
        dialog = ::UI::HtmlDialog.new(
          dialog_title:    DIALOG_TITLE,
          preferences_key: DIALOG_PREFS,
          scrollable:      false,
          resizable:       false,
          width:           420,
          height:          340,
          style:           ::UI::HtmlDialog::STYLE_DIALOG
        )

        dialog.add_action_callback("load_state") { |_ctx|         on_load_state(dialog) }
        dialog.add_action_callback("save")       { |_ctx, json|   on_save(dialog, json) }
        dialog.add_action_callback("cancel")     { |_ctx|         dialog.close }

        dialog.set_file(HTML_PATH)
        dialog
      end

      def self.on_load_state(dialog)
        state = {
          host:      SU_MCP::Core::Config.host,
          port:      SU_MCP::Core::Config.port,
          log_level: SU_MCP::Core::Config.log_level,
          running:   SU_MCP::Core::Application.running?,
          current:   SU_MCP::Core::Application.running_config
        }
        dialog.execute_script("window.applyState(#{JSON.generate(state)})")
      rescue StandardError => e
        SU_MCP::Core::Logger.log_error("settings_dialog.load_state", e)
      end

      def self.on_save(dialog, json)
        payload = JSON.parse(json)
        result  = SettingsValidator.validate(payload)

        unless result[:ok]
          dialog.execute_script(
            "window.onSaveResult(#{JSON.generate({ ok: false, errors: result[:errors] })})"
          )
          return
        end

        normalized   = result[:normalized]
        was_running  = SU_MCP::Core::Application.running?
        old_host     = SU_MCP::Core::Config.host
        old_port     = SU_MCP::Core::Config.port

        SU_MCP::Core::Config.update!(
          host:      normalized[:host],
          port:      normalized[:port],
          log_level: normalized[:log_level]
        )

        dialog.execute_script("window.onSaveResult(#{JSON.generate({ ok: true })})")

        need_restart = was_running &&
                       (normalized[:host] != old_host || normalized[:port] != old_port)

        if need_restart
          answer = ::UI.messagebox("Restart server with new settings now?", MB_YESNO)
          SU_MCP::Core::Application.restart if answer == IDYES
        end
      rescue StandardError => e
        SU_MCP::Core::Logger.log_error("settings_dialog.save", e)
        dialog.execute_script(
          "window.onSaveResult(#{JSON.generate({ ok: false, errors: { host: \"Internal error: #{e.message}\" } })})"
        )
      end
    end
  end
end
```

- [ ] **Step 2: Syntax-check**

Run: `ruby -c su_mcp/su_mcp/ui/settings_dialog.rb`
Expected: `Syntax OK`.

- [ ] **Step 3: Verify no broken references in dependent modules**

This file references:
- `SU_MCP::Core::Config.host/.port/.log_level/.update!` — defined in Task 1
- `SU_MCP::Core::Application.running?/.running_config/.restart` — `running_config` defined in Task 3
- `SU_MCP::UI::SettingsValidator.validate` — defined in Task 4
- `SU_MCP::Core::Logger.log_error` — pre-existing
- Sketchup-only globals (`UI::HtmlDialog`, `MB_YESNO`, `IDYES`, `UI.messagebox`) — not testable outside SketchUp

Run: `grep -n "SU_MCP::" su_mcp/su_mcp/ui/settings_dialog.rb`
Visually confirm each reference matches the definitions in Tasks 1, 3, 4.

- [ ] **Step 4: Commit**

```bash
git add su_mcp/su_mcp/ui/settings_dialog.rb
git commit -m "feat: add SettingsDialog — UI::HtmlDialog singleton + save flow

Three action_callbacks (load_state/save/cancel). Save validates via
SettingsValidator, writes through Config.update!, then prompts the user
to restart the server only if it was running and host/port changed.
Log-level changes apply immediately without restart."
```

---

## Task 7: Wire UI files into `LOAD_ORDER` and add the menu entry

**Files:**
- Modify: `su_mcp/su_mcp/main.rb`

- [ ] **Step 1: Add the two UI files to `LOAD_ORDER`**

In `su_mcp/su_mcp/main.rb`, find the `LOAD_ORDER` block:
```ruby
  LOAD_ORDER = %w[
    core/config
    core/errors
    helpers/units
    core/logger
    helpers/validation
    helpers/entities
    helpers/geometry
    core/framing
    handlers/dispatch
    handlers/geometry
    handlers/operations
    handlers/joints
    handlers/materials
    handlers/export
    handlers/model
    handlers/eval
    core/server
    core/application
  ].freeze
```

Replace with:
```ruby
  LOAD_ORDER = %w[
    core/config
    core/errors
    helpers/units
    core/logger
    helpers/validation
    helpers/entities
    helpers/geometry
    core/framing
    handlers/dispatch
    handlers/geometry
    handlers/operations
    handlers/joints
    handlers/materials
    handlers/export
    handlers/model
    handlers/eval
    core/server
    core/application
    ui/settings_validator
    ui/settings_dialog
  ].freeze
```

- [ ] **Step 2: Add "Settings…" menu item**

In the same file, find the `install_menu` method:
```ruby
    menu.add_item("Restart Server") { SU_MCP::Core::Application.restart }
    menu.add_separator
    menu.add_item("Show Log") { SU_MCP::Core::Application.show_log }
```

Replace with:
```ruby
    menu.add_item("Restart Server") { SU_MCP::Core::Application.restart }
    menu.add_separator
    menu.add_item("Settings...") { SU_MCP::UI::SettingsDialog.show }
    menu.add_item("Show Log") { SU_MCP::Core::Application.show_log }
```

- [ ] **Step 3: Syntax-check**

Run: `ruby -c su_mcp/su_mcp/main.rb`
Expected: `Syntax OK`.

- [ ] **Step 4: Run the full Ruby test suite one last time**

Run: `ruby test/run_all.rb`
Expected: all tests PASS — Config (13 tests), SettingsValidator (12 tests), and pre-existing suites combined.

- [ ] **Step 5: Commit**

```bash
git add su_mcp/su_mcp/main.rb
git commit -m "feat: register UI modules + add 'Settings...' menu entry

LOAD_ORDER picks up ui/settings_validator and ui/settings_dialog.
Menu gains a 'Settings...' item between Restart and Show Log."
```

---

## Task 8: Update `CLAUDE.md` and `README.md`

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

- [ ] **Step 1: Update `CLAUDE.md`**

Find the section starting with `## Configuration via ENV`:
```markdown
## Configuration via ENV

- `SKETCHUP_MCP_HOST` (default `127.0.0.1`)
- `SKETCHUP_MCP_PORT` (default `9876`)
- `SKETCHUP_MCP_TIMEOUT` (Python only; default `60` seconds)
- `SKETCHUP_MCP_LOG_LEVEL` (`DEBUG` / `INFO` / `WARN` / `ERROR`; default `INFO`)
```

Replace with:
```markdown
## Configuration

**Ruby (SketchUp extension)** — settings are edited through `Plugins → MCP Server → Settings…` and persisted in SketchUp preferences under section `SU_MCP`. No ENV variables are read on the Ruby side.

| Setting | Default | Notes |
|---|---|---|
| Host | `127.0.0.1` | bind address; use `0.0.0.0` to accept connections from other machines (e.g. host → VM) |
| Port | `9876` | 1..65535 |
| Log Level | `INFO` | `DEBUG` / `INFO` / `WARN` / `ERROR` |

Log-level changes apply immediately. Host/port changes prompt the user to restart the server if it is running.

> **Migration from 0.0.1:** ENV variables `SKETCHUP_MCP_HOST` / `SKETCHUP_MCP_PORT` / `SKETCHUP_MCP_LOG_LEVEL` are no longer read by the Ruby side. After updating the extension, open Settings… once and enter the values you previously set via ENV.

**Python (MCP server invoked by Claude)** — configured through ENV in the Claude Desktop MCP config:

- `SKETCHUP_MCP_HOST` (default `127.0.0.1`) — where to connect to the SketchUp extension
- `SKETCHUP_MCP_PORT` (default `9876`)
- `SKETCHUP_MCP_TIMEOUT` (default `60` seconds)
- `SKETCHUP_MCP_LOG_LEVEL` (`DEBUG` / `INFO` / `WARN` / `ERROR`; default `INFO`)
```

- [ ] **Step 2: Audit `README.md` for ENV references**

Run: `grep -nE "SKETCHUP_MCP_(HOST|PORT|LOG_LEVEL)" README.md`

If matches exist:
1. Open `README.md` and read the context around each match.
2. If a match refers to the Ruby extension (e.g., "set this env var before launching SketchUp"), rewrite it to point to `Plugins → MCP Server → Settings…`.
3. If a match refers strictly to the Python MCP server config (e.g., inside a `claude_desktop_config.json` example), keep it.
4. If unclear from context, default to keeping Python-only references and rewriting Ruby-only ones.

If no matches: skip to Step 3.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: document menu-driven Ruby config, drop ENV references

CLAUDE.md Configuration section split between Ruby (Settings… dialog) and
Python (ENV). README updated to remove stale ENV instructions for the
Ruby side; Python ENV documentation kept where it appears."
```

(Drop `README.md` from `git add` if Step 2 found no matches to change.)

---

## Task 9: Final verification

**Files:** none modified.

- [ ] **Step 1: Run the full Ruby test suite**

Run: `ruby test/run_all.rb`
Expected: all tests PASS. The count should be the pre-existing 80 runs minus the 4 removed ENV tests, plus the 13 new Config tests and 12 new validator tests = approximately **101 runs** (exact count depends on the existing baseline). All assertions pass.

- [ ] **Step 2: Run the Python test suite**

Run: `uv run pytest tests/ -q`
Expected: all 52 tests PASS. (No Python code was modified, so this is purely a regression check.)

- [ ] **Step 3: Confirm no `Config::HOST`/`PORT`/`LOG_LEVEL` left in any file**

Run: `grep -rn -E "Config::(HOST|PORT|LOG_LEVEL)" su_mcp/ test/ src/ docs/ 2>/dev/null`
Expected: zero matches outside of `docs/superpowers/specs/2026-05-11-menu-settings-ui-design.md` (which is a historical record).

- [ ] **Step 4: Confirm no `ENV["SKETCHUP_MCP_HOST"|"PORT"|"LOG_LEVEL"]` left in Ruby code**

Run: `grep -rn -E "ENV\\[.SKETCHUP_MCP_(HOST|PORT|LOG_LEVEL)" su_mcp/ test/ 2>/dev/null`
Expected: zero matches. (Python `src/sketchup_mcp/config.py` still reads these — that is intentional and out of scope for this grep.)

- [ ] **Step 5: Manual smoke check guidance (not executable in this plan)**

The HtmlDialog cannot be unit-tested outside SketchUp. The implementer should manually verify on a SketchUp instance:

1. `cd su_mcp && ruby package.rb` — builds `su_mcp_v0.0.1.rbz`.
2. In SketchUp: Extensions → Extension Manager → Install Extension → select the `.rbz`.
3. Restart SketchUp.
4. `Plugins → MCP Server → Settings…` — dialog opens; fields show defaults (127.0.0.1 / 9876 / INFO).
5. Change host to `0.0.0.0`, click Save. Dialog confirms (no errors shown). No restart prompt (server not running yet).
6. `Plugins → MCP Server → Start Server`. Open Settings… again — status block shows "running on 0.0.0.0:9876".
7. Change port to `9877`, click Save. Prompt "Restart server with new settings now?" appears. Click Yes. `Show Status` confirms `:9877`.
8. Re-open Settings…, type port `0`, click Save. Inline error: "Port must be a number between 1 and 65535". Dialog stays open.
9. Close SketchUp, reopen — settings survive (read from `Sketchup.read_default`).

If any of these fail, the implementer reports back rather than attempting to patch the spec.

- [ ] **Step 6: No commit needed for verification**

The plan ends here. The implementer should hand the branch back for review (or move on to the next step indicated by the user / executing-plans skill).

---

## Spec coverage check (for the implementer)

| Spec section | Covered by Task |
|---|---|
| 5.1 Config refactor | 1 |
| 5.2 Boot wiring | 3 |
| 5.3 Consumers | 2 |
| 5.4 HtmlDialog files & IPC | 5, 6 |
| 5.5 Save flow | 6 |
| 5.6 Validation rules | 4 |
| 5.7 HTML layout | 5 |
| 5.8 Menu wiring | 7 |
| 6.1 ENV removal | 1 (config rewrite drops `read_env`) |
| 6.2 Docs | 8 |
| 6.3 Packaging (no change) | — (verified in design; `cp_r` is recursive) |
| 7.1 test_config.rb adapted | 1 |
| 7.2 test_settings_validation.rb new | 4 |
| 7.3 test_state_machine.rb (no change) | — (verified in spec) |
| 8 Risks/edge cases | mitigations woven into Tasks 1/4/6 |
| 9 Out of scope | — (intentionally not implemented) |
