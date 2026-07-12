# Execution prompt — version-compat handshake (fresh session)

Paste the block below into a fresh Claude Code session running in
`/opt/github/zinin/sketchup-mcp2`.

---

## TASK

Execute the implementation plan for the Python ↔ Ruby version
compatibility handshake feature in `sketchup-mcp2`.

Use `/superpowers:subagent-driven-development` skill for execution.

## DOCUMENTS

- Design: `docs/superpowers/specs/2026-05-16-version-compat-check-design.md`
- Plan:   `docs/superpowers/plans/2026-05-16-version-compat-check-plan.md`

Read both documents first.

## IMPORTANT: DO NOT START WORK YET

After reading the documents:
1. Confirm you have loaded all context.
2. Briefly summarize your understanding (≤ 200 words).
3. **WAIT for explicit user instruction before taking any action.**

Do NOT begin implementation until the user explicitly tells you to start.

## REPO STATE

- Branch: `feature/viewport-screenshot-and-prompt` (continuing here,
  bundled with viewport-screenshot for the 0.1.0 release).
- Most recent commits (newest first):
  - `d761361` docs(superpowers): add implementation plan for version-compat handshake
  - `5859ad2` docs(superpowers): add design for Python<->Ruby version compatibility check
  - `66eba81` docs: trim completed Tasks 7-11 from viewport-screenshot plan
  - … earlier viewport-screenshot commits.
- Test baseline before starting this plan:
  - Python: `uv run pytest tests/ -q` → **81 passed, 0 failed, 0 skipped**.
  - Ruby: `ruby test/run_all.rb` → **154 runs / 354 assertions / 0 fail / 0 err / 0 skip**.

## SESSION CONTEXT — non-obvious knowledge from brainstorming

### Architectural decisions (resolved during brainstorming — do not relitigate)

1. **Two identical tables, not one.** Python `src/sketchup_mcp/compat.py`
   and Ruby `su_mcp/su_mcp/core/compat.rb` each hold their own
   `(MIN, MAX)` range. Both sides verify independently. Rejected
   alternatives: client-only table, protocol_version + lookup table.

2. **Version channel is per-message, not handshake-only.** Every
   request carries `client_version`; every response carries
   `server_version`. The inbound check runs on **every** response —
   no per-connection cache. Rejected alternatives: cache first
   verdict, send only at first request.

3. **Hard-fail on mismatch.** No warning-only mode, no soft-fail. The
   only diagnostic exception is `get_version` itself, which bypasses
   the check on **both** sides (so users on mismatched setups can
   still inspect versions to know what to upgrade).

4. **Format is `(MIN, MAX)` range — not explicit list or mapping.**
   Rejected alternatives: list of compatible versions (`["0.0.3",
   "0.1.0"]`), `{own_version: [counterparts]}` history mapping.

5. **`compatible` flag computed Python-side.** Ruby returns raw
   `ruby_version` / `min_compatible_python` / `max_compatible_python`;
   Python applies the compat table and emits the boolean. Rejected:
   Ruby pre-computes `compatible` (would duplicate compat logic in
   runtime).

6. **`handlers/system.rb` is a new file**, not an addition to
   `handlers/model.rb`. Concept-clean separation.

7. **`get_version` in CLAUDE.md belongs to the `Introspection`
   category**, not a new `Version` category. Single-tool category
   would be overkill.

8. **Branch strategy:** continue on
   `feature/viewport-screenshot-and-prompt` — version-compat ships
   bundled with viewport-screenshot as the 0.1.0 release. One PR
   covers both features.

9. **Test file isolation:** Python handshake tests live in a new
   `tests/test_version_handshake.py` — NOT folded into the existing
   `tests/test_connection.py`. test_connection stays focused on
   transport.

### Wire-level nuance — the `tools/call` indirection

This trips up the design if you read the design doc too literally:

- The Python `_send_once` in `connection.py` (line 129-134) always
  sends `method: "tools/call"` and puts the real tool name in
  `params.name`. The `method` in the JSON-RPC envelope is NEVER the
  bare tool name.
- Therefore the **Ruby-side bypass check** for `get_version` must
  look at `request["method"] == "tools/call" && request.dig("params",
  "name") == "get_version"`, NOT `request["method"] == "get_version"`.
- The **Python-side bypass** uses `name`, which is the parameter
  passed to `send_command(name, args)` — that one IS the bare tool
  name (`"get_version"`).

