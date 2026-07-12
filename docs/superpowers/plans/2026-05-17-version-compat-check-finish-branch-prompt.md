# Finish development branch — viewport-screenshot + version-compat-check (0.1.0 release)

Paste this block into a fresh Claude Code session running in
`/opt/github/zinin/sketchup-mcp2`.

---

## TASK

Run the **branch-finishing workflow** for
`feature/viewport-screenshot-and-prompt`.

Two features (viewport-screenshot AND version-compat-check) are bundled
into the upcoming 0.1.0 release on this branch. All implementation,
unit tests, external code review, and 22-step live smoke verification
are complete. Now: clean up planning docs, push the branch, and open a
PR to `master`.

## CRITICAL: DO NOT START WORKING

**STOP. READ THIS CAREFULLY.**

After loading all context below, you MUST:
1. Read the documents and confirm branch state.
2. Report what you understood (brief summary, ≤ 200 words).
3. **WAIT for explicit user instructions** before taking ANY action.

**DO NOT:**
- Run `git rm` on `docs/superpowers/` files yet.
- Push the branch.
- Open a PR.
- Bump version strings to `"0.1.0"` (that's a separate release-time
  session per `docs/release.md`).
- Make code changes — implementation is fully complete and verified.

**The user will tell you exactly what to do.** Until then, only read
and summarize.

## SKILL TO USE

Invoke `superpowers:finishing-a-development-branch` when the user gives
the go-ahead. It presents structured options (merge / PR / cleanup) —
follow whichever path the user picks.

## DOCUMENTS

**Version-compat-check (this work, trimmed):**
- Design: `docs/superpowers/specs/2026-05-16-version-compat-check-design.md`
- Plan (Task 1-12 all trimmed): `docs/superpowers/plans/2026-05-16-version-compat-check-plan.md`
- iter-1 review log: `docs/superpowers/specs/2026-05-16-version-compat-check-review-iter-1.md`

**Viewport-screenshot (earlier on the same branch):**
- Design: `docs/superpowers/specs/2026-05-16-viewport-screenshot-and-prompt-design.md`
- Plan: `docs/superpowers/plans/2026-05-16-viewport-screenshot-and-prompt-plan.md`
- iter-1/iter-2 reviews: `docs/superpowers/specs/2026-05-16-viewport-screenshot-and-prompt-review-iter-*.md`

Per global `~/.claude/CLAUDE.md` rule: ALL `docs/superpowers/` artifacts
for BOTH features must be `git rm`'d in a single cleanup commit BEFORE
opening the PR. They remain accessible in git history.

## BRANCH STATE

- Branch: `feature/viewport-screenshot-and-prompt`
- HEAD: `2587a6d docs: trim Task 12 from version-compat-check plan`
- Ahead of `origin/feature/viewport-screenshot-and-prompt` by **3 commits**
  (`c0a8680`, `aaaca02`, `2587a6d`); intentionally not pushed
  (branch-finish concern).
- Working tree: clean except for untracked planning docs +
  session-transfer artifacts in `docs/`. Untracked is fine — they get
  removed by the cleanup `git rm` step anyway.

## COMPLETED WORK ON THIS BRANCH

**Version-compat-check (13 commits, `a80cef4`..`2587a6d`):**
- Python ↔ Ruby version handshake — `client_version` on every JSON-RPC
  request; `server_version` on every response.
- New MCP tool `get_version` — diagnostic bypass that always returns a
  payload (in `_RETRY_SAFE_TOOLS`; name-based bypass on both sides).
- `IncompatibleVersionError` (JSON-RPC code `-32001`); Python promotes
  inbound `-32001` envelopes so callers catch one class.
- Strict `[0-9]+` ASCII-digit regex parsers on both sides (closes
  Unicode-digit cross-language drift channel).
