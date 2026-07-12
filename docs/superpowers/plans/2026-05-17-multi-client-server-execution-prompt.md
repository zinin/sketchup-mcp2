## TASK

Execute the implementation plan for **multi-client Ruby TCP server + one-time `hello` handshake** in `/opt/github/zinin/sketchup-mcp2`.

Use `/superpowers:subagent-driven-development` skill for execution.

## DOCUMENTS

- **Design:** `docs/superpowers/specs/2026-05-17-multi-client-server-design.md`
- **Plan:** `docs/superpowers/plans/2026-05-17-multi-client-server.md`

Read both documents in full before doing anything else. The plan is large (≈2580 lines, 10 tasks + pre-flight) — load it all.

## IMPORTANT: DO NOT START WORK YET

After reading the documents:

1. Confirm you have loaded all context (mention the branch you're on and the spec/plan dates).
2. Summarize your understanding briefly (≤ 250 words): what the multi-client work changes, what the handshake protocol looks like, what's in scope vs explicitly out of scope.
3. **WAIT for explicit user instruction before taking ANY action** — including pre-flight checks (`P1`, `P2`) listed in the plan.

Do NOT begin implementation until the user explicitly says to start. Do NOT auto-run the baseline test counts. Do NOT dispatch subagents.

## SESSION CONTEXT

### Branch state

- **Current branch:** `feature/multi-client-server` (already created — do NOT branch again).
- **Forked from:** `feature/viewport-screenshot-and-prompt` at HEAD `3111ad6`.
- Parent branch bundles viewport-screenshot + version-compat-check for a 0.1.0 release (PR not yet opened to `master`).
- This branch currently has 2 commits beyond parent: the design doc (`de6de39`) and the plan doc (`4e695f8`). Both will be `git rm`'d before the eventual PR per global CLAUDE.md rule — do NOT delete them mid-execution.
- Author is the **sole user**. No external clients to worry about, no deprecation period needed.

### Decisions reached during brainstorming (rationale not always in the plan)

1. **FIFO over round-robin.** User explicitly picked global FIFO ordering of decoded frames. Pipelining starvation by one client over another within a single tick is an accepted trade-off — not a bug. Round-robin reads / per-tick frame caps are explicitly **out of scope**.

2. **Global queue over per-client inline (Approach 2 over Approach 1).** Behaviorally equivalent on the typical workload, but the explicit `@frame_queue` is preferred for code clarity, testability, and log readability. Do NOT collapse to inline processing as a "simplification".

3. **No hard cap on concurrent clients.** Rely on OS fd limits. The `0.0.0.0` security model already says "trust your network" — a cap doesn't add real protection. Do NOT introduce a cap as a "safety" addition.

4. **`IDLE_DEADLINE_S` removed entirely.** Not shortened, not raised — **gone**. Half-open sockets are detected via `SO_KEEPALIVE` only (OS default ~2h). Do NOT add an application-level idle timeout back.

5. **One-time handshake is a breaking wire-protocol change.** Per-request `client_version` and per-response `server_version` are **gone**. Backward compatibility with older Python clients (`<= 0.1.x`) is explicitly **not** maintained. The Python client and Ruby plugin must be upgraded in lockstep.

6. **Bundled in one branch:** multi-client + handshake + removal of dormant `resources/list` / `prompts/list` branches + multi-client smoke + CLAUDE.md/release.md updates. Do NOT split into multiple PRs unless explicitly asked.

7. **Logger keyword-arg extension** (`client_label:`) chosen over thread-local / positional / `Thread.current[:su_mcp_client]` magic. The plan's Task 2 has the exact implementation.

8. **Handler files do NOT get `ClientState` plumbing.** Per-handler logs (`tool=create_component status=ok …`) remain without `client=…` — surrounding `server` lines on the same client provide context. Threading state into every handler is explicitly **out of scope**.

### Rejected alternatives (do not re-propose)

- **Connect-per-call** (Python opens a new TCP connection per tool-call) — rejected for accept-tick cost, TIME_WAIT accumulation, server-push lock-in.
- **Heartbeat / proactive reconnect** — palliative; doesn't solve the underlying multi-client problem.
- **Lazy connect + explicit "busy" reject** — 80% fix; user wanted the full thing.
- **Session locks / per-entity locks / MVCC** — explicitly user-rejected. Logical races between clients are the user's organizational responsibility.
- **Round-robin reads** for "true TCP arrival order" — too complex, not enough benefit.
- **Per-tick frame processing cap** — matches today's behavior (no cap) intentionally; pipelining freeze is the same risk as today, just multiplied by client count.
- **Hard cap on clients** — see decision #3.
- **Soft cap with warning** — same.
- **Idle timeout shortened to 30 min** — user wanted full removal.
- **Welcome-message wire change** beyond `client_id` in `hello` response — not needed; client_id is sufficient and lives inside the hello reply's `result`.
- **One-time version handshake without multi-client work** — user wanted bundled; less protocol churn.

### Edge cases and warnings the plan assumes you understand

- **Between Task 5 commit and Task 6 commit: end-to-end is temporarily broken.** Ruby requires `hello`, Python doesn't send it yet. Do NOT run any live smoke (`examples/smoke_check.py` or `examples/smoke_multi_client.py`) in that window. Ruby unit tests + Python unit tests still pass independently because they don't cross-talk.

- **Task 5 Step 6 is easy to miss.** After adding the handshake gate, every test in `test_server_multi_client.rb` that was written in Task 4 needs a `HELLO` chunk prepended and assertion adjustments. The plan spells this out — follow it carefully. If you skip the update, Task 5's regression run will fail.

- **`encode_response_body` `server_version` injection is removed in Task 5, not Task 4.** Task 4 deliberately keeps the old injection so its tests end green. Don't pre-remove it in Task 4.

- **Live smoke (Task 8 Step 6) is HUMAN-only.** Do NOT attempt to spawn SketchUp or run `examples/smoke_multi_client.py` from a subagent. The plan explicitly marks this step as requiring a human operator with real SketchUp running. Mark the step as "blocked on human" and report at the controller level.

- **`test/test_server_compat.rb` is rewritten, not patched.** The old per-request version-check tests are obsolete. Task 3 Step 1 has the full replacement file content — paste it whole.

- **`tests/test_version_handshake.py` likely needs cuts in Task 6.** Tests that assert per-request `client_version` or per-response `server_version` presence are obsolete. The plan tells you to delete them; don't try to "salvage" them.

- **Baseline test counts** (Pre-flight P2): Ruby 189 runs / 428 assertions, Python 119 tests. If your starting numbers differ, **stop and reconcile** before proceeding — the plan's expected counts at each task end assume this baseline.

- **Each task ends with a commit.** Follow the commit messages in the plan verbatim where given — they document the rationale for the change at that step. Don't squash multiple tasks into one commit.

- **CLAUDE.md global rule:** when execution is fully complete and all tests pass, the design + plan + execution-prompt docs in `docs/superpowers/` will be `git rm`'d in a separate cleanup commit before the PR is opened. That cleanup is **not** part of this plan — it happens later via `superpowers:finishing-a-development-branch`. Do NOT delete the docs as part of any task in this plan.

### Project-specific gotchas (already in CLAUDE.md but worth a reminder)

- SketchUp is single-threaded; all I/O lives inside `UI.start_timer` callbacks. Do NOT introduce threads.
- The wire framing is 4-byte big-endian length prefix + JSON body. The plan does NOT change this — only the JSON-RPC method set.
- Ruby tests are `minitest/autorun` stdlib only. No rspec, no fixtures library, no gems beyond stdlib.
- Python tests are pytest + `pytest-asyncio` (already in dev dependencies).
- The build command is `cd su_mcp && ruby package.rb && cd ..` for the `.rbz`. Used in Task 10 as a sanity check that all `require_relative`s resolve.

## PLAN QUALITY WARNING

The plan was written for a substantive refactor and may contain:
- Inaccuracies in line numbers or exact text for `Edit` operations against the current code (especially `core/compat.rb` error message wording — the plan says "grep for 'request' and rephrase" because exact text wasn't captured during planning).
- Test code samples that assume specific stub/fixture patterns (`tests/conftest.py`) that may need light adaptation if the existing pattern differs.
- Assumed test counts may drift by 1–2 if Ruby/Python tests were added on this branch between planning and execution.
- Order-of-removal in `dispatch.rb` (Task 3) — the plan replaces the whole `self.handle` method; if any currently-existing helper method in that file has been refactored independently, reconcile before pasting.

**If you notice any issues during implementation:**
1. STOP before proceeding with the problematic step.
2. Clearly describe what doesn't match (file content, test expectation, signature drift, …).
3. Explain why the plan instruction doesn't apply as written.
4. Ask the user how to proceed.

Do NOT silently work around plan issues. Do NOT make significant deviations from the design (handshake protocol, FIFO semantics, no-cap, no-idle-deadline) without explicit user approval — those are decisions reached during brainstorming and have rationale that lives in the session context above, not in the docs.
