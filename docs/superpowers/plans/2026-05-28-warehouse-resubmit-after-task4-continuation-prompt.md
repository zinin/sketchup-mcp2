# Continue Plan — Warehouse Resubmit v0.2.0 (after Task 4)

## TASK

Continue executing the implementation plan for the SketchUp extension
warehouse re-submission (v0.2.0). Tasks 1–4 are fully closed (impl +
spec review ✅ + code review ✅ each); Tasks 5–14 remain. Execute via
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

- Start dispatching Task 5 (or any task).
- Make any code or document changes.
- Run any commands except reading documents and `git log`/`git status`.

**The user will tell you exactly what to do.** Until then, only read,
summarise, and ask.

## DOCUMENTS

Read in this order:

1. **Design (post-iter-2 final):** `docs/superpowers/specs/2026-05-28-warehouse-resubmit-design.md` (~332 lines)
2. **Plan (post-Task-4 trim):** `docs/superpowers/plans/2026-05-28-warehouse-resubmit.md` (~2262 lines after trimming Tasks 1–4)
3. **Iter-1 decisions log:** `docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-iter-1.md`
4. **Iter-2 decisions log:** `docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-iter-2.md`

`docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-merged-iter-2.md`
is the raw reviewer-panel output (already digested into the iter-2 log);
read only to look up a specific finding.

## STATE OF THE REPO

**Branch:** `feature/warehouse-resubmit`
**HEAD:** `415e76f docs: trim completed Tasks 2-4 from plan for warehouse-resubmit`

```
415e76f  docs: trim completed Tasks 2-4 from plan          [this session: plan trim]
02f7982  feat(config): new prefs + build_profile hook       [Task 4]
bb907d1  feat(logger): [MCPforSU] prefix + default WARN      [Task 3]
2cd849f  refactor: Title Case start_operation labels ...     [Task 2]
41603e0  docs: trim completed tasks from plan                [prior session]
dd2d7db  docs(plan): add Step 12.7.a ...                     [Task 1 follow-up]
4415dfd  refactor: rename SU_MCP -> MCPforSketchUp ...        [Task 1]
```

**Working tree:** clean of tracked-file modifications. Many untracked
files (session-transfer docs, `.gemini/`, `diff.patch`, other
superpowers plans/specs, continuation prompts including this one) are
pre-existing — **do NOT stage them.** Use explicit `git add <path>` per
the iter-1 CONCERN-7 commit policy.

**Tests last seen (end of this session):** Ruby **268 runs / 624
assertions / 0 failures / 0 errors**; Python **120 passed** (Python was
NOT touched this session — first Python change is Task 9). Both must
stay green.

## PROGRESS

### ✅ Completed

- [x] **Task 1: Mechanical rename** — `4415dfd` + `dd2d7db` (prior session).
- [x] **Task 2: Title Case `start_operation` labels + silent-rescue cleanup** — `2cd849f`.
      11 label sites Title-Cased; 7 silent rescues → `rescue => e` + DEBUG log;
      new `test/test_operation_names.rb`.
- [x] **Task 3: Logger `[MCPforSU]` prefix + default level WARN** — `bb907d1`.
      `LINE_PREFIX` via new private `_emit`; `log_tool` + DEBUG-gated `first(3)`
      backtrace preserved; default `log_level` INFO→WARN.
- [x] **Task 4: New Config prefs + build_profile loading** — `02f7982`.
      sentinel-nil `eval_enabled` + `log_to_file`/`log_file_path`;
      `coerce_bool_pref`; `eval_enabled?` w/ non-inherited BuildProfile fallback;
      conditional `core/build_profile.rb` require in main.rb;
      `test/support/config_reset.rb` (`ConfigReset.reset_all!`);
      new `test_build_profile_fixture.rb` + `test_extension_json.rb`.

### ⏸ Remaining (Tasks 5–14, in order)

- [ ] **Task 5:** Logger writes to file when `log_to_file` is on. Extends
      `_emit` with `append_to_file` + `_emit_console` split. File-IO errors
      fall back silently with one-shot DEBUG line; never raise. Test asserts
      the DEBUG fallback message (iter-2 CONCERN-10).
- [ ] **Task 6:** `eval_ruby` gate (-32010 when disabled). `saved_eval` is a
      local var (lowercase — uppercase = dynamic constant error).
