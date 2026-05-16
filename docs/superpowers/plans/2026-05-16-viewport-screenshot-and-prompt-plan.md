# Viewport Screenshot Tool + Modeling Strategy Prompt — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a single MCP tool `get_viewport_screenshot` (returns the current SketchUp viewport as an `Image`) and a single MCP prompt `sketchup_modeling_strategy` (usage guidance for Claude) — ported from blender-mcp, adapted to our typed-tools-first architecture.

**Architecture:** Two additions, both fully additive. Python side: new `prompts.py` registered via side-effect import in `app.py`; new `get_viewport_screenshot` wrapper in `tools.py` that round-trips a JSON-RPC call returning base64 PNG and wraps it in `mcp.server.fastmcp.Image`. Ruby side: new `handlers/view.rb` that snapshots camera + rendering options, applies optional `view_preset`/`style`/`zoom_extents`, calls `view.write_image`, base64-encodes, then restores state. No wire-protocol changes; existing 4-byte length-prefix framing carries the ~300 KiB – 1 MiB PNG payload comfortably under the 64 MiB cap.

**Tech Stack:** Python 3.10+, FastMCP, Pydantic v2, pytest (Python tests); Ruby 2.7 inside SketchUp, minitest (Ruby tests), SketchUp Ruby API (`View#write_image`, `Sketchup.send_action`, `model.rendering_options`).

**Reference spec:** `docs/superpowers/specs/2026-05-16-viewport-screenshot-and-prompt-design.md`.

**Branch (already created):** `feature/viewport-screenshot-and-prompt`.

---

## File Structure

### Files to CREATE

| Path | Responsibility |
|---|---|
| `src/sketchup_mcp/prompts.py` | Defines `sketchup_modeling_strategy` MCP prompt; pure text constant + one `@mcp.prompt`-decorated function. |
| `tests/test_prompts.py` | Asserts registration, body length, anchor phrases, description presence. |
| `tests/test_screenshot.py` | Asserts Python tool wrapper: validation, payload shape, base64-decoding, `Image` return, error propagation. |
| `su_mcp/su_mcp/handlers/view.rb` | Ruby handler `Handlers::View.viewport_screenshot`: validation, camera/RO snapshot/restore, direct `view.camera=` for preset (no `send_action`), write_image to tmpfile, base64 response. |
| `test/test_view.rb` | Ruby unit tests for the handler using minitest stubs of `Sketchup::*` API. |

### Files to MODIFY

| Path | Change |
|---|---|
| `src/sketchup_mcp/app.py` | One extra side-effect import (`import sketchup_mcp.prompts`) next to existing `import sketchup_mcp.tools` at app.py:51. |
| `src/sketchup_mcp/tools.py` | One new `@mcp.tool()`-decorated function `get_viewport_screenshot` near the existing `get_model_info` block (line 282-ish). |
| `su_mcp/su_mcp/main.rb` | One new entry `handlers/view` in `LOAD_ORDER` after `handlers/eval`. |
| `su_mcp/su_mcp/handlers/dispatch.rb` | One new `when "get_viewport_screenshot"` branch in `call_handler` (around dispatch.rb:111). |
| `examples/smoke_check.py` | One new step exercising the new tool against the live server. |
| `CLAUDE.md` | New "View" row in the tool category table; short paragraph documenting that the server exposes one MCP prompt. |
| `docs/sketchup-ruby-cookbook.md` | New section "Viewport snapshot via View#write_image" with the save → mutate → restore pattern. |
| `README.md` | One-line mention of `get_viewport_screenshot` in feature list; one-line mention of the modeling prompt. |

### Files NOT touched (sanity check)

- `src/sketchup_mcp/config.py` — no new env vars.
- `src/sketchup_mcp/errors.py` — no new error types.
- `su_mcp/su_mcp/core/*.rb` — server, framing, errors unchanged.
- `su_mcp/su_mcp/handlers/{geometry,operations,joints,materials,export,model,eval}.rb` — all existing handlers untouched.
- `pyproject.toml`, `uv.lock` — no new dependencies (FastMCP already provides `Image`); `asyncio_mode = "auto"` is already set at `pyproject.toml:48-49`.

> `src/sketchup_mcp/connection.py` is touched by one tiny addition to
> `_RETRY_SAFE_TOOLS` — see Task 4 step 4.3.

---

## Task 0: Pre-implementation acceptance gate — COMPLETED in review iter 1

All four empirical checks were performed during review iter 1 against
a live SketchUp 2026 session (see commit log). Results, used to shape
§5.2 and §5.3 of the design:

