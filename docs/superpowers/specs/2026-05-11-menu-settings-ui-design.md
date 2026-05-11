# Design: Settings UI in SketchUp menu

- **Date:** 2026-05-11
- **Branch:** feature/menu-settings-ui
- **Status:** Draft → awaiting user approval before writing-plans

## 1. Problem

The Ruby side of `sketchup-mcp2` is configured through three environment
variables (`SKETCHUP_MCP_HOST`, `SKETCHUP_MCP_PORT`, `SKETCHUP_MCP_LOG_LEVEL`)
read once at plugin load. This is awkward inside SketchUp:

- SketchUp is launched from the OS GUI, so users have to set system-wide ENV
  variables and restart the app. On macOS this requires `launchctl setenv`,
  on Windows `setx` + relogin — both are far from a plugin's UX standards.
- Power users on VMs frequently need to switch `host` between `127.0.0.1`
  and `0.0.0.0` for network access, which today means editing the OS
  environment and relaunching SketchUp.
- No discoverability: nothing in the plugin's UI hints that configuration
  is even possible.

## 2. Goals

- Configure **host**, **port**, **log level** through a SketchUp dialog.
- Persist settings across SketchUp sessions.
- Apply log-level changes immediately; allow user-confirmed restart for
  host/port changes.
- Remove ENV-variable reads from the Ruby side entirely (no fallback, no
  override).

## 3. Non-goals

- Python side configuration is **unchanged**. `src/sketchup_mcp/config.py`
  keeps reading `SKETCHUP_MCP_HOST`/`SKETCHUP_MCP_PORT`/`SKETCHUP_MCP_TIMEOUT`/
  `SKETCHUP_MCP_LOG_LEVEL` because the MCP server is launched from Claude
  Desktop config where ENV is the natural mechanism.
- No port-availability pre-check (let `TCPServer.new` fail naturally on
  `Errno::EADDRINUSE` and surface via existing `Application.start`
  error path).
- No GUI for `MAX_MESSAGE_SIZE` (it is a protocol invariant, not a setting).
- No per-model configuration (settings are user-global, like all SketchUp
  plugin preferences).

## 4. Solution overview

```
┌─ menu (main.rb) ──────────────────────────────┐
│  Start / Stop / Restart Server                │
│  ─────────────                                │
│  Settings…       ← new                        │
│  Show Log / Show Status                       │
└───────────────────────────────────────────────┘
              │
              ▼
┌─ ui/settings_dialog.rb (new) ─────────────────┐
│  • builds UI::HtmlDialog                      │
│  • loads ui/settings.html                     │
│  • action_callback("load_state")              │
│  • action_callback("save")                    │
└───────────────────────────────────────────────┘
              │
              ▼
┌─ core/config.rb (refactored) ─────────────────┐
│  Config.host / .port / .log_level (accessors) │
│  Config.load_from_defaults!                   │
│  Config.update!(host:, port:, log_level:)     │
└───────────────────────────────────────────────┘
              │
              ▼
┌─ Sketchup.read_default / write_default ───────┐
│  section "SU_MCP", keys host/port/log_level   │
└───────────────────────────────────────────────┘
```

## 5. Detailed design

### 5.1 `Core::Config` — const → accessor refactor

```ruby
module SU_MCP::Core::Config
  SECTION = "SU_MCP"

  DEFAULTS = {
    host:      "127.0.0.1",
    port:      9876,
    log_level: "INFO",
  }.freeze

  LEVELS           = { "DEBUG" => 0, "INFO" => 1, "WARN" => 2, "ERROR" => 3 }.freeze
  MAX_MESSAGE_SIZE = 64 * 1024 * 1024  # unchanged

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

  def self.level_value;            level_value_for(@log_level); end
  def self.level_value_for(name);  LEVELS.fetch(name, LEVELS["INFO"]); end
end
```

The injectable `reader`/`writer` argument exists to let `minitest` stub the
`Sketchup` global (which is unavailable in standalone Ruby).

The legacy `Config.read_env` method is **deleted**. The `PORT`, `HOST`,
`LOG_LEVEL` constants are **deleted**.

### 5.2 Boot-time wiring (`main.rb`)

A single line is added after `core/config` is required:

```ruby
LOAD_ORDER.each { |path| Sketchup.require(File.join(PLUGIN_ROOT, path)) }
SU_MCP::Core::Config.load_from_defaults!   # ← new
```

`load_from_defaults!` is called at plugin load, not lazily at `Application.start`,
so that "Show Status" and any tooling that introspects Config see the right
values even before the server is started.

### 5.3 Consumers (5 call sites)

