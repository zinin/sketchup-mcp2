# Continue Plan — Warehouse Resubmit v0.2.0 (after Task 7)

## TASK

Continue executing the implementation plan for the SketchUp extension
warehouse re-submission (v0.2.0). Tasks 1–7 are fully closed (impl +
spec review ✅ + code review ✅ each); Tasks 8–14 remain. Execute via
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

- Start dispatching Task 8 (or any task).
- Make any code or document changes.
- Run any commands except reading documents and `git log`/`git status`.

**The user will tell you exactly what to do.** Until then, only read,
summarise, and ask.

## DOCUMENTS

Read in this order:

1. **Design (post-iter-2 final):** `docs/superpowers/specs/2026-05-28-warehouse-resubmit-design.md` (~332 lines)
2. **Plan (post-Task-7 trim):** `docs/superpowers/plans/2026-05-28-warehouse-resubmit.md` (~1767 lines after trimming Tasks 1–7)
3. **Iter-1 decisions log:** `docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-iter-1.md`
4. **Iter-2 decisions log:** `docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-iter-2.md`

`docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-merged-iter-2.md`
is the raw reviewer-panel output (already digested into the iter-2 log);
read only to look up a specific finding.

### Trimmed-plan line ranges (for curated, bounded dispatch)

After the Task-1–7 trim, the remaining tasks live at these line ranges
(hand the implementer ONLY its task's range, never the whole file):

- **Task 8:**  lines ~83–637  (Settings dialog — LARGE)
- **Task 9:**  lines ~639–809 (Python −32010 routing)
- **Task 10:** lines ~811–1039 (package.rb dual-variant)
- **Task 11:** lines ~1041–1141 (version bump 0.2.0)
- **Task 12:** lines ~1143–1433 (docs)
- **Task 13:** lines ~1435–1621 (smoke skip)
- **Task 14:** lines ~1623–1767 (final verification + PR)

(Re-confirm with `grep -nE '^## Task ' <plan>` before dispatching — the
numbers shift if the plan is edited again.)

## STATE OF THE REPO

**Branch:** `feature/warehouse-resubmit`
**HEAD:** `9bcd327 docs: trim completed Tasks 5-7 from plan for warehouse-resubmit`

```
9bcd327  docs: trim completed Tasks 5-7 from plan       [this session: plan trim]
8b61156  feat(settings): validator accepts new prefs    [Task 7, amended with +1 test]
5415e31  feat(eval): gate eval_ruby behind ... (-32010)  [Task 6]
893a5a4  feat(logger): optional log-to-file mode         [Task 5]
415e76f  docs: trim completed Tasks 2-4 from plan        [prior session]
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

**Tests last seen (end of this session):** Ruby **281 runs / 662
assertions / 0 failures / 0 errors**; Python **120 passed** (Python was
NOT touched this session — first Python change is Task 9). Both must
stay green.

## PROGRESS

### ✅ Completed

- [x] **Task 1: Mechanical rename** — `4415dfd` + `dd2d7db` (prior session).
- [x] **Task 2: Title Case labels + silent-rescue cleanup** — `2cd849f`.
- [x] **Task 3: Logger `[MCPforSU]` prefix + default WARN** — `bb907d1`.
- [x] **Task 4: New Config prefs + build_profile loading** — `02f7982`.
- [x] **Task 5: Logger log-to-file** — `893a5a4`. `_emit` split into
      `_emit_console` + `append_to_file`; IO errors fall back to console with a
      one-shot DEBUG line, never raise; 4 new `test/test_logger.rb` tests.
- [x] **Task 6: eval_ruby gate (−32010)** — `5415e31`. Surgical gate in
      `handlers/eval.rb` (`EVAL_DISABLED_CODE = -32010` + frozen actionable
      message; raises `StructuredError(-32010)` when `Config.eval_enabled?` is
      false). NO dispatch.rb change — it already maps `StructuredError#code` to
      the JSON-RPC envelope (verified `dispatch.rb:44-48`). 2 new dispatch tests.
- [x] **Task 7: Settings validator** — `8b61156`. Accepts `eval_enabled`,
      `log_to_file`, `log_file_path`; `log_to_file=true` requires non-empty path
      AND existing parent dir; strict `truthy?` helper; 7 new tests (incl. the
      parent-dir-missing failure branch added on code-review recommendation).

### ⏸ Remaining (Tasks 8–14, in order)

- [ ] **Task 8 (LARGE):** Settings dialog HTML + Ruby on_save wire-up.
      `settings.html` 3 new fields + JS; `settings_dialog.rb` two-phase deferred
      eval-confirm (`UI.start_timer(0,false)` + timer-internal rescue),
      `persist_and_finalize` helper, dialog `height: 480, scrollable: true`;
      `application.rb` `show_log` rewrite + `file_uri_for` helper
      (`URI::DEFAULT_PARSER.escape`, NOT `URI::File.build`). New
      `test/test_application_show_log.rb` (3 `file_uri_for` cases). See the
      pre-verification notes below.
- [ ] **Task 9:** Python `eval_ruby` actionable error on −32010 (FIRST Python
      change). `EVAL_DISABLED_CODE = -32010` in `compat.py`; `tools.py::eval_ruby`
      returns `e.message` verbatim (no `[code]` prefix); `prompts.py` eval-gate
      paragraph. **Carry-forward (Task-6 review):** add reciprocal "mirrored in …"
      comments tying the Ruby `-32010` (`handlers/eval.rb`) and the new Python
      `-32010` (`compat.py`) together — no shared source across the socket, so a
      comment is the pragmatic anti-drift guard.
- [ ] **Task 10:** `package.rb` dual-variant build (warehouse|github).
      `File.write build_profile.rb` INSIDE begin/ensure (CRITICAL-4). Post-build
      `Zip::File.open` verifies name + product_id + version + build_profile
      content. New `test/test_package_default_variant.rb`.
- [ ] **Task 11:** Version bump → 0.2.0 in 7 canonical locations. Wire-protocol
      break: MIN_PYTHON/MIN_RUBY = MAX_* = "0.2.0".
- [ ] **Task 12:** Documentation (README, CLAUDE, release, cookbook).
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

### How this session ran (Tasks 5–7)

Executed via `/do-plan` (250k threshold) → `superpowers:subagent-driven-development`,
**Opus for every subagent**. Each task: implementer subagent → spec-compliance
review subagent → code-quality review subagent. **Every review found at most
Minor issues; all verdicts were APPROVED.** Each task is exactly one commit.
STOP fired at ctx:250k while reading `settings_dialog.rb` for Task 8
pre-verification; paused cleanly at the Task 7/8 boundary (Task 8 NOT started,
no code touched).

### ⭐ The "surgical edit, NOT whole-file replace" pattern (recurring — carry forward)

Several plan steps phrase a change as "Replace `<file>` with [full module
block]". Taken **literally**, those blocks silently DROP:
(a) the stale `# su_mcp/su_mcp/<path>.rb` line-1 header comments — these are
KNOWN and **owned by Step 12.7.a**, which sweeps them before the Step 12.8
strict-grep; removing them early desyncs 12.7.a's documented count; and
(b) useful explanatory comments (e.g. eval.rb's `result.to_s` rationale).

**Tasks 6 and 7 were applied as surgical edits** — add ONLY the new code,
preserve the header + existing comments, keep the diff additive. The
controller (you) pre-verified this against the live files and instructed the
implementer accordingly; both spec reviewers confirmed the deviations were
intentional. **Apply the same discipline in Task 8:**
- `settings.html` (Step 8.1) is a near-full replacement — check its current
  line-1 header first; if it carries a `su_mcp` marker, preserve it.
- `settings_dialog.rb` (Step 8.2) edits are already SURGICAL in the plan
  (change DIALOG_TITLE, two constructor values, extract `load_state_payload`,
  rewrite `on_save`, add `persist_and_finalize` + `confirm_eval_enable`) — lower
  header risk, but still don't touch line 1.
- `application.rb` (Step 8.3) — surgical `show_log` rewrite + add `file_uri_for`;
  don't whole-file replace.

### 🎁 Task 8 pre-verification (already done — read `settings_dialog.rb` @ `8b61156`)

Confirmed anchors for Step 8.2 in the LIVE file:
- `DIALOG_TITLE = "MCP Server Settings"` (line 8) → change to
  `"MCP Server for SketchUp Settings"`.
- `build_dialog` constructor (lines 30–38): currently `scrollable: false`
  (line 34), `width: 380` (35), `height: 360` (36). Change to
  `scrollable: true, height: 480` (iter-1 CONCERN-4). Surgical value edits;
  both keyword args are on their own lines.
- `on_load_state` (lines 58–69): builds a 5-key state hash
  `{host, port, log_level, running, current}`. Extract `load_state_payload`
  adding `log_to_file`, `log_file_path`, and `eval_enabled:
  Config.eval_enabled?` (NOT the raw accessor — iter-1 CRITICAL-2).
- `on_save` (lines 71–129): the current body IS the baseline the plan rewrites
  (validate → `unless ok` → return; `normalized`; `current_runtime` snapshot;
  `Config.update!(host/port/log_level)` → expands to 6 fields via
  `persist_and_finalize`; `onSaveResult`; `need_restart`; deferred
  `dialog.close` + messagebox; outer rescue with `e.message…scrub("?")`).
- The Windows-quirk comment the plan references as "settings_dialog.rb:100" is
  at lines 100–107 (deferred messagebox via `::UI.start_timer(0, false)`). ✅
- `js_safe_json` (lines 137–142) exists (also escapes `</`, U+2028, U+2029).
- **STILL TO READ before dispatching Task 8** (pre-verify these yourself):
  `ui/settings.html` (Step 8.1 near-full replacement — current field IDs +
  header), `core/application.rb` (Step 8.3 — current `show_log`, whether
  `require "uri"` is already present, the menu wiring), and whether
  `test/test_application_show_log.rb` already exists.

### Review findings worth carrying forward

- **Controller judgment on Minor findings:** Task 5's code-review raised 3
  Minors that the reviewer itself marked "don't change / optional / cosmetic"
  (e.g. the "one-shot" comment wording, which is plan-verbatim and defensible) —
  these were NOT applied; the task proceeded on the APPROVED verdict. Task 7's
  code-review raised a Minor the reviewer actively recommended (an untested
  `Dir.exist?(parent)` failure branch) — this WAS applied. **Rule of thumb:**
  apply recommended/actionable Minors; don't churn an APPROVED task for cosmetics
  the reviewer said to leave.
- **Fix mechanism:** actionable review fixes were applied by re-dispatching the
  SAME implementer via `SendMessage` (context intact) + `git commit --amend`, so
  each task stays exactly one commit. (Resume a completed subagent via its
  `agentId` from the original spawn result.)
- **No latent bugs found this session** (unlike Task 2's nested-rescue clobber in
  the prior session). All three tasks were clean.

### Plan-quality warnings (STILL ACTIVE — carry forward)

- **Stale absolute test counts.** The plan's per-task baseline numbers are
  unreliable. **Record the actual `run_all.rb` baseline before each task and
  compare the DELTA.** Current baseline: Ruby **281 / 662**; Python **120**.
- **Anchor drift → STOP and ask.** If any sed/Edit anchor (line number OR
  before-string) doesn't match the live file, STOP and surface it — don't invent
  a workaround. (Anchors for Tasks 5–7 all matched.)
- **No silent workarounds.** If a plan step doesn't fit observed state, describe
  the mismatch + why, and ask.
- **Controller-curated dispatch worked well:** before each dispatch, pre-verify
  the task's risky anchors yourself (read the live files), then hand the
  implementer the precise findings + the bounded plan line-range (NOT the whole
  plan). Task 8 is LARGE — this de-risking pays off most here.

### Commit policy (iter-1 CONCERN-7) — STILL ACTIVE

Always explicit `git add <path>`. NEVER `git add -A`/`git add .`. Each task's
Files header lists the staging set. Pre-existing untracked files MUST NOT land
in feature commits. Before staging, run `git status` and confirm only the
task's files are modified.

### Sed portability (iter-2 CONCERN-2) — STILL ACTIVE

`sed -i 's/.../.../g' file` is GNU syntax. This host is **Linux** (GNU sed
works as written). On macOS BSD sed, use `gsed` or `sed -i.bak '...' && rm -f
file.bak`. Relevant in Task 12 (12.1/12.7/12.7.a).

### Known-and-deferred: stale `# su_mcp/...` header comments

Several Ruby files (and 2 Python docstrings) still carry `# su_mcp/su_mcp/...`
path-header comments from before the Task-1 rename. These are KNOWN and are
deliberately owned by **Step 12.7.a (Task 12)**, which sed-sweeps them before
the Step 12.8 strict-grep gate. **Do NOT fix them ad-hoc in Tasks 8–11** — it
would just widen those tasks' diffs and desync 12.7.a's count. See the
"surgical edit" pattern above.

### Test infra available

`test/support/config_reset.rb` defines `ConfigReset.reset_all!` (nils all 6
Config accessors). Wired into `test_config.rb`, `test_logger.rb`,
`test_application.rb` setups. Future test files that touch module-level Config
state should `require_relative "support/config_reset"` and call it in `setup`.
(`test_dispatch_post_handshake.rb` does NOT use it — its eval-gate tests
self-protect via explicit save/restore of `Config.eval_enabled`.)

### Reviewer panel (for any future review rounds)

- `codex-executor` (gpt-5.5, xhigh) — works.
- `ccs-executor / albb-deepseek` (DeepSeek-V4 Pro, 1M) — works.
- `ccs-executor / albb-kimi` — works.
- `ccs-executor / glm` — fails (upstream). `ccs-executor / albb-qwen` — fails
  (no Qwen model id on the tenant). `albb-glm` — skip per user preference.

### /do-plan threshold

Config at `~/.claude/state/do-plan-config--opt-github-zinin-sketchup-mcp2.json`
holds `{"stop_threshold": 250000}`. `/do-plan` re-reads it; override with
`/do-plan 400k` (≥150k) for a different ceiling. **Task 8 is LARGE** — a single
session at 250k got through ~2 medium tasks plus part of a third before STOP
fired. Task 8 alone (controller pre-verification of 3 files + a big implementer
dispatch + 2 reviews) may not finish under 250k; consider `/do-plan 400k` if you
want Task 8 to complete in one session.

## PLAN QUALITY WARNING

The plan was hardened across 2 review iterations + 1 spec-review-during-
execution round, and Tasks 1–7 executed cleanly against it. It is rigorous but
NOT bulletproof for the remaining tasks:

- **STOP at the first plan step that doesn't match observed codebase state.**
- **STOP at any sed/Edit anchor that doesn't apply cleanly.**
- **Do not silently work around plan issues** — describe the problem, explain
  why the plan doesn't fit, and ask how to proceed.

## INSTRUCTIONS

1. Read the 4 documents listed in «DOCUMENTS» (design, plan, iter-1, iter-2).
2. Optionally `git show 8b61156 -s` (Task 7) or `git show 5415e31 -s` (Task 6)
   for the most recent context.
3. Summarise current state in ≤6 lines.
4. **STOP and WAIT** — do NOT start anything.
5. Ask the user what to do. The natural next step is `/do-plan` (resumes via
   `superpowers:subagent-driven-development` at Task 8), but the user may want a
   manual review, a higher threshold (`/do-plan 400k` for the large Task 8), an
   iter-3 review round, or something else.
