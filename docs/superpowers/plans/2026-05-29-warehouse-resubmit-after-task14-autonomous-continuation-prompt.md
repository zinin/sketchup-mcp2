# Continue — Warehouse Resubmit v0.2.0 (after Task 14 autonomous + docs)

## TASK

Finish the LAST remaining work of the SketchUp warehouse re-submission
(v0.2.0). **All autonomous work is done.** What remains is the
interactive / user-gated tail of **Task 14** PLUS one small UI fix found
during acceptance: a Settings-dialog **scrollbar** the user wants removed
(see "Step 14.7-A — NEW FINDING" below). So there IS one autonomous code
task left (the scroll fix → spec+code review → rebuild both variants),
then live SketchUp 2026+ acceptance via MCP (Step 14.7), Trimble intake
pre-check (Step 14.0), branch push (Step 14.8), and PR (Step 14.9).

## CRITICAL: DO NOT START WORKING UNTIL SKETCHUP IS READY

The live acceptance needs the user to physically install a `.rbz` on the
SketchUp machine and start the plugin. After loading context:

1. Read this doc + the design/plan (paths below) + verify repo state with
   `git log --oneline -6` and `git status`.
2. Confirm the `sketchup` MCP tools are connected (try a `ToolSearch`
   for `mcp__sketchup__get_version`). **If not connected, the user has
   not installed/started the plugin yet — ask them to do it first.**
3. Report a ≤6-line summary and WAIT for the user to say which variant is
   installed before running any MCP verification.

## STATE OF THE REPO

**Branch:** `feature/warehouse-resubmit`
**HEAD:** `a4f1d79` (docs(release): warehouse .rbz uploaded unsigned…)

Commits made in the session that produced this handoff (newest first):
```
a4f1d79  docs(release): warehouse .rbz uploaded unsigned; Trimble signs after EW review   [carry-forward A]
6a8ebf2  docs: correct stale test counts in CLAUDE.md (Ruby 287/684, Python 123)          [carry-forward B]
beeaef8  fix(examples): smoke_check skips eval_ruby steps when gate is closed              [Task 13]
175b0bf  docs: trim completed Tasks 10-12 from plan for warehouse-resubmit                 [prior session]
```

**Working tree:** clean of tracked modifications. Many pre-existing
untracked files (session-transfer docs, `.gemini/`, `diff.patch`,
superpowers plans/specs incl. THIS continuation prompt) — **do NOT
stage them.** Use explicit `git add <path>`. Never `git add -A`.

**Test baselines (verified this session):** Ruby **287 runs / 684
assertions / 0 failures / 0 errors**; Python **123 passed**. Both `.rbz`
variants build clean; `build_profile` differs correctly; strict legacy-name
grep is empty; `uv build` + `twine check` PASS.

## DOCUMENTS (read for context)

1. Design: `docs/superpowers/specs/2026-05-28-warehouse-resubmit-design.md` (§8 distribution, §12 acceptance, but NOTE: design §8 wrongly says "both go through the Trimble signing service" — release.md was corrected to reality, see carry-forward A below; the design doc is git-rm'd before PR so its staleness doesn't ship).
2. Plan: `docs/superpowers/plans/2026-05-28-warehouse-resubmit.md` — Task 14 = lines ~301–423. Step 14.7 = the 11-substep manual acceptance.
3. Iter logs: `…-review-iter-1.md`, `…-review-iter-2.md` (only if you need to look up a specific decision).

## ✅ DONE (this + prior sessions)

- **Tasks 1–12:** complete (prior sessions).
- **Task 13:** ✅ `beeaef8` — `examples/smoke_check.py` graceful skip on −32010 (`_maybe_skip_eval` catches `SketchUpError` by `e.code == EVAL_DISABLED_CODE`; `sys.path.insert` under `__main__` guard; `eval_skipped=[0]`; new `tests/test_smoke_helpers.py`). spec ✅ + code ✅. Python 121→123.
- **Task 14 autonomous portion:** ✅ all design §12 invariants re-verified independently — Ruby 287/684, Python 123, both variants build with correct `EVAL_ENABLED_BY_DEFAULT` (warehouse=false / github=true), strict grep clean, wheel+twine PASS. spec ✅ + code ✅.
- **Carry-forward B:** ✅ `6a8ebf2` — `CLAUDE.md:74-75` test counts 230/516→287/684, 120→123. spec ✅ + code ✅.
- **Carry-forward C:** decided — **leave `release.md:5` heading «Breaking changes (v0.1.0)» as-is** (user choice; historically accurate). No action.
- **Carry-forward D:** ✅ applied — Step 14.5 grep run with the strict 12.8 pattern (`su_mcp|SU_MCP|Sketchup MCP Server|SketchUp MCP Server|SketchupMCP|SU_MCP_SERVER`) → empty.
- **Carry-forward A:** ✅ `a4f1d79` — release.md §7 + related sections corrected to the REAL process (see next section). spec ✅ + code ✅.