- [ ] **Task 7:** Settings validator — accept eval_enabled, log_to_file,
      log_file_path. `log_to_file=true` requires non-empty path AND
      `File.directory?(parent)`. `truthy?` nil-semantics comment.
- [ ] **Task 8:** Settings dialog HTML + Ruby on_save wire-up (LARGE). Two-phase
      deferred confirm (`UI.start_timer` + timer-internal rescue),
      `persist_and_finalize` helper, dialog 480/scrollable. `application.rb`
      `show_log` rewrite + `file_uri_for` helper (`URI::DEFAULT_PARSER.escape`,
      NOT `URI::File.build`). New `test/test_application_show_log.rb` (3 cases).
- [ ] **Task 9:** Python `eval_ruby` actionable error on -32010 (FIRST Python
      change). `EVAL_DISABLED_CODE = -32010` in `compat.py`; `tools.py::eval_ruby`
      returns `e.message` verbatim; `prompts.py` gets eval-gate paragraph.
- [ ] **Task 10:** `package.rb` dual-variant build (warehouse|github).
      `File.write build_profile.rb` INSIDE begin/ensure (CRITICAL-4). Post-build
      `Zip::File.open` verifies name + product_id + version + build_profile
      content. New `test/test_package_default_variant.rb`.
- [ ] **Task 11:** Version bump → 0.2.0 in 7 canonical locations. Wire-protocol
      break: MIN_PYTHON/MIN_RUBY = MAX_* = "0.2.0".
- [ ] **Task 12:** Documentation (README, CLAUDE, release, cookbook).
      **⚠ Step 12.7.a is OBLIGATORY before Step 12.8** — sweeps the stale
      `# su_mcp/su_mcp/...` Ruby file-header comments + 2 Python docstrings;
      without it the Step 12.8 strict-grep fails with ~27 leftover matches.
- [ ] **Task 13:** `examples/smoke_check.py` graceful skip on -32010.
      `sys.path.insert` in `__main__` guard (CONCERN-5); `eval_skipped = [0]`
      mutable container (CONCERN-12). New `tests/test_smoke_helpers.py`.
- [ ] **Task 14:** Final verification — Trimble intake pre-check (QUESTION-4),
      full Ruby + Python suites, build both .rbz variants, strict tracked-grep,
      Python wheel + twine, manual SketchUp 2026+ acceptance (11 substeps),
      push branch, open PR after manual acceptance (per global CLAUDE.md:
      `git rm` design+plan docs first).

## SESSION CONTEXT (knowledge not in the documents)

### How this session ran (Tasks 2–4)

Executed via `/do-plan` (250k threshold) → `superpowers:subagent-driven-development`,
Opus for every subagent. Each task: implementer subagent → spec-compliance
review subagent → code-quality review subagent. **Every review found at most
Minor issues; all fixes were applied by re-dispatching the SAME implementer
(via SendMessage, context intact) and `git commit --amend`** — so each task is
exactly one commit. STOP fired at ctx:250k right after Task 4's implementer
returned; Task 4 was driven to a clean checkpoint (both reviews + complete)
before pausing, per `/pause-after-current-task`.

### Review findings worth carrying forward

- **Task 2 had a REAL latent bug (now fixed).** The silent-rescue cleanup
  introduced a nested `rescue StandardError => e` in `core/server.rb`
  `accept_pending_clients` that reassigned the outer `e` read by
  `Logger.log_error(..., e)` on the next line. Fixed by renaming the inner
  binding to `close_err` (and `stop_err` in `application.rb`). **Lesson:
  watch for nested `rescue => e` clobbering an outer `e`** if any later task
  adds rescues near an existing one.
- **Task 4 — 2 deferred OPTIONAL code-review minors (not applied, on purpose,**
  because they'd deviate from the plan's verbatim code): (a) `coerce_bool_pref`
  in `config.rb` calls `Logger.log` without a `defined?(Logger)` guard (unlike
  `warn_invalid_pref`) — intentional per iter-2 CONCERN-3; a one-line comment
  would help future readers. (b) `eval_enabled?` uses a 3-line guard clause that
  could be a one-liner. **Task 5 touches `config.rb`/`logger.rb` anyway** — fold
  in (a)'s comment there if convenient. Neither blocks anything.
- **Task 4 plan had a prose-vs-code discrepancy (resolved):** Step 4.5 PROSE
  says "add `core/build_profile` to LOAD_ORDER"; the CODE BLOCK (correct) uses a
  separate conditional `Sketchup.require(...) if File.exist?(...)` after the
  loop. We used the code block — `build_profile.rb` is gitignored/absent in
  dev/test, so a LOAD_ORDER entry would raise LoadError.

