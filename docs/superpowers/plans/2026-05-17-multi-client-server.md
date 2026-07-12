# Multi-client Ruby Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single-`@client` slot in `su_mcp/su_mcp/core/server.rb` with a multi-client server (N concurrent TCP connections, global FIFO frame queue, single-threaded dispatch on the SketchUp UI thread). Simultaneously simplify the version-check protocol to a one-time `hello` handshake performed on connect (per-request `client_version` / per-response `server_version` removed).

**Architecture:** `Server` maintains `@clients = {sock => ClientState}` and a global `@frame_queue = [[ClientState, body], …]`. Each `UI.start_timer` tick: (1) drain TCP backlog into new `ClientState` entries, (2) read pending bytes from every client via per-client `FrameReader`, push decoded frames to `@frame_queue`, (3) dispatch queued frames FIFO. The first frame from any client MUST be JSON-RPC method `hello` carrying `client_version`; server responds with `server_version` and assigned `client_id`. After handshake, regular `tools/call` requests carry no version fields. Per-client errors (parse / write timeout / handshake violation / framing) close only that client; the queue, other clients, and the server itself keep running.

**Tech Stack:**
- Ruby 2.7+ (SketchUp 2026 extension; stdlib `socket`, `json`, `minitest`; no gem dependencies)
- Python 3.13 (FastMCP, asyncio, pytest)
- No new gems / no new pip dependencies

---

## File Structure

**Created:**
- `su_mcp/su_mcp/core/client_state.rb` — per-connection state class
- `test/test_client_state.rb` — unit tests for ClientState
- `test/test_logger.rb` — unit tests for Logger keyword arg
- `test/support/fake_socket.rb` — shared FakeSocket helper for server tests
- `test/support/frame_helpers.rb` — shared frame helpers (Addendum C)
- `test/test_server_multi_client.rb` — multi-client server tests (uses FakeSocket)
- `test/test_server_handshake.rb` — handshake-flow tests (uses FakeSocket)
- `examples/smoke_multi_client.py` — live multi-client smoke (manual, runs against running SketchUp)

**Modified:**
- `su_mcp/su_mcp/main.rb` — `require_relative` the new `client_state.rb`
- `su_mcp/su_mcp/core/server.rb` — major rewrite (single → multi-client, handshake gate, SO_KEEPALIVE, IDLE removed)
- `su_mcp/su_mcp/core/logger.rb` — add optional `client_label:` keyword to `log_tool`/`log_error`
- `su_mcp/su_mcp/handlers/dispatch.rb` — remove per-request version check, remove `get_version` bypass, remove dormant `resources/list` / `prompts/list` branches
- `su_mcp/su_mcp/core/compat.rb` — adjust error wording (no more "every request carries client_version")
- `src/sketchup_mcp/connection.py` — add `_handshake()` in `connect()`, drop `client_version` from per-request envelope, drop per-response `server_version` check
- `src/sketchup_mcp/compat.py` — adjust error wording
- `src/sketchup_mcp/tools.py` — drop "bypass" phrasing from `get_version` docstring (Addendum H)
- `test/test_server_compat.rb` → **renamed** to `test/test_dispatch_post_handshake.rb` and rewritten (drop version-check cases; assert post-handshake dispatch semantics)
- `tests/test_connection.py` — rewrite for handshake roundtrip, drop `client_version` assertions
- `tests/test_version_handshake.py` — rewrite for one-time handshake semantics
- `tests/test_version_tool.py` — minor cleanup (get_version tool stays, but no longer "bypass diagnostic")
- `CLAUDE.md` — multi-client section, updated version handshake paragraph, removed `IDLE_DEADLINE_S` / restart-plugin / `prompts/list` mentions
- `docs/release.md` — breaking-change note for the next release

**Deleted:** none.

---

## Pre-flight

✅ Done — branch `feature/multi-client-server` confirmed; baseline Ruby 189/428/0/0, Python 119 passed.

---

## Task 1: `ClientState` class

✅ Done — see commit `c6a318f` ("feat(ruby): add ClientState per-connection state struct"). Includes Addendum A (`close_after_response` accessor + corresponding test). Tests: 196/441/0.

---

## Task 2: `Logger` keyword-arg extension

✅ Done — see commit `86f4cb8` ("feat(ruby): add client_label: keyword to Logger.log_tool/log_error"). Tests: 202/453/0.

---

## Task 3: Simplify `Dispatch` — drop per-request version check, `get_version` bypass, dormant branches

✅ Done — see commit `5875a3e` ("refactor(ruby): drop per-request version check and dormant branches from Dispatch"). Renamed `test/test_server_compat.rb` → `test/test_dispatch_post_handshake.rb` (11 tests). Tests: 205/447/0.

