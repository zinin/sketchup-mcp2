# Continue execution — Python ↔ Ruby version-compat handshake

Paste this block into a fresh Claude Code session running in
`/opt/github/zinin/sketchup-mcp2`.

---

## TASK

Continue executing the implementation plan for the **Python ↔ Ruby
version compatibility handshake** feature in `sketchup-mcp2`.

Use `/superpowers:subagent-driven-development` skill for execution.

## CRITICAL: DO NOT START WORKING

**STOP. READ THIS CAREFULLY.**

After loading all context below, you MUST:
1. Read the documents and understand the context
2. Report what you understood (brief summary ≤ 200 words)
3. **WAIT for explicit user instructions** before taking ANY action

**DO NOT:**
- Start implementing tasks
- Make any code changes
- Run any commands (except reading documents)
- Assume what task to work on next

**The user will tell you exactly what to do.** Until then, only read
and summarize.

## DOCUMENTS

- **Design:** `docs/superpowers/specs/2026-05-16-version-compat-check-design.md`
- **Plan:** `docs/superpowers/plans/2026-05-16-version-compat-check-plan.md`
- **Latest review iteration:** `docs/superpowers/specs/2026-05-16-version-compat-check-review-iter-1.md`

Read all three before reporting.

## PROGRESS

**Completed:**
- [x] Brainstorming + design document written
- [x] Implementation plan written (12 tasks)
- [x] **Design review iteration 1** — 5 reviewers (codex/gpt-5.5, ccs/glm,
      ollama/{kimi, minimax, deepseek}), 31 issues triaged: 24 auto-fixes,
      3 auto-after-analysis, 1 discussed with user, 2 dismissed
- [x] All review fixes applied to design + plan (commits `87d1c4e`, `c327daa`)

**Remaining — Plan Tasks 1–12 (ALL):**
- [ ] Task 1: Python `errors.py` — add `IncompatibleVersionError(SketchUpError)` with code -32001
- [ ] Task 2: Python `compat.py` + `test_compat.py` (TDD pair) — strict regex parser, CLIENT_VERSION imported from __init__, MIN_RUBY/MAX_RUBY, hint-suffixed messages
- [ ] Task 3: Ruby `core/compat.rb` + `test/test_compat.rb` (TDD pair) — SERVER_VERSION, MIN_PYTHON/MAX_PYTHON, with_range helper with defined?-guards
- [ ] Task 4: Ruby `handlers/system.rb` + dispatch route + `test_system.rb` (REORDERED — was Task 5, must precede Task 5 integration tests)
- [ ] Task 5: Ruby server-compat handshake — dispatch.rb client_version check (request_id captured BEFORE check, notifications dropped), server.rb injects server_version in encode_response_body (covers JSON-generator-error fallback), `test_server_compat.rb` uses REAL Dispatch.handle + REAL Core::Server (no method-overriding double)
- [ ] Task 6: Python `connection.py` + `tests/test_version_handshake.py` + `tests/conftest.py` — outbound client_version, inbound check, -32001 → IncompatibleVersionError promotion, dict assertion, `get_version` added to _RETRY_SAFE_TOOLS, conftest encode_response() helper updated
- [ ] Task 7: Python `tools.py` get_version tool + `tests/test_version_tool.py` — JSON-string return, except ConnectionError + except SketchUpError, two-way compat check (Python's table AND Ruby's advertised range)
- [ ] Task 8: `examples/smoke_check.py` — append step 22
- [ ] Task 9: `docs/release.md` — 5 places → 7 places + MIN/MAX policy + invariant tests note
- [ ] Task 10: `CLAUDE.md` updates — Introspection row, version-handshake constraint bullet, Architecture tables
- [ ] Task 11: `README.md` updates — feature bullet + tool catalog entry
- [ ] Task 12: Final verification — Python + Ruby suite green, live smoke check (requires manual user step at 12.3 — rebuild .rbz, install in SketchUp, restart everything)

## SESSION CONTEXT (review-iter-1 fixes — do NOT relitigate these)

The plan has been substantially restructured by iter-1 review fixes.
Key non-obvious facts you need before starting:

### Constants renaming
- Python: `PYTHON_VERSION` (in `src/sketchup_mcp/compat.py`) is now
  **`CLIENT_VERSION`** — matches wire field `client_version`.
- Ruby: `SU_MCP::Core::Compat::RUBY_VERSION` is now **`SERVER_VERSION`**
  — matches wire field `server_version` and avoids shadowing
  `::RUBY_VERSION` (interpreter version).
- Symmetry: `CLIENT_VERSION` ↔ `SERVER_VERSION` via wire-role.

### Task order is NOT 1-to-12 sequential dispatch
- Task 4 (handlers/system.rb) must run BEFORE Task 5 (server-compat
  handshake integration tests). The plan reflects this — just don't
  reshuffle by intuition.

### Ruby `request_id` capture order
- `dispatch.rb::handle` MUST capture `request_id` and `is_notification`
  BEFORE calling `Core::Compat.check_python_version`. Otherwise the
  rescue block builds a `-32001` response with `id: nil` (JSON-RPC
  violation) and notifications get unsolicited responses.

### Ruby `server_version` injection point
- Inject in `core/server.rb::encode_response_body`, NOT in
  `write_response`. The injection must happen on BOTH the happy path
  (before the first `JSON.generate`) AND the rescue/fallback path
  (before the second `JSON.generate(Errors.build_error_response(...))`).
  Test `test_encode_response_body_injects_server_version_on_json_generator_fallback`
  forces the fallback and asserts the field is present.

