# Python ↔ Ruby Version Compatibility Check — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a version handshake so Python and Ruby halves of `sketchup-mcp2` hard-fail with an actionable hint when their versions are incompatible — every JSON-RPC request carries `client_version`, every response carries `server_version`, and the new MCP tool `get_version` is a diagnostic bypass that always returns a payload.

**Architecture:** Two new modules — `src/sketchup_mcp/compat.py` and `su_mcp/su_mcp/core/compat.rb` — hold mirror-image `(MIN, MAX)` ranges. Inbound checks live in `connection.py::_send_once` (Python) and `handlers/dispatch.rb::handle` (Ruby). Outbound version injection is one-line edits in those same call-sites; the response gets `server_version` injected at the choke point `core/server.rb::encode_response_body` (covers happy path AND `JSON::GeneratorError` fallback envelope — single source of truth for every emitted envelope).

**Changelog vs design (iter-1 review fixes):**
- Server-side check moved from `core/server.rb` (per design §8.2 v0) to `handlers/dispatch.rb` (better — reuses structured-error rescue). Design §8.2 has been updated to match.
- `server_version` injection moved from `write_response` to `encode_response_body` so the JSON-generator-error fallback also carries the field.
- `request_id` and `is_notification` are captured BEFORE the version check so `-32001` responses preserve the correct id and notifications are silently dropped.
- Wire-level bypass uses `method == "tools/call" && params.name == "get_version"` (matches the actual protocol), not the simplified `method != "get_version"` pseudocode that appeared in design §8.2 v0.
- `get_version` tool catches both `ConnectionError` AND `SketchUpError` (the latter covers old-Ruby `-32601 "unknown tool"`).
- `get_version` added to `_RETRY_SAFE_TOOLS` so cold-start stale-socket auto-retries instead of bubbling.
- Compat verdict is TWO-WAY: Python's table accepts ruby_version AND Ruby's advertised range accepts CLIENT_VERSION. Catches table-drift.
- Python `_send_once` promotes inbound `error.code == -32001` to `IncompatibleVersionError` (instead of generic `SketchUpError`) so callers see the same class regardless of which side detected the mismatch.
- `tests/conftest.py::encode_response()` updated to inject `server_version` by default so existing `test_connection.py` stays green; a separate negative-case test exercises missing-field semantics. **(Implementation correction:** helper actually lives in `tests/test_connection.py`, not `conftest.py`; was updated there instead.)
- `test/test_server_compat.rb` uses the REAL `Dispatch.handle` + REAL `Core::Server` (with a captured-write fake socket) instead of overriding `write_response` with a hand-written copy — production code is actually exercised.
- Task 4 reordered: `handlers/system.rb` + dispatch route created BEFORE `test_server_compat.rb` so the integration test can exercise the real `get_version` path.

**Tech Stack:** Python 3.10+ (`asyncio`, FastMCP, Pydantic v2, pytest); Ruby 2.7 inside SketchUp (minitest, stdlib only).

**Reference spec:** `docs/superpowers/specs/2026-05-16-version-compat-check-design.md`.

**Branch (already on it):** `feature/viewport-screenshot-and-prompt` — version-compat bundles into the same 0.1.0 release as viewport-screenshot.

**Version state at implementation time vs at release time:**
- During implementation, `__version__` in `src/sketchup_mcp/__init__.py` is `"0.0.3"`; tests and the live smoke check run against that. Accordingly, `MIN_RUBY`, `MAX_RUBY`, `SERVER_VERSION`, `MIN_PYTHON`, `MAX_PYTHON` are all set to `"0.0.3"` initially. This keeps the matched-pair "compatible=true" invariant during development.
- At release time, a separate session bumps all seven version strings to `"0.1.0"` per `docs/release.md` §1 (which Task 9 extends from 5 → 7 places).

---

## File Structure

### Files to CREATE

| Path | Responsibility |
|---|---|
| `src/sketchup_mcp/compat.py` | Single source of truth for Python↔Ruby compatibility: CLIENT_VERSION (imported from `__init__.py`), MIN_RUBY, MAX_RUBY, `_parse`, `check_ruby_version`, canonical error-message strings. |
| `tests/test_compat.py` | Unit tests for `_parse`, `check_ruby_version`, MIN ≤ MAX sanity. |
| `tests/test_version_handshake.py` | Tests for outbound `client_version` injection, inbound `server_version` check on every response, get_version bypass. |
| `tests/test_version_tool.py` | Tests for `get_version` MCP tool: registration, compatible/incompatible payload shape, bypass works on mismatch. |
| `su_mcp/su_mcp/core/compat.rb` | Ruby mirror — SERVER_VERSION, MIN_PYTHON, MAX_PYTHON, `parse`, `check_python_version`, canonical error-message strings. |
| `su_mcp/su_mcp/handlers/system.rb` | `Handlers::System.get_version(_params)` — returns the Ruby-side compat metadata payload. |
| `test/test_compat.rb` | Symmetric to `test_compat.py`. |
| `test/test_server_compat.rb` | Tests for incoming `client_version` check (dispatch bypass for get_version), outgoing `server_version` injection on success/error/JSON-generator-fallback, `request_id` preserved on -32001, notification-with-mismatch silently dropped. Uses REAL `Dispatch.handle` + REAL `Core::Server` (no method-overriding double). |
| `test/test_system.rb` | `Handlers::System.get_version` handler unit tests + dispatch routing. |

