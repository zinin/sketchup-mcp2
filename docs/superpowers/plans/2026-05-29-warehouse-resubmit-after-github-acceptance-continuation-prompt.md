# Continue — Warehouse Resubmit v0.2.0 (after BOTH-variant acceptance + retry-hint fix)

## TASK

The interactive release tail is nearly done. **All code AND all live SketchUp
acceptance are complete.** What remains is git-only / web-form work that needs
NO SketchUp or MCP: Trimble intake pre-check (14.0), branch push (14.8), PR
(14.9).

## STATE OF THE REPO

- **Branch:** `feature/warehouse-resubmit`
- **HEAD:** `5416c3b` — fix(connection): enrich stale-socket transport errors with tool name + recovery hint
- **Working tree:** tracked files clean. Many pre-existing UNTRACKED working
  notes (session-transfer docs, `.gemini/`, `diff.patch`, superpowers
  plans/specs incl. THIS prompt and `2026-05-29-connection-retry-hint-spec.md`).
  **Do NOT stage them.** Always explicit `git add <path>`, never `-A`/`.`.
- **Tests:** Python **127 passed** (was 123; +4 from the retry-hint change).
  Ruby **287/684** untouched.

## ✅ DONE THIS SESSION

### Step 14.7 — live acceptance COMPLETE (both variants)
- **Warehouse:** `get_version` 0.2.0 ✓; eval gate OFF → −32010 verbatim ✓;
  `create_component` cube 100³ ✓; `get_model_info`/`list_components` sane ✓;
  Settings dialog has NO scrollbar even at host `0.0.0.0` (14.7-A fix holds) ✓;
  `examples/smoke_check.py` 22/22 ✓.
- **Github:** `get_version` 0.2.0 ✓; `eval_ruby` works WITHOUT manual enabling
  (returned an int) ✓; **clean build-default confirmed** — after clearing all
  `MCPforSketchUp` prefs and a clean reinstall, the Settings "Enable Ruby
  evaluation" checkbox was ON by default with no leftover pref ✓.

### Retry-hint change — committed `5416c3b` (Python-only)
When the persistent socket goes stale (server restart), non-retry-safe tools
(`eval_ruby` + mutating) now surface an ENRICHED error: tool name (no more
`tool=?`) + an ADVISORY recovery hint (reconnect via a read-only tool, inspect
state, never blind-retry a possibly-committed mutation). Read-only tools still
auto-reconnect transparently. spec ✅ (Opus) + TDD + code ✅ (Opus); verified
live (stale → enriched message → read-only auto-reconnect). **No version bump,
no `.rbz` rebuild** (the error text is not part of the wire protocol; handshake
stays 0.2.0↔0.2.0). The .rbz artifacts accepted in 14.7 remain valid.
- Spec working note (UNTRACKED — do NOT commit):
  `docs/superpowers/specs/2026-05-29-connection-retry-hint-spec.md`.

## ⛔ REMAINING (all user-gated)

### Step 14.0 — Trimble intake pre-check (user, web form)
<https://extensions.sketchup.com/developer/submit> — confirm (1) a brand-new
`product_id` `MCP_FOR_SKETCHUP` is accepted without linking to the dead v0.1.0
listing, and (2) the UNSIGNED upload + EW-side signing flow matches
`docs/release.md`. Surface any contradiction before submission.

### Step 14.8 — push (only on explicit user OK)
```bash
git push -u origin feature/warehouse-resubmit
```

### Step 14.9 — PR (after push; design+plan must NOT appear in the diff)
Per global CLAUDE.md, `git rm` the two TRACKED superpowers docs first:
```bash
git rm docs/superpowers/specs/2026-05-28-warehouse-resubmit-design.md \
       docs/superpowers/plans/2026-05-28-warehouse-resubmit.md
git commit -m "chore: remove plan/spec docs before PR (kept in branch history)"
git push
gh pr create   # base = master
```
Verify with `git status` first. The many untracked continuation prompts and the
new `connection-retry-hint-spec.md` are NOT in git and won't appear in the diff —
leave them untracked (do NOT commit them).

## NOTES
- `.mcp.json` carries a LOCAL-ONLY `UV_PROJECT_ENVIRONMENT=/home/zinin/.venvs/sketchup-mcp2`
  fix (gitignored, not in git). If the `sketchup` MCP server ever times out on
  connect, re-check that env var.
- On the SketchUp machine this session: all `MCPforSketchUp` prefs were cleared,
  then `host` was re-set to `0.0.0.0` for remote MCP. The Settings Save may have
  re-persisted `eval_enabled=true` — irrelevant for shipping (build defaults are
  verified by unit tests + `build_profile.rb` autogen).
- Conventions still active: explicit `git add <path>`; push/PR only on explicit
  user OK; any further code change → spec ✅ + code ✅ (Opus) + both suites green.

## INSTRUCTIONS
1. `git log --oneline -5` and `git status` to confirm (HEAD should be `5416c3b`).
2. ≤6-line summary, then drive 14.0 → 14.8 → 14.9 as the user authorizes each.
   Do NOT push or open the PR without explicit user go-ahead.