- [x] **Step 0.1: `rendering_options` write-ability** — `DisplayShaded`,
      `DisplayShadedUsingAllSameObject`, `DrawEdges`, `DrawFaces` are
      **WRITE-REJECTED** in SketchUp 2026 (`ArgumentError`). Working
      writeable keys: `RenderMode` (0..7), `DrawHidden`, `DrawProfilesOnly`,
      `Texture`, `DrawBackEdges`. **Design §5.3 was rewritten to use
      `RenderMode` enum exclusively.**
- [x] **Step 0.2: `view.camera` identity** — returns a fresh object each
      call (different `object_id`). Deep-copy snapshot via
      `Sketchup::Camera.new(eye, target, up)` confirmed correct.
- [x] **Step 0.3: `rendering_options[]=` undo behavior** — does NOT trigger
      `ModelObserver#onTransactionStart`/`Commit`. Confirmed via a
      live observer in the test session. §5.5 design assumption holds —
      no `start_operation` wrap needed.
- [x] **Step 0.4: `Sketchup.send_action("view{Preset}:")` synchronicity** —
      **ASYNCHRONOUS**. Camera unchanged before the call returns,
      verified for `viewIso:`, `viewTop:`, `viewFront:`. **Design §5.2
      was rewritten to use direct `view.camera = Sketchup::Camera.new(...)`
      assignment** (verified synchronous in the same test session).

No live-SU checks remain blocking. Implementation can proceed.

---

## Task 1: Python prompt — failing tests

✅ Done — see commit(s): `90435e2` (combined with Task 2 — TDD pair commit).

---

## Task 2: Python prompt — implementation

✅ Done — see commit(s): `90435e2`.

---

## Task 3: Python screenshot wrapper — failing tests

✅ Done — see commit(s): `8cc7f47` (combined with Task 4 — TDD pair commit); fixup `0b18223`.

---

## Task 4: Python screenshot wrapper — implementation

✅ Done — see commit(s): `8cc7f47`; review-fixup `0b18223` (docstring, PEP 570 rationale, async test, ConnectionError contract test).

---

## Task 5: Ruby view handler — failing tests

✅ Done — see commit(s): `690397a` (combined with Task 6 — TDD pair commit); fixup `49357f5`.

---

## Task 6: Ruby view handler — implementation + wiring

✅ Done — see commit(s): `690397a`; review-fixup `49357f5` (direct `visible_bounds` tests, `restore_view` scope comment, validation reorder, comment fixes).

---

## Task 7: Live smoke check

**Files:**
- Modify: `examples/smoke_check.py`

- [ ] **Step 7.1: Read current smoke check end**

Run: `wc -l examples/smoke_check.py && tail -30 examples/smoke_check.py`

Identify the last step number and the cleanup section (if any).

- [ ] **Step 7.2: Add the screenshot step (with renumber)**

The existing `smoke_check.py` calls Ruby directly through the
`SketchUpConnection.send_command`-based `call(conn, tool, **args)` helper
(it does NOT use FastMCP's `ClientSession` — Python MCP server is not
booted by the smoke). Match that convention. FastMCP-level `Image`
serialization is already covered by `test_screenshot_via_mcp_dispatch`
in `tests/test_screenshot.py`, so no live FastMCP testing is needed.

The current tail of `smoke_check.py` numbers cleanup as `step = 19` and
undo as `step = 20`. The screenshot is inserted BEFORE cleanup so it
exercises the tool on a populated model. **Renumber while you're there:**
screenshot becomes `step = 19`, cleanup shifts to `step = 20`, undo
shifts to `step = 21`. Otherwise the printed step sequence will skip a
number and the new step won't be exercised in the natural order.

Insert the following block immediately before the existing `step = 19`
(cleanup) block, then bump the cleanup `step = 19` → `step = 20` and the
undo `step = 20` → `step = 21`:

