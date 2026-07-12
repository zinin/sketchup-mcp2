## TASK

Wrap up the **multi-client Ruby TCP server + one-time `hello` handshake** branch (`feature/multi-client-server`) in `/opt/github/zinin/sketchup-mcp2`.

All 10 plan tasks are complete and an external multi-reviewer code-review pass has landed its fixes. Only two ceremony steps remain — both gated on the human operator:

1. **Live smoke** (HUMAN-only — requires SketchUp 2026 running with a freshly-built `.rbz`).
2. **`superpowers:finishing-a-development-branch`** to prepare the PR (will need to `git rm` the design / plan / iter docs before the merge commit, per the global CLAUDE.md rule).

## CRITICAL: DO NOT START WORKING

**STOP. READ THIS CAREFULLY.**

After loading all context below, you MUST:
1. Read the documents and understand the context
2. Report what you understood (brief summary, ≤ 250 words)
3. **WAIT for explicit user instructions** before taking ANY action

**DO NOT:**
- Spawn SketchUp or run `examples/smoke_check.py` / `examples/smoke_multi_client.py`
- Invoke `superpowers:finishing-a-development-branch` autonomously
- Make any code changes
- Run any commands (except reading documents and read-only git inspection)

**The user will tell you exactly what to do.** Until then, only read and summarize.

## DOCUMENTS

- **Design:** `docs/superpowers/specs/2026-05-17-multi-client-server-design.md`
- **Plan:** `docs/superpowers/plans/2026-05-17-multi-client-server.md` (all tasks ✅ Done — pointers to commits)
- **Review iter-1 log (pre-execution):** `docs/superpowers/specs/2026-05-17-multi-client-server-review-iter-1.md`

Read the design + plan to ground yourself.

## PROGRESS

**Plan tasks (all complete):**

- [x] P1/P2 pre-flight — baseline Ruby 189/428, Python 119
- [x] Task 1: ClientState class — commit `c6a318f`
- [x] Task 2: Logger `client_label:` keyword — commit `86f4cb8`
- [x] Task 3: Simplified Dispatch (dropped per-request version check + dormant branches) — commit `5875a3e`
- [x] Task 4: Multi-client Server rewrite + addenda B/C/D/E/I — commit `b9e3b13`
- [x] Task 5: Handshake gate in Server + addendum F — commit `e2798a4`
- [x] Task 6: Python `_handshake()` + addenda G/H — commit `3b510c0`
- [x] Task 7: `SO_KEEPALIVE` — subsumed by Task 4
- [x] Task 8: `examples/smoke_multi_client.py` — commits `4d5842b` + `cad5550`
- [x] Task 9: CLAUDE.md updates — commit `503ab21`
- [x] Task 10: release notes + verification — commit `f761345` (+ accuracy fix `7c96d99`)

**Post-plan fix-ups:**

- [x] CLAUDE.md test-counts refresh — commit `100568f`

**External code-review pass (multi-reviewer, this is what just landed):**

- [x] AUTO cosmetic / wording fixes — commit `11b5bbf` (server.rb snapshot comment, CLAUDE.md "arrival order" wording, stale test comments in test_dispatch_post_handshake / test_connection.py, scope `is_notification` to pre-handshake, smoke_multi_client precondition rewrite)
- [x] Defense-in-depth: D4 `rescue StandardError` in `drain_one_client`, D5 normalize `asyncio.IncompleteReadError` in `_handshake`, D7 explicit `server_version is None` check — commit `d7d8649`
- [x] **D3 non-blocking writes**: per-client `pending_write_bytes` buffer, `flush_pending_writes_all_clients` phase at top of timer tick, `write_nonblock` loop, `WRITE_DEADLINE_S=5.0` cumulative, `PENDING_WRITE_MAX_BYTES=16 MiB` cap with `pending_write_overflow` close reason. New tests for partial-write resumption, write deadline, EPIPE isolation, overflow cap — commit `67cf683`

**External review — DISPUTED items resolved by user decision (no commit needed):**

- D1 (`MAX_DISPATCH_PER_TICK`) — leave per design §3 non-goal
- D2 (`MAX_CLIENTS`) — leave per design §3 non-goal
- D6 (validate `jsonrpc=="2.0"` / `id==0` in Python handshake) — leave per user decision (server is our own code; YAGNI)

**External review — DISMISSED as false-positive:**

- D8 (`settings_dialog.rb` size change 360×290 → 380×360) — origin commit `3111ad66`, parent branch `feature/viewport-screenshot-and-prompt`, **not** in our diff range. Reviewers misread the range.

**Remaining (HUMAN-only / user-invoked):**

- [ ] **Live smoke** — rebuild `.rbz` (since `67cf683` changed server.rb), install in SketchUp 2026, start plugin, run `examples/smoke_check.py` (22-step end-to-end) then `examples/smoke_multi_client.py --n 2` (multi-client load test). Both must be green.
- [ ] **Branch finishing** — invoke `superpowers:finishing-a-development-branch`. Per the global CLAUDE.md rule, `git rm` all four `docs/superpowers/` artifacts before the merge commit:
  - `docs/superpowers/specs/2026-05-17-multi-client-server-design.md`
  - `docs/superpowers/specs/2026-05-17-multi-client-server-review-iter-1.md`
  - `docs/superpowers/plans/2026-05-17-multi-client-server.md`
  - **And this file** (continuation prompt itself)
  Plus other untracked plan/continuation/session-transfer scaffolding listed in `git status -s ?? docs/`.