### Carry-forward A — the corrected release process (now in release.md, AUTHORITATIVE)

The user confirmed the real Extension Warehouse behavior (this differs from
design §8 and from what Task 12 had written):

- **github variant** → the user **self-signs** it via the Trimble
  extension-signing service (<https://extensions.sketchup.com/developer/sign-extension>),
  then uploads the **signed** `.rbz` to **GitHub Releases**.
- **warehouse variant** → uploaded to the EW intake form **UNSIGNED**
  (do NOT pre-sign). The EW form value "Encryption Type: Encrypt"
  requests Trimble's signing, which happens **after** the 2–3 day review.

release.md now states this consistently everywhere. No further doc work
needed unless the live Trimble intake (Step 14.0) contradicts it.

## ⛔ REMAINING (all user-gated / interactive)

### Built artifacts (ready, gitignored, v0.2.0, ~53 KB each)
- `mcp_for_sketchup/mcp_for_sketchup_v0.2.0-warehouse.rbz`
- `mcp_for_sketchup/mcp_for_sketchup_v0.2.0-github.rbz`
(Rebuild if stale: `cd mcp_for_sketchup && ruby package.rb --variant=warehouse && ruby package.rb --variant=github && cd ..`)

### MCP setup for live verification (IMPORTANT)
- The `sketchup` MCP server (configured in `.mcp.json`) runs the **local
  editable** package: `uv run --directory /opt/github/zinin/sketchup-mcp2
  python -m sketchup_mcp` → **version 0.2.0** (matches the plugin; v0.2.0
  is NOT on PyPI yet, so the local install is what makes the handshake
  succeed — MIN_RUBY=MAX_RUBY=0.2.0).
- It connects to SketchUp at **`192.168.20.20:9876`** (SketchUp is on a
  separate machine). The user installs the `.rbz` THERE and runs
  `Plugins → MCP Server → Start Server`.
- Pre-approved tools in `.claude/settings.local.json`:
  `mcp__sketchup__{get_model_info,create_component,set_material,transform_component,eval_ruby,list_components}`.
  Others (`get_version`, etc.) may prompt.

### Step 14.7-A — NEW FINDING (2026-05-29): Settings dialog has a scrollbar — remove it

During warehouse acceptance the user installed `…-warehouse.rbz`, opened
`Plugins → MCP Server → Settings…`, and confirmed (screenshot) the rebrand
is visually correct: title **"MCP Server for SketchUp Settings"**, sections
**Network / Logging / Ruby Evaluation**, all three new fields present (Log
to file, Log file path, Enable Ruby evaluation), and the eval note **"Off
by default in this build."** ✅ BUT the dialog now shows a **vertical
scrollbar** and the bottom warning line is partly clipped. **The user
wants NO scroll** (their suggestion: make the window wider).

- **Cause:** Task 8 (`d3423c2`, iter-1 CONCERN-4) set the HtmlDialog to
  `height: 480, scrollable: true` to avoid truncation on Windows scaling.
  At the user's DPI the content needs a little more room, so it scrolls.
- **Fix direction:** in `ui/settings_dialog.rb` (the HtmlDialog
  constructor — `width`/`height`/`scrollable` were patched in Task 8)
  increase **width** so the wrapping labels ("Log to file (in addition to
  console)", "Enable Ruby evaluation (DANGEROUS)", the bottom warning
  paragraph) fit on fewer lines → less height; and/or bump height to fit
  all content, then set `scrollable: false`. May also touch
  `ui/settings.html` (CSS/spacing). Goal: at default Windows scaling ALL
  content (through the eval warning) is visible with NO scrollbar — but
  keep height sane so it still fits a laptop screen. Re-check the original
  CONCERN-4 worry (don't reintroduce truncation on high-DPI Windows).
- **This is a real code change** → spec+code review (Opus), then **rebuild
  BOTH variants** (shared UI), user reinstalls, re-confirm no scrollbar.
- **Sequence:** do this fix FIRST (autonomous + review + rebuild both
  `.rbz`), THEN the user reinstalls and you proceed to the live MCP
  acceptance below.

> Live MCP acceptance is still PENDING — the `sketchup` MCP server did NOT
> connect in the prior session (plugin was not started / SketchUp not
> reachable yet). The fresh session must establish the MCP connection (see
> "MCP setup" above; ToolSearch `mcp__sketchup__get_version`) before the
> per-variant checks below.

### Step 14.7 — live acceptance (collaborative: user installs, you verify via MCP)

Run the user's plan: they install one variant at a time; you verify live.
Keep MCP calls LEAN (prefer text tools; `get_viewport_screenshot` returns
a big image — use sparingly).

**WAREHOUSE variant (eval OFF by default):**
1. `get_version` → ruby_version `0.2.0`, handshake compatible. (Confirms the rebrand build loads + version-match.)
2. `eval_ruby(code:"1+1")` → MUST return the actionable **−32010** disabled message ("eval_ruby is disabled. Open Plugins → MCP Server → Settings…"). This is THE key warehouse gate check.
3. `create_component(type:"cube", dimensions:[100,100,100])` → succeeds, `bbox_mm` ~100³. (Confirms typed tools work without eval.)
4. `get_model_info` / `list_components` → sane. Clean up the cube (`delete_component`) if desired.
5. Manual (user eyeballs in SketchUp): Extension Manager shows display name **"MCP Server for SketchUp"** + creator; Settings dialog has Network / Logging / Ruby Evaluation sections; console lines prefixed `[MCPforSU]`; (optional) enable eval in Settings → confirm the security messagebox → retry eval_ruby succeeds; log-to-file + Show Log.

**GITHUB variant (eval ON by default):** user uninstalls warehouse, installs github, restarts, starts server. Then:
1. `get_version` → 0.2.0 compatible.
2. `eval_ruby(code:"Sketchup.active_model.entities.length")` → **succeeds** (returns an int) — no enabling needed. This is THE key github check.

If all pass → the build is acceptance-verified and ready to ship.

### Step 14.0 — Trimble intake pre-check (user, web form)
Open <https://extensions.sketchup.com/developer/submit>; confirm (1) a brand-new `product_id` `MCP_FOR_SKETCHUP` is accepted without linking to the dead v0.1.0 listing, and (2) the **unsigned** upload + EW-side signing flow matches release.md (carry-forward A). If the form contradicts release.md, surface to the user before submission.

### Step 14.8 — push (only on explicit user OK; global CLAUDE.md: push only when asked)
```bash
git push -u origin feature/warehouse-resubmit
```

### Step 14.9 — PR (after 14.7 acceptance passes)
Per global CLAUDE.md, the design + plan docs must NOT appear in the PR diff:
```bash
git rm docs/superpowers/specs/2026-05-28-warehouse-resubmit-design.md \
       docs/superpowers/plans/2026-05-28-warehouse-resubmit.md
git commit -m "chore: remove plan/spec docs before PR (kept in branch history)"
git push
gh pr create   # standard workflow; base = master
```
(Only the two tracked superpowers docs above need `git rm` — the many
untracked continuation prompts/specs are not in git and won't appear in
the diff. Verify with `git status` first.)

## CONVENTIONS (still active)
- Commit policy: explicit `git add <path>`, NEVER `-A`/`.`. Confirm `git status` before staging.
- Surgical edits, not whole-file replace. Pre-verify anchors; on drift, STOP and ask.
- Both test suites must stay green: Ruby 287/684, Python 123.
- Reviews: any further code change goes through spec ✅ + code ✅ (per the session's /do-plan rigor), Opus subagents.

## INSTRUCTIONS
1. Read this doc + skim the design/plan. `git log --oneline -6`, `git status`.
2. Check the `sketchup` MCP connection (ToolSearch `mcp__sketchup__get_version`). If absent → ask user to install+start the plugin.
3. ≤6-line summary, then WAIT for the user to say which variant is installed.
4. Drive Step 14.7 live verification (lean MCP calls), then 14.0 → 14.8 → 14.9 as the user authorizes each. Do NOT push or open the PR without explicit user go-ahead.
