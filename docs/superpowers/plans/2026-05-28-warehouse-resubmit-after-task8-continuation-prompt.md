# Continue Plan — Warehouse Resubmit v0.2.0 (after Task 8)

## TASK

Continue executing the implementation plan for the SketchUp extension
warehouse re-submission (v0.2.0). Tasks 1–8 are fully closed (impl +
spec review ✅ + code review ✅ each); Tasks 9–14 remain. Execute via
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

- Start dispatching Task 9 (or any task).
- Make any code or document changes.
- Run any commands except reading documents and `git log`/`git status`.

**The user will tell you exactly what to do.** Until then, only read,
summarise, and ask.

## DOCUMENTS

Read in this order:

1. **Design (post-iter-2 final):** `docs/superpowers/specs/2026-05-28-warehouse-resubmit-design.md` (~332 lines)
2. **Plan (post-Task-8 trim):** `docs/superpowers/plans/2026-05-28-warehouse-resubmit.md` (1217 lines after trimming Tasks 1–8)
3. **Iter-1 decisions log:** `docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-iter-1.md`
4. **Iter-2 decisions log:** `docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-iter-2.md`

`docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-merged-iter-2.md`
is the raw reviewer-panel output (already digested into the iter-2 log);
read only to look up a specific finding.

### Trimmed-plan line ranges (for curated, bounded dispatch)