```python
    import base64

    step = 19; print(f"[{step}] get_viewport_screenshot — exercise the new tool")
    result = await call(
        conn, "get_viewport_screenshot",
        view_preset="iso", zoom_extents=True, max_size=640,
        style="default", restore_view=True,
    )
    payload = json.loads(text_of(result))
    # Structural assertions — response shape.
    for key in ("png_base64", "width", "height", "preset_used", "style_used"):
        assert key in payload, f"missing {key!r} in {payload!r}"
    assert payload["preset_used"] == "iso", f"unexpected preset_used: {payload['preset_used']!r}"
    assert payload["style_used"] == "default", f"unexpected style_used: {payload['style_used']!r}"
    # Dimension sanity — width/height are positive integers, both ≤ max_size=640.
    w, h = payload["width"], payload["height"]
    assert isinstance(w, int) and isinstance(h, int), f"non-int dimensions: {w!r}×{h!r}"
    assert 0 < w <= 640 and 0 < h <= 640, f"dimensions out of bounds: {w}×{h}"
    # Content sanity — must be a non-trivial PNG (a valid 1×1 PNG is ~70 bytes;
    # require > 1024 bytes to rule out blank/empty captures).
    png = base64.b64decode(payload["png_base64"])
    assert png.startswith(b"\x89PNG\r\n\x1a\n"), \
        f"missing PNG magic header: got {png[0:8]!r}"
    assert len(png) > 1024, f"PNG suspiciously small: {len(png)} bytes"
    print(f"    PNG ok: {len(png)} bytes, {w}×{h}, preset={payload['preset_used']}")
```

- [ ] **Step 7.3: Sanity check that the smoke check still parses**

Run: `uv run python -c "import ast; ast.parse(open('examples/smoke_check.py').read()); print('parses OK')"`

Expected: `parses OK`.

- [ ] **Step 7.4: Run the smoke check against live SketchUp (manual)**

This requires SketchUp running with the rebuilt plugin loaded. Rebuild and reload:

```bash
cd su_mcp && ruby package.rb && cd ..
# install the .rbz into SketchUp via Extension Manager,
# then from SketchUp menu: Plugins → MCP Server → Start Server
```

Then run: `python examples/smoke_check.py`

Expected: all 21 steps print success in consecutive order (1, 2, …, 19=screenshot, 20=cleanup, 21=undo); final exit code 0.

If SketchUp is not available right now, mark this step as "deferred until SketchUp available" — do not block the rest of the plan on it. Document the deferral in the PR description.

- [ ] **Step 7.5: Commit**

```bash
git add examples/smoke_check.py
git commit -m "test(smoke): exercise get_viewport_screenshot in smoke check

New step 21 calls the tool with view_preset=iso, zoom_extents=true,
max_size=640 and asserts the response is a non-trivial image/png."
```

---

## Task 8: Documentation — CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 8.1: Locate the Tool categories table**

Run: `grep -n "Tool categories" CLAUDE.md` to find the section.

- [ ] **Step 8.2: Add a "View" row**

Find the table that looks like:

```markdown
| Category | Tools |
|---|---|
| Geometry | `create_component`, ... |
| ... |
| Introspection | `get_model_info`, `list_components`, ... |
| Lifecycle | `undo` |
| Scripting | `eval_ruby` |
```

Insert a new row after `Introspection`:

```markdown
| View | `get_viewport_screenshot` (returns MCP Image; optional view_preset/style/zoom_extents; non-destructive by default; **requires SketchUp 2026+** — see below) |
```

Also add a note immediately after the table:

```markdown
> **SketchUp version requirement (viewport screenshot only):** the
> `get_viewport_screenshot` tool relies on SketchUp 2026 behavior for
> `view.camera=` (synchronous), `Sketchup::RenderingOptions["RenderMode"]`
> writability, and `Sketchup::Camera#is_2d?`. Earlier SketchUp versions
> may work but are not tested and not officially supported by this tool.
> All other tools target the same baseline as the rest of the plugin.
```

- [ ] **Step 8.3: Add a Prompts paragraph**

Find a logical home (near the bottom of the Architecture section, or at the end of the file before "Releasing"). Add a short subsection:

```markdown
## MCP Prompts

The server exposes one MCP prompt — `sketchup_modeling_strategy` —
defined in `src/sketchup_mcp/prompts.py`. It teaches Claude the
project conventions (pre-flight checks, typed-tools-vs-`eval_ruby`,
millimeter/degree units, post-mutation `bbox_mm` verification, known
traps). MCP-aware clients (e.g. Claude Desktop) surface it in the
slash menu. Ruby `handlers/dispatch.rb` still has a dormant
`prompts/list → []` branch — FastMCP serves prompts Python-side and
never forwards `prompts/*` to Ruby, so the branch is never exercised
but left in place for safety.
```

- [ ] **Step 8.4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude-md): document viewport screenshot tool and MCP prompts"
```

---

## Task 9: Documentation — Ruby cookbook

**Files:**
- Modify: `docs/sketchup-ruby-cookbook.md`

- [ ] **Step 9.1: Append a new section to the cookbook**

Append to the end of `docs/sketchup-ruby-cookbook.md`:

```markdown
## Viewport snapshot via `View#write_image`

For non-destructive screenshots, deep-copy the camera and snapshot the
rendering-options keys you intend to change, mutate, write the image,
then restore. `View#camera=` and `RenderingOptions[]=` are UI state —
they don't enter the undo stack — so you don't need `model.start_operation`.

**Important notes for SketchUp 2026** (verified empirically):

- `Sketchup.send_action("viewIso:")` is **asynchronous** — the camera does
  NOT change before the call returns. Use direct `view.camera =
  Sketchup::Camera.new(eye, target, up)` for synchronous, locale-independent
  preset switching.
- The boolean rendering-options keys `DisplayShaded`, `DrawEdges`, `DrawFaces`
  are **WRITE-REJECTED** (`ArgumentError`). For switching rendering style use
  the `RenderMode` integer enum (`0` Wireframe / `1` Hidden Line / `2` Shaded /
  `3` Textured Shaded / `4` Monochrome / `5` Sketchy / `6` X-Ray).

```ruby
view  = Sketchup.active_model.active_view
model = view.model

# --- snapshot (deep copy — protects against future API changes that might
# return live references; iter-1 verified `view.camera` returns a fresh
# wrapper today, but the deep copy is defence-in-depth) ---
c = view.camera
snap_camera = Sketchup::Camera.new(c.eye, c.target, c.up)
snap_camera.perspective = c.perspective?
if c.perspective?
  snap_camera.fov = c.fov
else
  snap_camera.height = c.height
end
ro_keys = ["RenderMode"]
snap_ro = ro_keys.map { |k| [k, model.rendering_options[k]] }.to_h

# --- mutate (direct camera assignment + RenderMode enum) ---
bb     = model.bounds
center = bb.center
dist   = (bb.diagonal.zero? ? 1000.0 : bb.diagonal) * 1.5
offset = Geom::Vector3d.new(1, -1, 1)
offset.length = dist
eye    = center + offset
view.camera = Sketchup::Camera.new(eye, center, Geom::Vector3d.new(0, 0, 1))
model.rendering_options["RenderMode"] = 2  # 2 = Shaded
view.zoom_extents

require "tempfile"
Tempfile.create(["snap_", ".png"]) do |tmp|
  tmp.close
  ok = view.write_image(
    filename: tmp.path,
    width: 800, height: 450,
    antialias: true,
    compression: 1.0,             # PNG is always lossless; 1.0 = strongest compression
    transparent: false,
  )
  raise "write_image failed" unless ok

  bytes = File.binread(tmp.path)
  # ... use bytes (Base64.strict_encode64 for transport) ...
end                                 # Tempfile auto-deletes here

# --- restore ---
view.camera = snap_camera
snap_ro.each { |k, v| model.rendering_options[k] = v }
```

Used internally by `Handlers::View.viewport_screenshot` (see
`su_mcp/su_mcp/handlers/view.rb`).
```

- [ ] **Step 9.2: Commit**

```bash
git add docs/sketchup-ruby-cookbook.md
git commit -m "docs(cookbook): add viewport snapshot recipe"
```

---

## Task 10: Documentation — README

**Files:**
- Modify: `README.md`

- [ ] **Step 10.1: Add screenshot/prompts mentions to Features list**

Open `README.md`. Find the Features bullet list (currently after "SketchupMCP connects Sketchup ..."). Add two bullets at the end of the list:

```markdown
* **Viewport snapshots**: `get_viewport_screenshot` returns the current SketchUp viewport as an MCP `Image`, so Claude can visually verify the scene between operations. Optional `view_preset` / `style` / `zoom_extents`; restores camera and rendering options after the snapshot by default.
* **Modeling-strategy prompt**: an MCP prompt `sketchup_modeling_strategy` is available in the slash menu of MCP-aware clients — insert it at the start of a chat to teach Claude the project conventions (pre-flight checks, typed-tools-vs-`eval_ruby`, millimeter units, post-mutation verification).
```

- [ ] **Step 10.2: Commit**

```bash
git add README.md
git commit -m "docs(readme): mention viewport screenshot tool and modeling prompt"
```

---

## Task 11: Final verification

- [ ] **Step 11.1: Run full Python test suite**

Run: `uv run pytest tests/ -q`

Expected: all green (existing 56 + 5 prompt + 8 screenshot + 1 connection regression = 70 tests).

- [ ] **Step 11.2: Run full Ruby test suite**

Run: `ruby test/run_all.rb`

Expected: all green (existing 120 runs + ~18 new test_view.rb runs).

- [ ] **Step 11.3: Confirm no untracked or modified files left behind**

Run: `git status`

Expected: working tree clean (or only the design/plan docs in `docs/superpowers/` which we will remove before PR).

- [ ] **Step 11.4: Reminder — remove design docs before PR**

Per the global CLAUDE.md rule: the spec and plan files in
`docs/superpowers/specs/` and `docs/superpowers/plans/` MUST NOT appear
in the final PR diff. Right before opening the PR:

```bash
git rm docs/superpowers/specs/2026-05-16-viewport-screenshot-and-prompt-design.md
git rm docs/superpowers/plans/2026-05-16-viewport-screenshot-and-prompt-plan.md
git commit -m "chore: remove design and plan docs from PR diff