> Coverage note: 3 deleted tests for `Server#encode_response_body server_version` injection are not separately backfilled — that injection itself was removed in Task 5, so the deleted coverage targeted a behavior that no longer exists.

---

## Task 4: Multi-client `Server` rewrite (without handshake gate yet)

✅ Done — see commit `b9e3b13` ("feat(ruby): multi-client TCP server with per-client error isolation"). Incorporates Addenda B (`ACCEPT_ABORTED_MAX` + `setsockopt` rescue), C (`FrameHelpers` module), D (save/restore `io_select_writable?`), E (additional tests: framing-envelope-before-close, partial-frame-EOF, multi-tick frame split), I (FIFO comment). Tests: 220/481/0.

> Implementer fix note: the plan's `raise IO::WaitReadable` snippet was wrong — `IO::WaitReadable` is a module, not a class. `FakeSocket#read_nonblock` and `FakeServer#accept_nonblock` use `Errno::EAGAIN.new(...).extend(IO::WaitReadable)` to match the real socket API contract.

> Open minor (deferred): `drain_one_client` lacks a final `rescue StandardError` arm. Any unexpected exception bubbles to `on_timer_tick`'s catch-all (logs but does not close the misbehaving client). Per-client isolation goal is mostly intact but not exhaustive. Add a bottom-level `rescue StandardError => e` arm + `close_client(state, "drain_error: ...")` if observed in the wild.

---

## Task 5: Handshake gate in `Server`

✅ Done — see commit `e2798a4` ("feat(ruby): one-time hello handshake gate in Server"). Incorporates Addendum F (positive `server_version`-in-handshake-reply assertion + EPIPE-during-rejection test). `test_server_multi_client.rb` retrofitted to prepend hello frames; `disconnect_mid_queue` wrap fires only on first post-handshake response (`response["id"] != 0`). `encode_response_body` no longer injects `server_version` (handshake covered it). Tests: 230/516/0.

> Open minor (deferred): `close_after_response` is checked AFTER `io_select_writable?` returns nil — if write probe times out on a rejection response, the close-reason logged is `"write_timeout"` rather than `"handshake_rejected"`. Functionally equivalent (client still closed), only log line is misleading.

---

## Task 6: Python — `_handshake()` on connect; drop per-request `client_version`

✅ Done — see commit `3b510c0` ("feat(python): one-time hello handshake on connect"). Incorporates Addenda G (`FakeServerMulti`, stale-socket-retry test, handshake-timeout test, bounded-busy-loop sync) and H (`tools.py` docstring no longer says "bypass" / "only diagnostic"). `connect()` wraps `_handshake()` in `asyncio.wait_for(..., timeout=self.timeout)`. All malformed-envelope paths normalized into `SketchUpError`. Python: 120 passed (baseline 119 + 8 new − 7 deleted from `test_version_handshake.py`).

> Open minor (deferred): `_handshake()` does not normalize `asyncio.IncompleteReadError` (peer closes TCP without writing hello reply) — would bubble as raw EOFError. In practice Ruby's `handle_pre_handshake` always writes a response, so this edge is unreachable on the protocol side, but a `try / except asyncio.IncompleteReadError → SketchUpError(-32000, "peer closed before handshake reply")` would round out the normalization.

> Open minor (deferred): `tests/test_version_handshake.py` now contains exactly one test (`_RETRY_SAFE_TOOLS` membership). Could fold into `tests/test_connection.py` and delete the file, or rename to `test_retry_safe_tools.py`. Cosmetic.

---

## Task 7: `SO_KEEPALIVE` on accepted sockets

✅ Done — subsumed by Task 4 (commit `b9e3b13`). `setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true)` is set on every accepted socket inside `accept_pending_clients`, wrapped in `begin/rescue StandardError` per Addendum B (registered-or-closed invariant). The `test_so_keepalive_enabled_on_accepted_clients` test is in `test/test_server_multi_client.rb`.

---

## Task 8: Multi-client live smoke test

✅ Done — see commits `4d5842b` ("test(python): live multi-client smoke (manual)") + `cad5550` ("fix(smoke): simplify HEAVY_WORKLOAD id-capture per code review").

`examples/smoke_multi_client.py` spawns N concurrent subprocess workers, each opening its own `SketchUpConnection`. LIGHT_WORKLOAD (worker 0) = `get_version` + `get_model_info`×8 + `list_components`×5 (read-only). HEAVY_WORKLOAD (workers 1..N-1) = create×2 → get_model_info → delete×2 (captures `id` from create responses into a plain Python list, no `$ref`/`capture` indirection). LIGHT uses a `for step in WORKLOAD` loop template; HEAVY uses a separate imperative template. Script syntax verified via `ast.parse`. Live smoke run is human-only (requires SketchUp 2026 + rebuilt `.rbz`).