### Files MODIFIED

| Path | Change |
|---|---|
| `src/sketchup_mcp/errors.py` | +1 class `IncompatibleVersionError(SketchUpError)` with JSON-RPC code `-32001`. |
| `src/sketchup_mcp/connection.py` | In `_send_once`: outbound `client_version`; inbound dict-assert + `if name != "get_version"` check; -32001 → IVE promotion. `_RETRY_SAFE_TOOLS` gains `"get_version"`. |
| `src/sketchup_mcp/tools.py` | +1 `@mcp.tool()` async `get_version` (catches ConnectionError AND SketchUpError; two-way verdict; JSON-string return). |
| `tests/test_connection.py` | `encode_response()` helper injects `server_version=compat.MAX_RUBY` by default via sentinel; explicit `server_version=None` for negative cases. (Plan said conftest.py, helper actually lives here.) |
| `su_mcp/su_mcp/core/server.rb` | `encode_response_body` injects `server_version` on BOTH happy path AND JSON::GeneratorError fallback. |
| `su_mcp/su_mcp/handlers/dispatch.rb` | Capture `request_id`/`is_notification` BEFORE compat check; bypass `tools/call`+`params.name=="get_version"`; WARN log for -32001; preserved `log_error` + `exception_to_data` enrichment for non-version errors. |
| `su_mcp/su_mcp/main.rb` | LOAD_ORDER gains `core/compat` (after `core/errors`) and `handlers/system` (after `handlers/eval`). |
| `test/test_view.rb` | Added `require_relative "../su_mcp/su_mcp/core/compat"` + `"client_version" => MIN_PYTHON` to dispatch routing fixture (previously raised -32001 after Task 5). |
| `examples/smoke_check.py` | +1 step (22) calling `get_version`, asserting `compatible=true`. |
| `docs/release.md` | §1 from 5 → 7 places (add `compat.py` + `core/compat.rb`); MIN/MAX policy paragraph; references three invariant tests. |
| `CLAUDE.md` | Introspection row gains `get_version`; new Non-Obvious Constraints bullet on handshake; Architecture tables expanded with `compat.py` / `core/compat.rb` / `handlers/system.rb`. |
| `README.md` | One Features bullet + one Introspection tool entry. |

### Files NOT touched (sanity)

- `src/sketchup_mcp/__init__.py` — `__version__` stays `"0.0.3"` until the release-time bump (separate session).
- `src/sketchup_mcp/app.py`, `config.py`, `prompts.py`, `server.py` — unchanged.
- `tests/conftest.py` — unchanged (plan correction).
- `su_mcp/su_mcp/core/{config,errors,framing,logger,application}.rb` — unchanged.
- `su_mcp/su_mcp/handlers/{geometry,operations,joints,materials,export,model,eval,view}.rb` — unchanged.
- `pyproject.toml`, `uv.lock`, `su_mcp/extension.json`, `su_mcp/package.rb`, `su_mcp/su_mcp.rb` — unchanged until release-time bump.

---

## Task 1: Python `errors.py` — add `IncompatibleVersionError`

✅ Done — see commit: `a80cef4`

---

## Task 2: Python `compat.py` — TDD pair

✅ Done — see commit: `b6887ce`

---

## Task 3: Ruby `core/compat.rb` — TDD pair

✅ Done — see commit: `5704e1c`

---

## Task 4: Ruby `handlers/system.rb` + dispatch routing — TDD pair

✅ Done — see commit: `a425b6b`

---

## Task 5: Ruby server-compat handshake — request check + response injection

✅ Done — see commit: `135bd19`

