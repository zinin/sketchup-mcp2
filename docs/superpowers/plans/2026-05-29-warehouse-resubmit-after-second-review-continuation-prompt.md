# Continue — v0.2.0 warehouse-resubmit: SECOND external review PROCESSED; remaining = release tail

> Supersedes `docs/superpowers/plans/2026-05-29-external-review-complete-continuation-prompt.md`
> for day-to-day state. That older prompt remains the authoritative reference for the
> release-tail mechanics (14.0 Trimble / 14.8 push / 14.9 PR) and the original
> DISMISSED/MINOR lists — read it for detail.

## TASK

Drive the **release tail** of the `feature/warehouse-resubmit` branch (v0.2.0) — the Extension
Warehouse re-submission after the v0.1.0 rejection. The code is complete and a SECOND
`/external-code-review` (7 reviewers) has just been fully processed and committed. Both `.rbz`
are rebuilt. Nothing is pushed; no PR exists.

## ⛔ CRITICAL: DO NOT START WORKING

**STOP. READ THIS CAREFULLY.**

After loading all context below, you MUST:
1. Read the documents and understand the context.
2. Report what you understood (brief summary).
3. **WAIT for explicit user instructions** before taking ANY action.

**DO NOT:**
- Push, open a PR, or submit anything to Trimble.
- Make code changes.
- Run build/test commands (delegate to the `build-runner` agent only when the user asks).
- Assume the next step.

The entire release tail is **user-gated**. Until the user speaks, only read and summarize.

## STATE

