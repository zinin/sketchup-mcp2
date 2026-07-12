# Continuation: Iter-1 Auto-Fixes for Warehouse-Resubmit v0.2.0

## TASK

Continue iteration 1 of the external design review for the **warehouse-resubmit v0.2.0** project. Resume by applying the remaining auto-fixes catalogued in the iter-1 handoff document, then complete Steps 11–14 of the `superpowers:review-design-external-iterative` skill (commit auto-fixes, discuss 2 disputed items one-at-a-time, generate iter-1 file, final commit).

## CRITICAL: DO NOT START WORKING

**STOP. READ THIS CAREFULLY.**

After loading all context below, you MUST:
1. Read the documents and understand the context
2. Report what you understood (brief summary)
3. **WAIT for explicit user instructions** before taking ANY action

**DO NOT:**
- Start applying patches
- Make any code changes
- Run any commands (except reading documents)
- Assume what work to start on next

**The user will tell you exactly what to do.** Until then, only read and summarize.

## DOCUMENTS (read in this order)

1. **Handoff doc with verbatim patches:** `docs/superpowers/plans/2026-05-28-warehouse-resubmit-iter1-remaining-fixes.md`
   This is the PRIMARY working spec. It enumerates every remaining auto-fix with the exact code/text to apply. Each row's status column shows whether design and/or plan still need patching.

2. **Design (already partially patched):** `docs/superpowers/specs/2026-05-28-warehouse-resubmit-design.md`
   Section §4.2 (sentinel-nil mechanism), §4.3 (two-phase confirm flow), §5.1 (prefix in shared write), §5.2 (validator parent-dir check), §5.3 (URI::File.build for show_log), §7 (silent rescue table — 2 more rows added) are already updated. Do NOT re-edit these.

3. **Plan (partially patched):** `docs/superpowers/plans/2026-05-28-warehouse-resubmit.md`
   The preamble «Architecture» line has been rewritten (CRITICAL-7 fix). Step 4.1 tests have been updated for the sentinel-nil mechanism (CRITICAL-1 partial: tests done, but Step 4.3(a) DEFAULTS hash and Step 4.3(c) `load_from_defaults!` body still hold `false`/`!!raw_eval` and need patching per handoff doc). Everything else in the plan is still pre-iter-1.

4. **Merged review (reference, do NOT edit):** `docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-merged-iter-1.md`
   Full output from the 3 contributing reviewers (codex full, ccs-glm summary extracted from raw.jsonl, albb-deepseek full). albb-kimi and albb-qwen failed and are noted at the top.

## STATE OF THE REPO

**Branch:** `feature/warehouse-resubmit`

**Iter-1 commits already made (DO NOT revert):**
- `fadb746` — `docs: review iter 1 — partial auto-fixes (design + handoff)` (6 design-tier fixes + merged review file + this handoff doc + remaining-fixes doc)
- `ce80b45` — `docs: review iter 1 — CRITICAL-1 plan tests (sentinel-nil)` (Step 4.1 test edits in plan)

**Prior branch commits (untouched in iter-1):**
- `0f7d635` — `docs(plan): warehouse resubmit implementation plan (v0.2.0)`
- `119da49` — `docs(spec): warehouse resubmit design (v0.2.0)`

**Working tree:** clean.

## REMAINING WORK (per skill steps)

### Step 10 (auto-fix application) — 23 plan-tier patches remaining

The handoff doc has verbatim patches for ALL of these. Apply in order; group related edits in a single message when efficient. Status table from the handoff doc:

| # | Where | Patch summary |
|---|---|---|
| CRITICAL-1 | plan §4.3 (a)(c) + StubReader | DEFAULTS `nil`, `load_from_defaults!` sentinel-preserving body |
| CRITICAL-2 | plan Step 8.2 | `on_load_state` uses `Config.eval_enabled?` |
| CRITICAL-3 | plan Step 8.1 (HTML) + Step 8.2 (Ruby) | two-phase `UI.start_timer` confirm + `<div id="eval_enabled-error">` + `clearErrors` array fix + `applyState(previous)` on No |
| CRITICAL-4 | plan Step 13.2-13.3 | `_maybe_skip_eval` catches `SketchUpError(code=-32010)` not text |
| CRITICAL-5 | plan Steps 1.4 / 1.6 / 12.4 / 12.8 | extend sed for lowercase `su_mcp` + add `test/run_all.rb` to rename + replace CLAUDE.md sed with manual Edits + strict verification grep |
| CRITICAL-6 | plan Step 10.2 | `begin/ensure` around package.rb body |
| CRITICAL-8 | plan Step 6.1 | rename `SU_MCP_save_eval` → `saved_eval`; add `require_relative .../helpers/validation` and `.../handlers/eval` to test requires |
| CONCERN-1 | plan Step 3.3 | refactor Logger: `_emit` private helper shared by `log()` and `log_error()` (backtrace prefix) |
| CONCERN-2 | plan Task 2 | add Steps 2.11.a (`Geometry.safe_abort`) and 2.11.b (`ClientState#peer_label`) |
| CONCERN-3 | plan Step 12.6 | rewrite EW section in release.md (signed-via-Trimble) |
| CONCERN-4 | plan Task 8 | dialog `height: 480`, `scrollable: true` |
| CONCERN-5 | plan Step 7.3 + Step 8.3 | validator: parent-dir-exists check; `show_log`: `URI::File.build` |
| CONCERN-7 | plan all commit steps (14×) | replace `git add -A` with explicit paths per task |
| CONCERN-8 | plan Step 1.4 | word-boundary `\bSU_MCP\b` + pre-sed verification grep |
| CONCERN-9 | plan new test helper | `test/support/config_reset.rb` + use in setup of test_config/test_logger/test_application |
| CONCERN-10 | plan Task 4 | back-compat smoke test (3-arg `update!`) |
| SUGGESTION-1 | plan Task 9 Step 9.3 | `EVAL_DISABLED_CODE` constant in `compat.py`; import into `tools.py` |
| SUGGESTION-2 | plan new test | `test/test_build_profile_fixture.rb` with monkeypatched BuildProfile |
| SUGGESTION-3 | plan Task 10 | post-build `extension.json` assertion in `package.rb` |
| SUGGESTION-4 | plan Step 12.8 | tracked-grep script (5 patterns, strict exit 1) |
| SUGGESTION-5 | plan multiple | 5 real-contract tests (BuildProfile, raw smoke skip, logger backtrace, default variant, explicit pref) |
| SUGGESTION-6 | plan Step 2.1 | `refute_empty files` in `test_operation_names.rb` |
| SUGGESTION-7 | plan Step 12.4 | replace sed with manual Edit operations for `CLAUDE.md` (overlap with CRITICAL-5) |
| QUESTION-1 | plan Step 12.6 | (overlap with CONCERN-3) |
| QUESTION-3 | plan Step 14.7 | add «clear eval_enabled pref» substep (`Sketchup.write_default("MCPforSketchUp", "eval_enabled", nil)`) |
| QUESTION-4 | plan Task 14 new Step 14.0 | Trimble intake form pre-check |
| QUESTION-5 | plan Step 11.9 | check `git ls-files uv.lock` and branch the lockfile regen accordingly |
| QUESTION-6 | plan Step 1.9 | note that `description` capitalization is intentional |
| QUESTION-7 | (baked into CRITICAL-1 test additions already in plan Step 4.1) | done |

(Total 23 remaining. CRITICAL-7 and CONCERN-1/2/5/QUESTION-7 already handled in design tier; QUESTION-7 verification test is in Step 4.1 already.)

### Step 11 (commit auto-fixes)

After ALL 23 plan-tier patches are applied:

```bash
git add docs/superpowers/specs/2026-05-28-warehouse-resubmit-design.md \
        docs/superpowers/plans/2026-05-28-warehouse-resubmit.md
git commit -m "docs: review iter 1 — auto-fixes (warehouse-resubmit)"
```

(Do not include the handoff doc or merged review in this commit; they are already committed.)

### Step 12 (discuss DISPUTED — one at a time, structured analysis)

Two items remain for user discussion. For EACH, follow skill Step 12 protocol: write Суть → Анализ → Варианты (with Плюсы/Минусы) → Рекомендация, then either auto-apply (if only one option adequate) or ask via AskUserQuestion. Process strictly one at a time, separate messages.

1. **CONCERN-6 — Test approach for Title Case operation labels.**
   - Option A: keep current plan (regex parsing of handler source files in `test_operation_names.rb`) — robust to refactor of handler internals, but doesn't actually verify `start_operation` is called.
   - Option B: implement design-promised mock `start_operation` recorder — `MockModel` records args, tests invoke real handler methods and assert recorded labels. Matches design §6 intent; verifies behavior, not source-text presence.
   - Option C: hybrid — keep regex guard AND add mock-recorder integration tests.
   - Recommendation depends on user preference for design-fidelity vs implementation pragmatism.

2. **QUESTION-2 — Mention eval-gate in `src/sketchup_mcp/prompts.py`?**
   - Option A: add short block to `sketchup_modeling_strategy` prompt mentioning that `eval_ruby` may return `-32010` and instructing the LLM to surface the message verbatim — minor prompt-bloat, but better UX for warehouse-variant users.
   - Option B: leave prompt unchanged — Python tool wrapper already returns actionable text and any reasonable LLM will pass it through.
   - Option C: defer to a follow-up issue after re-submission.

### Step 13 (generate iter-1 file)

Create `docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-iter-1.md` per skill format with:
- Source list (DESIGN_PATH, PLAN_PATH, agents, merged path)
- All 32 issues (30 AUTO + 2 DISPUTED) with their statuses, answers, actions
- Document-changes table
- Stats: 30 auto-fixed (29 mechanical + 1 partial pre-existing), 2 discussed with user (or auto-applied after analysis if so), 0 dismissed, 0 repeats, agents = codex + ccs-glm-partial + albb-deepseek

### Step 14 (final commit)