## SESSION CONTEXT

### Final test baseline

- **Ruby: 242 runs / 553 assertions / 0 failures / 0 errors** (was 230/516 before D3 fix)
- **Python: 120 passed**
- `.rbz` build was last produced at `su_mcp/su_mcp_v0.0.3.rbz` from commit `f761345` — **stale.** Rebuild via `cd su_mcp && ruby package.rb && cd ..` before live smoke (the new server.rb has the non-blocking-write rewrite that the existing `.rbz` doesn't carry).

### Branch state

```
67cf683 feat(ruby): non-blocking writes with per-client buffer + write deadline
d7d8649 review: apply defense-in-depth fixes from external review
11b5bbf review: auto-fix valid issues from external review
100568f docs: refresh stale test counts in CLAUDE.md
7c96d99 docs(release): correct accuracy issues per code review
f761345 docs: release notes for multi-client + one-time-handshake breaking change
503ab21 docs: update CLAUDE.md for multi-client server and one-time handshake
4b2278e docs: trim completed tasks from plan for multi-client server
cad5550 fix(smoke): simplify HEAVY_WORKLOAD id-capture per code review
4d5842b test(python): live multi-client smoke (manual)
3b510c0 feat(python): one-time hello handshake on connect
e2798a4 feat(ruby): one-time hello handshake gate in Server
b9e3b13 feat(ruby): multi-client TCP server with per-client error isolation
5875a3e refactor(ruby): drop per-request version check and dormant branches from Dispatch
86f4cb8 feat(ruby): add client_label: keyword to Logger.log_tool/log_error
c6a318f feat(ruby): add ClientState per-connection state struct
890667b docs: review iter 1 — decisions + log (multi-client-server)
9bbd958 docs: review iter 1 — auto-fixes (multi-client-server)
4e695f8 plan: multi-client Ruby server + one-time handshake implementation
de6de39 design: multi-client Ruby TCP server + one-time version handshake
```

20 commits ahead of `feature/viewport-screenshot-and-prompt`. After `git rm` of design/plan/iter docs and a finishing commit, the squash-or-merge-into-master decision is the user's.

### Reviewer pass details (for context only — closed)

External code review used 6 reviewers in parallel via a `code-review` team:
- **claude-reviewer** (general-purpose + superpowers:requesting-code-review)
- **codex-reviewer** (OpenAI Codex CLI)
- **ccs-glm-reviewer** (CCS, PROFILE=glm)
- **ollama-deepseek-reviewer** (DeepSeek-V4 Pro)
- **ollama-kimi-reviewer** — **FAILED** to synthesize (raw event stream only, no report.md)
- **ollama-minimax-reviewer** — **FAILED** to synthesize (raw event stream only, no report.md)

If you want to re-run just those two in a fresh session, their prompts are saved at `/home/zinin/.claude/ollama-interaction/2026-05-17-17-26-00-*-ollama-kimi/prompt.md` and `.../2026-05-17-17-26-08-*-ollama-minimax/prompt.md`.

The four working reviewers produced 24 deduplicated findings: 0 Critical, 9 Important, 15 Minor. Of those, 10 were applied (6 AUTO cosmetic + 3 defense-in-depth + 1 large D3), 3 were left per user/design decision (D1/D2/D6), 1 was dismissed as false positive (D8), and 10 were dismissed as design-accepted trade-offs / release-time work / pure taste.

### Team residue

`~/.claude/teams/code-review/` and `~/.claude/tasks/code-review/` still exist (harmless residue — the `TeamDelete` call returned "no team context" because shutdown_requests had already cleared the inbox routing). Clean up via `rm -rf` if it bothers you; otherwise it's inert.

### Hook anomaly (informational, not your problem)

The `check-context-size.sh` hook in the prior session was misconfigured and didn't fire milestone or STOP signals reliably; this session it did fire (ctx:150k, ctx:200k, ctx:225k, ctx:250k STOP, ctx:275k). User explicitly overrode the STOP threshold mid-session to finish the external review walkthrough. Don't worry about hook behavior — it's been told this is not your concern.

### Open notes (carried over from earlier sessions, still applicable)

- `examples/smoke_multi_client.py` HEAVY worker orphans boxes if the second create raises before delete fires (acceptable for a manual one-shot — user can `Edit → Undo`).
- ollama kimi/minimax reviewers tend to hang in this environment when given multi-file review prompts — appears to be a daemon-level timeout / synthesis issue rather than anything we can fix from the prompt side.

## PLAN QUALITY WARNING

The original plan (2026-05-17-multi-client-server.md) was fully executed and externally reviewed — its content is now historical reference only. The remaining ceremony work (live smoke + branch finishing) is NOT in the plan. **If the user asks you to do something not explicitly listed above:**

1. STOP before proceeding
2. Verify what they're asking for is consistent with the branch state described above
3. If there's any ambiguity, ask

In particular: do NOT auto-invoke `superpowers:finishing-a-development-branch` — the user has historically run this skill themselves. Wait for explicit instruction.

## INSTRUCTIONS

1. Read the design + plan documents listed above
2. Optionally skim the latest `git log --oneline feature/viewport-screenshot-and-prompt..HEAD` to ground yourself in the commit shape
3. Provide a brief summary (≤ 250 words) of what you understood
4. **STOP and WAIT** — do NOT proceed with live smoke, branch finishing, or any other ceremony step
5. Ask: "What would you like me to work on?"
