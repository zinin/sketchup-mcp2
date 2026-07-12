## TASK

Continue executing the implementation plan for **multi-client Ruby TCP server + one-time `hello` handshake** in `/opt/github/zinin/sketchup-mcp2`.

Two tasks remain: **Task 9** (update `CLAUDE.md`) and **Task 10** (release notes + final verification). The first 8 tasks are already committed on branch `feature/multi-client-server`.

Use `/superpowers:subagent-driven-development` for execution (or `/do-plan` to resume autonomous mode with the configured 250 k-token STOP threshold).

## CRITICAL: DO NOT START WORKING

**STOP. READ THIS CAREFULLY.**

After loading all context below, you MUST:
1. Read the documents and understand the context
2. Report what you understood (brief summary, ≤ 250 words)
3. **WAIT for explicit user instructions** before taking ANY action

**DO NOT:**
- Start implementing tasks
- Run pre-flight checks (P1, P2)
- Auto-run baseline test counts
- Dispatch subagents
- Make any code changes
- Assume what task to work on next

**The user will tell you exactly what to do.** Until then, only read and summarize.

## DOCUMENTS

- **Design:** `docs/superpowers/specs/2026-05-17-multi-client-server-design.md`
- **Plan:** `docs/superpowers/plans/2026-05-17-multi-client-server.md` (trimmed — completed tasks reduced to one-line stubs)
- **Review iter-1 log:** `docs/superpowers/specs/2026-05-17-multi-client-server-review-iter-1.md`

Read the design (it stays unchanged through execution) and the plan (Tasks 9 + 10 are full; everything else points at commits).

## PROGRESS

**Completed (8 of 10 tasks; all reviewed via spec + code-quality subagents):**

- [x] Pre-flight P1/P2 — branch confirmed, baseline Ruby 189/428/0/0, Python 119 passed
- [x] Task 1: ClientState class — commit `c6a318f` — Ruby 196/441
- [x] Task 2: Logger `client_label:` keyword — commit `86f4cb8` — Ruby 202/453
- [x] Task 3: Simplify Dispatch + rename test_server_compat→test_dispatch_post_handshake — commit `5875a3e` — Ruby 205/447
- [x] Task 4: Multi-client Server rewrite + addenda B/C/D/E/I — commit `b9e3b13` — Ruby 220/481
- [x] Task 5: Handshake gate in Server + addendum F — commit `e2798a4` — Ruby 230/516
- [x] Task 6: Python `_handshake()` + addenda G/H — commit `3b510c0` — Python 120 passed
- [x] Task 7: SO_KEEPALIVE — subsumed by Task 4 (already inside `b9e3b13`)
- [x] Task 8: `examples/smoke_multi_client.py` — commits `4d5842b` + `cad5550` — ast.parse clean

**Latest current state (must hold before Task 9):**
- Ruby: 230 runs / 516 assertions / 0 failures / 0 errors
- Python: 120 passed
- Branch: `feature/multi-client-server`; commits ahead of `feature/viewport-screenshot-and-prompt` (parent): 13 (4 docs/design/plan/iter1 + 1 plan-trim + 8 task commits)

**Remaining:**
- [ ] **Task 9: Update `CLAUDE.md`** — replace "single TCP client" bullet with multi-client variant; rewrite Version-handshake paragraph for one-time semantics; remove dormant `prompts/list` note; sanity-grep for stale `IDLE_DEADLINE_S` / `accept_one_client` / "single @client" mentions
- [ ] **Task 10: Release notes + final verification** — append breaking-change note to `docs/release.md`; run full Ruby + Python suites; verify `ast.parse` of smoke; build `.rbz` via `cd su_mcp && ruby package.rb && cd ..`; live smoke is **human-only** (requires real SketchUp 2026 + rebuilt `.rbz`); final git log review

## SESSION CONTEXT (knowledge from the prior execution session)

### Hook anomaly worth flagging

`/do-plan` was invoked with STOP threshold = 250 000 tokens. The `PostToolUse` hook `check-context-size.sh` injected exactly ONE milestone (`ctx:150k`, early in Task 1) and ZERO subsequent milestones or STOP signals during all 8 tasks — despite the context size clearly exceeding 250 k by mid-session. The config file `~/.claude/state/do-plan-config--opt-github-zinin-sketchup-mcp2.json` was written correctly with `{"stop_threshold": 250000}`. The user manually paused after Task 8 via `/pause-after-current-task` because the hook never fired. Worth checking the hook's settings / activation path before restarting `/do-plan` with autonomous threshold — or just accept manual pacing.