**Plan corrections applied during implementation:**
- `Logger.log_warn` does not exist — replaced with `Core::Logger.log("WARN", ...)`.
- `Object.new` does NOT trigger `JSON::GeneratorError` (it serializes via `to_s`) — replaced with `Float::NAN` in the fallback test.
- Preserved existing `log_error` + `exception_to_data` rescue enrichment (the plan's sample rescue dropped these).
- `test/test_view.rb` dispatch-routing fixture updated to include `client_version` (the new check would otherwise break it).
- `test/test_server_compat.rb` includes a `setup` block initializing `Core::Config` (defensive consistency with `test_application.rb`).

**Known minor finding (Minor / non-blocking):** malformed notifications (missing `jsonrpc` or `method`) now produce a -32600 error envelope where the pre-Task-5 code silently dropped them. JSON-RPC §4.1 prefers silence — to restore, hoist `request_id`/`is_notification` capture above `validate_envelope!`. Not yet applied; reviewer marked as non-blocking polish.

---

## Task 6: Python `connection.py` — outbound `client_version` + inbound `server_version` check

✅ Done — see commit: `c684339`

**Plan correction applied:** the `encode_response()` helper lives in `tests/test_connection.py`, NOT `tests/conftest.py`. Updated in-place there with a `_INJECT_MAX` sentinel default. `tests/conftest.py` is unchanged.

---

## Task 7: Python `tools.py` — `get_version` MCP tool

✅ Done — see commit: `170d7cd`

**FastMCP API drift handled in tests:** `mcp.call_tool(...)` returns a 2-tuple `(content_blocks_list, structured_result_dict)` rather than a flat list (since tools with `-> str` annotation auto-acquire an output schema via FuncMetadata). The 3 payload-extraction tests use a defensive unpack `blocks = result[0] if isinstance(result, tuple) else result`. Production `tools.py::get_version` is verbatim from the plan.

**Reviewer-recommended follow-ups (not yet applied, non-blocking):**
- `test_get_version_returns_payload_on_unknown_tool_error` — locks in the SketchUpError(-32601) branch.
- `test_two_way_compat_drift_detected` — locks in the QUESTION-1 two-way verdict.

Production code handles both scenarios correctly; tests are regression guards only.

---

## Task 8: Live smoke check step 22

✅ Done — see commit: `eb8d061`

---

## Task 9: `docs/release.md` update — 5 places → 7 places

✅ Done — see commit: `8b30bd0`

---

## Task 10: `CLAUDE.md` update

✅ Done — see commit: `3b0f000`

---

## Task 11: `README.md` update

✅ Done — see commit: `9d67ab7`

---

## Task 12: Final verification

**12.1 Python test suite** — ✅ green: `115 passed, 0 failed, 1 pre-existing deprecation warning`.

**12.2 Ruby test suite** — ✅ green: `180 runs / 419 assertions / 0 failures / 0 errors / 0 skips`.

**12.3 Manual `.rbz` rebuild + SketchUp reinstall + Claude Code restart** — ⏳ pending user.

```bash
cd /opt/github/zinin/sketchup-mcp2/su_mcp && ruby package.rb && cd ..
ls -la su_mcp/su_mcp_v0.0.3.rbz
```

Then:
1. SketchUp Extension Manager → uninstall the previous `su_mcp` → install the freshly built `.rbz`.
2. Restart SketchUp (or Plugins → MCP Server → Start Server).
3. Restart the Claude Code session so it picks up the freshly built `uv pip install -e .` Python side.

**12.4 Live `get_version()` call** — ⏳ pending user (depends on 12.3).

Expected payload:
```json
{
  "python_version": "0.0.3",
  "ruby_version": "0.0.3",
  "min_compatible_ruby": "0.0.3",
  "max_compatible_ruby": "0.0.3",
  "compatible": true,
  "error": null
}
```

**12.5 Live `python examples/smoke_check.py`** — ⏳ pending user.

Expected: all 22 steps green, including the new step 22 `versions: python=0.0.3 ruby=0.0.3`.

---

## Implementation Summary

11 atomic commits, each spec-reviewed + code-quality-reviewed:

```
9d67ab7 docs(readme): mention version handshake feature + get_version tool
3b0f000 docs(claude-md): document version handshake + get_version tool
8b30bd0 docs(release): grow version bump list 5 → 7 places (compat.py + compat.rb)
eb8d061 test(smoke): exercise get_version handshake in step 22
170d7cd feat(tools): add get_version MCP tool — diagnostic that always succeeds
c684339 feat(handshake): wire client_version outbound + server_version check inbound
135bd19 feat(handshake): check client_version in dispatch, inject server_version in encode_response_body
a425b6b feat(handlers): add get_version system handler + dispatch route
5704e1c feat(compat): add Ruby-side version compatibility module
b6887ce feat(compat): add Python-side version compatibility module
a80cef4 feat(errors): add IncompatibleVersionError for -32001 mismatches
```

After steps 12.3-12.5 pass, the branch is ready for `superpowers:finishing-a-development-branch` (separate session — also performs `git rm` of design/plan docs per global CLAUDE.md rule).