After the Task-1–8 trim, the remaining tasks live at these line ranges
(hand the implementer ONLY its task's range, never the whole file):

- **Task 9:**  lines ~89–259  (Python −32010 routing — FIRST Python change)
- **Task 10:** lines ~261–489 (package.rb dual-variant)
- **Task 11:** lines ~491–591 (version bump 0.2.0)
- **Task 12:** lines ~593–883 (docs — LARGE)
- **Task 13:** lines ~885–1071 (smoke skip)
- **Task 14:** lines ~1073–1217 (final verification + PR)

(Re-confirm with `grep -nE '^## Task [0-9]' <plan>` before dispatching — the
numbers shift if the plan is edited again.)

## STATE OF THE REPO

**Branch:** `feature/warehouse-resubmit`
**HEAD:** `d7e80ea docs: trim completed Task 8 from plan for warehouse-resubmit`

```
d7e80ea  docs: trim completed Task 8 from plan         [this session: plan trim]
d3423c2  feat(settings): UI for eval_enabled, ...        [Task 8, amended once for code-review fixes]
9bcd327  docs: trim completed Tasks 5-7 from plan       [prior session: plan trim]
8b61156  feat(settings): validator accepts new prefs    [Task 7]
5415e31  feat(eval): gate eval_ruby behind ... (-32010)  [Task 6]
893a5a4  feat(logger): optional log-to-file mode         [Task 5]
02f7982  feat(config): new prefs + build_profile hook    [Task 4]
bb907d1  feat(logger): [MCPforSU] prefix + default WARN  [Task 3]
2cd849f  refactor: Title Case start_operation labels ...  [Task 2]
4415dfd  refactor: rename SU_MCP -> MCPforSketchUp ...     [Task 1]
```

**Working tree:** clean of tracked-file modifications. Many untracked
files (session-transfer docs, `.gemini/`, `diff.patch`, other
superpowers plans/specs, continuation prompts including this one) are
pre-existing — **do NOT stage them.** Use explicit `git add <path>` per
the iter-1 CONCERN-7 commit policy.

**Tests last seen (end of this session):** Ruby **286 runs / 676
assertions / 0 failures / 0 errors**; Python **120 passed** (Python was
NOT touched in any task so far — the FIRST Python change is Task 9). Both
must stay green.

## PROGRESS

### ✅ Completed

- [x] **Task 1: Mechanical rename** — `4415dfd` + `dd2d7db`.
- [x] **Task 2: Title Case labels + silent-rescue cleanup** — `2cd849f`.
- [x] **Task 3: Logger `[MCPforSU]` prefix + default WARN** — `bb907d1`.
- [x] **Task 4: New Config prefs + build_profile loading** — `02f7982`.
- [x] **Task 5: Logger log-to-file** — `893a5a4`.
- [x] **Task 6: eval_ruby gate (−32010)** — `5415e31`. Surgical gate in
      `handlers/eval.rb` (`EVAL_DISABLED_CODE = -32010` + frozen actionable
      message; raises `StructuredError(-32010)` when `Config.eval_enabled?`
      is false). NO dispatch.rb change — it already maps `StructuredError#code`.
- [x] **Task 7: Settings validator** — `8b61156`. Accepts the three new
      fields; `log_to_file=true` requires non-empty path AND existing parent
      dir; strict `truthy?` helper.
- [x] **Task 8: Settings dialog UI** — `d3423c2` (THIS session). See details
      below.

### ⏸ Remaining (Tasks 9–14, in order)

- [ ] **Task 9 (FIRST Python change):** Python `eval_ruby` actionable error on
      −32010. `EVAL_DISABLED_CODE = -32010` in `compat.py`; `tools.py::eval_ruby`
      returns `e.message` verbatim (no `[code]` prefix); `prompts.py` eval-gate
      paragraph; new test in `tests/test_tools.py`. **Carry-forward (Task-6
      review, STILL OPEN):** add reciprocal "mirrored in …" comments tying the
      Ruby `-32010` (`handlers/eval.rb`) and the new Python `-32010`
      (`compat.py`) together — no shared source across the socket, so a comment
      is the pragmatic anti-drift guard. NOTE: doing this means Task 9 also
      touches `handlers/eval.rb` (one comment line) — extends the plan's Python-only
      Files list; flag as an intentional controller-approved addition.
- [ ] **Task 10:** `package.rb` dual-variant build (warehouse|github).
      `File.write build_profile.rb` INSIDE begin/ensure (CRITICAL-4). Post-build
      `Zip::File.open` verifies name + product_id + version. New
      `test/test_package_default_variant.rb` (shells out + Zip-verifies
      build_profile content).
- [ ] **Task 11:** Version bump → 0.2.0 in 7 canonical locations. Wire-protocol
      break: MIN_PYTHON/MIN_RUBY = MAX_* = "0.2.0".
- [ ] **Task 12 (LARGE):** Documentation (README, CLAUDE, release, cookbook).
      **⚠ Step 12.7.a is OBLIGATORY before Step 12.8** — sweeps the stale
      `# su_mcp/su_mcp/...` Ruby file-header comments + 2 Python docstrings;
      without it the Step 12.8 strict-grep fails with leftover matches.
- [ ] **Task 13:** `examples/smoke_check.py` graceful skip on −32010.
      `sys.path.insert` in `__main__` guard (CONCERN-5); `eval_skipped = [0]`
      mutable container (CONCERN-12). New `tests/test_smoke_helpers.py`.
- [ ] **Task 14:** Final verification — Trimble intake pre-check (QUESTION-4),
      full Ruby + Python suites, build both .rbz variants, strict tracked-grep,
      Python wheel + twine, manual SketchUp 2026+ acceptance (11 substeps),
      push branch, open PR after manual acceptance (per global CLAUDE.md:
      `git rm` design+plan docs first).

## SESSION CONTEXT (knowledge not in the documents)

### How this session ran (Task 8 only)

Executed via `/do-plan` (250k threshold) → `superpowers:subagent-driven-development`,
**Opus for every subagent**. Task 8 was the designated LARGE task; it consumed
the whole session. STOP (ctx:250k) fired exactly as Task 8 reached its clean
checkpoint, and the controller paused proactively at the Task 8/9 boundary
(Task 9 NOT started, no code touched).

### Task 8 — what was built (commit `d3423c2`, one commit, amended once)

- `ui/settings.html`: near-full rewrite (line 1 is `<!DOCTYPE html>`, no stale
  header). Three sections (Network / Logging / Ruby Evaluation), three new
  fields (`log_to_file` checkbox, `log_file_path` text, `eval_enabled` checkbox
  + DANGEROUS warning), full JS wiring (clearErrors/isDirty/applyState/savedState/
  payload/listeners for all six fields). Preserved the port `type="text"`
  comment and the `(incl. eval_ruby)` host-security wording.
- `ui/settings_dialog.rb`: `DIALOG_TITLE`, `scrollable: true`/`height: 480`,
  `load_state_payload` helper (uses `Config.eval_enabled?`, NOT raw accessor —
  iter-1 CRITICAL-2), two-phase deferred eval-confirm `on_save` (off→on only),
  `persist_and_finalize` (shared finalizer, `private_class_method`),
  `confirm_eval_enable`, and an extracted `report_general_error(dialog, e, tag:,
  revert:)` helper (added during code-review fixes to dedupe the two `_general`
  rescue blocks). `js_safe_json` untouched. **Stale line-1 header untouched.**
- `core/application.rb`: `require "uri"` added as line 2 (AFTER the stale line-1
  header, before `module`), `show_log` rewrite (opens log file via
  `file_uri_for` + `UI.openURL` when log-to-file active & file exists, else
  `SKETCHUP_CONSOLE`), `file_uri_for` helper (`URI::DEFAULT_PARSER.escape`, NOT
  `URI::File.build`; `private_class_method`). **Stale line-1 header untouched.**
- `test/test_application_show_log.rb` (NEW): 3 `file_uri_for` tests.
- `test/test_settings_dialog.rb` (extended in the fix round): 2 new
  `load_state_payload` tests (the eval_enabled?-not-raw guarantee is
  mutation-verified by the code reviewer).

Ruby suite grew 281 → **286 runs / 676 assertions / 0F / 0E**.

### Task 8 review cycle (worth knowing for future tasks)

- **Spec review:** ✅ all 28 spec items verified by reading code (stale headers
  untouched, no scope creep).
- **Code review:** first pass **CHANGES REQUESTED** — 0 Critical, 2 Important
  (1: eval-decline message misleadingly implied only eval was affected when the
  whole Save batch is discarded per spec §4.3 "do NOT persist"; 2: duplicated
  `_general` rescue blocks). Controller decision: rejected the reviewer's
  "persist non-eval fields" option as spec-contradicting; applied option (b)
  message clarification (`'Cancelled — no settings were saved (Ruby evaluation
  remains disabled)'`) + extracted `report_general_error`. Applied recommended
  Minors (comment-accuracy fix, a `load_state_payload` test, an anti-drift
  comment); skipped Minor 5 (sentinel-nil pinned on first save) as by-design
  (reviewer said flag-only). Re-review: ✅ APPROVED (behavior-preservation +
  mutation test confirmed).
- **Fix mechanism:** re-dispatched the SAME implementer via `SendMessage`
  (resume by `agentId` — the agent is NOT addressable by name once it
  completes; use the `agentId` from its spawn result) + `git commit --amend
  --no-edit`, so Task 8 stayed exactly ONE commit.

### ⭐ The "surgical edit, NOT whole-file replace" pattern (recurring — carry forward)

Several plan steps phrase a change as "Replace `<file>` with [full block]".
Taken literally those blocks silently DROP (a) the stale
`# su_mcp/su_mcp/<path>.rb` line-1 header comments — KNOWN and owned by Step
12.7.a — and (b) useful explanatory comments. Tasks 6/7/8 were all applied as
surgical edits; the controller pre-verified anchors against the live files and
instructed the implementer accordingly, and reviewers confirmed the deviations
were intentional. **Task 9 is Python** (no `su_mcp` line-1 headers in the
target files — but `compat.py:3` and `tools.py` near line 164 carry the two
KNOWN stale `su_mcp/su_mcp/...` docstring references owned by Step 12.7.a; do
NOT fix them in Task 9). For Tasks 9–11 in general: keep edits additive,
preserve existing comments, do not touch the deferred stale headers/docstrings.

### 🎁 Task 9 pre-verification (DO THIS before dispatching — not done yet this session)

The plan's Step 9.3 rewrites `src/sketchup_mcp/tools.py::eval_ruby`. Read the
LIVE files first and confirm these anchors (the plan assumes a specific
structure that has NOT been re-verified against the current code this session):

- `src/sketchup_mcp/tools.py`: the current `eval_ruby` wrapper body (plan says
  it's currently a one-line `_call(ctx, "eval_ruby", code=code)`), and whether
  `_raw_call`, `_call`, `format_error`, `config` (for `config.LOG_LEVEL`),
  `SketchUpError`, `ConnectionError`, `json`, `Annotated`/`Field` are all
  imported/available. Confirm whether a `_EVAL_DISABLED_CODE` already exists
  (the plan replaces it with `from sketchup_mcp.compat import EVAL_DISABLED_CODE`).
- `src/sketchup_mcp/compat.py`: where the version constants are (add
  `EVAL_DISABLED_CODE = -32010` after them) + the existing stale
  `su_mcp/su_mcp/core/compat.rb` docstring reference (leave it; Step 12.7.a).
- `src/sketchup_mcp/prompts.py`: the structure of `sketchup_modeling_strategy`
  (where to append the short eval-gate paragraph; Step 9.5.a).
- `tests/test_tools.py`: the existing `test_eval_ruby_no_longer_returns_old_success_wrapper`
  (Step 9.6 says it uses `-32000`, unaffected) and the `mock_send_command` /
  `mock_ctx` fixtures the new test relies on.
- `mcp_for_sketchup/mcp_for_sketchup/handlers/eval.rb`: where `EVAL_DISABLED_CODE`
  lives (Task 6, `5415e31`) — for the reciprocal "mirrored in compat.py" comment
  carry-forward.

### Plan-quality warnings (STILL ACTIVE — carry forward)

- **Stale absolute test counts.** The plan's per-task baseline numbers are
  unreliable. Record the actual baseline before each task and compare the DELTA.
  Current baseline: Ruby **286 / 676**; Python **120**.
- **Anchor drift → STOP and ask.** If any sed/Edit anchor (line number OR
  before-string) doesn't match the live file, STOP and surface it — don't invent
  a workaround.
- **No silent workarounds.** If a plan step doesn't fit observed state, describe
  the mismatch + why, and ask.
- **Controller-curated dispatch worked well:** before each dispatch, pre-verify
  the task's risky anchors yourself (read the live files), then hand the
  implementer the precise findings + the bounded plan line-range (NOT the whole
  plan).

### Commit policy (iter-1 CONCERN-7) — STILL ACTIVE

Always explicit `git add <path>`. NEVER `git add -A`/`git add .`. Each task's
Files header lists the staging set. Pre-existing untracked files MUST NOT land
in feature commits. Before staging, run `git status` and confirm only the
task's files are modified.

### Sed portability (iter-2 CONCERN-2) — STILL ACTIVE

`sed -i 's/.../.../g' file` is GNU syntax. This host is **Linux** (GNU sed
works as written). Relevant in Task 12 (12.1/12.7/12.7.a).

### Known-and-deferred: stale `# su_mcp/...` header comments / docstrings

Several Ruby files (and 2 Python docstrings: `compat.py:3`, `tools.py` ~164)
still carry `# su_mcp/su_mcp/...` path references from before the Task-1 rename.
These are KNOWN and deliberately owned by **Step 12.7.a (Task 12)**, which
sed-sweeps them before the Step 12.8 strict-grep gate. **Do NOT fix them ad-hoc
in Tasks 9–11** — it would widen those tasks' diffs and desync 12.7.a's count.
(Task 8 left `application.rb` and `settings_dialog.rb` line-1 headers stale on
purpose; `require "uri"` went on line 2.)

### Test infra available

`test/support/config_reset.rb` defines `ConfigReset.reset_all!` (nils all 6
Config accessors). Used by `test_config.rb`, `test_logger.rb`,
`test_application.rb`, and now the new `load_state_payload` tests in
`test_settings_dialog.rb`. Python tests use pytest with `mock_send_command` /
`mock_ctx` fixtures (see `tests/test_tools.py`).

### Reviewer panel (for any future review rounds)

- `codex-executor` (gpt-5.5, xhigh) — works.
- `ccs-executor / albb-deepseek` (DeepSeek-V4 Pro, 1M) — works.
- `ccs-executor / albb-kimi` — works.
- `ccs-executor / glm` — fails (upstream). `ccs-executor / albb-qwen` — fails
  (no Qwen model id on the tenant). `albb-glm` — skip per user preference.

### /do-plan threshold

Config at `~/.claude/state/do-plan-config--opt-github-zinin-sketchup-mcp2.json`
holds `{"stop_threshold": 250000}`. `/do-plan` re-reads it; override with
`/do-plan 400k` (≥150k) for a different ceiling. Remaining tasks 9–11 and 13 are
small–medium; Task 12 is LARGE (docs, ~290 plan lines). A 250k session got
through one LARGE task (Task 8) plus its full two-stage review + fix cycle. For
the next session, default 250k likely covers Tasks 9–11 (and maybe part of 12);
consider `/do-plan 400k` if you want Task 12 to complete in one session.

## PLAN QUALITY WARNING

The plan was hardened across 2 review iterations + spec-review-during-execution,
and Tasks 1–8 executed cleanly against it. It is rigorous but NOT bulletproof
for the remaining tasks:

- **STOP at the first plan step that doesn't match observed codebase state.**
- **STOP at any sed/Edit anchor that doesn't apply cleanly.**
- **Do not silently work around plan issues** — describe the problem, explain
  why the plan doesn't fit, and ask how to proceed.

## INSTRUCTIONS

1. Read the 4 documents listed in «DOCUMENTS» (design, plan, iter-1, iter-2).
2. Optionally `git show d3423c2 -s` (Task 8) or `git show 5415e31 -s` (Task 6)
   for the most recent context.
3. Summarise current state in ≤6 lines.
4. **STOP and WAIT** — do NOT start anything.
5. Ask the user what to do. The natural next step is `/do-plan` (resumes via
   `superpowers:subagent-driven-development` at Task 9), but the user may want a
   manual review, a higher threshold, an iter-3 review round, or something else.
