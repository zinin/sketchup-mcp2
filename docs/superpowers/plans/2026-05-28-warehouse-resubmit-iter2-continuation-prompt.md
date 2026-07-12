# Continuation: Iter-2 External Design Review for Warehouse-Resubmit v0.2.0

## TASK

Run iteration 2 of the external design review for the **warehouse-resubmit v0.2.0** project using the `superpowers:review-design-external-iterative` skill. Iter-1 is already complete on this branch; the skill will auto-load the iter-1 decisions table and filter duplicate findings.

## CRITICAL: DO NOT START WORKING

**STOP. READ THIS CAREFULLY.**

After loading all context below, you MUST:
1. Read the documents and understand the context
2. Report what you understood (brief summary)
3. **WAIT for explicit user instructions** before taking ANY action

**DO NOT:**
- Dispatch any reviewer agents (codex/ccs/gemini/ollama) yet
- Make any document edits
- Run any commands (except reading documents)
- Assume the user wants to run iter-2 immediately

**The user will tell you exactly what to do.** Until then, only read and summarize.

## DOCUMENTS (read in this order)

1. **Iter-1 decision log (PRIMARY reference for skip-list):** `docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-iter-1.md` — 32 issues with their resolutions. Skill Step 3 builds PREVIOUS_DECISIONS from this; iter-2 reviewers will receive it as filter input.

2. **Design (current state, iter-1 patched):** `docs/superpowers/specs/2026-05-28-warehouse-resubmit-design.md` — what reviewers will critique. Key sections changed in iter-1: §4.2 sentinel-nil mechanism, §4.3 two-phase confirm, §5.1 prefix in shared write, §5.2 validator parent-dir, §5.3 URI::File.build, §6 regex-parser test guard decision, §7 silent-rescue table extended.

