# SketchUp Menu Settings UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Ruby ENV-based configuration (host/port/log_level) with a SketchUp menu-driven `UI::HtmlDialog` persisted via `Sketchup.write_default`.

**Architecture:** Refactor `Core::Config` constants into mutable accessors loaded from SketchUp prefs at plugin boot. Add a singleton HtmlDialog opened from the Plugins menu. Validation lives in a pure Ruby module testable without SketchUp; the Ruby↔JS bridge uses `add_action_callback` with three actions (`load_state`, `save`, `cancel`). Application captures a runtime snapshot of the config it was started with, so the dialog can show "saved values differ — restart needed".

**Tech Stack:** Ruby (SketchUp Ruby API 2017+), `UI::HtmlDialog`, `Sketchup.read_default`/`write_default`, minitest. No JS build step, no external HTML dependencies.

---

## Status

All 8 tasks complete. Branch: `feature/menu-settings-ui`. Latest commit: `2253be2`.

| # | Task | Commit(s) |
|---|---|---|
| 1 | Refactor `Core::Config` — accessors + load/update API + tests | `dba6d91` |
| 2 | Consumers + boot wiring + `running_config` + `test_application` + migration banner | `a420c9f` |
| 3 | `SettingsValidator` module (TDD) | `329899c` |
| — | Hotfix: `::UI` qualification in `application.rb` (namespace shadowing surfaced by Task 3) | `e9092b7` |
| — | Hotfix: `::UI` qualification in `server.rb` + `main.rb` (same root cause, swept proactively) | `f5cd39c` |
| 4 | `settings.html` — UI shell | `55642a3` |
| 5 | `SettingsDialog` Ruby class — IPC + Save flow | `77673d1` |
| 6 | Wire UI files into `LOAD_ORDER` + add `Settings...` menu entry | `c9c2dd5` |
| 7 | Update `CLAUDE.md` Configuration section | `88c46ec` |
| — | Polish: ASCII ellipsis in CLAUDE.md menu label (consistency with `main.rb` literal) | `2253be2` |
| 8 | Final verification (no commit — automated checks only) | — |

**Final verification:** Ruby `108 runs / 246 assertions / 0 failures`. Python `52 passed`. Zero `Config::HOST/PORT/LOG_LEVEL` refs in production. ENV reads only inside `show_migration_banner!` (intentional) and `test_config.rb` migration tests (intentional). `.rbz` builds at 36 KB and includes all 3 new `ui/` files.

---

## File structure

**Created:**
- `su_mcp/su_mcp/ui/settings_validator.rb` — pure validation module
- `su_mcp/su_mcp/ui/settings_dialog.rb` — singleton wrapping UI::HtmlDialog + callbacks
- `su_mcp/su_mcp/ui/settings.html` — single-page HTML/CSS/JS
- `test/test_settings_validation.rb` — minitest for validator
- `test/test_application.rb` — minitest for `Application.running_config` lifecycle (via StubServer)

**Modified:**
- `su_mcp/su_mcp/core/config.rb` — full rewrite (const → accessors, ENV removed, add `show_migration_banner!`, runtime-first `update!`)
- `su_mcp/su_mcp/core/server.rb` (line 26)
- `su_mcp/su_mcp/core/application.rb` (full rewrite: injectable `server_class`, `running_config` snapshot, updated status text)
- `su_mcp/su_mcp/core/logger.rb` (line 19)
- `su_mcp/su_mcp/main.rb` (LOAD_ORDER additions, menu entry, boot-time `load_from_defaults!` + `show_migration_banner!`, Show Status uses `running_config`)
- `test/test_config.rb` — remove ENV tests, add reader/writer/UI-based tests
- `CLAUDE.md`, `README.md` — update Configuration section

**Unchanged:**
- `su_mcp/package.rb` (FileUtils.cp_r picks up new `ui/` directory)
- `su_mcp/su_mcp/core/framing.rb` (MAX_MESSAGE_SIZE stays a constant)
- `test/test_state_machine.rb` (only refs `Config::MAX_MESSAGE_SIZE`)
- Everything under `src/sketchup_mcp/` (Python side ENV-driven, by design)

---

## Task 1: Refactor `Core::Config` — accessors + load/update API + tests

✅ Done — see commit: `dba6d91`

---

## Task 2: Consumers + boot wiring + `running_config` + test_application + migration banner

✅ Done — see commit: `a420c9f`

(Single atomic commit — fusion preserved per iter-1 reviewer guidance. Splitting would have left the working tree referencing the deleted `Config::HOST/PORT/LOG_LEVEL` constants between commits.)

---

## Task 3: `SettingsValidator` module (TDD)

✅ Done — see commit: `329899c`

After Task 3, two follow-up hotfixes were needed because introducing the `SU_MCP::UI` namespace shadowed top-level `::UI` for any unqualified `UI.*` reference inside `SU_MCP::*`:

- `e9092b7` — `::UI.messagebox` in `application.rb:43` (rescue path; surfaced via `test_start_failure_leaves_running_config_nil` regression).
- `f5cd39c` — `::UI.start_timer/stop_timer` in `server.rb:28,33` and `::UI.menu` in `main.rb:46` (latent bugs of the same shape; would have broken plugin boot at Task 6).

The plan author was aware of the collision elsewhere (always wrote `::UI.messagebox`, `::UI::HtmlDialog`, `ui: ::UI`) but the `application.rb` excerpt at plan line 416 had a stray bare `UI`. Same audit logic as the hotfix swept the remaining sites.

---

## Task 4: `settings.html` — UI shell

✅ Done — see commit: `55642a3`

---

## Task 5: `SettingsDialog` Ruby class — IPC + Save flow

✅ Done — see commit: `77673d1`

(Not unit-tested by design — `UI::HtmlDialog`, `MB_YESNO`, `IDYES` require live SketchUp. Manual smoke check covered in Task 8.)

---

## Task 6: Wire UI files into `LOAD_ORDER` and add the menu entry

✅ Done — see commit: `c9c2dd5`

---

## Task 7: Update `CLAUDE.md` and `README.md`

✅ Done — see commits: `88c46ec`, `2253be2`

(README intentionally not modified — its only `SKETCHUP_MCP_*` refs are inside the Python-side `claude_desktop_config.json` example, which remains correct. Polish commit `2253be2` switched `Settings…` (U+2026) to `Settings...` (3 ASCII periods) in CLAUDE.md to match the actual `menu.add_item("Settings...")` literal in `main.rb`.)

---

## Task 8: Final verification

✅ Done — automated verification only (no commit).

- `ruby test/run_all.rb` → **108 runs, 246 assertions, 0 failures, 0 errors, 0 skips**
- `uv run pytest tests/ -q` → **52 passed**
- `grep -rn -E "Config::(HOST|PORT|LOG_LEVEL)" su_mcp/ test/ src/` → **zero matches**
- `grep -rn -E "ENV\[.SKETCHUP_MCP_(HOST|PORT|LOG_LEVEL)" su_mcp/ test/` → only intentional matches (3 in `test_config.rb` migration-banner tests; production `show_migration_banner!` uses `ENV[v]` with runtime-variable index which is correct and out of regex scope)
- `cd su_mcp && ruby package.rb` → built `su_mcp_v0.0.1.rbz` (36 KB, includes `ui/settings.html`, `ui/settings_dialog.rb`, `ui/settings_validator.rb`)

**Manual smoke check** (requires live SketchUp — not executable in CI):

1. Build .rbz: `cd su_mcp && ruby package.rb`.
2. SketchUp → Extensions → Extension Manager → Install Extension → select the `.rbz`.
3. Restart SketchUp.
4. `Plugins → MCP Server → Settings...` — dialog opens; fields show defaults (127.0.0.1 / 9876 / INFO).
5. Change host to `0.0.0.0`, click Save. Dialog confirms, no errors. No restart prompt (server not running yet).
6. `Plugins → MCP Server → Start Server`. Open Settings... again — status block shows "running on 0.0.0.0:9876".
7. Change port to `9877`, click Save. Prompt "Restart server with new settings now?" appears. Click Yes. `Show Status` confirms `:9877`.
8. Re-open Settings..., type port `0`, click Save. Inline error: "Port must be a number between 1 and 65535". Dialog stays open.
9. Close SketchUp, reopen — settings survive (read from `Sketchup.read_default`).

---

## Spec coverage check (for the implementer)

| Spec section | Covered by Task |
|---|---|
| 5.1 Config refactor (incl. update! runtime-first, .to_s host, migration banner) | 1 |
| 5.2 Boot wiring (load_from_defaults! + show_migration_banner!) | 2 |
| 5.3 Consumers + `running_config` + Show Status | 2 |
| 5.4 HtmlDialog files & IPC | 4, 5 |
| 5.5 Save flow (with on_load_state refresh + UI.start_timer wrap) | 5 |
| 5.6 Validation rules (incl. host charset regex) | 3 |
| 5.7 HTML layout (em / flex-basis for High-DPI) | 4 |
| 5.8 Menu wiring | 6 |
| 6.1 ENV removal | 1 (config rewrite drops `read_env`) |
| 6.2 Migration banner | 1 (Config.show_migration_banner!) + 2 (boot call) |
| 6.3 Docs | 7 |
| 6.4 Packaging (no change) | — (verified in design; `cp_r` is recursive) |
| 7.1 test_application.rb new | 2 |
| 7.2 test_config.rb adapted | 1 |
| 7.3 test_settings_validation.rb new | 3 |
| 7.4 test_state_machine.rb (no change) | — (verified in spec) |
| 8 Risks/edge cases | mitigations woven into Tasks 1/2/5 |
| 9 Out of scope | — (intentionally not implemented) |
