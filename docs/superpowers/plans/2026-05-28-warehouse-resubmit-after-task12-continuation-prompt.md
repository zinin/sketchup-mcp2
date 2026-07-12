# Continue Plan — Warehouse Resubmit v0.2.0 (after Task 12)

## TASK

Continue executing the implementation plan for the SketchUp extension
warehouse re-submission (v0.2.0). Tasks 1–12 are fully closed (impl +
spec review ✅ + code review ✅ each); **Tasks 13–14 remain.** Execute via
`superpowers:subagent-driven-development` with `/do-plan` (default STOP
threshold 250k tokens) or pause/resume via `/pause-after-current-task` /
`/continue-plan-fresh-session`.

## CRITICAL: DO NOT START WORKING

**STOP. READ THIS CAREFULLY.**

After loading all context below, you MUST:

1. Read the documents and understand the context.
2. Report what you understood (brief summary ≤6 lines).
3. **WAIT for explicit user instructions** before taking ANY action.

**DO NOT:**

- Start dispatching Task 13 (or any task).
- Make any code or document changes.
- Run any commands except reading documents and `git log` / `git status`.

**The user will tell you exactly what to do.** The natural next step is
`/do-plan`, but the user may want manual review, a different threshold,
or something else.

## DOCUMENTS

Read in this order:

1. **Design (post-iter-2 final):** `docs/superpowers/specs/2026-05-28-warehouse-resubmit-design.md` (~332 lines)
2. **Plan (post-Task-12 trim):** `docs/superpowers/plans/2026-05-28-warehouse-resubmit.md` (445 lines after trimming Tasks 1–12)
3. **Iter-1 decisions log:** `docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-iter-1.md`
4. **Iter-2 decisions log:** `docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-iter-2.md`

`...-review-merged-iter-2.md` is the raw reviewer-panel output (already
digested into the iter-2 log); read only to look up a specific finding.

### Trimmed-plan line ranges (re-confirm before dispatch)

After the Task-1–12 trim, the remaining tasks live at:

- **Task 13:** lines ~113–299 (smoke_check graceful skip on −32010)
- **Task 14:** lines ~301–425 (final verification + PR)
- (Spec coverage self-review: ~427–445)

Re-confirm with `grep -nE '^## Task [0-9]' <plan>` before dispatching —
numbers shift if the plan is edited again.

## STATE OF THE REPO

**Branch:** `feature/warehouse-resubmit`
**HEAD:** `175b0bf docs: trim completed Tasks 10-12 from plan for warehouse-resubmit`

```
175b0bf  docs: trim completed Tasks 10-12 from plan   [this session: plan trim]
f7129b9  docs: update README, CLAUDE, release.md...   [Task 12: this session]
f125c23  chore: bump to v0.2.0                         [Task 11: this session]
847dcf8  feat(package): dual-variant build (...)       [Task 10: this session, amended after code review]
f125c23 < ... < c5d72da  (Task 9 and earlier — prior sessions)
```

**Working tree:** clean of tracked-file modifications. Many untracked
files (session-transfer docs, `.gemini/`, `diff.patch`, other
superpowers plans/specs, continuation prompts including this one) are
pre-existing — **do NOT stage them.** Use explicit `git add <path>` per
the iter-1 CONCERN-7 commit policy. ALWAYS `git status` before staging.

**Tests last seen (end of this session):** Ruby **287 runs / 684
assertions / 0 failures / 0 errors**; Python **121 passed**. Both must
stay green. (Task 13 adds a new Python test file `tests/test_smoke_helpers.py`
→ Python count will rise; Task 13 touches no Ruby.)

## PROGRESS

### ✅ Completed (Tasks 1–12)

