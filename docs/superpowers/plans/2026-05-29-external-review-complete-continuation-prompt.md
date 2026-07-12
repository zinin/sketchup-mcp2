# Continue — external review FULLY PROCESSED; remaining = re-acceptance + release tail

> Supersedes `2026-05-29-external-review-after-F1-continuation-prompt.md` (now stale —
> it listed F3/F4b/F6 as remaining; all are DONE).

## TASK
The 7-model `/external-code-review` of `feature/warehouse-resubmit` (v0.2.0) is
**fully processed**: 6 AUTO fixes + all 4 DISPUTED decisions applied, tested, and
committed; both `.rbz` rebuilt. What remains is NOT code: (1) live re-acceptance
of the rebuilt `.rbz` in SketchUp (USER reinstalls), (2) the release tail
(14.0 Trimble pre-check, 14.8 push, 14.9 PR). Nothing pushed; no PR.

## STATE
- **Branch:** `feature/warehouse-resubmit`
- **HEAD:** `194fca3` — review: apply decisions from external review discussion
- **Commits THIS review session (on top of pre-review `5416c3b`):**
  - `6803c24` review: auto-fix valid issues (6 AUTO: F2 IPv6 host-warning, F4a validator null-byte rescue, F5 logger UTF-8, F13 build_profile comment, F14/F15 package tests)
  - `c3ad4d1` review: F1 — fail-closed transactional `Config.update!` (snapshot+rollback)
  - `194fca3` review: decisions — F3 (`MAX_CLIENTS=64` cap), F4b (logger `File.expand_path`), F6 (lifespan catches `IncompatibleVersionError` → degrade)
- **Tests (green):** Ruby **294 runs / 715 assertions / 0 failures**, Python **129 passed**.
- **Both `.rbz` rebuilt** (gitignored, at `mcp_for_sketchup/*.rbz`): warehouse `EVAL_ENABLED_BY_DEFAULT=false`, github `=true`; post-build verification passed for both.
- **Working tree:** tracked files clean. Untracked working notes only (incl. this prompt) — do NOT stage. Always explicit `git add <path>`, never `-A`/`.`.

## ⛔ REMAINING

### Re-acceptance (USER reinstalls, then I verify via the `sketchup` MCP)
The live SketchUp is still running the OLD `.rbz` until reinstalled. **User step:**
install `mcp_for_sketchup/mcp_for_sketchup_v0.2.0-warehouse.rbz` (Extensions →
Install Extension), restart the MCP server in SketchUp. Then verify the touched
surfaces:
- Settings dialog: host security warning now also fires for `::` and
  `0:0:0:0:0:0:0:0` (F2); eval checkbox + log path fields still behave.
- Log-to-file: enable with a `~/...` path AND a non-ASCII line in the log →
  file is written at the expanded path with UTF-8 intact (F4b + F5).
- eval gate OFF in warehouse → `eval_ruby` returns the `-32010` message verbatim.
- `get_version` → 0.2.0, compatible.
- `examples/smoke_check.py` → 22/22.
- (Optional) F6 is Python-only; to see degraded-start, point the Python client
  at a mismatched server — not required for warehouse acceptance.

### Release tail (all user-gated — do NOT push/PR without explicit OK)
- **14.0 Trimble intake pre-check** (user, web form): new `product_id`
  `MCP_FOR_SKETCHUP` accepted without linking to dead v0.1.0; unsigned upload +
  EW signing matches `docs/release.md`.
- **14.8 push:** `git push -u origin feature/warehouse-resubmit`
- **14.9 PR (base=master):** ⚠️ `git rm` ALL **7** tracked `docs/superpowers/`
  docs (NOT 2 — per global CLAUDE.md "all files from docs/superpowers/"):
  `plans/2026-05-28-warehouse-resubmit-iter1-remaining-fixes.md`,
  `plans/2026-05-28-warehouse-resubmit.md`,
  `specs/2026-05-28-warehouse-resubmit-design.md`,
  `specs/2026-05-28-warehouse-resubmit-review-iter-1.md`,
  `specs/2026-05-28-warehouse-resubmit-review-iter-2.md`,
  `specs/2026-05-28-warehouse-resubmit-review-merged-iter-1.md`,
  `specs/2026-05-28-warehouse-resubmit-review-merged-iter-2.md`.
  All 7 are ADDED in this branch (absent on master). Commit
  `chore: remove plan/spec docs before PR (kept in branch history)`, `git push`,
  `gh pr create`. Verify `git status` first. The 3 review commits
  (6803c24/c3ad4d1/194fca3) stay in the PR — they are real product fixes.

## CLEANUP
- Team **`code-review-warehouse`** still up with 7 idle teammates
  (claude-rev, codex-rev, ccs-glm, ccs-qwen, ollama-deepseek, ollama-kimi,
  ollama-minimax). `ollama-deepseek` never delivered a report. To remove:
  SendMessage `{type: shutdown_request}` to each → wait → `TeamDelete`.
  (Unrelated orphan team `code-review` from a prior EBS session — leave alone.)

## DISMISSED (do NOT reopen) & MINOR follow-ups (optional, v0.2.1 candidates)
- DISMISSED (false positives, verified): get_version IS in `_RETRY_SAFE_TOOLS`;
  `close_client` dup-log is guarded; `TOPLEVEL_BINDING.dup` = top-level scope;
  logger `rescue StandardError` does NOT catch NoMemoryError/SystemStackError;
  ConnectionRefused→retry harmless; `URI::DEFAULT_PARSER.escape` is the
  deliberate non-removed path; `safe_byte_truncate` terminates; view.rb
  `is_a?(Integer)` fine (Python coerces).
- MINOR/optional: connection.py:387 reconnect-without-await; package concurrent-
  build race (release builds sequentially); logger per-line open + no rotation;
  `_RETRY_SAFE_TOOLS`↔dispatch contract test; conftest.py:21 StreamReader
  deprecation; test gaps (get_version ValueError branch, BuildProfile pref=true-
  over-false symmetry); style nits.

## INSTRUCTIONS
1. `git log --oneline -5` + `git status` to confirm HEAD `194fca3`, tree clean.
2. ≤6-line summary, then: confirm re-acceptance with the user (they reinstall the
   warehouse `.rbz`; I verify via the `sketchup` MCP), then drive 14.0 → 14.8 →
   14.9 as the user authorizes each. Do NOT push/PR without explicit go-ahead.