- **Branch:** `feature/warehouse-resubmit`
- **HEAD:** `a0d0785` — review: apply decisions from second external review discussion (#8, #9)
- **Commits of the second-review session (newest first):**
  - `a0d0785` review: apply decisions from second external review discussion (#8, #9)
  - `55f1dbb` review: auto-fix valid issues from second external review (7 AUTO)
  - `d1d35f2` docs: correct Ruby log-level default to WARN + document eval per-call review (prior session)
- **Tests GREEN** (verified this session via build-runner): Ruby **298 runs / 735 assertions / 0 failures / 0 errors**, Python **130 passed**.
- **Both `.rbz` REBUILT + verified this session** (gitignored, `mcp_for_sketchup/*.rbz`):
  - warehouse `56,320 B` — `EVAL_ENABLED_BY_DEFAULT=false`, `VARIANT="warehouse"`
  - github `56,316 B` — `EVAL_ENABLED_BY_DEFAULT=true`, `VARIANT="github"`
  - both: loader **"MCP Server for SketchUp"**, version **0.2.0**, clean root (loader `.rb` + `mcp_for_sketchup/` subfolder, 28 files), per-build `build_profile.rb` cleaned up.
- **Working tree:** tracked files clean (both review commits landed). Untracked = working notes only
  (incl. this prompt). Always explicit `git add <path>`, never `-A`/`.`.

## WHAT THE SECOND-REVIEW SESSION DID

Ran `/external-code-review` (team mode) with 7 reviewers: claude (superpowers:requesting-code-review),
codex, ccs `albb-qwen`, ccs `glm`, ollama `deepseek`/`kimi`/`minimax`. Processed per the fixed
four-phase order (dedupe+classify → auto-fix → commit → disputed one-by-one → commit).

**7 AUTO → `55f1dbb`:**
1. `core/config.rb` — persist `eval_enabled` **LAST** in `update!` so the code-exec gate is
   fail-closed ON DISK too (a mid-save write failure can't leave `eval=true` persisted while
   runtime rolled back to closed → would have silently reopened on next SketchUp restart).
   (codex Critical / claude Minor / kimi Important.) Also guard `coerce_bool_pref`'s `Logger.log`
   with `defined?(Logger)`.
2. `core/application.rb` — `show_log` expands the log path **once** (a `~/x.log` was written but
   "Show Log" silently opened the console). (codex + claude.)
3. `src/sketchup_mcp/app.py` — `server_lifespan` catches `SketchUpError` (covers handshake
   timeout/parse/zero-frame + the `IncompatibleVersionError` subclass) → degrade, not crash. (kimi.)
4. `core/logger.rb` — log-file write-failure notice now **one-shot** (WARN, direct console,
   re-armed on next successful write) so an unwritable path can't flood the shared console. (codex.)
5. `ui/settings_dialog.rb` — `report_general_error` DEBUG-logs the swallowed secondary
   `execute_script` instead of a truly-silent `rescue StandardError; nil`. (codex.)
6. `helpers/validation.rb` — `require_id` narrows `Integer() rescue nil` → `rescue ArgumentError, TypeError`. (codex.)
7. tests — +disk-fail-closed, +non-boolean `eval_enabled` coercion (`test_config`), +one-shot
   log-file fallback (`test_logger`), +lifespan-degrades-on-`SketchUpError` (`test_app`);
   `config_reset` clears the logger one-shot flag between tests.

**2 DISPUTED → `a0d0785`** (both decided interactively as **Variant B**):
- **#8** `core/server.rb` — `PENDING_WRITE_MAX_BYTES` (16 MiB) was < the max legal screenshot
  frame (~43 MiB base64, under the 64 MiB framing cap), so a large `get_viewport_screenshot`
  force-closed the client. Fix: the overflow guard fires **only on a non-empty backlog**
  (`backlog > 0 && projected > cap`); a single frame is already bounded by the framing layer.
  +regression test `test_single_oversized_frame_on_empty_buffer_is_not_overflow`. (codex.)
- **#9** `ui/settings.html` — wildcard bind (`0.0.0.0`/`::`/`0:0:0:0:0:0:0:0`) + eval enabled had
  only a non-blocking hint. Fix: the host warning **escalates** (red, explicit "UNAUTHENTICATED
  arbitrary Ruby … to anyone on your LAN") when host is wildcard AND eval is on; updates live on
  host-input and eval-checkbox-change. **HTML/JS only — the fragile two-phase save flow is
  untouched** (chosen over a blocking confirm to avoid destabilising it before resubmission). (codex.)

**DISMISSED (do NOT reopen):**
- #10 `core/application.rb:92` `URI::DEFAULT_PARSER.escape` — deliberate surviving *instance*
  method (design §5.3 rejected `URI::File.build`; prior-review DISMISSED), NOT the removed
  `URI.escape` module method. ccs-qwen conflated the two.
- #11 "no Ruby test for the -32010 eval gate" — `test/test_dispatch_post_handshake.rb:135-170`
  covers it end-to-end. ccs-qwen self-refuted.
- #12 cross-variant leftover eval pref (shared SECTION) — documented accepted risk (design §11).
- ollama-minimax's 2 hallucinations: "export_scene missing `@mcp.tool()`" (`tools.py:144` IS the
  decorator) and "`compat.py:42` uses `int(parts[0.0])`" (actual code is correct).
- ollama-deepseek produced **no findings** — deterministic DSML tool-call protocol incompatibility
  with the Claude CLI (its native `<｜DSML｜…｜>` markup isn't executed as tool calls). Drop that
  profile for agentic review.

## DEFERRED to v0.2.1 (valid, NOT blocking resubmit — do not fix now)

`_RETRY_SAFE_TOOLS`↔dispatch contract test (corroborated by minimax); `logger.rb:57` open-per-line
+ no rotation; `errors.rb` `backtrace.first(3)` always over the wire; `operations.rb:151` awkward
"no edges to Chamfer Edges" wording; `materials.rb:32` lowercase hex in undo label;
`connection.py:289` imprecise `_StaleSocketError` on send-side; `handlers/view.rb:149` Tempfile
prefix `sumcp_vp_` naming vestige; no length cap on `log_file_path`; fragile substring asserts /
possible partial `.rbz` on mid-build failure in `package.rb`.

## REMAINING (release tail — all user-gated, nothing pushed, no PR)

1. **Live re-acceptance** (USER reinstalls the freshly-rebuilt warehouse `.rbz` via Extensions →
   Install Extension, restarts the MCP server in SketchUp; then verify via the `sketchup` MCP):
   - **#9:** in Settings set host `0.0.0.0` (or `::`) AND enable eval → the warning ESCALATES (red,
     "UNAUTHENTICATED arbitrary Ruby … LAN"); toggling either field updates it live.
   - **#8:** a large `get_viewport_screenshot` (complex viewport, `max_size` up to 4096) returns the
     image instead of dropping the connection.
   - **#2:** `log_to_file=true` with a `~/...` path → "Show Log" opens the FILE (not the console);
     a non-ASCII log line is written UTF-8 at the expanded path.
   - eval gate OFF in warehouse → `eval_ruby` returns the `-32010` message verbatim.
   - `get_version` → 0.2.0 compatible; `examples/smoke_check.py` → all steps (eval steps skip gracefully).
2. **14.0 Trimble intake pre-check** (USER, web form): new `product_id` `MCP_FOR_SKETCHUP` accepted
   without linking to the dead v0.1.0 record; unsigned upload + EW signing per `docs/release.md`.
3. **14.8 push:** `git push -u origin feature/warehouse-resubmit`.
4. **14.9 PR (base=master):** ⚠️ FIRST `git rm` the **7 TRACKED** `docs/superpowers/` files
   (tracked on this branch; absent on master), commit
   `chore: remove plan/spec docs before PR (kept in branch history)`, then push + `gh pr create`. The 7:
   - `plans/2026-05-28-warehouse-resubmit-iter1-remaining-fixes.md`
   - `plans/2026-05-28-warehouse-resubmit.md`
   - `specs/2026-05-28-warehouse-resubmit-design.md`
   - `specs/2026-05-28-warehouse-resubmit-review-iter-1.md`
   - `specs/2026-05-28-warehouse-resubmit-review-iter-2.md`
   - `specs/2026-05-28-warehouse-resubmit-review-merged-iter-1.md`
   - `specs/2026-05-28-warehouse-resubmit-review-merged-iter-2.md`
   (The many other `docs/superpowers/*` shown as `??` in `git status` are untracked working notes —
   they will NOT appear in the PR. Do NOT stage them. The 5 review commits
   `6803c24`/`c3ad4d1`/`194fca3`/`55f1dbb`/`a0d0785` are real product fixes and STAY in the PR.)

## DOCUMENTS

- Design: `docs/superpowers/specs/2026-05-28-warehouse-resubmit-design.md`
- Plan: `docs/superpowers/plans/2026-05-28-warehouse-resubmit.md` — **FULLY EXECUTED, historical**;
  read only for detail on a specific past task, do NOT re-execute it.
- Prior state + release-tail mechanics + original DISMISSED/MINOR:
  `docs/superpowers/plans/2026-05-29-external-review-complete-continuation-prompt.md`
- Conventions / non-obvious constraints: `CLAUDE.md`; release workflow: `docs/release.md`

## PLAN QUALITY WARNING

These working docs span a long multi-session effort and may contain stale, superseded, or
inaccurate details. The STATE + WHAT-THE-SECOND-REVIEW-DID sections above reflect the current
verified code, not the older docs. If anything in a doc contradicts the live code or this prompt,
trust the live code — and if you spot a real problem, STOP, describe it, and ask the user before
changing anything.

## INSTRUCTIONS

1. Read the documents above (and `CLAUDE.md`).
2. Understand current progress + the second-review result.
3. Provide a brief summary of what you understood.
4. **STOP and WAIT** — do NOT push/PR/submit or run builds.
5. Ask: "What would you like me to work on?" (The user drives each release-tail step.)
