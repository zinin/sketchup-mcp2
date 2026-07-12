# Continue — v0.1.0 rejection audit PASSED; user is about to re-run external code review

> Supersedes `2026-05-29-external-review-complete-continuation-prompt.md` for day-to-day
> state. That older prompt is still the authoritative source for the release-tail
> mechanics (14.0 Trimble / 14.8 push / 14.9 PR) and the DISMISSED/MINOR follow-up lists —
> read it too.

## TASK

The `feature/warehouse-resubmit` branch (v0.2.0) is **code-complete and verified**.
This session re-audited every point of the original Extension Warehouse v0.1.0
**rejection letter** against the current code AND the actually-built `.rbz` — all
hard rejections + both Notes are addressed (details below). Doc fixes were committed.
The user is about to **re-run an external code review** (`/external-code-review`) in
this fresh session before resubmitting, then drive the release tail.

## ⛔ CRITICAL: DO NOT START WORKING

**STOP. READ THIS CAREFULLY.**

After loading all context below, you MUST:
1. Read the documents and understand the context.
2. Report what you understood (brief summary).
3. **WAIT for explicit user instructions** before taking ANY action.

**DO NOT:**
- Start the external code review yourself (the USER triggers it).
- Make code changes, push, or open a PR.
- Run build/test commands (delegate to the `build-runner` agent only when the user asks).
- Assume the next step.

The release tail is **entirely user-gated**. Until the user speaks, only read and summarize.

## STATE

- **Branch:** `feature/warehouse-resubmit`
- **HEAD:** `d1d35f2` — docs: correct Ruby log-level default to WARN + document eval per-call review
- **Last few commits (newest first):**
  - `d1d35f2` docs: log-level WARN fix + eval per-call-review doc + config table + test counts (THIS session)
  - `194fca3` review: apply decisions from external review discussion (F3/F4b/F6)
  - `c3ad4d1` review: F1 — fail-closed transactional `Config.update!`
  - `6803c24` review: auto-fix valid issues from external review (F2/F4a/F5/F13/F14/F15)
  - `5416c3b` fix(connection): enrich stale-socket transport errors (pre-review baseline)
- **Tests GREEN** (verified this session via build-runner): Ruby **294 runs / 715 assertions / 0 failures / 0 errors**, Python **129 passed**.
- **Both `.rbz` built** (gitignored, `mcp_for_sketchup/*.rbz`), binary-verified by unzip this session:
  warehouse `EVAL_ENABLED_BY_DEFAULT=false`, github `=true`; loader name `MCP Server for SketchUp`, v0.2.0.
- **Working tree:** tracked files clean (the doc commit landed). Untracked = working notes only
  (incl. this prompt). Always explicit `git add <path>`, never `-A`/`.`.

## WHAT THIS SESSION DID