### Plan-quality warnings (STILL ACTIVE — carry forward)

- **Stale absolute test counts.** The plan's per-task baseline numbers and
  "expected failures" counts are unreliable (Task 4's Step 4.2 said "~8
  failures" but it was 32). **Record the actual `run_all.rb` baseline before
  each task and compare the DELTA, not absolute counts.** Current baseline:
  Ruby 268 / 624.
- **Anchor drift → STOP and ask.** If any sed/Edit anchor (line number OR
  before-string) doesn't match the live file, STOP and surface it — don't
  invent a workaround. (Anchors for Tasks 2–4 all matched, but the plan is not
  guaranteed bulletproof for Tasks 5+.)
- **No silent workarounds.** If a plan step doesn't fit observed state,
  describe the mismatch + why, and ask.
- **Controller-curated dispatch worked well:** before each dispatch, pre-verify
  the task's risky anchors yourself (read the live files), then hand the
  implementer the precise findings + the bounded plan line-range to read (NOT
  the whole plan). For big tasks (Task 8 next), this de-risking pays off.

### Commit policy (iter-1 CONCERN-7) — STILL ACTIVE

Always explicit `git add <path>`. NEVER `git add -A`/`git add .`. Each task's
Files header lists the staging set. Pre-existing untracked files MUST NOT land
in feature commits.

### Sed portability (iter-2 CONCERN-2) — STILL ACTIVE

`sed -i 's/.../.../g' file` is GNU syntax. This host is **Linux** (GNU sed
works as written). On macOS BSD sed, use `gsed` or `sed -i.bak '...' && rm -f
file.bak`. Relevant in Tasks 12 (12.1/12.7/12.7.a).

### Known-and-deferred: stale `# su_mcp/...` header comments

Several Ruby files (and 2 Python docstrings) still carry `# su_mcp/su_mcp/...`
path-header comments from before the Task-1 rename. These are KNOWN and are
deliberately owned by **Step 12.7.a (Task 12)**, which sed-sweeps them before
the Step 12.8 strict-grep gate. **Do NOT fix them ad-hoc in Tasks 5–11** — it
would just widen those tasks' diffs.

### Test infra now available

`test/support/config_reset.rb` defines `ConfigReset.reset_all!` (nils all 6
Config accessors). It's wired into `test_config.rb`, `test_logger.rb`,
`test_application.rb` setups. Future test files that touch module-level Config
state should `require_relative "support/config_reset"` and call it in `setup`.

### Reviewer panel (for any future review rounds)

- `codex-executor` (gpt-5.5, xhigh) — works.
- `ccs-executor / albb-deepseek` (DeepSeek-V4 Pro, 1M) — works.
- `ccs-executor / albb-kimi` — works (recovered in iter-2).
- `ccs-executor / glm` — fails (upstream). `ccs-executor / albb-qwen` — fails
  (no Qwen model id on the tenant). `albb-glm` — skip per user preference.

### /do-plan threshold

Config at `~/.claude/state/do-plan-config--opt-github-zinin-sketchup-mcp2.json`
holds `{"stop_threshold": 250000}`. `/do-plan` re-reads it; override with
`/do-plan 400k` (≥150k) for a different ceiling. Task 8 is large — consider a
higher ceiling if you want it to finish in one session.

## PLAN QUALITY WARNING

The plan was hardened across 2 review iterations + 1 spec-review-during-
execution round, and Tasks 1–4 executed cleanly against it. It is rigorous but
NOT bulletproof for the remaining tasks:

- **STOP at the first plan step that doesn't match observed codebase state.**
- **STOP at any sed/Edit anchor that doesn't apply cleanly.**
- **Do not silently work around plan issues** — describe the problem, explain
  why the plan doesn't fit, and ask how to proceed.

## INSTRUCTIONS

1. Read the 4 documents listed in «DOCUMENTS» (design, plan, iter-1, iter-2).
2. Optionally `git show 02f7982 -s` (Task 4) for the most recent context.
3. Summarise current state in ≤6 lines.
4. **STOP and WAIT** — do NOT start anything.
5. Ask the user what to do. The natural next step is `/do-plan` (resumes via
   `superpowers:subagent-driven-development` at Task 5), but the user may want a
   manual review, an iter-3 review round, a different threshold, or something
   else.