The plan's Task 4 (Ruby dispatch.rb edit) and Task 6 (Python
connection.py edit) both reflect this correctly. Don't "simplify" by
checking `method == "get_version"`.

### Version values during implementation

All version strings stay at `"0.0.3"` (current `__version__`) until a
later **separate session** runs `docs/release.md` step 1 to bump every
string to `"0.1.0"`. Set:

- `PYTHON_VERSION` ← imported from `__init__.py` (`"0.0.3"`).
- `MIN_RUBY = MAX_RUBY = "0.0.3"` in `compat.py`.
- `RUBY_VERSION = MIN_PYTHON = MAX_PYTHON = "0.0.3"` in `compat.rb`.

This keeps the matched-pair smoke check (`compatible=true`) green
during implementation. Do NOT preemptively bump to `"0.1.0"` — that's
release.md's job, and a bump now would invalidate test fixtures.

### Backward-compat shearline (one-time, at user upgrade)

When 0.1.0 ships, users on the old 0.0.3 `.rbz` will see a hard-fail
the first time they hit it — `server_version` will be missing from
Ruby responses. The hint message (`"SketchUp plugin pre-dates
version-compat checking. Reinstall su_mcp_v0.0.3.rbz from the GitHub
release."`) is in the unit tests; with the release-time bump it
becomes `"…su_mcp_v0.1.0.rbz…"` automatically because the message is
built from `MAX_RUBY`. Same symmetry for Python old client → new Ruby.

This is the only known UX shearline. Document it in the GitHub
release notes when the release is cut (separate session).

### `IncompatibleVersionError` — JSON-RPC code `-32001`

- Python: new class in `errors.py`, subclass of `SketchUpError`,
  always uses code `-32001`.
- Ruby: re-uses existing `Core::StructuredError` with code `-32001`
  (no new exception class needed — symmetry on the wire level is
  what matters).

Code `-32001` is chosen as the sibling of `-32000` (used by
`StructuredError`) so log-grep can distinguish version-mismatch from
plain server errors. Stay in the implementation-defined range
`-32000…-32099` per JSON-RPC 2.0 §5.1.

### Single point of `server_version` injection in Ruby

Inject `response["server_version"] = Core::Compat::RUBY_VERSION`
inside `core/server.rb::write_response` (the existing method on the
`Core::Server` class) — NOT in `Dispatch.handle`, `build_success_response`,
or `Errors.build_error_response`. The single choke point at
`write_response` covers:
- success responses,
- error responses from `Dispatch` raising `StructuredError`,
- transport errors from `send_transport_error`,
- the encoding-fallback envelope from `encode_response_body`'s rescue
  clause.

This is the reason the plan's Task 4 uses ONE edit at the bottom of
`write_response` instead of multiple edits at the builder sites.

### Ruby test idiom for swapping constants

`test/test_compat.rb` uses `remove_const` / `const_set` to temporarily
swap `MIN_PYTHON` / `MAX_PYTHON` per-test. This is the standard
minitest pattern (no `Module#stub` for constants). Make sure each
test's `ensure` block restores the original values — if a test
leaks, downstream tests can produce mysterious failures. The
`with_range(min, max) { … }` helper in the plan's test file template
already handles this — do NOT remove its `ensure` block.

### Python tests use AsyncMock + frame builder

`tests/test_version_handshake.py` uses `_frames_to_reader` and
`_capturing_writer` helpers to mock TCP without actually opening a
socket. The framing helpers correctly emit `struct.pack(">I",
len(body)) + body` — match this format if you adjust them. Project
already uses pytest-asyncio in `asyncio_mode = "auto"` (set in
`pyproject.toml:48-49`), so `@pytest.mark.asyncio` is optional but
harmless.

### `examples/smoke_check.py` step numbering

Viewport-screenshot already added step 19; the design referenced
step 22 in the plan (after the viewport's renumbered step 21 and
some pre-existing cleanup/undo). When implementing, double-check
the current step numbering with `grep -n "^# *[0-9]" examples/smoke_check.py`
before appending — if the count drifted, use the next available
integer rather than the literal "22".

### Live verification — manual user action needed

Task 12 step 12.3 requires the user to:
1. Rebuild `.rbz` via `cd su_mcp && ruby package.rb`.
2. Uninstall the previous extension in SketchUp Extension Manager.
3. Install the freshly built `.rbz`.
4. Restart SketchUp / start MCP Server.
5. Restart Claude Code so it picks up the fresh `uv pip install -e .`.

