# Continue Plan — Warehouse Resubmit v0.2.0 (after Task 1)

## TASK

Continue executing the implementation plan for the SketchUp extension
warehouse re-submission (v0.2.0). Task 1 (mechanical rename) is fully
closed; Tasks 2–14 remain. Execute via `superpowers:subagent-driven-development`
with `/do-plan` (default STOP threshold 250k tokens) or pause-and-resume
via `/pause-after-current-task` / `/continue-plan-fresh-session` as
needed.

## CRITICAL: DO NOT START WORKING

**STOP. READ THIS CAREFULLY.**

After loading all context below, you MUST:

1. Read the documents and understand the context.
2. Report what you understood (brief summary ≤6 lines).
3. **WAIT for explicit user instructions** before taking ANY action.

**DO NOT:**

- Start dispatching Task 2 (or any task).
- Make any code or document changes.
- Run any commands except reading documents and `git log`/`git status`.

**The user will tell you exactly what to do.** Until then, only read,
summarise, and ask.

## DOCUMENTS

Read in this order:

1. **Design (post-iter-2 final):** `docs/superpowers/specs/2026-05-28-warehouse-resubmit-design.md` (~332 lines)
2. **Plan (post-Task-1 trim):** `docs/superpowers/plans/2026-05-28-warehouse-resubmit.md` (~3224 lines after trimming Task 1)
3. **Iter-1 decisions log:** `docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-iter-1.md`
4. **Iter-2 decisions log:** `docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-iter-2.md`

`docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-merged-iter-2.md`
is the raw reviewer panel output (input to iter-2 round 1+2 fixes);
already digested — read only if you need to look up a specific finding.

## STATE OF THE REPO

**Branch:** `feature/warehouse-resubmit`
**HEAD:** `41603e0 docs: trim completed tasks from plan for warehouse-resubmit`

```
41603e0  docs: trim completed tasks from plan for warehouse-resubmit
dd2d7db  docs(plan): add Step 12.7.a — sweep Ruby/Python source path comments
4415dfd  refactor: rename SU_MCP → MCPforSketchUp + filesystem prefix      [Task 1]
795328c  docs: review iter 2 — round 2 fixes + decisions log               [iter-2 finish]
644d193  docs: review iter 2 — partial auto-fixes round 1
a0337fc  docs: review iter 1 — decisions + log
2f56d7a  docs: review iter 1 — auto-fixes
ce80b45  docs: review iter 1 — CRITICAL-1 plan tests (sentinel-nil)
fadb746  docs: review iter 1 — partial auto-fixes (design + handoff)
0f7d635  docs(plan): warehouse resubmit implementation plan (v0.2.0)
119da49  docs(spec): warehouse resubmit design (v0.2.0)
```

**Working tree:** clean of tracked-file modifications. The many
untracked files (session-transfer docs, `.gemini/`, `diff.patch`, other
superpowers plans/specs, this continuation prompt file) are
pre-existing — **do NOT stage them.** Use explicit `git add <path>` per
iter-1 CONCERN-7 commit policy.

**Tests last seen:** Ruby `242 runs / 553 assertions / 0 failures / 0 errors`;
Python `120 passed`. Both should remain green throughout subsequent tasks.

## PROGRESS

### ✅ Completed

- [x] **Task 1: Mechanical rename (filesystem + module + paths)** — commits
      `4415dfd` (implementation) + `dd2d7db` (Step 12.7.a plan-fix follow-up
      addressing iter-2 spec-review gap).
      - su_mcp/ → mcp_for_sketchup/ (top dir, loader, ext subfolder).
      - SU_MCP → MCPforSketchUp in 26 Ruby files.
      - test/ paths updated in 19 files.
      - extension.json name/product_id/description fixed.
      - package.rb EXTENSION_NAME, loader display name, Config SECTION literal.
      - **Concerns documented + deferred:**
        - `mcp_for_sketchup/package.rb` lines 20/22/23 still reference `'su_mcp'` —
          Task 10 rewrites the entire file (deliberate).
        - ~25 Ruby header comments `# su_mcp/su_mcp/...` + 2 Python docstrings
          still contain `su_mcp/su_mcp/` substrings — closed by the new
          **Step 12.7.a** (added in commit `dd2d7db`), which runs a single sed
          pass before Step 12.8 strict-grep gate.

