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

✅ Done — see commit(s): `76b1fce` (smoke step 19 + renumber cleanup→20, undo→21; `import base64` later hoisted to module top in `883a903`).

---

## Task 8: Documentation — CLAUDE.md

✅ Done — see commit(s): `bb5a45d` (View row + SU 2026 version blockquote + MCP Prompts subsection); follow-up `883a903` (refresh stale test/step counts, add `prompts.py`/`view.rb`/`ui/` to architecture tables, sharpen version note, extract dormant `prompts/list` to `> Note:` block).

---

## Task 9: Documentation — Ruby cookbook

✅ Done — see commit(s): `08d3aa0` (initial Viewport snapshot via `View#write_image` recipe); `822d01f` (apply 8 review fixes: compression-comment correction, preserve perspective, defensive bb.diagonal check, drop "iter-1" marker, soften SU 2026 phrasing, add bytes peek + zoom_extents comment, move section before Common pitfalls); `883a903` (note that production handler uses `Helpers::Geometry.visible_bounds`, not `model.bounds`).

---

## Task 10: Documentation — README

✅ Done — see commit(s): `a6a10c7` (two Features bullets — viewport snapshots + modeling-strategy prompt); follow-up `883a903` (tighten Features bullets, add `get_viewport_screenshot` to detailed Tools catalog under Visual: section).

---

## Task 11: Final verification

✅ Done — pytest **81 passed / 0 failed / 0 skipped**, ruby **154 runs / 354 assertions / 0 failures / 0 errors / 0 skips**. Live SketchUp 2026 verification performed via direct MCP tool calls (`get_model_info`, `get_viewport_screenshot` across all combinations of view_preset/style/zoom_extents/restore_view, `create_component` + `undo`) — all green; visual checks confirmed iso/top/wireframe/shaded/hidden_line render correctly and `restore_view=true` returns viewport to original state after the call. `examples/smoke_check.py` step 19 (the integration-test equivalent) was added in commit `76b1fce`; the full 21-step run against a live SU session was NOT executed (functional equivalent already covered by MCP-tool live verification — both exercise the same Ruby JSON-RPC path).

> **NOT done in this session (intentionally user-only per global CLAUDE.md rule):**
> - `git rm docs/superpowers/specs/2026-05-16-viewport-screenshot-and-prompt-design.md` + plan file before opening PR.
> - Open PR / merge to master.
> - Post-merge: bump `pyproject.toml` version (proposed `0.1.0`), `uv lock`, follow `docs/release.md`, rebuild `.rbz` for distribution.

The SketchUp `.rbz` package (`su_mcp/su_mcp_v0.0.3.rbz`) was rebuilt in this session (May 16, 20:35) and reinstalled into SketchUp for live verification — version string still `0.0.3` (bump happens with the PyPI release after merge).

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