The agent CANNOT perform any of these. State this clearly when you
reach Task 12, ask the user to do them, and wait for confirmation
before running step 12.4 (live `get_version()` call).

## REJECTED ALTERNATIVES (for the record)

| Rejected | Reason |
|---|---|
| One central compat table | Rejected — symmetric two-table design lets each side fail-fast independently with the right local message. |
| Soft-fail / warning-only on mismatch | Rejected — silent breakage is worse than a clear error at the start. |
| Cache verdict per connection | Rejected — check runs on every response (microseconds of cost; catches mid-session re-routes). |
| Send `client_version` only at handshake | Rejected — symmetry with `server_version` (in every response) is cleaner. |
| Use `Sketchup.send_action("view{Preset}:")` (legacy viewport-screenshot leftover) | N/A for this feature — mentioned only to confirm we will NOT re-introduce the `send_action` async dependency. |
| Store `RUBY_VERSION` in a separate `version.rb` | Rejected (option A2 in brainstorming) — YAGNI; one constant in `compat.rb` is enough. |
| Tool category "Version" in CLAUDE.md | Rejected — one-tool category is overkill; fold into Introspection. |
| Fold tests into existing `test_connection.py` | Rejected — keeps transport tests separate from handshake tests. |

## PLAN QUALITY WARNING

The plan was written for a multi-task feature and may contain:
- Errors or inaccuracies in implementation details.
- Oversights about edge cases or dependencies.
- Assumptions that don't match the actual codebase (e.g. exact line
  numbers may drift; the design-doc claim about a specific
  attribute's behavior may be wrong for a future SketchUp version).
- Missing steps or incomplete instructions.

**Specific places to be skeptical of, based on prior experience with
this codebase:**

1. **`mcp._tool_manager._tools` vs `mcp._tools`** in
   `tests/test_version_tool.py::test_get_version_is_registered` — the
   FastMCP internal registry attribute has changed names across
   versions. The test has a fallback (`hasattr(mcp, "_tool_manager")`),
   but if both fail, query via `await mcp.list_tools()` instead.

2. **`asyncio.IncompleteReadError` in the mock reader** — the mock
   `readexactly` in `tests/test_version_handshake.py` uses a position
   counter and a concatenated buffer. If you encounter "OSError:
   `MagicMock` has no attribute `read`" or similar, the simpler fix
   is `StreamReader` with `feed_data` + `feed_eof` from the asyncio
   docs; rewrite if needed.

3. **Test for `_dispatch_with_incompatible_client_version_returns_error`**
   in `test_server_compat.rb` calls `list_layers` which depends on
   `Sketchup.active_model`. The version check should raise BEFORE the
   handler is reached (which is the point of the test), but if you
   see a `NameError: uninitialized constant Sketchup`, the check
   ordering is wrong — fix the order in `Dispatch.handle`.

4. **Constants swap idiom in Ruby tests** — `remove_const` raises if
   the constant doesn't exist; `const_set` warns if it already
   does. The plan's `with_range` helper handles both, but if you
   refactor it, preserve the warning-silencing pattern.

5. **`prepend` / `singleton_class` in `make_server_double`** — the
   plan uses `server.singleton_class.send(:define_method, ...)` to
   override `write_response` on a single instance. If the override
   doesn't take (because the method is private and was already
   bound), try `server.define_singleton_method(:write_response) {
   ... }` instead.

**If you notice any issues during implementation:**
1. STOP before proceeding with the problematic step.
2. Clearly describe the problem you found.
3. Explain why the plan doesn't work or seems incorrect.
4. Ask the user how to proceed.

Do NOT silently work around plan issues or make significant
deviations without user approval.

## INSTRUCTIONS WHEN USER SAYS GO

1. Invoke `/superpowers:subagent-driven-development`.
2. Dispatch one fresh subagent per task (Tasks 1–11). Task 12 (final
   verification) you may run yourself — it's mostly `pytest` + `ruby
   test/run_all.rb` + a manual live check.
3. Between tasks, review the subagent's diff before dispatching the
   next one. Keep commits atomic per task (the plan's commit message
   suggestions are in the steps).
4. At Task 12's live-verification step, **pause** and ask the user to
   perform the manual `.rbz` rebuild + SketchUp reinstall + Claude
   Code restart described in Task 12 step 12.3.
5. After all 12 tasks are green, STOP. Do NOT run `git rm` on the
   design/plan docs, do NOT push, do NOT open a PR — those are the
   branch-finish steps and they happen in yet another fresh session
   per global CLAUDE.md rule.
