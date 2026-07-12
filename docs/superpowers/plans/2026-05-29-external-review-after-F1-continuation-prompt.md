# Continue — external-code-review hardening pass (after AUTO fixes + F1)

## TASK
Mid-flight through `/external-code-review` Step 4 (process results) on branch
`feature/warehouse-resubmit` (v0.2.0 warehouse-resubmit). A 7-model review ran,
all findings were verified against code and classified. **AUTO fixes + the first
DISPUTED item (F1) are DONE and committed.** What remains: 3 DISPUTED items
(F3, F4b, F6) → decisions-commit → rebuild both `.rbz` → re-acceptance →
release tail (14.0 Trimble pre-check, 14.8 push, 14.9 PR). Paused at the 250k
context STOP threshold.

## STATE OF THE REPO
- **Branch:** `feature/warehouse-resubmit`
- **HEAD:** `c3ad4d1` — review: apply F1 — fail-closed transactional Config.update!
- **New commits THIS session (on top of pre-review `5416c3b`):**
  - `6803c24` review: auto-fix valid issues from external review (6 AUTO fixes)
  - `c3ad4d1` review: apply F1 — fail-closed transactional Config.update!
- **Tests (green):** Ruby **292 runs / 709 assertions / 0 failures**,
  Python **127 passed** (1 non-fatal warning = conftest StreamReader, see Minors).
- **Working tree:** tracked files clean. The usual pile of UNTRACKED working
  notes (session-transfer docs, `.gemini/`, `diff.patch`, superpowers
  plans/specs incl. THIS prompt). **Do NOT stage them.** Always explicit
  `git add <path>`, never `-A`/`.`.
- **Conventions still active:** push/PR only on explicit user OK; any code
  change → run BOTH suites via the build-runner agent (never run tests
  directly); Ruby changes → rebuild both `.rbz` + re-acceptance.

## WHAT THE REVIEW FOUND (already verified by me)
7 reviewers (claude, codex, ccs-glm, ccs-qwen, ollama-kimi, ollama-minimax;
`ollama-deepseek` never delivered a report — two idle notifications, no content).
**No true Critical.** ollama-minimax's 2 "Critical" were both false positives
(verified). Full classification: AUTO 6 (done), DISPUTED 4 (F1 done; F3/F4b/F6
remain), DISMISSED 8, Minor-follow-up ~10.

Reviewer raw artifacts (if needed): `~/.claude/{codex,ccs,ollama}-interaction/2026-05-29-16-*/output.txt`.

### DONE — AUTO fixes (commit 6803c24)
- F2  `ui/settings.html` host warning extended to IPv6 wildcard (`::`, `0:0:0:0:0:0:0:0`).
- F4a `ui/settings_validator.rb` — `File.expand_path` wrapped in rescue ArgumentError (NUL byte) → structured error.
- F5  `core/logger.rb` — `File.open(path, "a:UTF-8")` so non-ASCII logs aren't dropped on Windows.
- F13 `package.rb` — dropped the `docs/superpowers/...` reference baked into the shipped `build_profile.rb` comment.
- F14 `test/test_package_default_variant.rb` — github-variant built+verified e2e (EVAL=true) + guard that baked build_profile has no `docs/superpowers`.
- F15 same file — invalid `--variant` aborts non-zero, no artifact.

### DONE — F1 (commit c3ad4d1)
eval-gate fail-open: `Config.update!` set runtime `eval_enabled` before the
persistence loop that can raise. Fixed via **option B (snapshot + rollback)**:
snapshot 6 runtime fields at entry; any `write_default==false` rolls runtime
back before re-raising → gate fails CLOSED. Updated comment block; replaced
`test_update_mutates_runtime_before_raising` →
`test_update_rolls_back_runtime_when_persistence_fails`; added
`test_update_does_not_open_eval_gate_when_persistence_fails`.

## ⛔ REMAINING DISPUTED — present ONE at a time, decide, apply, then commit ALL together

> Process: present the structured analysis (Суть/Анализ/Варианты/Рекомендация),
> then AskUserQuestion (multiple reasonable approaches exist for each). After
> the user picks: apply + add tests + run both suites (build-runner). Commit all
> three decisions together: `review: apply decisions from external review discussion`.