### Python bypass and -32001 remap
- `_send_once` bypass: `if name != "get_version"` (uses the bare tool
  name parameter, NOT the JSON-RPC `method` field which is always
  `"tools/call"`).
- After the inbound check, if response carries `error.code == -32001`,
  promote it to `IncompatibleVersionError` (not generic `SketchUpError`)
  so callers see one class regardless of which side detected.

### `get_version` is in `_RETRY_SAFE_TOOLS`
- Don't forget this entry — it's the diagnostic tool, must auto-retry
  on stale-socket cold start.

### `get_version` tool catches BOTH ConnectionError AND SketchUpError
- Old Ruby (0.0.3) returns `-32601 "unknown tool"`; this is a
  SketchUpError, not a ConnectionError. Both must be caught and turned
  into a `compatible=false, ruby_version=null, error=<msg>` payload.

### Two-way compat verdict
- `get_version` payload computes `compatible = python_accepts_ruby AND
  ruby_accepts_python_via_advertised_range`. The Ruby-advertised range
  comes back as `min_compatible_python` / `max_compatible_python` in
  the payload (Ruby's handler returns them).
- Exposed in payload as `ruby_min_compatible_python` and
  `ruby_max_compatible_python` fields.

### conftest.py update is part of Task 6
- `tests/conftest.py::encode_response()` must inject
  `server_version=compat.MAX_RUBY` by default, otherwise existing
  ~20 tests in `test_connection.py` trip the new inbound check. Pass
  `server_version=None` explicitly for negative-case tests.

### Version values during implementation
- All version strings remain at `"0.0.3"` (current `__version__`)
  during implementation. The release-time bump to `"0.1.0"` happens
  in a **separate session** per `docs/release.md` step 1 (which Task 9
  extends from 5 → 7 places).

### Test count expectations (Task 12)
- Python: ~114 expected (81 baseline + ~33 new across compat,
  handshake, version_tool).
- Ruby: ~180 expected (154 baseline + ~26 new across compat,
  server_compat, system).

### Live verification (Task 12.3) needs manual user action
- The agent CANNOT rebuild .rbz, install in SketchUp Extension Manager,
  or restart Claude Code session. Pause at Task 12 step 12.3 and ask
  the user to do these steps; wait for confirmation before running
  step 12.4 (live `get_version()` call).

## PLAN QUALITY WARNING

The plan has been substantially improved through iter-1 review, but
may still contain:
- Errors in line numbers (codebase may have drifted)
- Implementation details that don't match current source
- Subtle ordering issues not caught by review

**Specific places to be skeptical of:**

1. **Exact line numbers** in `connection.py`, `dispatch.rb`, `server.rb` —
   if your read of the file shows different content at those lines,
   trust the file, not the plan.

2. **`encode_response_body` exact structure** — plan assumes a specific
   `rescue JSON::GeneratorError` shape. Read the current `server.rb`
   first; the rescue may live in a different method or have a
   different signature.

3. **FastMCP internal registry** in `test_get_version_is_registered`
   — the `_tool_manager._tools` attribute name may have changed; the
   test has a fallback but if both fail, use `await mcp.list_tools()`.

4. **`asyncio.IncompleteReadError` mock** in
   `tests/test_version_handshake.py::_frames_to_reader` — if the mock
   reader misbehaves, switch to `StreamReader` with `feed_data` +
   `feed_eof` per asyncio docs.

5. **`test/test_view.rb` and other existing Ruby tests** — they call
   `Dispatch.handle` without `client_version`. After Task 5 ships,
   they'll fail. Either update the fixture builder to inject a
   valid `client_version` by default, or add it to each call.

**If you notice any issues during implementation:**
1. STOP before proceeding with the problematic step.
2. Clearly describe the problem you found.
3. Explain why the plan doesn't work or seems incorrect.
4. Ask the user how to proceed.

Do NOT silently work around plan issues or make significant deviations
without user approval.

## INSTRUCTIONS

1. Read all three documents (design, plan, iter-1 review log).
2. Briefly summarize your understanding (≤ 200 words).
3. **STOP and WAIT** — do NOT proceed with any implementation.
4. When user says GO:
   - Invoke `/superpowers:subagent-driven-development`.
   - Dispatch one fresh subagent per task (Tasks 1–11). Task 12 (final
     verification) you may run yourself.
   - Between tasks, review the subagent's diff before dispatching next.
   - Keep commits atomic per task.
5. At Task 12 step 12.3, PAUSE and ask the user to perform the manual
   .rbz rebuild + SketchUp reinstall + Claude Code restart.
6. After all 12 tasks are green, STOP. Do NOT `git rm` design/plan
   docs, do NOT push, do NOT open a PR — those are branch-finish steps
   in yet another fresh session.

## REPO STATE

- Branch: `feature/viewport-screenshot-and-prompt` (continuing here,
  bundled with viewport-screenshot for the 0.1.0 release).
- Most recent commits (newest first):
  - `c327daa` docs: review iter 1 — decisions + log (version-compat-check)
  - `87d1c4e` docs: review iter 1 — auto-fixes (version-compat-check)
  - `d761361` docs(superpowers): add implementation plan for version-compat handshake
  - `5859ad2` docs(superpowers): add design for Python<->Ruby version compatibility check
- Test baseline (pre-implementation):
  - Python: `uv run pytest tests/ -q` → 81 passed, 0 failed, 0 skipped.
  - Ruby: `ruby test/run_all.rb` → 154 runs / 354 assertions / 0 fail / 0 err / 0 skip.