| File | Was | Becomes |
|---|---|---|
| `core/server.rb:26`        | `Config::HOST, Config::PORT`     | `Config.host, Config.port` |
| `core/application.rb:18,19`| `Config::PORT`                   | `Config.port` |
| `core/logger.rb:19`        | `Config::LOG_LEVEL == "DEBUG"`   | `Config.log_level == "DEBUG"` |
| `main.rb:58`               | `Config::PORT`                   | `Config.port` |
| `core/logger.rb:8`         | `Config.level_value_for(level)`  | unchanged |
| `core/framing.rb` (×2)     | `Config::MAX_MESSAGE_SIZE`       | unchanged |

### 5.4 HtmlDialog — files & IPC contract

**New files:**
- `su_mcp/su_mcp/ui/settings_dialog.rb` — Ruby class building the dialog,
  wiring callbacks, owning lifecycle (~80 lines).
- `su_mcp/su_mcp/ui/settings.html` — single-page HTML/CSS/JS (~120 lines,
  no build step, no external dependencies).
- `su_mcp/su_mcp/ui/settings_validator.rb` — pure module with
  `validate(payload) → {ok:, errors:}`; testable without SketchUp.

**Load order addition (`main.rb`):**
```
helpers/...
core/framing
handlers/...
core/server
core/application
ui/settings_validator   # ← new (pure, no SketchUp deps)
ui/settings_dialog      # ← new (depends on UI::HtmlDialog)
```

**IPC contract:**

| Direction | Call | Payload |
|---|---|---|
| JS → Ruby (on DOM ready) | `sketchup.load_state()` (action_callback `"load_state"`) | (none) |
| Ruby → JS (response) | `dialog.execute_script("window.applyState(<json>)")` | `{host, port, log_level, running, current: {host, port, log_level} \| null}` |
| JS → Ruby (on Save click) | `sketchup.save(<json>)` (action_callback `"save"`) | `{host, port, log_level}` (strings as typed) |
| Ruby → JS (response) | `dialog.execute_script("window.onSaveResult(<json>)")` | `{ok: true}` *or* `{ok: false, errors: {host?: msg, port?: msg, log_level?: msg}}` |

`current` is the configuration the **running** server was started with —
captured by `Application` at `start` time. When `running` is true and
`saved ≠ current`, the dialog shows a banner "Saved values differ — restart
to apply."

### 5.5 Save flow (Ruby side)

```
on save_callback(payload):
  1. result = SettingsValidator.validate(payload)
  2. if !result.ok: dialog.execute_script("onSaveResult({ok:false, errors:...})") → return
  3. need_restart = Application.running? &&
                    (payload.host != Config.host || payload.port.to_i != Config.port)
  4. Config.update!(host:, port:, log_level:)   # persists to prefs + mutates runtime
  5. dialog.execute_script("onSaveResult({ok:true})")
  6. if need_restart:
       answer = UI.messagebox("Restart server with new settings now?", MB_YESNO)
       Application.restart if answer == IDYES
```

Note: log-level change does not require a restart — `Logger` reads
`Config.log_level` per call. Step 4 mutates runtime synchronously,
so the next log line uses the new level.

### 5.6 Validation rules (`SettingsValidator.validate`)

| Field | Rule | Error message |
|---|---|---|
| `host` | non-empty string, no whitespace, length 1..253 | `"Host must not be empty"` / `"Host must not contain whitespace"` / `"Host too long"` |
| `port` | parses as integer in 1..65535 | `"Port must be a number between 1 and 65535"` |
| `log_level` | uppercase ∈ `{DEBUG, INFO, WARN, ERROR}` | `"Invalid log level"` |

No DNS lookup, no IPv4-literal check — `0.0.0.0`, `127.0.0.1`,
`192.168.x.x`, `localhost`, `::1` all pass.

### 5.7 HTML layout (informative)

```
┌─ MCP Server Settings ──────────────────┐
│                                        │
│  Host       [127.0.0.1            ]    │
│  Port       [9876                 ]    │
│  Log Level  [INFO            ▾   ]    │
│                                        │
│  ─────────────────────────────────     │
│  Status: running on 0.0.0.0:9876       │
│  (saved settings differ — restart      │
│   needed to apply)                     │
│                                        │
│            [ Cancel ]  [  Save  ]      │
└────────────────────────────────────────┘
```

Status block is rendered only when `running` is true; the "saved differ" hint
is rendered only when `saved ≠ current`.

### 5.8 Menu wiring (`main.rb`)