### [F3] Unbounded client accept + unbounded per-tick frame drain (DoS)
- **Files:** `core/server.rb:76` (`accept_pending_clients` — no `MAX_CLIENTS`/accept cap) + `:155` (`process_frame_queue` drains the ENTIRE `@frame_queue` each tick).
- **Found:** claude (Important), codex (Important). **Verified real.** Per-client guards exist (READ_MAX_ITERATIONS=50, PENDING_WRITE_MAX_BYTES=16MiB, WRITE_DEADLINE_S, SO_KEEPALIVE, ACCEPT_ABORTED_MAX=10) but NOT client count nor total per-tick work. Loopback default mutes it; matters for `0.0.0.0` bind.
- **Variants:**
  - **A (recommend):** add `MAX_CLIENTS` (~64); when `@clients.size >= MAX_CLIENTS`, close the freshly-accepted sock with a `client_rejected reason=max_clients` log line and do NOT register (keeps the registered-or-closed invariant). Closes the connection-exhaustion gap with minimal risk + a test.
  - **B:** A + `MAX_ACCEPTS_PER_TICK` + a frame/time budget in `process_frame_queue` (process up to N frames or a time budget, defer rest to next tick). Fuller DoS hardening but adds cross-tick state/complexity; the queue is already bounded indirectly by per-client read caps × client count, so A closes most of the gap.
  - **C:** don't fix; document the limit (loopback default; `0.0.0.0` is opt-in + warned).
- **Ruby change → .rbz rebuild.**

### [F4b] log_file_path validated-expanded but persisted-raw (tilde paths silently fail)
- **Files:** `ui/settings_validator.rb:57` (validates `File.expand_path(log_path)` parent) vs `:74` (persists RAW `log_path`); `core/logger.rb:49` (`File.open(path)` — no expand); `core/config.rb:55` (loads raw, no expand). Builds on F4a (already applied).
- **Found:** codex (Important). **Verified real.** `~/mcp.log` passes validation (expand resolves `~`) but logger opens literal `~/mcp.log` → every write fails → caught by rescue → silently console-only.
- **Variants:**
  - **B (recommend):** expand at logger open-time — `File.open(File.expand_path(path), "a:UTF-8")`. Single robust point; covers dialog-entered AND prefs-loaded AND default paths. Downside: dialog shows the raw path (expansion implicit).
  - **A:** normalize at validator — persist `File.expand_path(log_path)` (validator line 74 `log_file_path:` → expanded). Dialog shows the real path on reopen; does NOT cover prefs-loaded paths that bypass the validator.
  - **C:** both A + B (visibility + defense-in-depth).
- **Ruby change → .rbz rebuild.** Add a test (logger resolves a `~/`-style path).

### [F6] IncompatibleVersionError not caught in app.py lifespan → server crashes on version mismatch
- **File:** `src/sketchup_mcp/app.py:33` (`except ConnectionError` only).
- **Found:** ccs-glm (Important). **Verified real.** `IncompatibleVersionError` is a `SketchUpError` subclass (not `OSError`/`ConnectionError`); it escapes `get_connection()` (which only maps `OSError`→`ConnectionError`) → server crashes on startup at a version mismatch. `connection.py:327-331` deliberately promotes `-32001` to this class "so callers catch a single class" — app.py is the startup caller that doesn't.
- **Variants:**
  - **A (recommend):** `except (ConnectionError, IncompatibleVersionError) as e:` → log warning, degrade. Server starts; the mismatch surfaces via `get_version` (tools.py catches `SketchUpError` → diagnostic verdict; verify the tools.py get_version path first). A crash-on-startup means Claude Desktop can't even load the server to diagnose.
  - **B:** keep fatal but raise a clean user-facing config error (not a raw traceback).
  - **C:** don't fix (version mismatch = fatal by design).
- **Python-only → NO .rbz rebuild.** Add a lifespan test (connect raises IncompatibleVersionError → no crash, warning logged).

## AFTER THE 3 DECISIONS
1. Run BOTH suites (build-runner), confirm green.
2. Commit: `review: apply decisions from external review discussion` (explicit `git add` of only the changed files).
3. **Rebuild both `.rbz`** (F2/F3/F4/F5/F13 touched the shipped Ruby tree):
   `cd mcp_for_sketchup && ruby package.rb --variant=warehouse && ruby package.rb --variant=github && cd ..`