### ⏸ Remaining (Tasks 2–14, in order)

- [ ] **Task 2:** Title Case start_operation labels (10 handlers) + silent
      rescue cleanup (5 reviewer-flagged + 2 iter-1 — Geometry.safe_abort,
      ClientState#peer_label with `"unknown"` preserved verbatim).
      New `test/test_operation_names.rb` with refute_empty handlers-dir guard.
- [ ] **Task 3:** Logger `[MCPforSU]` prefix + default level WARN. Surgical
      refactor through private `_emit`, preserves `log_tool` API (8 call
      sites), DEBUG-gated `first(3)` backtrace continuation also carries
      prefix.
- [ ] **Task 4:** New Config prefs (eval_enabled sentinel-nil, log_to_file,
      log_file_path) + conditional `core/build_profile.rb` load via main.rb.
      `coerce_bool_pref` helper, non-inherited `const_defined?(:X, false)`.
      Three new test files: `test/support/config_reset.rb`,
      `test/test_build_profile_fixture.rb`, `test/test_extension_json.rb`.
- [ ] **Task 5:** Logger writes to file when `log_to_file` is on — extends
      `_emit` with `append_to_file` + `_emit_console` split. File-IO errors
      fall back silently with one-shot DEBUG line; never raise.
- [ ] **Task 6:** `eval_ruby` gate (-32010 when disabled). `saved_eval` is
      a local var (lowercase) — uppercase would be a dynamic constant.
- [ ] **Task 7:** Settings validator — accept eval_enabled, log_to_file,
      log_file_path. log_to_file=true requires non-empty path AND
      `File.directory?(parent)`.
- [ ] **Task 8:** Settings dialog HTML + Ruby on_save wire-up. Two-phase
      deferred confirm (UI.start_timer + timer-internal rescue),
      `persist_and_finalize` helper shared by normal + Yes branches,
      dialog 480/scrollable. Also `application.rb` `show_log` rewrite +
      `file_uri_for` helper with `URI::DEFAULT_PARSER.escape` (CRITICAL-3
      replaces broken `URI::File.build`). New `test/test_application_show_log.rb`
      with 3 cases (spaces / Windows drive-letter / non-ASCII).
- [ ] **Task 9:** Python `eval_ruby` — actionable error on -32010.
      `EVAL_DISABLED_CODE = -32010` in `compat.py`; `tools.py::eval_ruby`
      returns `e.message` verbatim (no `[code]` prefix) when caught;
      `prompts.py::sketchup_modeling_strategy` gets eval-gate paragraph.
- [ ] **Task 10:** `package.rb` dual-variant build (warehouse|github).
      `File.write build_profile.rb` INSIDE begin/ensure (CRITICAL-4).
      Post-build `Zip::File.open` verifies `name` + `product_id` +
      `version` from embedded extension.json (CRITICAL-8). New
      `test/test_package_default_variant.rb` shells out + Zip-content
      asserts.
- [ ] **Task 11:** Version bump to 0.2.0 in 7 canonical locations.
      Wire-protocol break: MIN_PYTHON/MIN_RUBY = MAX_* = "0.2.0".
- [ ] **Task 12:** Documentation updates (README, CLAUDE, release, cookbook).
      **⚠ Step 12.7.a is OBLIGATORY before Step 12.8** — sweeps Ruby
      file-header path comments + Python source docstrings; without it,
      the Step 12.8 strict-grep fails with ~27 leftover matches.
- [ ] **Task 13:** `examples/smoke_check.py` graceful skip on -32010.
      `sys.path.insert` wrapped in `__main__` guard (iter-2 CONCERN-5).
      `eval_skipped = [0]` mutable container (iter-2 CONCERN-12). New
      `tests/test_smoke_helpers.py`.
- [ ] **Task 14:** Final verification — Trimble intake pre-check
      (QUESTION-4), full Ruby + Python suites, build both .rbz variants,
      strict tracked-grep, Python wheel + twine check, manual SketchUp
      2026+ acceptance (11 substeps including macOS messagebox modality
      QUESTION-2 + write_default(nil) semantics SUGGESTION-4), push branch,
      open PR after manual acceptance (per global CLAUDE.md: git rm
      design+plan docs first).

## SESSION CONTEXT (knowledge not in the documents)

### Why Task 1 produced two commits

1. `4415dfd` — implementer's commit. DONE_WITH_CONCERNS. All 13 plan
   steps executed; tests green; explicit-path commit policy honoured.
2. `dd2d7db` — controller-level plan fix. The spec compliance reviewer
   found a **plan gap**: Step 1.4's word-boundary sed (`\bSU_MCP\b`,
   `\bsu_mcp_v\b`) deliberately did not rewrite path substrings like
   `su_mcp/su_mcp/...` inside Ruby header comments and Python docstrings.
   Without a sweep step, the Task 12.8 strict-grep gate would fail the
   release. Plan was patched to add Step 12.7.a (the sed pass) BEFORE
   Step 12.8. Implementer's code commit was not amended; the gap is now
   captured in the plan so Task 12 will pick it up.

