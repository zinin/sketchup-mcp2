# Continue Plan — Warehouse Resubmit v0.2.0 (after Task 9)

## TASK

Continue executing the implementation plan for the SketchUp extension
warehouse re-submission (v0.2.0). Tasks 1–9 are fully closed (impl +
spec review ✅ + code review ✅ each); Tasks 10–14 remain. Execute via
`superpowers:subagent-driven-development` with `/do-plan` (default STOP
threshold 250k tokens) or pause/resume via `/pause-after-current-task`
/ `/continue-plan-fresh-session`.

## CRITICAL: DO NOT START WORKING

**STOP. READ THIS CAREFULLY.**

After loading all context below, you MUST:

1. Read the documents and understand the context.
2. Report what you understood (brief summary ≤6 lines).
3. **WAIT for explicit user instructions** before taking ANY action.

**DO NOT:**

- Start dispatching Task 10 (or any task).
- Make any code or document changes.
- Run any commands except reading documents and `git log`/`git status`.

**The user will tell you exactly what to do.** Until then, only read,
summarise, and ask. The natural next step is `/do-plan`, but the user
may want manual review, a different threshold, or something else.

## DOCUMENTS

Read in this order:

1. **Design (post-iter-2 final):** `docs/superpowers/specs/2026-05-28-warehouse-resubmit-design.md` (~332 lines)
2. **Plan (post-Task-9 trim):** `docs/superpowers/plans/2026-05-28-warehouse-resubmit.md` (1051 lines after trimming Tasks 1–9)
3. **Iter-1 decisions log:** `docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-iter-1.md`
4. **Iter-2 decisions log:** `docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-iter-2.md`

`...-review-merged-iter-2.md` is the raw reviewer-panel output (already
digested into the iter-2 log); read only to look up a specific finding.

### Trimmed-plan line ranges (re-confirm before dispatch)