```ruby
menu.add_item("Restart Server") { ... }
menu.add_separator
menu.add_item("Settings...")   { SU_MCP::UI::SettingsDialog.show }  # ← new
menu.add_item("Show Log")      { ... }
menu.add_item("Show Status")   { ... }
```

The dialog is a singleton — opening "Settings..." while it's already open
brings the existing window to front rather than creating a second one.

## 6. Migration

### 6.1 ENV removal — concrete deletions

- Delete `Config.read_env`.
- Delete constants `PORT`, `HOST`, `LOG_LEVEL` from `Config`.
- Delete `_snapshot` block and its assignments.
- No other module references `ENV["SKETCHUP_MCP_*"]`.

### 6.2 Documentation updates

- `CLAUDE.md` — rewrite the **Configuration via ENV** section:
  - Ruby side: settings via Plugins → MCP Server → Settings… persisted in
    SketchUp defaults section `SU_MCP`.
  - Python side: ENV variables remain as listed.
  - Add a "Migration from 0.0.1" line noting that ENV-configured users
    must open Settings and re-enter values once.
- `README.md` — same updates if it references Ruby ENV.
- `docs/release.md` — no change (release workflow is untouched).

### 6.3 Packaging — no change

`su_mcp/package.rb` does `FileUtils.cp_r('su_mcp', temp_dir)`, so the
new `su_mcp/su_mcp/ui/` directory is included in the `.rbz` automatically.

## 7. Tests

### 7.1 `test/test_config.rb` — adapted

Removed:
- `test_defaults_when_env_empty`, `test_port_from_env`, `test_host_from_env`,
  `test_log_level_uppercased` (tested the deleted ENV path).

Added (with `StubReader` / `StubWriter` helpers in the same file):
- `test_load_from_defaults_with_empty_prefs` — defaults applied when reader
  returns the supplied default.
- `test_load_from_defaults_reads_all_three_keys` — all three values come
  through the reader.
- `test_load_from_defaults_coerces_port_to_integer` — port stored as
  `"9876"` (string) becomes Integer.
- `test_load_from_defaults_upcases_log_level` — `"debug"` becomes
  `"DEBUG"`.
- `test_update_persists_and_mutates_runtime` — writer captures three
  `write_default` calls in the right section, and `Config.host/.port/.log_level`
  reflect the new values immediately.

### 7.2 `test/test_settings_validation.rb` — new

- `test_accepts_valid_payload`
- `test_rejects_empty_host`
- `test_rejects_host_with_whitespace`
- `test_rejects_non_numeric_port`
- `test_rejects_port_zero_and_above_65535`
- `test_rejects_unknown_log_level`
- `test_accepts_lowercase_log_level_and_normalizes`

### 7.3 `test/test_state_machine.rb` — no change needed

Audited at design time: only reference is `Config::MAX_MESSAGE_SIZE`
(line 63), which remains a constant. No edits required.

### 7.4 Not tested

The HtmlDialog itself, the HTML/JS code, and the action_callback wiring
are not unit-tested — they require a live SketchUp environment.
Manual verification will be: install the `.rbz` in SketchUp, open
Settings…, save, restart, confirm behavior. This is acceptable for
plugin-UI code.

## 8. Risks & edge cases

| Risk | Mitigation |
|---|---|
| `Sketchup.read_default` returns Integer where a String is expected | Explicit `.to_s.upcase` for log_level, `.to_i` for port |
| `Sketchup` global missing in minitest | Reader/writer injection; default = `Sketchup` only at runtime |
| HtmlDialog API not available (SketchUp < 2017) | We do not support pre-2017 SketchUp; behavior on legacy versions is a crash on `Settings…` click — acceptable |
| User closes dialog with the window-X after editing fields | Cancel semantics: discard, no write, no callback to Ruby |
| Port valid but already in use | `TCPServer.new` raises `Errno::EADDRINUSE`; `Application.start` already shows a messagebox |
| Live MCP session breaks on user-confirmed restart | Documented behavior — user explicitly confirmed via YES/NO box |
| Two Settings… dialogs opened by clicking the menu twice | `SettingsDialog.show` is idempotent: if `@dialog && @dialog.visible?`, call `bring_to_front`; otherwise build |
| `Sketchup.write_default` fails (disk full, permissions) | Catch, show messagebox with the error; in-memory state remains unchanged |

## 9. Out of scope (not in this change)

- Port availability pre-check in the dialog (would need TCP probe).
- "Test connection" button.
- Reset-to-defaults button (can add later if requested).
- Status auto-refresh while dialog is open (today: static at open time —
  user closes & reopens to refresh).
- Python side reconfiguration UI.
- Internationalization of dialog strings.
