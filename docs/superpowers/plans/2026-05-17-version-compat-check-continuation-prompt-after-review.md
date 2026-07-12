# Continue execution — Python ↔ Ruby version-compat handshake (live verification, post external review)

Paste this block into a fresh Claude Code session running in
`/opt/github/zinin/sketchup-mcp2`.

---

## TASK

Continue the **final live verification** of the Python ↔ Ruby
version-compat handshake feature.

State at hand-off (HEAD = `c0a8680`):
- Tasks 1-11 implementation complete + iter-1 design/plan reviews
  applied.
- External code review (`/external-code-review default`) executed in
  the previous session: 6 reviewers (claude / codex / ccs-glm /
  ollama-kimi / ollama-deepseek / ollama-minimax) found 1 Critical +
  16 Important + 11 Minor across both features on the branch. After
  dedupe + verification: 9 cross-validated auto-fixes committed as
  `c0a8680`, 2 DISPUTED resolved as "не исправлять" with rationale,
  18 DISMISSED.
- Tasks 12.1 + 12.2 (automated tests) green after auto-fixes.
- `.rbz` artifact pre-built locally: `su_mcp/su_mcp_v0.0.3.rbz`
  (44 KB) from current commit state.

Only the manual user step (12.3b–d: install + restarts) and the live
verification it gates (12.4 + 12.5) remain.

## CRITICAL: DO NOT START WORKING

**STOP. READ THIS CAREFULLY.**

After loading all context below, you MUST:
1. Read the documents and confirm the branch state.
2. Report what you understood (brief summary, ≤ 200 words).
3. **WAIT for explicit user instructions** before taking ANY action.

**DO NOT:**
- Rebuild the `.rbz` — it's already built and present at
  `su_mcp/su_mcp_v0.0.3.rbz` from `c0a8680`. Re-running `ruby
  package.rb` would rebuild identically; wasted work.
- Install the `.rbz` yourself (you can't — SketchUp's Extension
  Manager is a manual GUI step).
- Restart SketchUp or the Claude Code session yourself.
- Run `examples/smoke_check.py` against a live SketchUp without
  explicit user confirmation that they've done the install + restarts.
- Make any code changes — implementation + review fixes are committed.

**The user will tell you exactly what to do.** Until then, only read
and summarize.

## DOCUMENTS

- **Design:** `docs/superpowers/specs/2026-05-16-version-compat-check-design.md`
- **Plan (trimmed):** `docs/superpowers/plans/2026-05-16-version-compat-check-plan.md`
- **Iter-1 review log:** `docs/superpowers/specs/2026-05-16-version-compat-check-review-iter-1.md`

The plan was trimmed in commit `a913141`; each completed task is one
line "✅ Done — see commit X". Full implementation details are in git
history (`git show <sha>`).

## PROGRESS

**Completed (13 commits on `feature/viewport-screenshot-and-prompt`):**

```
c0a8680 review: auto-fix valid issues from external review        ← 6-reviewer cross-validated fixes
a913141 docs: trim completed Tasks 1-11 from version-compat-check plan
9d67ab7 docs(readme): mention version handshake feature + get_version tool   ← Task 11
3b0f000 docs(claude-md): document version handshake + get_version tool        ← Task 10
8b30bd0 docs(release): grow version bump list 5 → 7 places                    ← Task 9
eb8d061 test(smoke): exercise get_version handshake in step 22                ← Task 8
170d7cd feat(tools): add get_version MCP tool                                 ← Task 7
c684339 feat(handshake): wire client_version outbound + server_version check  ← Task 6
135bd19 feat(handshake): check client_version in dispatch, inject server_v    ← Task 5
a425b6b feat(handlers): add get_version system handler + dispatch route       ← Task 4
5704e1c feat(compat): add Ruby-side version compatibility module              ← Task 3
b6887ce feat(compat): add Python-side version compatibility module            ← Task 2
a80cef4 feat(errors): add IncompatibleVersionError for -32001 mismatches      ← Task 1
```

**Automated verification (Task 12.1 + 12.2) — GREEN after `c0a8680`:**
- Python: `uv run pytest tests/ -q` → **119 passed**, 0 failed (was
  115 baseline; +2 new regression tests in `test_version_tool.py`,
  +2 new Unicode-digit parametrize entries in `test_compat.py`).
- Ruby: `ruby test/run_all.rb` → **189 runs / 428 assertions / 0
  failures / 0 errors / 0 skips** (was 180 baseline; +9 expanded
  negative parse-cases in `test_compat.rb`).