```bash
git add docs/superpowers/specs/2026-05-28-warehouse-resubmit-design.md \
        docs/superpowers/plans/2026-05-28-warehouse-resubmit.md \
        docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-iter-1.md
git commit -m "docs: review iter 1 — decisions + log (warehouse-resubmit)"
```

(Merged review file is already committed.)

### Step 15 (next-step prompt)

After commit, ask the user via AskUserQuestion: новая итерация (fresh session) vs остановиться и начать работу (fresh session).

## SESSION CONTEXT — KNOWLEDGE NOT IN THE DOCUMENTS

### Reviewer status (iter-1)

- **codex-executor** (gpt-5.5, xhigh) — completed, full review at `~/.claude/codex-interaction/2026-05-28-14-32-03-439714-design-review-warehouse-resubmit-iter-1-codex/output.txt` (already in merged file).
- **ccs-executor / glm** — upstream stream dropped at 14:42 mid-summary; structured findings extracted from `raw.jsonl` thinking blocks; the agent itself confirmed the model never reached the response-composition phase. The summary section IS authoritative (it lists the 31 numbered body items but the model's own summary reclassifies most of them).
- **ccs-executor / albb-deepseek** (DeepSeek-V4 Pro 1M) — completed, full review at `~/.claude/ccs-interaction/2026-05-28-14-33-07-441077-design-review-warehouse-resubmit-iter-1-albb-deepseek/output.txt`.
- **ccs-executor / albb-kimi** — failed silently after 43 tool calls; no `result` event, no assistant text. Likely upstream timeout. Confirmed via background SendMessage after the fact.
- **ccs-executor / albb-qwen** — API error 400 «Model not exist» (profile's `qwen3.7-max[1m]` not on the Alibaba MaaS endpoint). Profile config in `~/.ccs/albb-qwen.settings.json` needs the model id updated before this profile becomes usable again.

User instruction for iter-1 was: «albb-glm не запускай» (skip albb-glm specifically). Iter-1 used default agent set minus albb-glm.

### Critical design-decision recap (do not relitigate)

- Naming: «MCP Server for SketchUp» neutral form; module `MCPforSketchUp`; SECTION `"MCPforSketchUp"`; product_id `MCP_FOR_SKETCHUP`.
- eval_ruby: disabled-by-default in warehouse, enabled-by-default in github; NO per-call confirmation (breaks LLM workflows); Python `-32010` returns actionable text not exception.
- Logging: WARN default, `[MCPforSU]` prefix, optional log-to-file under `Dir.tmpdir/mcp_for_sketchup.log`.
- No migration code (v0.1.0 treated as never-shipped).
- Wire-protocol: contract unchanged but version handshake floors bump to 0.2.0 (breaking; intentional).

### Why context exhausted

Applying 30 patches across two ~2.5k-line documents requires ~3-5k context per patch (read surrounding text + edit). Initial parallel review dispatch + extraction + merge + parse already consumed ~150k. Design tier (6 patches) finished at ~225k. Plan tier (24 patches) requires ~70-100k that wasn't available. Fresh session starts at baseline + just enough to load the 3 main docs (~40-50k), leaving headroom for ~40-50 edits — sufficient for the 23 remaining.

### Mechanical gotchas to watch in fresh session

- `git add -A` is risky — repo has many untracked files (session-transfer docs, `.gemini/`, `diff.patch`). CONCERN-7 fix is precisely to replace this; do not commit with `-A` while applying that fix.
- The handoff doc's patches use exact strings from the plan; if a prior auto-fix edits adjacent context, later patches' `old_string` may no longer match — re-read narrow plan sections via Read when an Edit fails.
- CRITICAL-5 sed is in TWO places (Step 1.4 and Step 1.6); both need updating.
- SUGGESTION-7 «manual CLAUDE.md» overlaps with CRITICAL-5 — apply CRITICAL-5 first, then SUGGESTION-7 just notes «see CRITICAL-5».
- QUESTION-1 fully overlaps with CONCERN-3; treat as already covered after applying CONCERN-3.

## PLAN QUALITY WARNING

The handoff doc was written under heavy context pressure and may contain:
- Errors in exact strings (the Edit tool will fail loudly — re-read the surrounding plan section)
- Step numbering that drifts after earlier edits insert new content
- Assumptions about plan section boundaries that may have shifted

**If you notice any issues while applying patches:**
1. STOP before proceeding with the problematic patch
2. Describe what doesn't match the plan (file:line, expected vs found)
3. Ask the user how to proceed

Do NOT silently work around problems or apply patches «approximately».

## INSTRUCTIONS

1. Read the 4 documents listed at the top in order
2. Confirm understanding by reporting: the 5-6 already-applied fixes, the 23 remaining plan patches (you don't need to enumerate, just confirm location of the handoff doc), the 2 disputed items
3. **STOP and WAIT** — do NOT apply any patches
4. Ask: «С чего начать применение? Со всех 23 plan-tier auto-fixes по handoff-документу подряд, или сначала с конкретной критической группы (CRITICAL-1 plan, потом CRITICAL-2, etc.)?»