- Two-way verdict in `tools.py::get_version` (Python's table accepts
  Ruby AND Ruby's advertised range accepts Python).
- Documentation: `CLAUDE.md` / `README.md` / `docs/release.md` updated;
  release.md version-bump checklist grew from 5 → 7 places.
- CLAUDE.md additionally now documents single-client Ruby server
  constraint + split-host smoke setup.

**Viewport-screenshot feature** (earlier commits on the same branch):
adds `get_viewport_screenshot` MCP tool — returns MCP Image, optional
`view_preset` / `style` / `zoom_extents`; non-destructive by default;
requires SketchUp 2026+. See its design + plan docs.

**Verification matrix — all green:**
- Python unit tests: **119 passed** (`uv run pytest tests/ -q`).
- Ruby unit tests: **189 runs / 428 assertions** (`ruby test/run_all.rb`).
- 22-step live smoke: green against remote SketchUp 2026 at
  `192.168.20.20:9876` (split-host).
- External code review (6 reviewers — claude, codex, ccs-glm,
  ollama-kimi, ollama-deepseek, ollama-minimax): **9 cross-validated
  fixes committed as `c0a8680`**; 2 DISPUTED dismissed with rationale;
  18 DISMISSED.
- Live `get_version()` through MCP: `compatible=true`, all two-way
  fields populated.

## SESSION CONTEXT (non-obvious facts)

- **Version strings stay `"0.0.3"` in this session.** Release-time bump
  to `"0.1.0"` happens in a **separate** session per `docs/release.md`
  step 1 (which Task 9 extended from 5 → 7 places). Do NOT bump here.
- **The `.rbz` artifact `su_mcp/su_mcp_v0.0.3.rbz` is present in the
  working tree** (built from `c0a8680` for live verification). Not
  committed (build artifact). The release-time session rebuilds from
  `"0.1.0"`.
- **Single-client Ruby server constraint** (documented in CLAUDE.md):
  `core/server.rb` accepts ONE TCP client at a time; second concurrent
  client gets `ECONNREFUSED`; auto-reset after 300s idle. Affects
  smoke-test orchestration.
- **Split-host dev setup** (documented in CLAUDE.md): SketchUp on
  separate Windows machine (`192.168.20.20`); `examples/smoke_check.py`
  honors `SKETCHUP_MCP_HOST` via `sketchup_mcp.config`. Step 18
  (`export_scene`) skips local `os.path.exists` when host is
  non-loopback because the file lives on the SketchUp host.
- **Smoke step 22 talks to Ruby directly** (no FastMCP), so it sees the
  raw `handlers/system.rb` payload only. The enriched
  `compatible`/`error`/`python_version` payload is computed only by
  `tools.py::get_version` (FastMCP path). Step 22 was fixed in
  `aaaca02` to replicate the two-way verdict locally — a latent bug
  from Task 8 that survived iter-1 design review AND 6-agent external
  code review.

## ARTIFACTS TO REMOVE BEFORE PR

The following `docs/superpowers/` files must be `git rm`'d (single
cleanup commit before pushing):

```
docs/superpowers/specs/2026-05-16-version-compat-check-design.md
docs/superpowers/specs/2026-05-16-version-compat-check-parsed-issues-iter-1.md
docs/superpowers/specs/2026-05-16-version-compat-check-review-iter-1.md
docs/superpowers/specs/2026-05-16-version-compat-check-review-merged-iter-1.md
docs/superpowers/specs/2026-05-16-viewport-screenshot-and-prompt-design.md
docs/superpowers/specs/2026-05-16-viewport-screenshot-and-prompt-review-iter-1.md
docs/superpowers/specs/2026-05-16-viewport-screenshot-and-prompt-review-iter-2.md
docs/superpowers/specs/2026-05-16-viewport-screenshot-and-prompt-review-merged-iter-1.md
docs/superpowers/specs/2026-05-16-viewport-screenshot-and-prompt-review-merged-iter-2.md
docs/superpowers/plans/2026-05-16-version-compat-check-plan.md
docs/superpowers/plans/2026-05-16-viewport-screenshot-and-prompt-plan.md
```

The untracked planning files in `docs/superpowers/plans/` (continuation
prompts, execution prompts, after-review prompts, finish-branch prompt)
are NOT tracked by git, so `git rm` doesn't apply to them — but they
should be left alone (or manually removed once the PR is merged).

## INSTRUCTIONS

1. Read the documents listed under DOCUMENTS.
2. Run `git status` + `git log --oneline origin/feature/viewport-screenshot-and-prompt..HEAD`
   to confirm branch state (3 commits ahead).
3. Provide a brief summary (≤ 200 words) covering:
   - the two features being bundled into 0.1.0,
   - the verification matrix (tests / live smoke / external review),
   - the list of docs that need `git rm`.
4. **STOP and WAIT** — do NOT proceed.
5. When the user gives the go-ahead, invoke
   `superpowers:finishing-a-development-branch` and follow its prompts.

## SCOPE BOUNDARIES

In scope for this session:
- `git rm` of design/plan docs under `docs/superpowers/` for BOTH
  features (single cleanup commit).
- Push the branch to origin.
- Open a PR to `master` with a descriptive body summarizing both
  features + verification matrix.

OUT of scope (separate sessions):
- Release-time version bump to `"0.1.0"` (7 places per `docs/release.md`).
- `.rbz` rebuild for the release.
- TestPyPI / PyPI uploads.
- GitHub release / tag.