**Build artifact ready (Task 12.3a):**
- `su_mcp/su_mcp_v0.0.3.rbz` (44 KB) — built from `c0a8680` state.
  Includes the auto-fix `compat.rb` regex change (`\d+` → `[0-9]+`).

**Remaining — Task 12 steps 12.3b–12.5 (LIVE verification, manual gates):**
- [ ] **12.3b** User: in SketchUp Extension Manager → uninstall the
      previous `su_mcp` → install
      `/opt/github/zinin/sketchup-mcp2/su_mcp/su_mcp_v0.0.3.rbz`.
- [ ] **12.3c** User: restart SketchUp (or Plugins → MCP Server →
      Start Server) to load the freshly installed extension.
- [ ] **12.3d** User: this fresh Claude Code session IS the restart
      requirement on the Python side; `uv pip install -e .` is
      editable, so the c0a8680 changes are already picked up.
- [ ] **12.4** User asks me to call `get_version()` via MCP. Expected:
      `compatible=true, python_version=ruby_version="0.0.3",
      error=null`, plus populated `ruby_min/max_compatible_python`.
- [ ] **12.5** User runs `python examples/smoke_check.py` — expects
      all 22 steps green; step 22 now also asserts `ruby_version`,
      `ruby_min/max_compatible_python`, `error is None` per c0a8680.

## SESSION CONTEXT (non-obvious facts after external review)

### What changed in `c0a8680` (auto-fixes from external review)

9 cross-validated fixes across 9 files. Read `git show c0a8680` for the
complete diff. Key behavioral changes:

1. **`get_version` is now bulletproof on malformed Ruby payloads**
   (`tools.py:490` parse wrapped in `try/except KeyError | IndexError
   | TypeError | json.JSONDecodeError`, plus `isinstance(dict)` guard).
   Honors the "always returns a payload" contract even if Ruby sends
   garbage. 4 reviewers independently flagged this.

2. **`connection.py:199` `assert isinstance` → explicit `if not …:
   raise SketchUpError(-32603)`**, moved BEFORE the `.get("id")` call.
   `assert` strips with `python -O`. 3 reviewers.

