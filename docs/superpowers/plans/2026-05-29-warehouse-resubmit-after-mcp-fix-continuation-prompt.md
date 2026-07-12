# Continue — Warehouse Resubmit v0.2.0 (after scrollbar fix + MCP-connection fix)

## TASK

Finish the interactive release tail of the SketchUp warehouse re-submission
(v0.2.0). **All autonomous code is done.** What remains: live SketchUp 2026+
acceptance via MCP (Step 14.7), Trimble intake pre-check (Step 14.0), branch
push (Step 14.8), PR (Step 14.9).

## CRITICAL: read first, then confirm with the user before live steps

After loading context:
1. Read this doc + the design/plan + the PRIOR continuation prompt (paths below).
2. `git log --oneline -5` and `git status` to confirm repo state.
3. The `sketchup` MCP server connection was BROKEN earlier this session and is
   **now FIXED + connected** (see "MCP CONNECTION FIX" below). Confirm tools are
   live: `ToolSearch` for `mcp__sketchup__get_version`. If they're NOT present,
   the user needs to `/mcp` reconnect (or restart Claude Code so `.mcp.json` is
   re-read).
4. Give a ≤6-line summary, then **WAIT for the user** to confirm WHICH `.rbz`
   variant is installed on the SketchUp machine before running MCP verification.
   Do NOT push or open the PR without explicit user go-ahead.

## STATE OF THE REPO

**Branch:** `feature/warehouse-resubmit`
**HEAD:** `d10b8d7`

Commits added in the session that produced THIS handoff (newest first):
```
d10b8d7  docs(readme): explain the VM-isolation rationale behind the shared-folder setup
5833426  docs(readme): document UV_PROJECT_ENVIRONMENT workaround for slow-filesystem startup timeouts
63c4000  fix(ui): widen Settings dialog and unwrap checkbox labels to remove scrollbar   [Step 14.7-A]
a4f1d79  docs(release): warehouse .rbz uploaded unsigned; Trimble signs after EW review  [prior session]
```

**Working tree:** clean of tracked modifications. Many pre-existing untracked
files (session-transfer docs, `.gemini/`, `diff.patch`, superpowers plans/specs
incl. THIS prompt). **Do NOT stage them.** Always explicit `git add <path>`,
never `git add -A`/`.`.

**Test baselines (unchanged, both green):** Ruby **287 runs / 684 assertions /
0 failures / 0 errors**; Python **123 passed**.