After the Task-1–9 trim, remaining tasks live at these ranges (hand the
implementer ONLY its task's range, never the whole file):

- **Task 10:** lines ~95–324  (package.rb dual-variant — SEE THE APPROVED RESOLUTION BELOW)
- **Task 11:** lines ~325–426 (version bump 0.2.0)
- **Task 12:** lines ~427–718 (docs — LARGE)
- **Task 13:** lines ~719–906 (smoke skip)
- **Task 14:** lines ~907–1051 (final verification + PR)

Re-confirm with `grep -nE '^## Task [0-9]' <plan>` before dispatching —
numbers shift if the plan is edited again.

## STATE OF THE REPO

**Branch:** `feature/warehouse-resubmit`
**HEAD:** `c5d72da docs: trim completed Task 9 from plan for warehouse-resubmit`

```
c5d72da  docs: trim completed Task 9 from plan        [this session: plan trim]
704d0e5  feat(python): route -32010 from eval_ruby... [Task 9: this session]
d7e80ea  docs: trim completed Task 8 from plan        [prior session]
d3423c2  feat(settings): UI for eval_enabled, ...      [Task 8]
8b61156  feat(settings): validator accepts new prefs   [Task 7]
5415e31  feat(eval): gate eval_ruby behind ... (-32010) [Task 6]
893a5a4  feat(logger): optional log-to-file mode        [Task 5]
02f7982  feat(config): new prefs + build_profile hook   [Task 4]
bb907d1  feat(logger): [MCPforSU] prefix + default WARN [Task 3]
2cd849f  refactor: Title Case start_operation labels    [Task 2]
4415dfd  refactor: rename SU_MCP -> MCPforSketchUp ...    [Task 1]
```

**Working tree:** clean of tracked-file modifications. Many untracked
files (session-transfer docs, `.gemini/`, `diff.patch`, other
superpowers plans/specs, continuation prompts including this one) are
pre-existing — **do NOT stage them.** Use explicit `git add <path>` per
the iter-1 CONCERN-7 commit policy. ALWAYS `git status` before staging.

**Tests last seen (end of this session):** Python **121 passed** (120 +
the new Task 9 test); Ruby **286 runs / 676 assertions / 0 failures / 0
errors** (Ruby unchanged — Task 9 touched Ruby only with one comment in
`handlers/eval.rb`). Both must stay green.

## PROGRESS

### ✅ Completed

- [x] **Task 1: Mechanical rename** — `4415dfd` + `dd2d7db`.
- [x] **Task 2: Title Case labels + silent-rescue cleanup** — `2cd849f`.
- [x] **Task 3: Logger `[MCPforSU]` prefix + default WARN** — `bb907d1`.
- [x] **Task 4: New Config prefs + build_profile loading** — `02f7982`.
- [x] **Task 5: Logger log-to-file** — `893a5a4`.
- [x] **Task 6: eval_ruby gate (−32010)** — `5415e31`.
- [x] **Task 7: Settings validator** — `8b61156`.
- [x] **Task 8: Settings dialog UI** — `d3423c2`.
- [x] **Task 9 (FIRST Python change): Python −32010 routing** — `704d0e5`
      (THIS session). `EVAL_DISABLED_CODE = -32010` defined canonically in
      `src/sketchup_mcp/compat.py`; `tools.py::eval_ruby` rewritten to use
      `_raw_call`, catch `SketchUpError`, and `return e.message` verbatim on
      −32010 (no `[code]` prefix) else `format_error`; ConnectionError string
      matches `_call`'s. New `# 8. eval_ruby gate` section in `prompts.py`.
      New test `test_eval_ruby_returns_actionable_text_on_minus32010`.
      Reciprocal "Mirrored in compat.py" comment added in `handlers/eval.rb`
      (1 line — the carry-forward anti-drift guard). **Controller deviations
      from the literal plan (both spec+code review ✅):** (a) referenced
      `compat.EVAL_DISABLED_CODE` rather than the plan's mid-file
      `from sketchup_mcp.compat import …` (matches the file's existing
      `compat.MIN_RUBY` idiom, zero new imports); (b) the eval.rb comment
      extends the plan's Python-only Files list — intentional, approved.

### ⏸ Remaining (Tasks 10–14, in order)

- [ ] **Task 10:** `package.rb` dual-variant build. **⚠ A PLAN-DEFECT WAS FOUND
      AND ITS FIX APPROVED THIS SESSION — see "TASK 10 RESOLUTION" below. Apply
      it; do not dispatch Step 10.2's post-build check as literally written.**
- [ ] **Task 11:** Version bump → 0.2.0 in 7 canonical locations. Wire-protocol
      break: MIN_PYTHON/MIN_RUBY = MAX_* = "0.2.0".
- [ ] **Task 12 (LARGE):** Documentation (README, CLAUDE, release, cookbook).
      **⚠ Step 12.7.a OBLIGATORY before Step 12.8** (sweeps stale
      `su_mcp/su_mcp/...` comments + the 2 Python docstrings; it ALSO edits
      `src/sketchup_mcp/tools.py` and `compat.py`). **PLUS a plan gap — see
      "TASK 12 PLAN GAP" below.**
- [ ] **Task 13:** `examples/smoke_check.py` graceful skip on −32010.
      `sys.path.insert` in `__main__` guard (CONCERN-5); `eval_skipped = [0]`
      mutable container (CONCERN-12); **new `_maybe_skip_eval` MUST
      `from sketchup_mcp.compat import EVAL_DISABLED_CODE`** (the shared
      constant added in Task 9 — its stated anti-drift purpose is only fully
      realised once the smoke helper imports it). New `tests/test_smoke_helpers.py`.
- [ ] **Task 14:** Final verification — Trimble intake pre-check (QUESTION-4),
      full Ruby + Python suites, build both .rbz variants, strict tracked-grep,
      Python wheel + twine, manual SketchUp 2026+ acceptance (11 substeps),
      push branch, open PR after manual acceptance (per global CLAUDE.md:
      `git rm` design+plan docs first).

## ⚠ TASK 10 RESOLUTION (READ BEFORE DISPATCHING TASK 10)

The controller pre-verified Task 10's anchors this session against the live
repo and found a **real plan defect**. The user chose the fix (**Option A**).
Hand the Task 10 implementer this resolution alongside the bounded plan range.

### The defect

Step 10.2's package.rb rewrite ends with an inline post-build verification
that opens the built `.rbz` and reads `extension.json`:

```ruby
Zip::File.open(OUTPUT_NAME) do |zf|
  entry = zf.find_entry(File.join(EXTENSION_NAME, "extension.json"))
  raise "post-build: extension.json missing ..." unless entry
  # ... assert product_id / name / version from the parsed JSON
end
```

This **always raises**, because `extension.json` is NOT in the `.rbz`:

- `extension.json` lives at the **top** of the source tree
  (`mcp_for_sketchup/extension.json`), a sibling of the loader and the
  extension subfolder — NOT inside the subfolder.
- `package.rb` only stages the subfolder (`cp_r EXTENSION_NAME`) + the loader
  (`cp "#{EXTENSION_NAME}.rb"`). It never copies the top-level `extension.json`.
- Verified by `unzip -l mcp_for_sketchup/su_mcp_v0.1.0.rbz`: the shipped
  artifact contains the loader (`su_mcp.rb`) at root + the subfolder with
  `.rbe`/`.susig`/`settings.html` — **no `extension.json` anywhere**. This is
  BY DESIGN: design §9 lists `.rbz` contents as loader + subfolder only;
  `docs/release.md` states EW rejects extra files at root and the loader
  declares metadata via `Sketchup::Extension.new`.
- The loader `mcp_for_sketchup/mcp_for_sketchup.rb:6` is what actually ships
  and carries the identity that caused the v0.1.0 rejection:
  `SketchupExtension.new('MCP Server for SketchUp', 'mcp_for_sketchup/main')`
  + `ext.version = '0.1.0'`.

The extension.json post-build check was added by external reviewers
(iter-1 SUGGESTION-3, iter-2 CRITICAL-8) on the false premise that
extension.json ships in the `.rbz`. It does not.

### The fix (Option A — user-approved)

In package.rb's inline post-build block, REPLACE the extension.json-from-`.rbz`
read with verification of what is REALLY in the `.rbz` and matters:

1. `find_entry("mcp_for_sketchup/core/build_profile.rb")` exists AND its body
   contains the expected `VARIANT` + `EVAL_ENABLED_BY_DEFAULT` for the built
   variant (warehouse → `false`, github → `true`). [the variant contract —
   the whole point of Task 10]
2. `find_entry("mcp_for_sketchup.rb")` (the loader) exists AND its body
   contains the display name `'MCP Server for SketchUp'` AND
   `ext.version == VERSION`. [this is the iter-2 CRITICAL-8 name-regression
   guard pointed at the RIGHT artifact — the loader, which shipped & caused
   the v0.1.0 reject; extension.json never ships]
3. DROP the `extension.json` `find_entry`/`JSON.parse` entirely.

Source-side `extension.json` product_id + name stays guarded by the existing
`test/test_extension_json.rb` (Task 4) — no change there. Keep `VERSION='0.1.0'`
in Task 10 (Task 11 bumps to 0.2.0, so the post-build version assertion uses
whatever VERSION is). Tell the spec + code reviewers this deviation is
controller+user-approved and design-aligned (spec §9 wins over the
reviewer-added extension.json check).

### Task 10 pre-verification already done this session (don't redo)

- `package.rb` (current) still hardcodes `cp_r('su_mcp')` / `cp('su_mcp.rb')`
  on lines 22-23 (a Task-1 leftover) — the Step 10.2 full rewrite to
  `EXTENSION_NAME` fixes these (they are also the `su_mcp` markers grep sees
  in package.rb).
- `.gitignore`: `*.rbz` IS ignored (line 28); `build_profile` is NOT yet
  listed → Step 10.1 appends it (confirmed missing).
- **rubyzip is 3.3.0** (NOT 2.x). The plan's Zip API
  (`Zip::File.open(name, create: true)`, `find_entry`, `get_input_stream`) is
  3.x-compatible, but the implementer must confirm by actually running the
  build (Steps 10.3–10.6) — watch for any 2.x→3.x API surprise.
- Run `package.rb` from INSIDE the top `mcp_for_sketchup/` dir.
  `EXTENSION_NAME='mcp_for_sketchup'` resolves to the SUBfolder
  (`mcp_for_sketchup/mcp_for_sketchup/`). `build_profile_path` is written into
  that subfolder BEFORE `cp_r`, so it lands in the `.rbz` at
  `mcp_for_sketchup/core/build_profile.rb` — the Step 10.6.a test's
  `find_entry("mcp_for_sketchup/core/build_profile.rb")` is CORRECT.
- Old artifacts `su_mcp_v0.1.0.rbz` + `su_mcp_v0.1.0-ew-source.rbz` sit on disk
  in `mcp_for_sketchup/` (gitignored; Step 10.8 `rm -f *.rbz` clears them; the
  test globs `mcp_for_sketchup_v*` so they don't interfere).
- The Step 10.6.a test (`test_package_default_variant.rb`) is CORRECT as
  written — it checks build_profile, not extension.json. Only the INLINE
  post-build block in package.rb (Step 10.2) carries the defect.

## ⚠ TASK 12 PLAN GAP (resolve when you reach Task 12)

Step 12.8's strict tracked-grep PATTERNS includes `SketchupMCP` and
`SU_MCP_SERVER`. The controller surveyed the tree this session; these legacy
markers in tracked non-historical files have **no explicit fix step** in the
plan and will FAIL Step 12.8 unless handled:

- `src/sketchup_mcp/app.py:42` — `"SketchupMCP"` (the FastMCP server name).
- `src/sketchup_mcp/prompts.py:1` — `"""MCP prompts for SketchupMCP.`
- `examples/smoke_multi_client.py:2` — `"""Multi-client live smoke for SketchupMCP."""`
- `test/test_dispatch_post_handshake.rb:132` — explanatory comment containing
  the literal `SU_MCP_save_eval`.

Also: Step 12.8 PATTERNS includes `SketchupMCP` but Step 14.5's grep does NOT
— a 12.8↔14.5 mismatch. **A rename decision is needed:** design §10 keeps the
Python package name `sketchup_mcp` / `sketchup-mcp2`, but does the FastMCP
server display name `"SketchupMCP"` count as in-scope? Surface this to the
user when reaching Task 12; don't silently rename or silently exclude.

Deferred Minor from Task 9 code review (fold into Task 12, since Step 12.7.a
already edits `tools.py`): `src/sketchup_mcp/tools.py:3-4` module docstring
says "Each tool is a thin wrapper that delegates to `_call`" — no longer
universally true (`eval_ruby` and `get_viewport_screenshot` use `_raw_call`).
Soften the wording.

**DO NOT fix any of the above in Tasks 10–11** — keep those tasks' diffs
minimal; these belong to Task 12.

## SESSION CONTEXT (how this session ran)

- Executed via `/do-plan` (250k threshold) → `superpowers:subagent-driven-development`,
  **Opus for every subagent** (implementer + spec reviewer + code reviewer).
- Task 9 ran cleanly: implementer DONE → spec review ✅ (independent code
  read, both suites run) → code review ✅ ("Ready to merge: Yes", 0 Critical /
  0 Important / 1 deferred Minor). ONE commit `704d0e5` (5 files, 66+/2−).
- Then the controller pre-verified Task 10, found the extension.json defect,
  escalated to the user (per the plan-quality "STOP and ask" rule), and the
  user chose Option A. The controller then **proactively paused at the clean
  Task 9/10 boundary** (ctx ~225k, 25k below the 250k STOP) rather than start
  the large Task 10 and be forced past budget — matching last session's
  pattern. The STOP signal fired during the `/continue-plan-fresh-session`
  handoff itself.

### Carry-forward conventions (STILL ACTIVE)

- **⭐ Surgical edit, NOT whole-file replace.** Several plan steps say
  "Replace `<file>` with [full block]". Taken literally those drop (a) the
  stale `# su_mcp/su_mcp/<path>.rb` line-1 headers (owned by Step 12.7.a) and
  (b) useful comments. Apply as surgical edits; pre-verify anchors against the
  live file; keep edits additive in Tasks 10–11.
- **Controller-curated dispatch worked well:** before each dispatch, the
  controller pre-verifies the task's risky anchors against live files, then
  hands the implementer the precise findings + the bounded plan line-range
  (NOT the whole plan). Do the same for Tasks 10–14.
- **Anchor drift → STOP and ask.** If any sed/Edit anchor (line number OR
  before-string) doesn't match the live file, STOP and surface it — don't
  invent a workaround. (This is exactly how the Task 10 defect was caught.)
- **Stale absolute test counts in the plan are unreliable.** Record the actual
  baseline before each task and compare the DELTA. Current baseline: Python
  **121**; Ruby **286 / 676**.
- **Commit policy (iter-1 CONCERN-7):** always explicit `git add <path>`,
  NEVER `git add -A`/`.`. Each task's Files header lists the staging set;
  derive from it. Confirm `git status` shows only the task's files before
  staging. Pre-existing untracked files must not land in feature commits.
- **Sed portability (iter-2 CONCERN-2):** `sed -i 's/.../.../g' file` is GNU
  syntax; this host is **Linux** (GNU sed works as written). Relevant in
  Task 12 (12.1/12.7/12.7.a).
- **Stale `# su_mcp/...` headers / 2 Python docstrings** (`compat.py:3`,
  `tools.py` ~l.164) are KNOWN and owned by **Step 12.7.a** — do NOT fix
  ad-hoc in Tasks 10–11.
- **Test infra:** `test/support/config_reset.rb` (`ConfigReset.reset_all!`).
  Python uses pytest with `mock_send_command` / `mock_ctx` fixtures
  (`tests/test_tools.py`).
- **Reviewer panel (for any external review round):** `codex-executor`
  (gpt-5.5, xhigh) — works. `ccs-executor / albb-deepseek` (DeepSeek-V4 Pro,
  1M) — works. `ccs-executor / albb-kimi` — works. `ccs-executor / glm`,
  `albb-qwen` — fail (upstream). `albb-glm` — skip per user preference.
- **/do-plan threshold config** lives at
  `~/.claude/state/do-plan-config--opt-github-zinin-sketchup-mcp2.json`
  (`{"stop_threshold": 250000}`). Override with `/do-plan 400k` (≥150k). Task
  12 is LARGE; consider `/do-plan 400k` if you want 11+12 in one session.
  A 250k session this time got through Task 9 + full two-stage review + the
  Task 10 investigation/escalation, then paused at the Task 9/10 boundary.

## PLAN QUALITY WARNING

The plan was hardened across 2 review iterations + spec-review-during-execution,
and Tasks 1–9 executed cleanly against it. It is rigorous but NOT bulletproof
for the remaining tasks (Task 10's extension.json defect is proof):

- **STOP at the first plan step that doesn't match observed codebase state.**
- **STOP at any sed/Edit anchor that doesn't apply cleanly.**
- **Do not silently work around plan issues** — describe the problem, explain
  why the plan doesn't fit, and ask how to proceed.

## INSTRUCTIONS

1. Read the 4 documents listed in «DOCUMENTS» (design, plan, iter-1, iter-2).
2. Optionally `git show 704d0e5 -s` (Task 9) for the most recent context.
3. Summarise current state in ≤6 lines.
4. **STOP and WAIT** — do NOT start anything.
5. Ask the user what to do. The natural next step is `/do-plan` (resumes via
   `superpowers:subagent-driven-development` at Task 10 — apply the TASK 10
   RESOLUTION above), but the user may want a manual review, a higher
   threshold, or something else.