### Plan quality warnings to carry forward

- **Stale baseline test counts.** Plan Step 1.1 says
  `230 runs / 516 assertions / 120 passed`; reality is
  `242 runs / 553 assertions / 120 passed`. The plan must NOT be
  trusted blindly on absolute test counts — record actual baseline per
  task and compare delta, not absolute.
- **Anchor mismatches.** If a sed/Edit anchor doesn't match the live
  file in any future task, STOP and ask the user. Per iter-1 plan-quality
  warning, the plan was hardened against the pre-rename state and may
  drift as the codebase evolves through Tasks 2+.
- **No silent workarounds.** If a plan step doesn't fit observed
  state, describe the problem + why the plan doesn't fit, and ask.
  Don't quietly invent an alternative.

### Commit policy (iter-1 CONCERN-7) — STILL ACTIVE

Always use explicit `git add <path>`. NEVER `git add -A` or `git add .`.
Each task's Files header lists the staging set. Pre-existing untracked
files (session-transfer docs, `.gemini/`, `diff.patch`, superpowers
plans/specs, continuation prompts) MUST NOT land in feature commits.

### Sed portability (iter-2 CONCERN-2) — STILL ACTIVE

`sed -i 's/.../.../g' file` is GNU syntax. On macOS BSD sed, substitute
`gsed` (brew install gnu-sed) or `sed -i.bak '...' file && rm -f
file.bak`. Linux/CI works as written. Pick one form per host when
executing.

### /do-plan threshold

The previous session ran `/do-plan` with the default 250k token STOP
threshold. The config file at
`~/.claude/state/do-plan-config--opt-github-zinin-sketchup-mcp2.json`
contains `{"stop_threshold": 250000}`. If you start with `/do-plan`
again it reads the same value. Override with `/do-plan 400k` (or any
value ≥ 150k) if you want a different ceiling.

### Reviewer panel (for any future review rounds)

- `codex-executor` (gpt-5.5, xhigh) — works.
- `ccs-executor / albb-deepseek` (DeepSeek-V4 Pro, 1M) — works.
- `ccs-executor / albb-kimi` — recovered in iter-2 (was stalled in iter-1).
- `ccs-executor / glm` — fails (upstream).
- `ccs-executor / albb-qwen` — fails (Alibaba MaaS Anthropic-bridge has
  no Qwen model id; all 9 probed ids return 400). Don't dispatch again
  until the tenant config is fixed.
- `albb-glm` — skip per global preference.

## PLAN QUALITY WARNING

The plan was hardened across 2 review iterations + 1 spec-review-during-
execution round (Step 12.7.a). It is rigorous but NOT bulletproof:

- **STOP at the first plan step that doesn't match observed codebase
  state.** Task 1 already surfaced a stale baseline; expect similar
  drift in subsequent tasks.
- **STOP at any sed/find anchor that doesn't apply cleanly.**
- **Do not silently work around plan issues.** Describe the problem,
  explain why the plan doesn't fit, ask the user how to proceed.

## INSTRUCTIONS

1. Read the 4 documents listed in the «DOCUMENTS» section (design,
   plan, iter-1 log, iter-2 log).
2. Optionally `git show 4415dfd -s --format="%H%n%s%n%n%b"` and
   `git show dd2d7db -s --format="%H%n%s%n%n%b"` for Task 1 context.
3. Summarise current state in ≤6 lines.
4. **STOP and WAIT** — do NOT start anything.
5. Ask the user what to do — the natural next step is `/do-plan` (which
   resumes via `superpowers:subagent-driven-development` starting at
   Task 2), but the user may want a manual review, an iter-3 review
   round, a different threshold, or something else entirely.