- [x] **Task 1: Mechanical rename** — `4415dfd` + `dd2d7db`.
- [x] **Task 2: Title Case labels + silent-rescue cleanup** — `2cd849f`.
- [x] **Task 3: Logger `[MCPforSU]` prefix + default WARN** — `bb907d1`.
- [x] **Task 4: New Config prefs + build_profile loading** — `02f7982`.
- [x] **Task 5: Logger log-to-file** — `893a5a4`.
- [x] **Task 6: eval_ruby gate (−32010)** — `5415e31`.
- [x] **Task 7: Settings validator** — `8b61156`.
- [x] **Task 8: Settings dialog UI** — `d3423c2`.
- [x] **Task 9: Python −32010 routing** — `704d0e5`.
- [x] **Task 10: package.rb dual-variant build** — `847dcf8` (THIS session).
      Applied the user-approved **Option A**: the post-build block verifies the
      embedded `core/build_profile.rb` (VARIANT + EVAL_ENABLED_BY_DEFAULT) and
      the loader `mcp_for_sketchup.rb` (display name + `ext.version == VERSION`)
      — NOT `extension.json` (which never ships in the `.rbz`). begin/ensure
      cleans build_profile + temp dir on any outcome; a post-build assertion
      failure also `rm_f`s the `.rbz` before re-raising (code-review fix). New
      `test/test_package_default_variant.rb`.
- [x] **Task 11: Version bump 0.2.0** — `f125c23` (THIS session). 7 canonical
      locations; wire-break (MIN_*=MAX_*=0.2.0 both sides); uv.lock regen. No
      test edits needed — both suites read versions dynamically with built-in
      consistency guards (`tests/test_compat.py:106`, `test/test_compat.rb:121-125`).
- [x] **Task 12: Documentation updates** — `f7129b9` (THIS session). README,
      CLAUDE.md, docs/release.md, cookbook updated for v0.2.0. Step 12.7.a swept
      25 Ruby header comments + `compat.py:3`/`tools.py:164` path docstrings.
      **User decided (option A): FastMCP server name `"SketchupMCP"` →
      `"MCP Server for SketchUp"`** (app.py:42 + prompts.py:1 + smoke_multi_client.py:2;
      README/CLAUDE prose too). Fixed the `SU_MCP_save_eval` comment in
      `test_dispatch_post_handshake.rb`. Folded in 2 deferred minors
      (compat.py:16 stale comment, tools.py:3-4 docstring soften). **Step 12.8
      strict grep returns ZERO legacy markers.**

### ⏸ Remaining (Tasks 13–14, in order)