3. **Plan (current state, iter-1 patched):** `docs/superpowers/plans/2026-05-28-warehouse-resubmit.md` — Architecture preamble; Commit policy preamble; Steps 1.4/1.6/12.4/12.8 (rename + grep); Step 1.9 (capitalization note); Step 2.1 (refute_empty + test_operation_names); Steps 2.11.a/b (Geometry.safe_abort + ClientState#peer_label); Step 3.3 (_emit refactor); Step 4.0 (config_reset helper); Step 4.1 (sentinel tests + back-compat + read_default round-trip); Step 4.3 (DEFAULTS nil + load_from_defaults!); Step 4.5.a (build_profile fixture); Step 5.3 (renamed write → _emit); Step 6.1 (saved_eval + requires); Step 7.3 (parent-dir check); Step 8.1 (HTML error div + clearErrors); Step 8.2 (two-phase flow + load_state_payload + dialog 480/scrollable); Step 8.3 (URI::File.build); Step 9.3 (EVAL_DISABLED_CODE); Step 9.5.a (eval-gate paragraph в prompts.py); Step 10.2 (begin/ensure + post-build extension.json verify); Step 10.6.a (default variant test); Step 11.9 (uv.lock branch); Step 12.6 (EW signed-via-Trimble rewrite); Step 13.2 (SketchUpError catch); Step 13.4.a (smoke helpers pytest); Step 14.0 (Trimble intake pre-check); Step 14.7.7a (clear eval_enabled pref); all `git add -A` → placeholders.

4. **Merged iter-1 review (reference only, do NOT edit):** `docs/superpowers/specs/2026-05-28-warehouse-resubmit-review-merged-iter-1.md` — raw output from iter-1 reviewers.

## STATE OF THE REPO

**Branch:** `feature/warehouse-resubmit`

**Iter-1 commits already made (DO NOT revert):**
- `0f7d635` — initial plan
- `119da49` — initial design
- `fadb746` — iter-1 partial auto-fixes (design + handoff + remaining-fixes + merged review)
- `ce80b45` — iter-1 CRITICAL-1 plan tests (sentinel-nil)
- `2f56d7a` — iter-1 all 23 plan-tier auto-fixes
- `a0337fc` — iter-1 decisions + log

**Working tree:** likely clean (verify with `git status --short`). Many pre-existing untracked files (session-transfer docs, `.gemini/`, `diff.patch`, other superpowers plans/specs) — do NOT stage them.

## SESSION CONTEXT — KNOWLEDGE NOT IN THE DOCUMENTS

### Iter-1 outcome (32 issues processed)

- **30 auto-fixed without discussion** (mechanical / single-obvious-fix).
- **2 auto-applied after structured analysis** (CONCERN-6, QUESTION-2) — both had only one adequate variant; presented Суть → Анализ → Варианты → Рекомендация → applied without asking user, per skill Step 12.b.
- **0 dismissed** as false positives.
- **0 discussed with user** (no genuine forks emerged).
- **1 repeat** (QUESTION-1 ⊃ CONCERN-3) — auto-answered.

### Iter-1 reviewer set (for iter-2 default)

- **codex-executor** (gpt-5.5, xhigh) — completed cleanly. Recommend keeping.
- **ccs-executor / albb-deepseek** (DeepSeek-V4 Pro, 1M context) — completed cleanly. Recommend keeping.
- **ccs-executor / glm** — partial. Stream killed by upstream before `output.txt` flushed; structured findings extracted from raw.jsonl thinking blocks. Recommend keeping (with awareness it may partial-fail again).
- **ccs-executor / albb-kimi** — silently stalled after 43 tool calls. Likely upstream timeout during generation. **Recommend skipping in iter-2** unless user wants to retry.
- **ccs-executor / albb-qwen** — API 400 «Model not exist». Profile `albb-qwen.settings.json` model id `qwen3.7-max[1m]` is invalid on the Alibaba MaaS endpoint. **Skip until profile config is updated.**
- **albb-glm** — explicitly skipped by user in iter-1. Continue skipping unless user says otherwise.

User's iter-1 instruction was «albb-glm не запускай»; assume same default in iter-2.

### Disputed-issue analysis pattern that worked in iter-1

For both CONCERN-6 and QUESTION-2, the structured analysis (Суть → Анализ → Варианты with Плюсы/Минусы → Рекомендация) revealed that only one variant was genuinely adequate — the others contradicted project constraints (CLAUDE.md invariants, design intent, ROI). In both cases auto-application was correct; user was not asked. **Apply same pattern in iter-2**: if your structured analysis converges on a single variant, announce decision + apply, don't ask. Reserve AskUserQuestion for issues with multiple genuinely-reasonable variants.

### Mechanical gotchas to watch

- Worktree carries many untracked files — every commit step in this plan now uses an explicit-path placeholder. When iter-2 generates document edits, stage only the documents being changed (design + plan + iter-2 file + merged-iter-2 file). NEVER `git add -A`.
- All `_EVAL_DISABLED_CODE = -32010` references in Python are now imported from `compat.py` as `EVAL_DISABLED_CODE`. Same constant in Ruby `handlers/eval.rb` as `EVAL_DISABLED_CODE`. If reviewers flag drift, that's a real bug — they're supposed to be the same value.
- Step 8.2 in plan now contains TWO eval-related edits: load_state_payload extraction AND two-phase deferred confirm in on_save. Reviewers may misread one without the other — context helps.

### What may resurface in iter-2 and is already-decided (autoanswer)

- «Sentinel-nil is fragile / unusual» — no. Decided in CRITICAL-1; tested explicitly by `test_read_default_sentinel_round_trip_for_eval_enabled`.
- «Why not use a config object instead of module-level Config?» — out of scope; v0.2.0 strictly mechanical-rename + new prefs. Major refactor goes to a separate spec.
- «product_id should keep SU_MCP_SERVER for continuity» — no. Trimble v0.1.0 listing is dead; new product_id is `MCP_FOR_SKETCHUP` per design §2.
- «Per-call eval_ruby confirmation» — rejected as default in design §10 (breaks LLM workflows). Could be a future opt-in pref.
- «Migration code for old SU_MCP prefs» — no. v0.1.0 treated as never-shipped (design §2).

## PLAN QUALITY WARNING (carried from iter-1)

The plan was written for a 14-task implementation. After iter-1, several edits were inserted (new steps 4.0 / 4.5.a / 9.5.a / 10.6.a / 13.4.a / 14.0) that interleave with original numbering. Step numbers within tasks may not be strictly sequential everywhere. If a reviewer cites a wrong step number that's because of the post-iter-1 inserts, not a logical hole.

When applying iter-2 auto-fixes:
1. STOP before proceeding if a patch's exact-string anchor no longer matches (later iter-1 edits may have changed surrounding context).
2. Describe the mismatch (file:line, expected vs found).
3. Ask the user how to proceed.

Do NOT silently work around mismatches.

## INSTRUCTIONS

1. Read the 4 documents listed above in order.
2. Report:
   - Brief understanding of what changed in iter-1 (3-4 lines).
   - Confirmation that iter-1 decision log is at the path noted above.
   - Reviewer set you intend to use (default: codex + albb-deepseek + glm; skip kimi/qwen/albb-glm).
3. **STOP and WAIT** — do NOT dispatch any reviewer agents.
4. Ask the user: «Запустить iter-2 с дефолтным набором (codex + albb-deepseek + glm) или изменить набор?»