## DOCUMENTS (read for context)
1. Design: `docs/superpowers/specs/2026-05-28-warehouse-resubmit-design.md` (§8 distribution, §12 acceptance). NOTE: design §8 wrongly says "both go through Trimble signing" — release.md is the corrected authority (see prior prompt's carry-forward A). Design doc is git-rm'd before PR.
2. Plan: `docs/superpowers/plans/2026-05-28-warehouse-resubmit.md` — Tasks 1–13 trimmed; **Task 14 (line ~301)** is the remaining live tail. Step 14.7 = the manual acceptance.
3. **Prior continuation prompt (still authoritative for the per-step detail):**
   `docs/superpowers/plans/2026-05-29-warehouse-resubmit-after-task14-autonomous-continuation-prompt.md`
   — its Step 14.7 (warehouse + github substeps), Step 14.0 (Trimble intake),
   Step 14.8 (push), Step 14.9 (PR) instructions are unchanged and apply as-is.
   This new prompt only updates STATE (14.7-A done; MCP fixed).

## ✅ DONE THIS SESSION

### Step 14.7-A — Settings-dialog scrollbar removed ✅ (`63c4000`)
The user reported a vertical scrollbar + clipped eval-warning in
`Plugins → MCP Server → Settings…`. Fixed:
- `ui/settings.html`: added `.row.bool label { flex: 1 1 auto; }` — checkbox-row
  labels were pinned to the 10em form-label column (`.row label { flex: 0 0 10em }`)
  and wrapped onto extra lines; now one line. Form-row alignment untouched.
- `ui/settings_dialog.rb`: HtmlDialog `width 380→440`, `height 480→570`.
  **`scrollable: true` KEPT** — it's auto (scrollbar only on overflow); with the
  window now tall enough no bar shows at normal DPI, and the CONCERN-4 high-DPI
  no-truncation safety net is preserved. HtmlDialog dims are logical units
  normalized to normal DPI, so "fits at normal DPI" holds across 125/150/200%.
- spec ✅ + code ✅ (Opus review: APPROVE, no Critical/Important).
- **Both `.rbz` REBUILT + verified**: fix is inside both artifacts; eval gate
  correct (warehouse `EVAL_ENABLED_BY_DEFAULT=false`, github `=true`); both
  53 225 B. Artifacts (gitignored): `mcp_for_sketchup/mcp_for_sketchup_v0.2.0-{warehouse,github}.rbz`.
- **OPEN micro-decision (user hasn't decided):** in one edge case (user types
  host `0.0.0.0`, or changes host/port without restart → the `status-hint`
  populates a 2-line security warning) content reaches ~567 px ≈ the 570 height —
  razor-thin; `scrollable: true` absorbs it gracefully. Won't occur in standard
  acceptance. If the user wants zero-scroll even in that edge case, bump height
  to ~590 and rebuild both `.rbz` (one more reinstall). Otherwise 570 ships.

### MCP CONNECTION FIX ✅ (the reason this session detoured into debugging)
The `sketchup` MCP server failed to connect: `MCP server "sketchup" connection
timed out after 30000ms`. **Root cause (NOT the network/SketchUp link):** the
repo and its `.venv` live on `vmhgfs-fuse` (VMware Shared Folders). Python import
I/O (hundreds of small files) is brutally slow there — `import sketchup_mcp.app`
took **~32 s** (vs 2–4 s on local disk) + ~9 s uv ≈ ~41 s, past Claude Code's
30 s MCP-init timeout. Layer-2 (Python↔Ruby TCP `hello` handshake) was always
fine (~0.05 s) — that's why `telnet 192.168.20.20 9876` succeeded but MCP did not.

**Fix (applied, VERIFIED — `initialize` now responds in 2.65 s):** added
```
"UV_PROJECT_ENVIRONMENT": "/home/zinin/.venvs/sketchup-mcp2"
```
to the `sketchup` server's `env` block in `.mcp.json`. This puts the MCP server's
venv on local ext4; project source stays on vmhgfs (small, editable). The venv at
`/home/zinin/.venvs/sketchup-mcp2` is pre-created/warmed and self-heals (uv
recreates in ~8 s if deleted).
- **`.mcp.json` IS GITIGNORED** (`.gitignore:38`) — this fix is **local-only and
  will NOT appear in git**. Do not be confused that it's "missing"; do not try to
  commit it. If the connection ever breaks again, re-check this env var.
- Documented as a general workaround in README Troubleshooting (`5833426`).
- The user's plain dev commands (`uv run pytest`, smokes, `ruby test/run_all.rb`)
  are still slow on vmhgfs — only the MCP server was relocated. Optional future
  speed-up: relocate the dev `.venv` to local disk too (user deferred this).

## ⛔ REMAINING (all user-gated / interactive — detail in the PRIOR prompt)

State right now: SketchUp is running on `192.168.20.20:9876` (host set to
`0.0.0.0`, plugin started), and the MCP tools are connected. Acceptance can run
immediately — but FIRST confirm which `.rbz` variant is currently installed (the
user changed the IP & restarted; unclear if they reinstalled the NEW scroll-fix
build). The user should install the **freshly-rebuilt warehouse `.rbz`** (the old
pre-scroll-fix build is stale) for the warehouse acceptance.

### Step 14.7 — live acceptance (collaborative)
**WAREHOUSE variant (eval OFF):** `get_version`→`0.2.0` compatible;
`eval_ruby("1+1")`→ the actionable **−32010** "disabled" message (THE key gate
check); `create_component(cube 100³)`→ ~100³ bbox; `get_model_info`/`list_components`
sane; manual eyeball: **Settings dialog has NO scrollbar** (the point of 14.7-A),
display name "MCP Server for SketchUp", sections Network/Logging/Ruby Evaluation,
console `[MCPforSU]`, optional enable-eval→confirm messagebox→eval works.
**GITHUB variant (eval ON):** user uninstalls warehouse, installs github,
restarts, starts server; `get_version`→0.2.0; `eval_ruby("Sketchup.active_model.entities.length")`→
**succeeds** (no enabling). Keep MCP calls lean; `get_viewport_screenshot` is a
big image — use sparingly.

### Step 14.0 — Trimble intake pre-check (user, web form)
Confirm a brand-new `product_id` `MCP_FOR_SKETCHUP` is accepted; unsigned upload +
EW-side signing flow matches release.md. Surface any contradiction before submit.

### Step 14.8 — push (only on explicit user OK)
`git push -u origin feature/warehouse-resubmit`

### Step 14.9 — PR (after 14.7 passes; design+plan must NOT be in the diff)
```
git rm docs/superpowers/specs/2026-05-28-warehouse-resubmit-design.md \
       docs/superpowers/plans/2026-05-28-warehouse-resubmit.md
git commit -m "chore: remove plan/spec docs before PR (kept in branch history)"
git push && gh pr create   # base = master
```
(Only those two tracked docs need `git rm`; the untracked continuation prompts
won't appear in the diff. Verify with `git status` first.)

## CONVENTIONS (still active)
- Explicit `git add <path>`, NEVER `-A`/`.`. Confirm `git status` before staging.
- Surgical edits; pre-verify anchors; on drift STOP and ask.
- Any further code change → spec ✅ + code ✅ (Opus subagents), both suites green
  (Ruby 287/684, Python 123).
- Do NOT push / open PR without explicit user go-ahead.

## INSTRUCTIONS
1. Read this doc + skim design/plan + the prior continuation prompt. `git log --oneline -5`, `git status`.
2. Confirm `sketchup` MCP tools are live (`ToolSearch mcp__sketchup__get_version`). If absent → user runs `/mcp` reconnect (or restarts Claude Code).
3. ≤6-line summary, then WAIT for the user to confirm which variant is installed.
4. Drive Step 14.7 (lean MCP calls) → 14.0 → 14.8 → 14.9 as the user authorizes each.