### Open deferred minors (non-blocking, captured in plan stubs)

The two-stage reviews (spec + code-quality) approved every task as "Ready to merge: Yes" with the following minor follow-ups that were intentionally deferred to keep scope tight:

1. **Task 4 — `drain_one_client` lacks final `rescue StandardError` arm.** Any non-anticipated exception bubbles to `on_timer_tick`'s catch-all (logs but does not close the misbehaving client). Per-client isolation goal mostly intact. Cheap to add a bottom-level rescue arm if you want defense-in-depth.

2. **Task 5 — `close_after_response` checked AFTER `io_select_writable?`.** If write probe times out on a rejection envelope, the close-reason logged is `"write_timeout"` rather than `"handshake_rejected"`. Functionally identical (client still closed), only log line is misleading.

3. **Task 6 — `_handshake()` does not normalize `asyncio.IncompleteReadError`.** Edge case: peer accepts TCP then closes without writing hello reply. Ruby's `handle_pre_handshake` always writes a response in practice, so unreachable on the protocol side. A one-line `try / except` would round out the malformed-envelope normalization invariant.

4. **Task 6 — `tests/test_version_handshake.py` is now a one-test stub.** Only `_RETRY_SAFE_TOOLS` membership remains after 7 obsolete tests were deleted. Could be folded into `tests/test_connection.py`, or the file renamed to `test_retry_safe_tools.py`. Purely cosmetic.

5. **Task 8 — HEAVY orphan boxes on partial failure.** If the second `create_component` raises, the for-loop over `ids` never reaches the deletes. Acceptable for a manual one-shot smoke (operator can `Edit → Undo`).

These are all "Nice to Have" per the reviewers — none required for correctness.

### Task 9 specifics worth knowing

`CLAUDE.md` currently contains the long "Ruby accepts a single TCP client at a time…" sentence in Non-Obvious Constraints, the `IDLE_DEADLINE_S = 300.0` mention, the `restart-plugin` workaround for smoke checks, the per-request "Version handshake" paragraph, AND the dormant-`prompts/list` `> Note:` block near the MCP Prompts section. All four must be touched; the plan body for Task 9 contains exact replacement text.

### Task 10 specifics

- Plan estimates "~212 runs" but real count is **230 runs / 516 assertions** post-Task-5 (the plan estimate predates several Addendum-driven new tests). Plan estimates "~110-115 Python passed", actual is **120 passed**. Don't be alarmed if final numbers don't match the plan's ballpark.
- `cd su_mcp && ruby package.rb && cd ..` must succeed (sanity check that the new `core/client_state.rb` and rewritten `core/server.rb` load cleanly together).
- **Live smoke is HUMAN-only.** Do NOT spawn SketchUp or run `examples/smoke_check.py` / `examples/smoke_multi_client.py` from a subagent. Mark as blocked-on-human and report at controller level.

### Branch finishing (separate from this plan)

The plan explicitly OUT-OF-SCOPES the `superpowers:finishing-a-development-branch` step that opens the PR and `git rm`'s `docs/superpowers/`. Do not run that as part of Task 10 — it's a separate ceremony the user will invoke directly when ready to merge.

### Untracked files to ignore

The working tree has many pre-existing untracked files in `docs/session-transfer-*` and `docs/superpowers/plans/*-continuation-prompt.md` from prior sessions. These are not part of this plan's scope; do not stage them.

## PLAN QUALITY WARNING

The plan was externally reviewed (codex/gpt-5.5 xhigh, ccs-glm, ollama-minimax, ollama-deepseek) before code was written, and 38 deduplicated issues were classified into auto-fixed / auto-applied / discussed / dismissed. All critical fixes from iter-1 have been applied during Tasks 1-6.

Remaining Tasks 9-10 are docs/verification only — low risk of drift. But:

- Some grep / sed commands in the plan may need adjustment if the corresponding `CLAUDE.md` sections have moved since the plan was authored. Read `CLAUDE.md` directly to confirm anchor text exists.
- Test count estimates in Task 10 are stale (see above).

**If you notice any issue during implementation:**
1. STOP before proceeding with the problematic step
2. Clearly describe what doesn't match
3. Explain why the plan instruction doesn't apply as written
4. Ask the user how to proceed

Do NOT silently work around plan issues.

## INSTRUCTIONS

1. Read both documents listed in DOCUMENTS section
2. Optionally skim the iter-1 review log for context on why specific addenda exist
3. Provide a brief summary (≤ 250 words) of what you understood
4. **STOP and WAIT** — do NOT proceed with any implementation, including pre-flight
5. Ask: "What would you like me to work on?"