4. **Re-acceptance** (needs SketchUp running + MCP) for the touched surfaces:
   Settings dialog (host warning incl. `::`; eval checkbox; log path), logger
   (log-to-file incl. non-ASCII), eval gate still OFF in warehouse / ON in
   github, and a quick `examples/smoke_check.py`. (14.7's acceptance is
   invalidated for these areas by the Ruby changes.)

## THEN THE RELEASE TAIL (all user-gated — do NOT push/PR without explicit OK)
- **14.0 Trimble intake pre-check** (user, web form <https://extensions.sketchup.com/developer/submit>): new `product_id` `MCP_FOR_SKETCHUP` accepted without linking to dead v0.1.0; unsigned upload + EW signing matches `docs/release.md`.
- **14.8 push:** `git push -u origin feature/warehouse-resubmit`
- **14.9 PR (base=master):** ⚠️ **CORRECTION to the earlier prompt** — `git rm` ALL **7** tracked `docs/superpowers/` docs (not 2; per global CLAUDE.md "all files from docs/superpowers/"). They are: `plans/2026-05-28-warehouse-resubmit-iter1-remaining-fixes.md`, `plans/2026-05-28-warehouse-resubmit.md`, `specs/2026-05-28-warehouse-resubmit-design.md`, `specs/2026-05-28-warehouse-resubmit-review-iter-1.md`, `specs/2026-05-28-warehouse-resubmit-review-iter-2.md`, `specs/2026-05-28-warehouse-resubmit-review-merged-iter-1.md`, `specs/2026-05-28-warehouse-resubmit-review-merged-iter-2.md`. All 7 are ADDED in this branch (absent on master), so all would appear in the PR diff. Commit `chore: remove plan/spec docs before PR (kept in branch history)`, then `git push`, then `gh pr create`. Verify with `git status` first. Untracked continuation prompts (incl. this file) and `connection-retry-hint-spec.md` are NOT in git — leave untracked.

## CLEANUP
- Team **`code-review-warehouse`** is still up with 7 idle teammates. To remove:
  SendMessage `{type: shutdown_request}` to each (claude-rev, codex-rev, ccs-glm,
  ccs-qwen, ollama-deepseek, ollama-kimi, ollama-minimax), wait for termination,
  then `TeamDelete`. (Also note an UNRELATED orphan team `code-review` from a
  prior EBS session — leave it alone.)

## DISMISSED (do NOT reopen unless new evidence) & MINOR follow-ups (optional, candidates for v0.2.1)
- DISMISSED: get_version IS in `_RETRY_SAFE_TOOLS` (connection.py:53); `close_client` dup-log guarded by early `return unless @clients.key?`; `TOPLEVEL_BINDING.dup` gives top-level scope (not a bypass); logger `rescue StandardError` does NOT catch NoMemoryError/SystemStackError (those are `Exception`, not `StandardError`); ConnectionRefused→retry is harmless; `URI::DEFAULT_PARSER.escape` is the deliberate non-removed path (only top-level `URI.escape` was removed); `safe_byte_truncate` terminates (empty string is valid_encoding); view.rb `is_a?(Integer)` is fine (Python coerces on the wire).
- MINOR/optional: connection.py:387 reconnect without awaiting old writer close; package.rb concurrent-build race (release builds sequentially); logger per-line open/close + no rotation (low volume); `_RETRY_SAFE_TOOLS`↔dispatch contract test; conftest.py:21 StreamReader-outside-loop deprecation (the 1 pytest warning); test gaps (get_version ValueError branch, BuildProfile pref=true-over-false symmetry); style nits (`!!eval_enabled`, literal U+2028/2029, dialog height, clearErrors `_general`).

## INSTRUCTIONS
1. `git log --oneline -4` + `git status` to confirm HEAD `c3ad4d1`, tree clean.
2. ≤6-line summary, then resume Step 4.4: present **F3** first (analysis above is ready), AskUserQuestion, apply, then F4b, then F6. Then decisions-commit → rebuild .rbz → re-acceptance → release tail as the user authorizes each.