> Deviation note: the plan's literal HEAVY_WORKLOAD used `{"name": "smoke_box_heavy_A"}` for both `create_component` and `delete_component`. Real signatures: `create_component(type, position, dimensions)` (no `name`); `delete_component(id: str)` (requires entity id, not name). Implementer captured the id from the create response and threaded it through to delete.

> Open minor (deferred): HEAVY orphans created boxes if the second create raises (the for-loop over `ids` never reaches the deletes). Acceptable for a manual one-shot — `undo` clears it.

---

## Task 9: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Locate and edit the "Non-Obvious Constraints" section**

In `CLAUDE.md`, find the bullet that begins **"Ruby accepts a single TCP client at a time"** (it spans several lines, mentions `IDLE_DEADLINE_S = 300.0`, and explains the smoke-check workaround).

Replace it with:

```markdown
- **Ruby supports N concurrent TCP clients**: `core/server.rb` keeps
  `@clients` (sock → ClientState) and a global FIFO `@frame_queue`.
  Each timer tick: accept pending connections, drain reads from every
  client into per-client `FrameReader`, dispatch queued frames in
  arrival order. Operations are still serialised on the SketchUp UI
  thread (single-threaded Ruby API). Per-client errors close only the
  offending client; other clients keep running. **Logical races between
  clients on the model are the user's responsibility** — the server
  does no locking. Half-open sockets are detected via `SO_KEEPALIVE`
  (OS default ~2h).
```

- [ ] **Step 2: Rewrite the "Version handshake" paragraph**

In `CLAUDE.md`, find the long paragraph beginning **"Version handshake:
every JSON-RPC request carries `client_version`…"** in the Non-Obvious
Constraints section.

Replace it with:

```markdown
- **Version handshake (one-time on connect)**: every TCP connection MUST
  begin with a JSON-RPC `hello` request carrying
  `params.client_version`. The server validates against
  `core/compat.rb`'s `MIN_PYTHON`..`MAX_PYTHON` range and replies with
  `{server_version, client_id}` in `result`. Mismatches return JSON-RPC
  error `-32001` (`IncompatibleVersionError` on the Python side) and
  the server closes the socket. After a successful handshake, regular
  `tools/call` requests carry no `client_version` field and responses
  carry no `server_version` field. Compatibility ranges live in
  `src/sketchup_mcp/compat.py` and `su_mcp/su_mcp/core/compat.rb`.
  `get_version` remains a regular tool returning the verdict payload.
```

- [ ] **Step 3: Remove the dormant `prompts/list` note**

In the **"MCP Prompts"** section near the bottom of `CLAUDE.md`, find
the `> Note:` block that mentions the dormant `prompts/list → []`
branch in `dispatch.rb`. Delete the entire note block — the branch is
gone.

- [ ] **Step 4: Sanity-check no stale `IDLE_DEADLINE_S` references remain**

```bash
grep -nF "IDLE_DEADLINE_S" CLAUDE.md
# Expected: no matches
```

If a match remains, delete the line. Same for `accept_one_client` (no
longer exists):

```bash
grep -nE "accept_one_client|single.*@client|first client wins" CLAUDE.md
# Expected: no matches
```

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for multi-client server and one-time handshake

- Replace 'single TCP client' constraint with the multi-client variant.
- Rewrite Version handshake paragraph for one-time on-connect semantics.
- Drop the dormant prompts/list note (branch removed).
- Drop stale IDLE_DEADLINE_S / accept_one_client mentions."
```

---

## Task 10: Release notes and final verification

**Files:**
- Modify: `docs/release.md` (append breaking-change note)
- Verify: full Ruby + Python suites, smoke (manual)

- [ ] **Step 1: Append release note**

Open `docs/release.md`. Find the appropriate location (top of the file
if it follows reverse-chronological order; otherwise the "Unreleased"
section). Add:

```markdown
## Breaking changes (next release)

- **Wire protocol: one-time handshake on connect.** Every TCP connection
  must now begin with a JSON-RPC `hello` request carrying
  `params.client_version`; the server replies with `server_version` and
  `client_id`. Per-request `client_version` / per-response
  `server_version` envelopes are **removed**. Old Python clients
  (`sketchup-mcp2 <= 0.1.x`) fail the handshake against this server and
  must be upgraded in lockstep with the `.rbz`.
- **Multi-client support.** The Ruby plugin now accepts N concurrent TCP
  clients; the previous "first client wins, rest time out" behavior is
  gone. The `restart plugin between smoke checks` workaround is no
  longer necessary.