- [ ] **Task 13:** `examples/smoke_check.py` graceful skip on −32010.
      `sys.path.insert` wrapped in `if __name__ == "__main__":` guard (iter-2
      CONCERN-5, so the importlib load in the test doesn't pollute sys.path);
      `eval_skipped = [0]` mutable container (iter-2 CONCERN-12, avoids
      `nonlocal`); new `_maybe_skip_eval` helper **MUST**
      `from sketchup_mcp.compat import EVAL_DISABLED_CODE` and
      `from sketchup_mcp.errors import SketchUpError`, catching
      `SketchUpError` with `e.code == EVAL_DISABLED_CODE` (iter-1 CRITICAL-4 —
      smoke uses raw `SketchUpConnection.send_command`, which RAISES on a
      JSON-RPC error envelope; do NOT check returned text). Check
      `examples/smoke_multi_client.py` for eval calls (apply same pattern if
      any). New `tests/test_smoke_helpers.py` (hermetic, monkeypatched). The
      shared `EVAL_DISABLED_CODE` constant (Task 9) only fully realises its
      anti-drift purpose once this smoke helper imports it.
- [ ] **Task 14:** Final verification + PR. **SEE "TASK 14 CARRY-FORWARDS" BELOW
      — four items gathered during Tasks 10–12 that are NOT in the plan's
      literal Step text.** Standard items: Trimble intake pre-check (Step 14.0 /
      QUESTION-4 — surface to user), full Ruby + Python suites, build BOTH .rbz
      variants at 0.2.0, verify build_profile differs, strict tracked-grep
      (Step 14.5), Python wheel + twine, manual SketchUp 2026+ acceptance (11
      substeps — needs user + SketchUp), push branch, open PR after manual
      acceptance (per global CLAUDE.md: `git rm` the design + plan docs from
      `docs/superpowers/` first, commit, then `gh pr create`).

## ⚠ TASK 14 CARRY-FORWARDS (apply when you reach Task 14)

These were discovered/decided during Tasks 10–12 and are recorded here +
in the TodoWrite Task 14 entry. Hand them to the Task 14 implementer
alongside the plan's Step 14.x text.

- **(A) release.md ↔ Trimble/EW signed-`.rbz` acceptance is UNVERIFIED
  external behavior** (Task 12 was `DONE_WITH_CONCERNS` on exactly this).
  Task 12 rewrote `docs/release.md` to the design-§8 flow («both variants
  go through the Trimble signing service; submit the signed warehouse
  `.rbz`»), DELETING the old v0.1.0 «EW rejects pre-encrypted `.rbz`,
  upload a plain `-ew-source.rbz`» workaround. BUT the old text was based
  on an empirically-observed EW rejection («Invalid extension is
  encrypted», commit `839466c`). **Step 14.0's Trimble intake pre-check
  MUST confirm with the user whether the real EW intake accepts a
  Trimble-signed `.rbz`.** If it still rejects signed bundles, restore the
  plain-source upload path in `docs/release.md` §7 (≈ the «Build & sign the
  warehouse `.rbz`» subsection + the form-table `Encryption Type` / `Upload
  file` rows). The release.md text today is internally self-consistent
  (no contradiction) — the uncertainty is purely about external EW behavior.
- **(B) `CLAUDE.md:74-75` stale test counts** — reads `# Ruby (230 runs /
  516 assertions)` and `# Python (120 tests)`; actual is **287 / 684** and
  **121**. Pre-existing (already stale at base, out of Task 12's scope).
  Update as part of Task 14's final pass (Task 14 otherwise modifies no
  files — this is a tiny doc fix; add `CLAUDE.md` to that commit's
  explicit `git add` if you make it).
- **(C) `docs/release.md:5` heading «Breaking changes (v0.1.0)»** — sits in
  a now-v0.2.0 doc. Pre-existing, internally accurate as history. OPTIONAL:
  retitle to «Breaking changes» or add a v0.2.0 sub-bullet (rebrand +
  wire-break). Low priority.
- **(D) Step 14.5 grep ↔ Step 12.8 mismatch** — Step 14.5's grep PATTERNS
  does NOT include `SketchupMCP`, but Step 12.8's does. Because the rename
  decision was **option A** (rename, keep the grep strict), **add
  `SketchupMCP` to Step 14.5's PATTERNS** so 14.5 is as strict as 12.8.
  Both return zero today; this just keeps the regression-guard consistent.

## SESSION CONTEXT (how this session ran)

- Executed via `/do-plan 300k` → `superpowers:subagent-driven-development`,
  **Opus for every subagent** (implementer + spec reviewer + code reviewer).
- Tasks 10, 11, 12 each ran: implementer → spec review ✅ → code review ✅.
  Task 10 needed one code-review fix loop (the post-build stray-`.rbz`
  cleanup); Tasks 11 and 12 passed code review with only deferred/pre-existing
  minors (no fix loop).
- The **Task 10 extension.json plan-defect** (flagged by the previous session)
  was confirmed against the live repo and fixed via **Option A** (verify
  build_profile + loader, not extension.json). Lynchpin verified by `unzip -l`
  of the shipped `su_mcp_v0.1.0.rbz` (no extension.json in the `.rbz`).
- **Task 12 rename decision surfaced to the user and decided: option A**
  (rename `"SketchupMCP"` → `"MCP Server for SketchUp"`). The user asked for
  the pros/cons first; the only functional spot was the FastMCP server `name`
  in `app.py:42` (shown as `serverInfo.name` to MCP clients; no test asserts
  it; NOT the PyPI/module name, which design §10 keeps).
- The **300k STOP** fired right after the Task 12 implementer reported (during
  Task 12's review cycle); per `/pause-after-current-task`, Task 12 was driven
  to a clean checkpoint (both reviews ✅) before stopping. This handoff was
  then generated. (Note: the comprehensive Step-12.8 pre-verification grep ate
  more context than expected — that, plus the large Task 12, is why the budget
  was consumed mid-Task-12. Consider `/do-plan 250k` is plenty for Tasks 13+14
  since Task 13 is small and Task 14 is mostly manual/user-driven.)

### Carry-forward conventions (STILL ACTIVE)

- **⭐ Surgical edit, NOT whole-file replace.** Plan steps that say «Replace
  `<file>` with [full block]» must be applied as surgical edits unless the file
  is generated tooling (package.rb was the one exception — a full rewrite was
  appropriate there). Pre-verify anchors against the live file.
- **Controller-curated dispatch worked well:** before each dispatch, the
  controller pre-verifies the task's risky anchors against live files, then
  hands the implementer the precise findings + the bounded plan line-range
  (NOT the whole plan — for the large Task 12, pointing the implementer at the
  plan's line range + a value-add cleanup map worked well). Do the same for 13–14.
- **Anchor drift → STOP and ask.** If any sed/Edit anchor (line number OR
  before-string) doesn't match the live file, STOP and surface it.
- **Stale absolute test counts in the plan are unreliable.** Record the actual
  baseline before each task and compare the DELTA. Current baseline: Python
  **121**; Ruby **287 / 684**.
- **Commit policy (iter-1 CONCERN-7):** always explicit `git add <path>`, NEVER
  `git add -A`/`.`. Each task's Files header lists the staging set; derive from
  it. Confirm `git status` shows only the task's files before staging.
- **Sed portability (iter-2 CONCERN-2):** this host is **Linux** (GNU sed works
  as written). Relevant if Task 13 uses any sed (it mostly uses Python edits).
- **Test infra:** Python uses pytest with `mock_send_command` / `mock_ctx`
  fixtures (`tests/test_tools.py`); Task 13 adds `tests/test_smoke_helpers.py`.
- **Reviewer panel (for any external review round):** `codex-executor`
  (gpt-5.5, xhigh) — works. `ccs-executor / albb-deepseek` (DeepSeek-V4 Pro,
  1M) — works. `ccs-executor / albb-kimi` — works. `ccs-executor / glm`,
  `albb-qwen` — fail (upstream). `albb-glm` — skip per user preference.
- **/do-plan threshold config** lives at
  `~/.claude/state/do-plan-config--opt-github-zinin-sketchup-mcp2.json`.
  Currently `{"stop_threshold": 300000}`. Override with `/do-plan 250k` etc.
  (≥150k). Tasks 13+14 are light on autonomous work (Task 14 is mostly manual
  SketchUp acceptance + user-gated submission), so a smaller threshold is fine.

## PLAN QUALITY WARNING

The plan was hardened across 2 review iterations + spec-review-during-execution,
and Tasks 1–12 executed cleanly against it. It is rigorous but NOT bulletproof
(Task 10's extension.json defect and the Task 12 README `cd su_mcp` / release.md
legacy-content gaps are proof):

- **STOP at the first plan step that doesn't match observed codebase state.**
- **STOP at any sed/Edit anchor that doesn't apply cleanly.**
- **Do not silently work around plan issues** — describe the problem, explain
  why the plan doesn't fit, and ask how to proceed.

## INSTRUCTIONS

1. Read the 4 documents listed in «DOCUMENTS» (design, plan, iter-1, iter-2).
2. Optionally `git show f7129b9 -s` (Task 12) for the most recent context.
3. Summarise current state in ≤6 lines.
4. **STOP and WAIT** — do NOT start anything.
5. Ask the user what to do. The natural next step is `/do-plan` (resumes via
   `superpowers:subagent-driven-development` at Task 13 — apply the Task 13
   specifics above; carry the TASK 14 CARRY-FORWARDS into Task 14), but the
   user may want manual review, a different threshold, or something else.