1. **Re-audited the v0.1.0 rejection letter, point by point, with file:line + built-`.rbz` evidence** (see next section). Conclusion: every hard Rejection and both Notes are addressed.
2. **Resolved reviewer point 1c (eval code "visible for case-by-case review")** as a no-code-change item: that visibility is provided by the **MCP client** (Claude Desktop/Code show each `eval_ruby` call's code and let the user approve/deny before it runs), not by the extension. Logging the code server-side would duplicate the client's permission UI and break autonomous (`--dangerously-skip-permissions`) use. Documented instead.
3. **Committed doc fixes** (`d1d35f2`, docs only — no code/test change):
   - `CLAUDE.md`: Ruby Log Level default was wrongly documented as `INFO`; code (`core/config.rb:12`) defaults to **`WARN`** → fixed + added the missing Configuration-table rows (Enable Ruby evaluation / Log to file / Log file path) + documented the eval three-layer guard + refreshed test counts.
   - `README.md`: added a **Per-call review** note and a **WARN-default / shared-console-hygiene** note.

## REJECTION-POINTS AUDIT RESULT (the key context for the re-review)

Original v0.1.0 rejection had: 4 Rejections (eval, console logging, name, `su_` prefix) + 2 Notes (undo op-names, silent rescues). Current status:

| # | Reviewer point | Status | Evidence (current code) |
|---|---|---|---|
| 1a | `eval` off by default | ✅ | `core/config.rb:13,151-166` sentinel→`BuildProfile`; `package.rb:15,93-95` bakes+asserts `false` for warehouse; **verified in the built warehouse `.rbz`** |
| 1b | warn at enable-time (files+system) | ✅ | `ui/settings_dialog.rb:106-137,190-200` blocking `confirm_eval_enable` ("FULL access to your filesystem, network, and shell"); static warning `ui/settings.html:74-75`; checkbox label "(DANGEROUS)" |
| 1c | code visible / case-by-case review | ✅ (at MCP-client layer) | Not an extension feature — the MCP client displays + gates each call. Documented in `CLAUDE.md` eval bullet + `README.md`. Soft "would be good"; the hard minimum (1a+1b) is met. |
| 2 | no console clutter; ext-id + timestamp | ✅ | `core/logger.rb:10,14` every line `[<UTC iso8601>] [MCPforSU] [LEVEL]`; default level **WARN** (`config.rb:12`) suppresses info/debug; **no stray `puts`/`print`** bypass the logger; optional log-to-file (`logger.rb:46-65`) |
| 3 | rename "SketchUp MCP Server" | ✅ | `extension.json:2` + loader `mcp_for_sketchup.rb:6` = "MCP Server for SketchUp"; post-build name guard `package.rb:102-104`; verified in `.rbz` |
| 4 | drop `su_` prefix | ✅ | no `su_` anywhere; dir `mcp_for_sketchup/`; `.rbz` root = loader + subfolder only (also satisfies Trimble "Extra files") |
| 5 | title-case undo op names | ✅ | all `start_operation` labels title-case: "Create Component (Cube)", "Delete Component", "Boolean Union", "Chamfer Edges", "Set Material (Red)", "Mortise and Tenon", etc. |
| 6 | no silent rescues (named: build_sphere, app stop, server cleanup) | ✅ | `geometry.rb:176` logs DEBUG; `application.rb` old `rescue nil` gone (stop has none; start-cleanup logs DEBUG); `server.rb:41,95,110,393` all log DEBUG; handler rescues are `safe_abort+raise` (re-raised, logged in `dispatch.rb:44-53`) |

## REMAINING (release tail — all user-gated, nothing pushed, no PR)

1. **(User, this session) Re-run external code review** on the branch. Expect a NEW review team to spawn (the prior `code-review-warehouse` team from an earlier session is defunct — its teammates died with that session; only harmless metadata dirs remain under `~/.claude/teams/`).
2. **Live re-acceptance:** user reinstalls `mcp_for_sketchup/mcp_for_sketchup_v0.2.0-warehouse.rbz` (Extensions → Install Extension), restarts the MCP server in SketchUp; then I verify touched surfaces via the `sketchup` MCP (F2 IPv6 host-warning, F4b/F5 log-to-file UTF-8 at expanded path, eval gate OFF → `-32010`, `get_version`→0.2.0, `examples/smoke_check.py`→22/22).
3. **14.0 Trimble intake pre-check** (user, web form): new `product_id` `MCP_FOR_SKETCHUP` accepted without linking to dead v0.1.0; unsigned upload + EW signing per `docs/release.md`.
4. **14.8 push:** `git push -u origin feature/warehouse-resubmit`.
5. **14.9 PR (base=master):** ⚠️ first `git rm` the **7 TRACKED** `docs/superpowers/` files (verified tracked this session; absent on master), commit `chore: remove plan/spec docs before PR (kept in branch history)`, then push + `gh pr create`. The 7:
   - `plans/2026-05-28-warehouse-resubmit-iter1-remaining-fixes.md`
   - `plans/2026-05-28-warehouse-resubmit.md`
   - `specs/2026-05-28-warehouse-resubmit-design.md`
   - `specs/2026-05-28-warehouse-resubmit-review-iter-1.md`
   - `specs/2026-05-28-warehouse-resubmit-review-iter-2.md`
   - `specs/2026-05-28-warehouse-resubmit-review-merged-iter-1.md`
   - `specs/2026-05-28-warehouse-resubmit-review-merged-iter-2.md`
   (The many other `docs/superpowers/*` shown as `??` in git status are untracked working notes — they will not appear in the PR. Do NOT stage them.)

## OPEN / OPTIONAL (not blocking resubmit)

- **1c eval-code logging:** intentionally NOT implemented (handled at MCP-client layer). Do not "fix" this.
- **`ui/settings_dialog.rb:215`** — the one remaining truly-silent rescue (`rescue StandardError; nil` in `report_general_error`, the terminal dialog error-reporter). Defensible but inconsistent with the DEBUG-log convention; optional one-line DEBUG tweak. Not in a reviewer-named file.
- **v0.2.1 minor candidates** (from the prior review, all deferred): `connection.py:387` reconnect-without-await, logger per-line open / no rotation, `_RETRY_SAFE_TOOLS`↔dispatch contract test, conftest StreamReader deprecation, a couple of test-gap/style nits. See the DISMISSED + MINOR lists in `2026-05-29-external-review-complete-continuation-prompt.md`.

## DOCUMENTS (read for full context)

- Design: `docs/superpowers/specs/2026-05-28-warehouse-resubmit-design.md`
- Plan (fully executed — historical): `docs/superpowers/plans/2026-05-28-warehouse-resubmit.md`
- Prior state + release-tail detail + DISMISSED/MINOR: `docs/superpowers/plans/2026-05-29-external-review-complete-continuation-prompt.md`
- Project conventions / non-obvious constraints: `CLAUDE.md`; release workflow: `docs/release.md`

## PLAN QUALITY WARNING

These working docs were written across a long multi-session effort and may contain stale
details, superseded decisions, or inaccuracies. The **audit table above** reflects the
current verified code, not the older docs. If anything in the docs contradicts the live
code or this prompt, trust the live code — and if you spot a real problem, STOP, describe
it, and ask the user before changing anything.

## INSTRUCTIONS

1. Read the documents listed above (and `CLAUDE.md`).
2. Understand current progress + the rejection-audit result.
3. Provide a brief summary of what you understood.
4. **STOP and WAIT** — do NOT start the external review or any implementation.
5. Ask: "What would you like me to work on?" (The user intends to trigger `/external-code-review` themselves.)