```

If `docs/release.md` doesn't have any "next release" section yet, place
the note at the top of the file under a new heading.

- [ ] **Step 2: Full Ruby test suite**

```bash
ruby test/run_all.rb 2>&1 | tail -3
# Expected: 0 failures, 0 errors. Current count after Tasks 1-8: 230 runs / 516 assertions.
```

- [ ] **Step 3: Full Python test suite**

```bash
uv run pytest tests/ -q 2>&1 | tail -3
# Expected: 0 failures. Current count after Task 6: 120 passed.
```

- [ ] **Step 4: Quick syntax / load check for the smoke script**

```bash
uv run python -c "import ast, pathlib; ast.parse(pathlib.Path('examples/smoke_multi_client.py').read_text())"
# Expected: clean
```

- [ ] **Step 5: Build the `.rbz` (sanity check that the Ruby reorg loads)**

```bash
cd su_mcp && ruby package.rb && cd ..
# Expected: prints the path to the .rbz; exit 0.
```

- [ ] **Step 6: Manual live smoke (HUMAN ACTION REQUIRED)**

This step is **for the human operator** — it requires a real SketchUp
2026 instance with the rebuilt `.rbz` installed and the MCP server
started. Capture the result.

1. Install the freshly-built `.rbz` (Window → Extension Manager →
   Install) and restart SketchUp.
2. Plugins → MCP Server → Start.
3. From a shell:
   ```bash
   uv run python examples/smoke_check.py
   ```
   Expected: 22 steps green.
4. Then:
   ```bash
   uv run python examples/smoke_multi_client.py --n 2
   ```
   Expected: both workers complete successfully; no `IncompatibleVersionError`,
   no `ConnectionError`, no starvation timeout.

If either fails, **do not commit the release note** — investigate and
fix first.

- [ ] **Step 7: Commit release note**

(Only after step 6 is green.)

```bash
git add docs/release.md
git commit -m "docs: release notes for multi-client + one-time-handshake breaking change"
```

- [ ] **Step 8: Final git log review**

```bash
git log --oneline feature/viewport-screenshot-and-prompt..HEAD
# Expected: ~ 10 commits, one per task, with the design + plan docs at
# the top. (Design + plan will be removed in the PR-finishing step,
# per global CLAUDE.md rule — but that is a separate step done with
# the superpowers:finishing-a-development-branch skill, not part of
# this plan.)
```

---

## Review Iteration 1 — Applied Auto-Fixes

✅ Done — all addenda (A–J) were applied during Tasks 1-6 execution; see commits `9bbd958` ("docs: review iter 1 — auto-fixes") and `890667b` ("docs: review iter 1 — decisions + log") for the original deltas.

- Addendum A: `close_after_response` accessor on `ClientState` — Task 1
- Addendum B: `ACCEPT_ABORTED_MAX` + setsockopt rescue + setsockopt-leak test — Task 4
- Addendum C: `test/support/frame_helpers.rb` (`include FrameHelpers`) — Task 4
- Addendum D: save/restore `io_select_writable?` in test setup/teardown — Tasks 4 & 5
- Addendum E: framing-envelope-before-close / partial-frame-EOF / multi-tick frame split tests — Task 4
- Addendum F: positive `server_version`-in-handshake-reply + handshake-rejection-with-EPIPE — Task 5
- Addendum G: Python `FakeServerMulti`, stale-socket-retry, handshake-timeout, bounded-loop sync, `"some_tool"` rename — Task 6
- Addendum H: `tools.py` `get_version` docstring no longer mentions "bypass" — Task 6
- Addendum I: FIFO comment above `drain_reads_all_clients` — Task 4
- Addendum J: test-count baseline adjustments — applied implicitly during execution; actual final Ruby 230/516, Python 120

---

## Self-Review Notes

Coverage check against design sections:

- §4 (high-level structure): Tasks 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 collectively touch every file listed. ✓
- §5.1 (ClientState): Task 1. ✓
- §5.2 (Server fields): Task 4. ✓
- §5.3 (tick algorithm — accept, drain, queue, process): Task 4. ✓
- §5.4 (close_client): Task 4. ✓
- §6 (handshake protocol): Task 5 (Ruby) + Task 6 (Python). ✓
- §7 (error isolation table): Task 4 + Task 5. ✓
- §8 (logging): Task 2 (Logger API) + Tasks 4, 5 (call sites). ✓
- §9 (configuration): Task 4 (drop IDLE) + Task 7 (SO_KEEPALIVE). ✓
- §10 (testing): Tasks 1, 2, 3, 4, 5, 6, 8 — every test scenario in
  the spec has a corresponding task step. ✓
- §11 (docs): Task 9 (CLAUDE.md) + Task 10 (release.md). ✓
- §13 (risks): no code, no task — risks are documented in the spec,
  not implemented. Plan covers all mitigations that were in scope. ✓

Placeholder scan: no TBD / TODO / "appropriate" / "similar to" left in
the plan body. Every step has concrete code or commands.

Type-consistency check: function and constant names used across tasks
match (`ClientState.handshaked`, `Server#close_client`, `_handshake`,
`HELLO` test helper, `FakeSocket` / `FakeServer` helpers, etc.).