Documents remain in branch git history; PR review focuses on code."
```

The docs stay accessible through the branch history. Do NOT do this step until the implementation is finished and you're ready to open the PR.

- [ ] **Step 11.5: Open the PR (or stop here)**

If everything is green and the design/plan docs have been removed:

```bash
gh pr create --title "feat: viewport screenshot tool and modeling-strategy prompt" \
  --body "$(cat <<'EOF'
## Summary
- Add `get_viewport_screenshot` MCP tool returning the current SketchUp viewport as an `Image`.
- Add `sketchup_modeling_strategy` MCP prompt with usage guidance for Claude.
- Non-destructive by default (snapshots and restores camera + rendering options).
- Two ports from blender-mcp adapted to our typed-tools-first architecture; out of scope: Sketchfab, Poly Haven, AI generation, telemetry.

## Test plan
- [x] `uv run pytest tests/ -q` — green (67 tests)
- [x] `ruby test/run_all.rb` — green
- [ ] `python examples/smoke_check.py` against live SketchUp (manual; mark deferred if not run)
- [ ] Manually verify `/sketchup_modeling_strategy` appears in Claude Desktop slash menu
EOF
)"
```

If SketchUp is not available, leave the smoke-check checkbox unchecked and note it in the PR body — do not block the PR on it.

- [ ] **Step 11.6: Post-merge — version bump (separate change)**

After PR merges into master:

1. Bump version in `pyproject.toml` (proposed `0.1.0`).
2. `uv lock`.
3. Follow `docs/release.md` step-by-step: build → twine check → TestPyPI verify → PyPI → `git tag v0.1.0` → GitHub release.
4. Rebuild `.rbz` for SketchUp users: `cd su_mcp && ruby package.rb`.

This is intentionally out of scope of this plan — it follows the existing release process unchanged.

---

## Self-Review Checklist (already completed by author)

- [x] **Spec coverage**: every section of the spec maps to at least one task.
  - §4 file structure → File Structure section.
  - §5 tool spec → Task 4 (Python wrapper), Task 6 (Ruby handler).
  - §5.3 style mapping → Task 6.1 (STYLE_RO constant).
  - §5.7 security → Task 4.2 (Literal/Field validators), Task 6.1 (require_max_size).
  - §6 prompt → Tasks 1-2.
  - §7.1 Python tests → Tasks 1 and 3.
  - §7.2 Ruby tests → Task 5.
  - §7.3 live smoke → Task 7.
  - §7.4 manual prompt check → mentioned in Task 11.5 PR body.
  - §7.5 TDD order → tasks are arranged in exactly that order.
  - §8 docs → Tasks 8-10.
  - §9 release → Task 11.4 (remove docs) and 11.6 (version bump).
  - §13 acceptance criteria → all covered by Tasks 1-11.

- [x] **Placeholder scan**: no `TBD`/`TODO`/"implement later"/"add validation" wording in steps; all code is concrete.

- [x] **Type consistency**: tool name is `get_viewport_screenshot` everywhere (Python @mcp.tool name, Ruby dispatch case, Ruby handler method, test assertions, smoke check). Field names (`png_base64`, `width`, `height`, `preset_used`, `style_used`) match between Ruby return Hash and Python decoding/Pydantic.

- [x] **Anchor phrases consistency**: Python `test_prompt_anchor_phrases` checks for the same strings (`get_model_info`, `millimeters`, `undo`, `eval_ruby`, `boolean_operation`, `bbox_mm`) that appear in the prompt text in Task 2.1 — verified by visual inspection.

- [x] **Validation values**: `MIN_MAX_SIZE=64`, `MAX_MAX_SIZE=4096` in Ruby (Task 6.1) match Pydantic `Field(ge=64, le=4096)` in Python (Task 4.2).
