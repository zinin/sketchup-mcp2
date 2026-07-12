# Spec: actionable hint + tool name on stale-socket transport errors (Python-only)

Date: 2026-05-29 · Branch: feature/warehouse-resubmit · Scope: Python MCP server only

## Problem

When the persistent TCP socket goes stale (e.g. the user restarts the SketchUp
MCP server), the FIRST call to a **non-retry-safe** tool (`eval_ruby` + all
mutating tools) surfaces:

```
[-32000] connection error: Connection lost — tool=?, params={}
```

- `connection.py::send_command` auto-retries ONLY `_RETRY_SAFE_TOOLS` (8
  read-only tools). Mutating / `eval_ruby` are deliberately NOT auto-retried: a
  commit may have landed before the socket closed, so a blind retry could
  double-apply (documented, Codex review PR #1). **This safety policy is correct
  and stays unchanged.**
- BUT the surfaced error (a) lacks the tool name (`tool=?`) and (b) gives the
  agent zero recovery guidance — so a naive agent gives up, even though the very
  next call reconnects (a manual retry succeeds, which is what happened in
  acceptance testing of v0.2.0).

## Goal

Make the stale-socket error self-describing and safety-aware, and fill in the
tool name. Python-only. No wire-protocol change, no version bump, no `.rbz`
rebuild (the `.rbz` is Ruby-only; this error text is not part of the protocol).

## Changes

### 1. `src/sketchup_mcp/connection.py` — `send_command`

Restructure the `except _StaleSocketError` block:
- `name in _RETRY_SAFE_TOOLS` → transparent reconnect + retry (unchanged).
- else → re-raise an enriched `SketchUpError` (SAME code `-32000`) with:
  - **message** = original `e.message` + an actionable, safety-aware hint, e.g.:
    > `<orig> — the persistent socket was stale (the SketchUp server likely
    > restarted) and has been reset. '<name>' was NOT auto-retried because it can
    > modify the model and the request may have committed before the socket
    > closed; a blind retry could double-apply it. Recovery: call a read-only
    > tool (e.g. get_model_info / list_components) to reconnect and inspect the
    > model, then retry '<name>' only if you can confirm it did NOT apply — if you
    > cannot confirm, do NOT retry.`
  - **data** = `{"tool": name}`

Wording is deliberately ADVISORY, not an instruction to retry (spec review
Important-1): for arbitrary `eval_ruby` the agent often cannot prove "did it
apply", so the hint must not manufacture false confidence. `_StaleSocketError`
has TWO raise sites (spec review Important-2) — zero-byte EOF
(`connection.py:262`) AND any `ConnectionError`/RST at any phase
(`connection.py:273`, incl. mid-write where the request may never have reached
Ruby). The message above is intentionally general enough to cover both.

Only `_StaleSocketError` is enriched. Timeout / partial-read / oversize keep
their current messages — retrying those is genuinely unsafe and they must NOT
advertise "reconnect and retry".

### 2. `src/sketchup_mcp/tools.py` — `_call` and `eval_ruby`

Before `format_error`, `e.data.setdefault("tool", <tool_name>)` so a
locally-raised transport error (timeout, partial-read, oversize, stale) that
surfaces THROUGH `format_error` carries the tool name → `tool=?` becomes the
real name. `setdefault` never overrides:
- Ruby-origin errors (already carry `"tool"` from `core/errors.rb`), nor
- the enriched stale error from change #1 (already set).

In `eval_ruby`, the `setdefault` goes AFTER the `-32010` (eval-disabled)
early-return, so the verbatim disabled message is untouched.

Scope note (spec review Minor-1/3): only `_call` and `eval_ruby` render errors
via `format_error`, so only they need the `setdefault`. `get_viewport_screenshot`
propagates a raw `SketchUpError` to FastMCP (no `format_error`, so `tool=` is not
rendered) and `get_version` surfaces via `str(e)` (message only). Both are also in
`_RETRY_SAFE_TOOLS`, so a stale socket auto-retries and rarely surfaces there.
The enriched MESSAGE from change #1 still survives on those paths (it lives in
`e.message`); only the `tool=` field is N/A. No change needed for them.

## Tests (TDD — write first, watch fail, then implement)

- `tests/test_connection.py` — enrichment pinned on BOTH `_StaleSocketError`
  raise sites for a mutating tool (spec review Minor-2):
  - zero-byte EOF (`reader.feed_eof()`) → raises `SketchUpError`, `code == -32000`,
    `e.data["tool"] == "<name>"`, message contains hint markers
    (`"NOT auto-retried"`, `"get_model_info"`, `"do NOT retry"`), `connect` not called.
  - `ConnectionError` mid-roundtrip (drain/recv raises `ConnectionResetError`) →
    same assertions. (Two tests, or one parametrized over the two failure modes.)
  Existing `no_retry_on_zero_byte_eof_for_mutating` / `no_retry_on_partial_read`
  stay green (still raise `-32000`, `connect` not called).
- `tests/test_tools.py` — new test: a text tool whose `send_command` raises a
  `SketchUpError` with empty `data` → the returned string from `_call` contains
  `tool=<name>` (verifies the `setdefault`).

## Non-goals

- No change to the retry SAFETY policy (`_RETRY_SAFE_TOOLS` unchanged).
- No version bump (`MIN_RUBY=MAX_RUBY=0.2.0` stays). No Ruby change. No `.rbz` rebuild.
- Option B (hint in the `sketchup_modeling_strategy` prompt) is out of scope here.

## Baselines

Ruby 287/684 untouched. Python 123 → +3 new tests = 126 (2 enrichment + 1 tool-name).