3. **Parser regex `\d+` → `[0-9]+` in both `compat.py` and `compat.rb`**
   — closes the Unicode-digit cross-language drift channel (Python's
   `\d` matches `١٢٣`, Ruby's `\d` is ASCII-by-default). codex marked
   this Critical; both halves now explicitly ASCII via `[0-9]+`.

4. **Smoke step 22** also asserts `ruby_version`,
   `ruby_min_compatible_python`, `ruby_max_compatible_python`, `error
   is None` — catches "compatible=true on partial data" failure mode.

5. **2 missing regression tests added** to
   `tests/test_version_tool.py`:
   - `test_get_version_returns_payload_on_unknown_tool_error` (locks
     in pre-handshake-Ruby `-32601` branch behavior — listed in design
     §9.1 but dropped from plan).
   - `test_two_way_compat_drift_detected` (locks in QUESTION-1's
     two-way verdict semantics).

6. **`compat._parse` renamed to `compat.parse`** (was reaching into a
   private symbol from `tools.py`); 3 reviewers flagged.

7. **Docstring fixes:** `compat.py` "absent (pre-0.1.0)" → "absent
   (pre-handshake)"; `smoke_check.py` pre-condition no longer
   references stale "Ruby plugin v0.0.1"; `CLAUDE.md` "21-step" →
   "22-step".

8. **`test/test_compat.rb` negatives expanded** from 5 → 14 cases to
   mirror `tests/test_compat.py` (whitespace, sign chars, underscore,
   Unicode digits).

### DISPUTED issues resolved as "не исправлять" (no commit, just for the record)

- **DISP-1 (codex Critical, ccs-glm Important): leading zeros in
  parser.** Reasoning: programmatic constants never have leading
  zeros; no cross-language drift (both sides parse `"01"` to `1`); no
  real bug ever caught by this rule. Adding strict `(0|[1-9][0-9]*)`
  would be a rule without a scenario. Will revisit if log
  canonicalization becomes a feature.

- **DISP-2 (codex Important): `-32001` envelope machine-readable
  metadata fields.** Reasoning: prose `message` already contains all 5
  versions explicitly; `get_version` already provides a
  machine-readable payload — THAT IS the diagnostic tool. Duplicating
  the metadata in every error envelope adds code surface without new
  capability.

### DISMISSED (18 findings, summary)

- **Out-of-scope for version-compat**: viewport-screenshot view.rb
  error code (-32603 vs -32602), `.to_f` redundancy — that feature
  was already reviewed in multiple iterations earlier.
- **Pre-existing / out-of-scope-for-this-PR**: `validate_envelope!`
  ordering in `dispatch.rb` (flagged in iter-1 review as
  non-blocking polish); `is_notification = false` default
  initialization.
- **By design**: version bump (all 7 strings still `"0.0.3"` — bump
  happens in a separate release-time session per `docs/release.md`).
- **Cosmetic test-only**: `test_get_version_in_retry_safe_tools` file
  placement; `test_dispatch_routes_get_version_to_system` constant
  choice; `.freeze` on Regexp literals.
- **Already addressed in iter-1**: micro-perf `_parse(MIN/MAX)`
  reparse cost (Concern-4 — declined as cosmetic).
- **Design-doc nits**: `docs/superpowers/` will be `git rm`'d per
  global CLAUDE.md rule before PR.

### Version state during implementation
- All seven version strings remain `"0.0.3"` (matches current
  `__version__`).
- Release-time bump to `"0.1.0"` happens in a separate session per
  `docs/release.md` step 1 (which Task 9 extended from 5 → 7 places).
- The matched-pair smoke test (`compatible=true`) holds without any
  bump.

### Test count expectations (Task 12 baselines, post-`c0a8680`)
- Python: **119** = 115 baseline + 2 new in `test_version_tool.py`
  + 2 new parametrize entries in `test_compat.py`.
- Ruby: **189** runs / **428** assertions = 180 baseline + 9
  expanded negative parse-tests.

## PLAN QUALITY WARNING

The plan has been substantially improved through iter-1 design review,
during implementation, and now external code review. The trimmed plan
is mostly a record of what was done. The remaining Task 12 steps
12.3b–12.5 are **straightforward live verification** — no
implementation work, no plan defects to worry about.

If the live `get_version()` call returns anything OTHER than
`compatible=true` with matched `"0.0.3"` versions, STOP and report the
payload. The most likely causes:
(a) the user forgot to install the `.rbz` (Ruby code stale), or
(b) SketchUp wasn't restarted after install (extension didn't reload), or
(c) something inside the .rbz install path failed silently — ask the
    user to confirm via Extension Manager that `su_mcp` shows version
    `0.0.3` and is enabled.

## INSTRUCTIONS

1. Read the three documents listed under DOCUMENTS.
2. Confirm git state: `git log --oneline -15` should show the 11
   feature commits + the trimming commit (`a913141`) + the auto-fix
   commit (`c0a8680`).
3. Provide a brief summary (≤ 200 words) confirming you understand:
   - All implementation + external review fixes are committed.
   - 12.1 + 12.2 are green at post-`c0a8680` counts (119 / 189).
   - `.rbz` is pre-built; remaining steps are gated by manual user
     actions (Extension Manager install + SketchUp restart).
4. **STOP and WAIT** — do NOT proceed with any action.
5. When the user confirms they've done step 12.3b–c (Extension
   Manager install + SketchUp restart):
   - Call `get_version()` via MCP.
   - Assert `compatible == true` and `python_version == ruby_version
     == "0.0.3"`.
   - Verify `ruby_min_compatible_python` and
     `ruby_max_compatible_python` are populated (not null) — this is
     the c0a8680 two-way-verdict check.
   - If any assertion fails, report the payload and STOP — do NOT
     attempt to debug the wire layer without explicit user permission.
6. When the user confirms 12.4 is green, ask whether to run
   `examples/smoke_check.py` against live SketchUp. Run only on user
   OK.
7. After all 12 steps are green, STOP. Do NOT `git rm` design/plan
   docs, do NOT push, do NOT open a PR — those are branch-finish
   steps for `superpowers:finishing-a-development-branch` in a
   different fresh session.

## REPO STATE

- Branch: `feature/viewport-screenshot-and-prompt` (continuing —
  bundled with viewport-screenshot for the 0.1.0 release).
- HEAD: `c0a8680 review: auto-fix valid issues from external review`.
- Working tree: clean (only untracked planning docs from prior
  sessions, including this very continuation-prompt file).
- Build artifact present: `su_mcp/su_mcp_v0.0.3.rbz` (44 KB, built
  from `c0a8680` state).
