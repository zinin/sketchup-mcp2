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

**Files:**
- Create: `tests/test_prompts.py`

- [ ] **Step 1.1: Write failing tests**

Create `tests/test_prompts.py`:

```python
"""Tests for the SketchUp modeling-strategy MCP prompt.

The prompt is registered as a side-effect of importing
``sketchup_mcp.prompts``. The module-level import below runs the
registration once for the whole test module (cheaper than a per-test
autouse fixture).
"""
import sketchup_mcp.prompts  # noqa: F401 — register the prompt for these tests

from sketchup_mcp.app import mcp


async def test_prompt_registered():
    prompts = await mcp.list_prompts()
    names = [p.name for p in prompts]
    assert "sketchup_modeling_strategy" in names


async def test_prompt_returns_non_empty_text():
    result = await mcp.get_prompt("sketchup_modeling_strategy", {})
    text = result.messages[0].content.text
    assert len(text) > 200, f"prompt body suspiciously short: {len(text)} chars"


async def test_prompt_anchor_phrases():
    """Guard rails — these phrases encode critical guidance and must
    survive future edits. If you intentionally rephrase one, update this
    test, but do NOT remove the concept."""
    result = await mcp.get_prompt("sketchup_modeling_strategy", {})
    text = result.messages[0].content.text
    for anchor in [
        "get_model_info",
        "millimeters",
        "undo",
        "eval_ruby",
        "boolean_operation",
        "bbox_mm",
    ]:
        assert anchor in text, f"missing anchor phrase: {anchor!r}"


async def test_prompt_required_sections():
    """Guard the structural skeleton of the prompt — section headers
    must all be present. Wording inside sections is allowed to drift;
    losing a whole section is not."""
    result = await mcp.get_prompt("sketchup_modeling_strategy", {})
    text = result.messages[0].content.text
    for section in [
        "# 1. Pre-flight",
        "# 2. Tool priority",
        "# 3. Conventions",
        "# 4. After every mutation",
        "# 5. Error recovery",
        "# 6. Known traps",
        "# 7. Joinery defaults",
    ]:
        assert section in text, f"missing section header: {section!r}"


async def test_prompt_description_present():
    prompts = await mcp.list_prompts()
    p = next(p for p in prompts if p.name == "sketchup_modeling_strategy")
    assert p.description
    assert "SketchUp" in p.description
```

> `asyncio_mode = "auto"` is already set in `pyproject.toml:48-49`, so
> the `async def` tests above run natively without `@pytest.mark.asyncio`.

- [ ] **Step 1.2: Run tests, verify they fail**

Run: `uv run pytest tests/test_prompts.py -v`

Expected: 5 errors (one per test). The exact error is
`ModuleNotFoundError: No module named 'sketchup_mcp.prompts'`, surfacing
at the file-level import.

Do NOT commit at this step. Failing tests don't ship alone.

---

## Task 2: Python prompt — implementation

**Files:**
- Create: `src/sketchup_mcp/prompts.py`
- Modify: `src/sketchup_mcp/app.py` (one new import at end of file)

> Note: `asyncio_mode = "auto"` is already set in `pyproject.toml:48-49`,
> so no asyncio-marker step is needed.

- [ ] **Step 2.1: Create `src/sketchup_mcp/prompts.py`**

```python
"""MCP prompts for SketchupMCP.

Imported for its side effect (FastMCP decorator registration). See
``app.py`` — the import sits next to ``import sketchup_mcp.tools``.
"""
from sketchup_mcp.app import mcp

_STRATEGY_TEXT = """\
You are working with a SketchUp model through the sketchup-mcp server.
Follow this strategy to be effective and avoid common pitfalls.

# 1. Pre-flight — ALWAYS start with
- get_model_info() — units, model bbox, layer list, total entity count.
- If the user references existing geometry: list_components or
  find_components(name=...) to locate IDs.
- For visual context after major changes:
  get_viewport_screenshot(view_preset="iso", zoom_extents=true).

# 2. Tool priority
1. Typed tools first — create_component, transform_component,
   set_material, boolean_operation, chamfer_edge, fillet_edge,
   create_mortise_tenon, create_dovetail, create_finger_joint,
   create_layer, delete_component. They handle units, transactions,
   and edge cases.
2. eval_ruby ONLY when typed tools cannot express the operation
   (custom curves, Follow Me, complex transformations,
   ComponentDefinition manipulation, layer attributes).
3. Never use eval_ruby for things a typed tool already does — you
   lose validation, mm-conversion, and atomic undo.

# 3. Conventions
- ALL linear dimensions are millimeters at the MCP boundary.
  SketchUp's Ruby API uses inches internally; the server converts.
- ALL angles are degrees.
- Entity IDs are integers but accept strings (server casts via .to_i).
- New geometry lives inside SketchUp Groups so it can be moved/deleted
  as a unit.

# 4. After every mutation — verify
- Geometry, material, boolean, joinery, and edge tools that create or
  modify a single entity return {id, name, type, bbox_mm}. When bbox_mm
  is returned, read it to confirm the result matches the intent before
  the next step (and to relocate the entity if its id becomes stale
  after destructive operations like boolean_operation).
- Other tools — delete_component, create_layer, undo, list/find
  queries, get_model_info, get_selection — have their own response
  shapes; see the tool docs.
- For visual confirmation across multiple parts:
  get_viewport_screenshot(view_preset="iso", zoom_extents=true).

# 5. Error recovery
- If a mutation produced wrong geometry — call undo immediately, then
  retry with corrected parameters. Do not pile up bad geometry hoping
  to fix it later.
- boolean_operation, chamfer_edge, fillet_edge are unreliable on
  non-manifold meshes. If they fail, try with simpler input or use
  eval_ruby for a manual workaround.

# 6. Known traps
- Group#subtract is REVERSED: A.subtract(B) returns B - A. Inside
  eval_ruby, to get "target minus tool", call tool.subtract(target).
- Sketchup::Model#undo does not exist. The undo MCP tool uses
  Sketchup.send_action("editUndo:") internally — just call it.
- Layers in SketchUp are visibility flags, not folders. Adding an
  entity to a layer doesn't move it in the hierarchy.

# 7. Joinery defaults
For mortise/tenon/dovetail/finger joints, when the user doesn't
specify:
- joint dimensions ≈ 0.3-0.5 × board thickness;
- number of fingers/tails: 3-5 for typical drawer-width boards
  (200-400 mm);
- if uncertain, ASK before generating — joints are hard to fix after
  the fact without scrapping the boards.
"""


@mcp.prompt(
    name="sketchup_modeling_strategy",
    description=(
        "How to use SketchUp MCP tools effectively: pre-flight checks, "
        "typed-tools-vs-eval_ruby priority, units/angles conventions, "
        "verification after mutations, error recovery, known traps."
    ),
)
def sketchup_modeling_strategy() -> str:
    return _STRATEGY_TEXT
```

- [ ] **Step 2.2: Add side-effect import in `app.py`**

Open `src/sketchup_mcp/app.py`. Find line 51:

```python
import sketchup_mcp.tools  # noqa: E402, F401
```

Add immediately below (preserving the same `# noqa` pragma):

```python
import sketchup_mcp.prompts  # noqa: E402, F401
```

- [ ] **Step 2.3: Run tests**

Run: `uv run pytest tests/test_prompts.py -v`

Expected: 5 passes.

- [ ] **Step 2.4: Commit**

```bash
git add src/sketchup_mcp/prompts.py src/sketchup_mcp/app.py tests/test_prompts.py
git commit -m "feat(prompts): add sketchup_modeling_strategy MCP prompt

Registers a single MCP prompt teaching Claude the project conventions:
pre-flight checks (get_model_info), typed-tools-vs-eval_ruby priority,
millimeter/degree units, post-mutation verification via bbox_mm, undo
on error, known traps (reversed Group#subtract, etc.).

Side-effect import in app.py keeps registration in line with how
tools.py is loaded."
```

---

## Task 3: Python screenshot wrapper — failing tests

**Files:**
- Create: `tests/test_screenshot.py`

- [ ] **Step 3.1: Write failing tests**

Create `tests/test_screenshot.py`:

```python
"""Tests for the get_viewport_screenshot MCP tool wrapper.

Validation tests go through FastMCP's full dispatch path
(`mcp.call_tool`), not via a non-existent `.fn` attribute or direct
function call — that's the only way Pydantic validation actually runs.
Mime-type assertions use the public `img.format` constructor argument
rather than the private `img._mime_type` attribute.
"""
import base64
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from mcp.server.fastmcp import Image
from mcp.types import ImageContent

from sketchup_mcp.app import mcp
from sketchup_mcp.errors import SketchUpError

# 1×1 transparent PNG, base64-encoded. Real PNG bytes — starts with the
# PNG magic header so consumers (e.g. live smoke) can validate.
_TINY_PNG_B64 = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9Q"
    "DwADhgGAWjR9awAAAABJRU5ErkJggg=="
)
_TINY_PNG_BYTES = base64.b64decode(_TINY_PNG_B64)
assert _TINY_PNG_BYTES.startswith(b"\x89PNG\r\n\x1a\n"), "fixture PNG corrupted"


def _ruby_result_for(png_b64=_TINY_PNG_B64, w=1, h=1,
                     preset="current", style="default"):
    """Build the MCP-shaped JSON-RPC result our Ruby handler returns."""
    return {
        "content": [
            {
                "type": "text",
                "text": (
                    '{"png_base64": "' + png_b64 + '",'
                    f'"width": {w}, "height": {h},'
                    f'"preset_used": "{preset}", "style_used": "{style}"}}'
                ),
            }
        ],
        "isError": False,
    }


def _mock_connection(result):
    """Patch get_connection so its returned object's send_command yields ``result``."""
    conn = MagicMock()
    conn.send_command = AsyncMock(return_value=result)
    return patch("sketchup_mcp.tools.get_connection", AsyncMock(return_value=conn))


async def test_screenshot_minimal_payload():
    """Default call passes the full default param map to Ruby."""
    captured: dict = {}

    async def fake_send(name, args):
        captured["name"] = name
        captured["args"] = args
        return _ruby_result_for()

    conn = MagicMock()
    conn.send_command = AsyncMock(side_effect=fake_send)
    with patch("sketchup_mcp.tools.get_connection", AsyncMock(return_value=conn)):
        from sketchup_mcp.tools import get_viewport_screenshot

        await get_viewport_screenshot(ctx=None)  # type: ignore[arg-type]

    assert captured["name"] == "get_viewport_screenshot"
    assert captured["args"] == {
        "max_size": 800,
        "view_preset": "current",
        "zoom_extents": False,
        "style": "default",
        "restore_view": True,
    }


async def test_screenshot_max_size_clamps():
    """max_size below 64 or above 4096 is rejected by FastMCP/Pydantic
    validation — exercised through the dispatcher (``mcp.call_tool``)
    because that's where validation lives."""
    # Connection is mocked so failed-validation paths don't try to touch sockets.
    conn = MagicMock(); conn.send_command = AsyncMock(return_value=_ruby_result_for())
    with patch("sketchup_mcp.tools.get_connection", AsyncMock(return_value=conn)):
        # Force the screenshot wrapper to be importable+registered.
        import sketchup_mcp.tools  # noqa: F401
        for bad in (10, 99999):
            with pytest.raises(Exception) as exc_info:
                await mcp.call_tool("get_viewport_screenshot", {"max_size": bad})
            # FastMCP raises a Pydantic ValidationError-derived class — keep
            # the assertion loose so a future FastMCP version that wraps it
            # in its own error class doesn't break the test.
            assert "max_size" in str(exc_info.value)


async def test_screenshot_view_preset_invalid():
    conn = MagicMock(); conn.send_command = AsyncMock(return_value=_ruby_result_for())
    with patch("sketchup_mcp.tools.get_connection", AsyncMock(return_value=conn)):
        import sketchup_mcp.tools  # noqa: F401
        with pytest.raises(Exception) as exc_info:
            await mcp.call_tool("get_viewport_screenshot",
                                {"view_preset": "diagonal"})
        assert "view_preset" in str(exc_info.value)


async def test_screenshot_style_invalid():
    conn = MagicMock(); conn.send_command = AsyncMock(return_value=_ruby_result_for())
    with patch("sketchup_mcp.tools.get_connection", AsyncMock(return_value=conn)):
        import sketchup_mcp.tools  # noqa: F401
        with pytest.raises(Exception) as exc_info:
            await mcp.call_tool("get_viewport_screenshot", {"style": "cartoon"})
        assert "style" in str(exc_info.value)


async def test_screenshot_returns_image():
    """On success, the wrapper returns a FastMCP Image with PNG bytes."""
    with _mock_connection(_ruby_result_for(preset="iso", style="shaded")):
        from sketchup_mcp.tools import get_viewport_screenshot
        img = await get_viewport_screenshot(ctx=None)  # type: ignore[arg-type]

    assert isinstance(img, Image)
    assert img.data == _TINY_PNG_BYTES
    # Public `format` attribute — the constructor arg we passed.
    # Avoid `img._mime_type` / `img._format` (private FastMCP internals).
    # MIME/format is additionally verified via the dispatch path in
    # `test_screenshot_via_mcp_dispatch` which asserts ImageContent.mimeType.
    assert img.format == "png"


async def test_screenshot_via_mcp_dispatch():
    """End-to-end through FastMCP dispatcher: verifies the Image returned
    by the wrapper is serialized to ImageContent with mimeType=image/png
    in the MCP envelope. This catches FastMCP-side regressions that unit
    tests of the wrapper alone would miss."""
    with _mock_connection(_ruby_result_for(preset="iso", style="shaded")):
        import sketchup_mcp.tools  # noqa: F401
        result = await mcp.call_tool("get_viewport_screenshot",
                                     {"view_preset": "iso", "style": "shaded"})

    # FastMCP's call_tool returns a sequence of content blocks.
    contents = list(result)
    assert contents, "no content blocks returned"
    img_block = next((c for c in contents if isinstance(c, ImageContent)), None)
    assert img_block is not None, f"expected ImageContent, got {contents!r}"
    assert img_block.mimeType == "image/png"
    assert img_block.data, "image data is empty"
    # data is base64-encoded by ImageContent serializer.
    assert base64.b64decode(img_block.data).startswith(b"\x89PNG\r\n\x1a\n")


async def test_screenshot_base64_decode_failure():
    """Invalid base64 in Ruby response surfaces as a clear error."""
    bad = _ruby_result_for(png_b64="not-base64!@#$")
    with _mock_connection(bad):
        from sketchup_mcp.tools import get_viewport_screenshot
        with pytest.raises(SketchUpError):
            await get_viewport_screenshot(ctx=None)  # type: ignore[arg-type]


async def test_screenshot_propagates_ruby_error():
    """A JSON-RPC error from Ruby surfaces as SketchUpError."""
    conn = MagicMock()
    conn.send_command = AsyncMock(
        side_effect=SketchUpError(-32000, "viewport write_image failed")
    )
    with patch("sketchup_mcp.tools.get_connection", AsyncMock(return_value=conn)):
        from sketchup_mcp.tools import get_viewport_screenshot
        with pytest.raises(SketchUpError):
            await get_viewport_screenshot(ctx=None)  # type: ignore[arg-type]
```

- [ ] **Step 3.2: Run tests, verify they fail**

Run: `uv run pytest tests/test_screenshot.py -v`

Expected: All 8 tests fail. The first failures are
`ImportError: cannot import name 'get_viewport_screenshot' from 'sketchup_mcp.tools'`
(for tests that directly import it) and `Unknown tool: get_viewport_screenshot`
(for tests that go through `mcp.call_tool`).

Do NOT commit yet.

---

## Task 4: Python screenshot wrapper — implementation

**Files:**
- Modify: `src/sketchup_mcp/tools.py` (add imports + new function near line 282)

- [ ] **Step 4.0: Refactor `_call` to delegate to a new `_raw_call` helper**

In `src/sketchup_mcp/tools.py`, immediately above the existing `_call` (line ~21), add a small shared helper. Then rewrite `_call` to delegate to it.

```python
async def _raw_call(ctx: Context, tool_name: str, /, **kwargs) -> dict:
    """Acquire the connection and execute one tools/call.

    Returns the raw MCP-shaped result dict
    (``{"content": [...], "isError": False}``).

    Does **not** translate :class:`ConnectionError` to anything — that
    is each caller's responsibility, since callers have divergent
    strategies for unavailable-server (string-returning tools surface a
    graceful string, Image-returning tools raise). Centralising the
    conversion here would introduce brittle string-based detection in
    callers and lose the canonical error text shared by the 22 existing
    text-returning tools.

    See the design's §5.8 for the rationale on error-handling asymmetry
    between text-returning and Image-returning tools.
    """
    sketchup = await get_connection()              # may raise ConnectionError
    return await sketchup.send_command(tool_name, kwargs)  # raises SketchUpError


async def _call(ctx: Context, tool_name: str, /, **kwargs) -> str:
    """Dispatch a tool call to SketchUp and shape the response for Claude.

    Same external contract as before — kept for compatibility with the 22
    existing string-returning tools. Now delegates to :func:`_raw_call`
    for connection acquisition and converts the result to a string.
    Connection failures surface as the canonical legacy string so the LLM
    sees a stable, actionable hint.
    """
    try:
        result = await _raw_call(ctx, tool_name, **kwargs)
    except ConnectionError as e:
        return f"SketchUp not running or extension not started: {e}"
    except SketchUpError as e:
        return format_error(e, debug=config.LOG_LEVEL == "DEBUG")
    content = result.get("content") if isinstance(result, dict) else None
    if (
        isinstance(content, list)
        and content
        and isinstance(content[0], dict)
        and "text" in content[0]
    ):
        return content[0]["text"]
    return json.dumps(result)
```

This is a **pure refactor** of `_call` — the contract for existing 22 tools is unchanged (same input, same output, same graceful "SketchUp not running" string on connection failure). Run the existing test suite to confirm:

```
uv run pytest tests/test_tools.py -v
```

Expected: no regressions.

- [ ] **Step 4.1: Add imports at top of `src/sketchup_mcp/tools.py`**

Open `src/sketchup_mcp/tools.py`. The current import block (lines 6-16) is:

```python
import json
import logging
from typing import Annotated, Literal, Optional

from mcp.server.fastmcp import Context
from pydantic import Field

from sketchup_mcp import config
from sketchup_mcp.app import mcp
from sketchup_mcp.connection import get_connection
from sketchup_mcp.errors import SketchUpError, format_error
```

Add `Image` to the FastMCP import and `base64` to stdlib imports. The block becomes:

```python
import base64
import json
import logging
from typing import Annotated, Literal, Optional

from mcp.server.fastmcp import Context, Image
from pydantic import Field

from sketchup_mcp import config
from sketchup_mcp.app import mcp
from sketchup_mcp.connection import get_connection
from sketchup_mcp.errors import SketchUpError, format_error
```

- [ ] **Step 4.2: Add the new tool function**

Insert this **before** the existing `@mcp.tool() async def get_model_info` (currently at line 282) so it sits alongside introspection tools:

```python
@mcp.tool()
async def get_viewport_screenshot(
    ctx: Context,
    max_size: Annotated[int, Field(ge=64, le=4096)] = 800,
    view_preset: Literal[
        "current", "front", "back", "left", "right",
        "top", "bottom", "iso",
    ] = "current",
    zoom_extents: bool = False,
    style: Literal["default", "shaded", "hidden_line", "wireframe"] = "default",
    restore_view: bool = True,
) -> Image:
    """Capture the current SketchUp viewport as a PNG and return it as an MCP Image.

    Useful for letting Claude visually verify the scene between steps.

    Parameters
    - max_size: largest side of the returned PNG (64..4096). Aspect ratio is
      taken from the current viewport; the smaller side is scaled proportionally.
    - view_preset: switch the camera to a standard view before snapping.
      ``current`` leaves the camera alone.
    - zoom_extents: call view.zoom_extents before snapping.
    - style: temporarily flip a small set of rendering_options keys.
      ``default`` leaves them alone.
    - restore_view: when true (default), camera and rendering_options are
      snapshotted before mutation and restored after the snapshot, so the
      user's viewport is unchanged.

    Note on operation order (Ruby handler): snapshot → preset → style →
    zoom_extents → write_image → restore. Restore runs in an outer ``ensure``
    block, so an exception anywhere between snapshot and write_image still
    leaves the viewport in its original state.
    """
    # Delegate connection + send_command to _raw_call so we don't duplicate
    # the transport logic of _call. _raw_call does NOT translate
    # ConnectionError (text-tools and Image-tools have divergent strategies),
    # so we convert here: there is no Image sentinel for "not connected",
    # so raise SketchUpError. See design §5.8 for the error-handling
    # asymmetry rationale.
    try:
        raw = await _raw_call(
            ctx,
            "get_viewport_screenshot",
            max_size=max_size,
            view_preset=view_preset,
            zoom_extents=zoom_extents,
            style=style,
            restore_view=restore_view,
        )
    except ConnectionError as e:
        raise SketchUpError(-32000, f"SketchUp not running: {e}") from e

    # Ruby returns MCP-shaped {content: [{type: "text", text: JSON-blob}], ...}.
    # Extract the JSON blob and decode the base64 PNG into raw bytes.
    text: Optional[str] = None
    if isinstance(raw, dict):
        content = raw.get("content")
        if (
            isinstance(content, list)
            and content
            and isinstance(content[0], dict)
        ):
            text = content[0].get("text")
    if not isinstance(text, str):
        raise SketchUpError(
            -32603, f"unexpected screenshot response shape: {raw!r}"
        )
    try:
        payload = json.loads(text)
    except json.JSONDecodeError as e:
        raise SketchUpError(-32603, f"screenshot response not JSON: {e}") from e
    b64 = payload.get("png_base64")
    if not isinstance(b64, str):
        raise SketchUpError(-32603, "screenshot response missing png_base64")
    try:
        png_bytes = base64.b64decode(b64, validate=True)
    except (ValueError, base64.binascii.Error) as e:
        raise SketchUpError(-32603, f"png_base64 decode failed: {e}") from e
    return Image(data=png_bytes, format="png")
```

- [ ] **Step 4.3: Add tool to `_RETRY_SAFE_TOOLS`**

Open `src/sketchup_mcp/connection.py`. Find `_RETRY_SAFE_TOOLS` at line ~43. Add `"get_viewport_screenshot"` to the frozenset:

```python
_RETRY_SAFE_TOOLS: frozenset[str] = frozenset(
    {
        "get_model_info",
        "list_components",
        "get_component_info",
        "find_components",
        "list_layers",
        "get_selection",
        "get_viewport_screenshot",  # read-only viewport capture; idempotent in
                                    # both restore_view modes (no document state changes)
    }
)
```

- [ ] **Step 4.4: Add a regression test in `tests/test_connection.py`**

Append at the bottom of `tests/test_connection.py`:

```python
def test_get_viewport_screenshot_is_retry_safe():
    """get_viewport_screenshot is read-only (no document state changes
    in either restore_view mode); regression guard against accidental
    removal from the retry whitelist."""
    from sketchup_mcp.connection import _RETRY_SAFE_TOOLS
    assert "get_viewport_screenshot" in _RETRY_SAFE_TOOLS
```

- [ ] **Step 4.5: Run screenshot tests**

Run: `uv run pytest tests/test_screenshot.py tests/test_connection.py -v`

Expected: 8 screenshot tests + the new connection regression test pass.

If `test_screenshot_propagates_ruby_error` fails: check that the `except SketchUpError` is **not** caught — the wrapper should re-raise it as-is (Pydantic-level `ConnectionError` is the only one we rewrap).

- [ ] **Step 4.6: Run full Python test suite**

Run: `uv run pytest tests/ -q`

Expected: existing 56 tests + 5 prompt tests + 8 screenshot tests + 1 new connection test = 70 pass. No regressions.

- [ ] **Step 4.7: Commit**

```bash
git add src/sketchup_mcp/tools.py src/sketchup_mcp/connection.py \
        tests/test_screenshot.py tests/test_connection.py
git commit -m "feat(tools): add get_viewport_screenshot returning MCP Image + _raw_call refactor

- Extract _raw_call(ctx, name, /, **kw) -> dict from _call. Carries
  connection acquisition + send_command + ConnectionError-to-SketchUpError
  translation. The existing _call now delegates to _raw_call and adds the
  string formatting for the 22 text-returning tools (zero behavior change
  for them; tests/test_tools.py passes unchanged).

- New tool get_viewport_screenshot wraps Ruby handler:
  Pydantic-validates max_size/view_preset/zoom_extents/style/restore_view,
  round-trips through _raw_call, parses MCP envelope, base64-decodes
  png_base64, returns mcp.server.fastmcp.Image so Claude can see the
  scene between steps.

- Add get_viewport_screenshot to connection._RETRY_SAFE_TOOLS — the
  handler is idempotent (no document state changes in either restore_view
  mode), so stale-socket retry is safe. Regression test guards against
  accidental removal.

- Error-handling asymmetry between text-returning tools and the
  Image-returning screenshot is intentional and documented in design §5.8."
```

---

## Task 5: Ruby view handler — failing tests

**Files:**
- Create: `test/test_view.rb`

- [ ] **Step 5.1: Write the test file with stubs**

Create `test/test_view.rb`:

```ruby
# test/test_view.rb
#
# Unit tests for SU_MCP::Handlers::View.viewport_screenshot.
# Stubs the SketchUp API surface we touch: Sketchup module,
# Sketchup::Model, Sketchup::View, Sketchup::Camera, RenderingOptions.

require "minitest/autorun"
require "base64"
require "tmpdir"

# 1×1 transparent PNG bytes — used as the stubbed write_image output so
# tests assert real PNG magic bytes, not a "FAKE_PNG_BYTES" placeholder.
TINY_PNG_BYTES = Base64.strict_decode64(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9Q" \
  "DwADhgGAWjR9awAAAABJRU5ErkJggg=="
)

# --- Minimal SketchUp stubs ---------------------------------------------------
# We stub only the API our handler touches. Other tests in test/ already
# define some of these — Ruby ``module`` declarations are additive.

# Minimal Geom stubs the production handler uses.
module Geom
  class Point3d
    attr_reader :x, :y, :z
    def initialize(x = 0, y = 0, z = 0); @x, @y, @z = x, y, z; end
    def to_a; [@x, @y, @z]; end
    def ==(o); o.is_a?(Point3d) && x == o.x && y == o.y && z == o.z; end
    def +(v); Point3d.new(@x + v.x, @y + v.y, @z + v.z); end
  end
  class Vector3d
    attr_accessor :x, :y, :z
    def initialize(x = 0, y = 0, z = 0); @x, @y, @z = x, y, z; end
    def length
      Math.sqrt(@x * @x + @y * @y + @z * @z)
    end
    def length=(l)
      cur = length
      return if cur == 0
      f = l.to_f / cur
      @x *= f; @y *= f; @z *= f
    end
  end
end unless defined?(Geom::Vector3d)

module Sketchup
  class Camera
    attr_accessor :eye, :target, :up
    attr_writer :perspective, :fov, :height
    def initialize(eye = Geom::Point3d.new(0, 0, 0),
                   target = Geom::Point3d.new(0, 0, 0),
                   up = Geom::Vector3d.new(0, 0, 1))
      @eye, @target, @up = eye, target, up
      @perspective = true
      @fov = 35.0
      @height = 100.0
    end
    def perspective?; @perspective; end
    def fov; @fov; end
    def height; @height; end
    def ==(o)
      o.is_a?(Camera) &&
        coord_eq?(eye, o.eye) && coord_eq?(target, o.target) && coord_eq?(up, o.up) &&
        perspective? == o.perspective? && fov == o.fov && height == o.height
    end
    private
    def coord_eq?(a, b)
      ax = a.respond_to?(:x) ? [a.x, a.y, a.z] : a.to_a
      bx = b.respond_to?(:x) ? [b.x, b.y, b.z] : b.to_a
      ax == bx
    end
  end

  # Strict rendering_options stub modelled on SketchUp 2026 behavior:
  # - These keys are READ-able but WRITE-REJECTED (verified live):
  #   DisplayShaded, DisplayShadedUsingAllSameObject, DrawEdges, DrawFaces.
  # - These keys are READ + WRITE OK:
  #   RenderMode, DrawHidden, DrawProfilesOnly, Texture, DrawBackEdges.
  # Tracks all successful writes via `writes` for spy assertions.
  class RenderingOptionsStub
    WRITEABLE_KEYS = %w[RenderMode DrawHidden DrawProfilesOnly Texture DrawBackEdges].freeze
    READONLY_KEYS  = %w[DisplayShaded DisplayShadedUsingAllSameObject DrawEdges DrawFaces].freeze
    KNOWN_KEYS = (WRITEABLE_KEYS + READONLY_KEYS).freeze

    attr_reader :writes
    def initialize(initial)
      @data = initial.dup
      @writes = []
    end
    def [](k); @data[k]; end
    def []=(k, v)
      unless WRITEABLE_KEYS.include?(k)
        if READONLY_KEYS.include?(k)
          raise ArgumentError, "Rendering option could not be set to the given value"
        else
          raise ArgumentError, "unknown rendering_options key: #{k.inspect}"
        end
      end
      @writes << [k, v]
      @data[k] = v
    end
    def dup; @data.dup; end
    def each_pair(&blk); @data.each_pair(&blk); end
    def keys; @data.keys; end
  end

  # Minimal BoundingBox stub used by build_preset_camera.
  class BBox
    attr_reader :center
    def initialize(center: Geom::Point3d.new(0, 0, 0), diagonal: 1000.0)
      @center = center; @diag = diagonal
    end
    def diagonal; @diag; end
  end

  class View
    attr_accessor :model, :write_image_size_override, :zoom_extents_raises
    attr_reader :write_image_calls, :zoom_extents_calls, :camera_writes

    def initialize(model:)
      self.vpwidth = 1920          # NOTE: via setter, not direct ivar
      self.vpheight = 1080         # (see CONCERN-13 in review iter 1)
      @camera = Camera.new([10, 10, 10], [0, 0, 0], [0, 0, 1])
      @model = model
      @write_image_calls = []
      @zoom_extents_calls = 0
      @write_image_result = true
      @write_image_size_override = nil   # nil → write TINY_PNG_BYTES; integer → write that many bytes
      @zoom_extents_raises = false
      @camera_writes = []                # spy: every camera= assignment
    end

    attr_accessor :vpwidth, :vpheight
    attr_reader :camera

    def camera=(c)
      @camera_writes << c
      @camera = c
    end

    def write_image(filename:, width:, height:, antialias: nil, compression: nil, transparent: nil)
      @write_image_calls << {filename: filename, width: width, height: height,
                              compression: compression}
      if @write_image_result
        bytes = @write_image_size_override ? ("\x00" * @write_image_size_override) : TINY_PNG_BYTES
        File.binwrite(filename, bytes)
      end
      @write_image_result
    end

    def force_write_image_failure!; @write_image_result = false; end

    def zoom_extents
      raise StandardError, "stub zoom_extents failure" if @zoom_extents_raises
      @zoom_extents_calls += 1
    end
  end

  class Model
    attr_reader :rendering_options
    attr_accessor :bounds
    def initialize
      @rendering_options = RenderingOptionsStub.new(
        # Read-only keys, present but write-rejected.
        "DisplayShaded" => nil,
        "DisplayShadedUsingAllSameObject" => nil,
        "DrawEdges" => nil,
        "DrawFaces" => nil,
        # Writeable keys with realistic defaults.
        "RenderMode" => 2,            # shaded
        "DrawHidden" => false,
        "DrawProfilesOnly" => false,
        "Texture" => true,
        "DrawBackEdges" => false,
      )
      @bounds = BBox.new(
        center: Geom::Point3d.new(0, 0, 0),
        diagonal: 1000.0,
      )
    end
  end

  class << self
    attr_reader :send_action_calls

    def send_action(name)
      @send_action_calls ||= []
      @send_action_calls << name
      true
    end

    def reset_send_action_calls!; @send_action_calls = []; end
    def active_model; @active_model ||= Model.new; end
    def reset_active_model!; @active_model = Model.new; end
  end
end

# --- Load production code -----------------------------------------------------
# Order matters: errors / config / logger / helpers must precede dispatch
# (CRITICAL-6 in review iter 1 — dispatch.rb references Core::Logger).
require_relative "../su_mcp/su_mcp/core/errors"
require_relative "../su_mcp/su_mcp/core/config"
require_relative "../su_mcp/su_mcp/helpers/units"
require_relative "../su_mcp/su_mcp/core/logger"
require_relative "../su_mcp/su_mcp/helpers/validation"
require_relative "../su_mcp/su_mcp/helpers/entities"
require_relative "../su_mcp/su_mcp/handlers/view"
require_relative "../su_mcp/su_mcp/handlers/dispatch"

class TestView < Minitest::Test
  V = SU_MCP::Handlers::View

  def setup
    Sketchup.reset_send_action_calls!
    Sketchup.reset_active_model!
    @view = Sketchup::View.new(model: Sketchup.active_model)
    # Wire the view as model.active_view.
    Sketchup.active_model.instance_variable_set(:@__view, @view)
    Sketchup.active_model.define_singleton_method(:active_view) {
      instance_variable_get(:@__view)
    }
  end

  def call(params = {})
    V.viewport_screenshot({
      "max_size" => 800,
      "view_preset" => "current",
      "zoom_extents" => false,
      "style" => "default",
      "restore_view" => true,
    }.merge(params))
  end

  # --- dispatch routing -------------------------------------------------------

  def test_dispatch_routes_to_view_handler
    response = SU_MCP::Handlers::Dispatch.handle({
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "params" => {"name" => "get_viewport_screenshot",
                   "arguments" => {"max_size" => 800,
                                   "view_preset" => "current",
                                   "zoom_extents" => false,
                                   "style" => "default",
                                   "restore_view" => true}},
      "id" => 1,
    })
    assert_equal "2.0", response["jsonrpc"]
    assert_equal 1, response["id"]
    assert response["result"], "expected result key"
    refute response["result"]["isError"], "expected isError=false"
  end

  # --- validation -------------------------------------------------------------

  def test_invalid_view_preset_raises
    assert_raises(SU_MCP::Core::StructuredError) { call("view_preset" => "diagonal") }
  end

  def test_invalid_style_raises
    assert_raises(SU_MCP::Core::StructuredError) { call("style" => "cartoon") }
  end

  def test_invalid_max_size_too_small_raises
    assert_raises(SU_MCP::Core::StructuredError) { call("max_size" => 10) }
  end

  def test_invalid_max_size_too_large_raises
    assert_raises(SU_MCP::Core::StructuredError) { call("max_size" => 99999) }
  end

  def test_no_active_view_raises
    # Replace active_view with nil to simulate "SketchUp not ready".
    Sketchup.active_model.define_singleton_method(:active_view) { nil }
    assert_raises(SU_MCP::Core::StructuredError) { call }
  end

  # --- camera snapshot/restore -----------------------------------------------

  def test_camera_restored_when_flag_true
    # Production code now sets camera DIRECTLY (view.camera = Camera.new(...)),
    # so we can observe two assignments: (1) preset → new camera, (2) restore → snapshot.
    original = @view.camera
    call("view_preset" => "top", "restore_view" => true)
    # Expect at least 2 assignments: preset apply + restore.
    assert @view.camera_writes.size >= 2,
           "expected preset assignment + restore assignment; got #{@view.camera_writes.size}"
    # The FINAL camera (after handler return) must match the original snapshot
    # on every restorable property — not just `eye`. A broken restore that only
    # writes `eye` would otherwise pass.
    final_camera = @view.camera_writes.last
    assert_equal original.eye.to_a,    final_camera.eye.to_a,    "eye not restored"
    assert_equal original.target.to_a, final_camera.target.to_a, "target not restored"
    assert_equal original.up.to_a,     final_camera.up.to_a,     "up not restored"
    assert_equal original.perspective?, final_camera.perspective?, "perspective flag not restored"
    if original.perspective?
      assert_in_delta original.fov, final_camera.fov, 1e-6, "fov not restored"
    else
      assert_in_delta original.height, final_camera.height, 1e-6, "height not restored"
    end
  end

  def test_camera_not_restored_when_flag_false
    call("view_preset" => "top", "restore_view" => false)
    # With restore_view=false, we should see exactly ONE assignment (preset apply),
    # not two — restore step is skipped.
    assert_equal 1, @view.camera_writes.size,
                 "expected exactly 1 camera assignment (preset, no restore); got #{@view.camera_writes.size}"
  end

  def test_camera_restored_after_zoom_extents_failure
    # Outer ensure must restore camera even when zoom_extents raises (CRITICAL-3).
    # Combine with a preset switch so "restore" has something non-trivial to undo —
    # without the preset, the camera never changes and the test could pass even
    # if restore is broken.
    @view.zoom_extents_raises = true
    original = @view.camera
    # zoom_extents failure is swallowed by handler's inner `rescue StandardError`,
    # so call() returns normally — no rescue needed here.
    call("view_preset" => "top", "zoom_extents" => true, "restore_view" => true)
    # Full property check — any partial restore would slip past an `eye`-only assert.
    assert_equal original.eye.to_a,    @view.camera.eye.to_a,    "eye not restored"
    assert_equal original.target.to_a, @view.camera.target.to_a, "target not restored"
    assert_equal original.up.to_a,     @view.camera.up.to_a,     "up not restored"
    assert_equal original.perspective?, @view.camera.perspective?, "perspective flag not restored"
    if original.perspective?
      assert_in_delta original.fov, @view.camera.fov, 1e-6, "fov not restored"
    else
      assert_in_delta original.height, @view.camera.height, 1e-6, "height not restored"
    end
  end

  # --- rendering_options snapshot/restore -------------------------------------

  def test_rendering_options_restored_for_style
    # Pre-mutate RenderMode so we can detect proper restore (wireframe sets RenderMode=0).
    ro = Sketchup.active_model.rendering_options
    ro["RenderMode"] = 2  # shaded baseline
    snap_before = ro.dup

    call("style" => "wireframe", "restore_view" => true)

    assert_equal snap_before["RenderMode"], ro["RenderMode"],
                 "RenderMode not restored to baseline after wireframe style"
  end

  def test_rendering_options_restored_after_write_image_failure
    ro = Sketchup.active_model.rendering_options
    ro["RenderMode"] = 2  # baseline
    snap_before = ro.dup
    @view.force_write_image_failure!
    begin
      call("style" => "wireframe", "restore_view" => true)
    rescue SU_MCP::Core::StructuredError
      # expected
    end
    assert_equal snap_before["RenderMode"], ro["RenderMode"],
                 "RenderMode not restored after write_image failure"
  end

  def test_rendering_options_not_restored_when_restore_view_false
    ro = Sketchup.active_model.rendering_options
    ro["RenderMode"] = 2
    snap_before = ro.dup
    call("style" => "wireframe", "restore_view" => false)
    refute_equal snap_before["RenderMode"], ro["RenderMode"],
                 "RenderMode should remain mutated to 0 when restore_view=false"
  end

  def test_no_ro_touched_when_style_default
    pre_writes = Sketchup.active_model.rendering_options.writes.size
    call("style" => "default", "restore_view" => true)
    post_writes = Sketchup.active_model.rendering_options.writes.size
    assert_equal pre_writes, post_writes,
                 "no RO writes expected when style=default"
  end

  # --- preset / zoom_extents --------------------------------------------------

  def test_camera_assigned_for_preset
    # Production code sets camera DIRECTLY via view.camera = Sketchup::Camera.new(...).
    # `send_action` is no longer used for presets (it was async in SU 2026 — see review iter 1).
    call("view_preset" => "iso", "restore_view" => false)
    assert_equal 1, @view.camera_writes.size,
                 "expected camera assignment for preset (no restore)"
    refute_includes (Sketchup.send_action_calls || []), "viewIso:",
                    "production code must NOT call Sketchup.send_action for presets"
  end

  def test_no_camera_assigned_for_current_preset
    call("view_preset" => "current", "restore_view" => false)
    assert_empty @view.camera_writes,
                 "no camera assignment expected for view_preset='current'"
  end

  def test_2d_camera_with_restore_view_fails_fast
    # 2D / match-photo cameras carry additional state we do not copy
    # (aspect_ratio, image_width, scale_2d, center_2d). With restore_view=true
    # the handler must fail fast rather than silently regress the viewport.
    @view.camera.define_singleton_method(:is_2d?) { true }
    err = assert_raises(SU_MCP::Core::StructuredError) {
      call("restore_view" => true)
    }
    assert_match(/2D|match-photo|is_2d/, err.message,
                 "expected error mentioning 2D/match-photo; got #{err.message.inspect}")
    assert_match(/restore_view=false/, err.message,
                 "expected error suggesting restore_view=false; got #{err.message.inspect}")
  end

  def test_2d_camera_with_restore_view_false_succeeds
    # restore_view=false skips the snapshot entirely, so the 2D guard is
    # bypassed — screenshot proceeds normally.
    @view.camera.define_singleton_method(:is_2d?) { true }
    result = call("restore_view" => false)
    assert_kind_of Hash, result
    assert result.key?("png_base64")
  end

  def test_camera_assigned_for_preset_orthographic
    # When the current camera is parallel projection (perspective=false),
    # build_preset_camera must override `height` from the bbox — copying
    # the current camera's height would clip or empty-frame the model.
    @view.camera.perspective = false
    @view.camera.height = 999_999.0      # nonsense baseline; bbox-derived override must apply
    call("view_preset" => "top", "restore_view" => false)
    assigned = @view.camera_writes.last
    refute assigned.perspective?, "preset camera should inherit perspective=false"
    refute_in_delta 999_999.0, assigned.height, 1.0,
                    "ortho preset must override height from bbox, not copy current camera's"
    # With the default test bbox (≈ unit cube), `diag * 0.6` is small;
    # the exact value is implementation-defined, just assert it's bounded.
    assert assigned.height > 0 && assigned.height < 999_999.0,
           "ortho preset height should be bbox-derived, got #{assigned.height}"
  end

  def test_preset_camera_uses_visible_bounds
    # Handler must call Helpers::Geometry.visible_bounds(model) (NOT
    # model.bounds directly) so it frames only the geometry the user can
    # see. Verified via method spy — avoids building a full entities/group
    # graph in stubs.
    spy_calls = []
    geom_mod  = SU_MCP::Helpers::Geometry
    geom_mod.singleton_class.send(:alias_method, :__orig_visible_bounds, :visible_bounds)
    geom_mod.define_singleton_method(:visible_bounds) do |model|
      spy_calls << model
      Sketchup::BBox.new(center: Geom::Point3d.new(0, 0, 0), diagonal: 100.0)
    end
    begin
      call("view_preset" => "iso", "restore_view" => false)
      assert_equal 1, spy_calls.size,
                   "handler should call Helpers::Geometry.visible_bounds exactly once for preset != current"
      assert_same Sketchup.active_model, spy_calls.first,
                  "visible_bounds should receive the active model"
    ensure
      geom_mod.define_singleton_method(:visible_bounds,
                                       geom_mod.method(:__orig_visible_bounds))
      geom_mod.singleton_class.send(:remove_method, :__orig_visible_bounds)
    end
  end

  def test_visible_bounds_not_called_for_current_preset
    # For view_preset="current" no camera mutation happens, so
    # visible_bounds must not be invoked either.
    spy_calls = []
    geom_mod  = SU_MCP::Helpers::Geometry
    geom_mod.singleton_class.send(:alias_method, :__orig_visible_bounds, :visible_bounds)
    geom_mod.define_singleton_method(:visible_bounds) do |model|
      spy_calls << model
      Sketchup::BBox.new(center: Geom::Point3d.new(0, 0, 0), diagonal: 100.0)
    end
    begin
      call("view_preset" => "current", "restore_view" => false)
      assert_empty spy_calls,
                   "handler must NOT call visible_bounds when view_preset='current'"
    ensure
      geom_mod.define_singleton_method(:visible_bounds,
                                       geom_mod.method(:__orig_visible_bounds))
      geom_mod.singleton_class.send(:remove_method, :__orig_visible_bounds)
    end
  end

  def test_zoom_extents_called_when_flag_true
    call("zoom_extents" => true)
    assert_equal 1, @view.zoom_extents_calls
  end

  def test_zoom_extents_not_called_when_flag_false
    call("zoom_extents" => false)
    assert_equal 0, @view.zoom_extents_calls
  end

  def test_zoom_extents_failure_does_not_propagate
    @view.zoom_extents_raises = true
    # Handler must swallow the failure (logged) and still return a response.
    result = call("zoom_extents" => true)
    assert_kind_of Hash, result
    assert result.key?("png_base64")
  end

  # --- write_image / response shape ------------------------------------------

  def test_write_image_failure_raises
    @view.force_write_image_failure!
    assert_raises(SU_MCP::Core::StructuredError) { call }
  end

  def test_oversize_png_raises
    # Produce a 33 MiB "PNG" — exceeds the 32 MiB cap.
    @view.write_image_size_override = 33 * 1024 * 1024
    err = assert_raises(SU_MCP::Core::StructuredError) { call }
    assert_match(/too large|max_size/i, err.message,
                 "expected oversize error mentioning max_size or size")
  end

  def test_tempfile_cleaned_up_on_success
    call
    leftovers = Dir.glob(File.join(Dir.tmpdir, "sumcp_vp_*.png"))
    assert_empty leftovers, "leftover tmp files: #{leftovers.inspect}"
  end

  def test_tempfile_cleaned_up_on_failure
    @view.force_write_image_failure!
    begin
      call
    rescue SU_MCP::Core::StructuredError
      # expected
    end
    leftovers = Dir.glob(File.join(Dir.tmpdir, "sumcp_vp_*.png"))
    assert_empty leftovers, "leftover tmp files after failure: #{leftovers.inspect}"
  end

  def test_response_structure
    result = call("view_preset" => "iso", "style" => "shaded")
    assert_kind_of Hash, result
    %w[png_base64 width height preset_used style_used].each do |k|
      assert result.key?(k), "missing #{k} in response"
    end
    assert_equal "iso", result["preset_used"]
    assert_equal "shaded", result["style_used"]
    # png_base64 must decode to bytes starting with the PNG magic header.
    decoded = Base64.strict_decode64(result["png_base64"])
    assert decoded.start_with?("\x89PNG\r\n\x1a\n".b),
           "response PNG missing magic header: got #{decoded[0..7].inspect}"
  end

  def test_aspect_ratio_preserved
    @view.vpwidth = 1920
    @view.vpheight = 1080
    result = call("max_size" => 800)
    assert_equal 800, result["width"]
    assert_equal 450, result["height"]
  end

  def test_aspect_ratio_preserved_portrait
    @view.vpwidth = 1080
    @view.vpheight = 1920
    result = call("max_size" => 800)
    assert_equal 450, result["width"]
    assert_equal 800, result["height"]
  end
end
```

- [ ] **Step 5.2: Run tests, verify they fail**

Run: `ruby test/test_view.rb`

Expected: `LoadError: cannot load such file -- .../handlers/view` or similar — the handler file doesn't exist yet.

Do NOT commit failing tests alone.

---

## Task 6: Ruby view handler — implementation + wiring

**Files:**
- Modify: `su_mcp/su_mcp/helpers/geometry.rb` (new `visible_bounds` helper)
- Create: `su_mcp/su_mcp/handlers/view.rb`
- Modify: `su_mcp/su_mcp/main.rb` (LOAD_ORDER)
- Modify: `su_mcp/su_mcp/handlers/dispatch.rb` (case branch)

- [ ] **Step 6.0: Add `visible_bounds` helper to `su_mcp/su_mcp/helpers/geometry.rb`**

Append after the existing `circle_points` method, inside
`module SU_MCP; module Helpers; module Geometry`:

```ruby
      # Bounding box that unions only visible top-level entities of the
      # current model — i.e. honors `entity.hidden?` and the visibility
      # of the entity's layer (`Sketchup::Layer#visible?`). Used by the
      # viewport screenshot tool for `view_preset` framing so the camera
      # frames what the user currently sees (consistent with screenshot
      # not unhiding anything; see design §5.2 / §5.6).
      #
      # Returns `model.bounds` (the global bbox of all entities, hidden
      # or not) when nothing is visible — degrade gracefully rather than
      # produce a degenerate camera.
      def self.visible_bounds(model)
        bb = Geom::BoundingBox.new
        model.entities.each do |e|
          next if e.respond_to?(:hidden?) && e.hidden?
          if e.respond_to?(:layer)
            layer = e.layer
            next if layer && layer.respond_to?(:visible?) && !layer.visible?
          end
          bb.add(e.bounds) if e.respond_to?(:bounds)
        end
        return model.bounds if bb.empty? || bb.diagonal.to_f <= 0.0
        bb
      end
```

- [ ] **Step 6.1: Create `su_mcp/su_mcp/handlers/view.rb`**

```ruby
# su_mcp/su_mcp/handlers/view.rb
#
# Operation order (do NOT reorder without re-deriving snapshot/restore
# invariants):
#   0. validate → guards (active_model!, active_view)
#   1. snapshot (camera deep-copy + RO subset) if restore_view
#   2. preset    (DIRECT view.camera = ... — synchronous in SU 2026; see §5.2)
#   3. style     (RenderMode enum write — empirically the only reliable way)
#   4. zoom_extents (rescued — empty-model dialog tolerated)
#   5. write_image into Tempfile
#   6. size cap check (< 32 MiB raw)
#   7. binread
#   8. restore (outer `ensure` — runs on any exception path)
require "base64"
require "tempfile"

module SU_MCP
  module Handlers
    module View
      V  = SU_MCP::Helpers::Validation
      E  = SU_MCP::Core::StructuredError
      EH = SU_MCP::Helpers::Entities

      ALLOWED_PRESETS = %w[current front back left right top bottom iso].freeze
      ALLOWED_STYLES  = %w[default shaded hidden_line wireframe].freeze
      MIN_MAX_SIZE = 64
      MAX_MAX_SIZE = 4096
      MAX_RAW_BYTES = 32 * 1024 * 1024

      # SketchUp 2026 RenderMode enum (verified empirically — review iter 1):
      # 0=wireframe, 1=hidden_line, 2=shaded, 3=textured_shaded,
      # 4=monochrome, 5=sketchy, 6=x-ray.
      STYLE_RO = {
        "shaded"      => { "RenderMode" => 2 },
        "hidden_line" => { "RenderMode" => 1 },
        "wireframe"   => { "RenderMode" => 0 },
      }.freeze

      # Direction vectors for camera presets (eye = target + dir*distance).
      # NOTE: these vectors are NOT pre-normalized — `iso` is (1,-1,1), not
      # (1/√3, -1/√3, 1/√3). Normalization happens at use site via
      # `offset.length = dist` in `build_preset_camera`. Kept unnormalized for
      # readability of intent (axis-aligned ↔ unit, iso ↔ unit cube corner).
      # `up` is Z+ for elevation views, Y+ for top/bottom (otherwise camera
      # goes singular when view-vector parallels world up).
      PRESET_DIR = {
        "front"  => [Geom::Vector3d.new( 0, -1,  0), Geom::Vector3d.new(0, 0, 1)],
        "back"   => [Geom::Vector3d.new( 0,  1,  0), Geom::Vector3d.new(0, 0, 1)],
        "left"   => [Geom::Vector3d.new(-1,  0,  0), Geom::Vector3d.new(0, 0, 1)],
        "right"  => [Geom::Vector3d.new( 1,  0,  0), Geom::Vector3d.new(0, 0, 1)],
        "top"    => [Geom::Vector3d.new( 0,  0,  1), Geom::Vector3d.new(0, 1, 0)],
        "bottom" => [Geom::Vector3d.new( 0,  0, -1), Geom::Vector3d.new(0, 1, 0)],
        "iso"    => [Geom::Vector3d.new( 1, -1,  1), Geom::Vector3d.new(0, 0, 1)],
      }.freeze

      def self.viewport_screenshot(params)
        # 0. Validate params and guards.
        max_size      = require_max_size(params)
        view_preset   = V.require_enum(params, "view_preset", ALLOWED_PRESETS)
        style         = V.require_enum(params, "style", ALLOWED_STYLES)
        zoom_extents  = V.optional_bool(params, "zoom_extents", false)
        restore_view  = V.optional_bool(params, "restore_view", true)

        model = EH.active_model!                              # raises if nil
        view  = model.active_view
        raise E.new(-32000, "no active view") if view.nil?

        # 1. Snapshot (only if we will mutate).
        snap_camera = nil
        snap_ro     = nil
        if restore_view
          c = view.camera
          # 2D / match-photo guard. Only eye/target/up/perspective/fov/height
          # are deep-copied; 2D cameras carry aspect_ratio, image_width,
          # scale_2d, center_2d that we don't restore. Fail fast rather than
          # silently regress the viewport — see design §5.4 step 1, §5.6
          # edge cases.
          if c.respond_to?(:is_2d?) && c.is_2d?
            raise E.new(-32000,
              "restore_view is not supported for 2D / match-photo cameras " \
              "(camera.is_2d? == true); pass restore_view=false to take the " \
              "screenshot without restoring viewport state")
          end
          # Construct a fresh Camera (deep copy) — verified safe in SU 2026.
          snap_camera = Sketchup::Camera.new(c.eye, c.target, c.up)
          snap_camera.perspective = c.perspective?
          if c.perspective?
            snap_camera.fov = c.fov
          else
            snap_camera.height = c.height
          end
          if style != "default"
            snap_ro = {}
            STYLE_RO[style].each_key { |k| snap_ro[k] = model.rendering_options[k] }
          end
        end

        vw = view.vpwidth.to_f
        vh = view.vpheight.to_f
        if vw <= 0 || vh <= 0
          raise E.new(-32603, "viewport has zero dimensions (vw=#{vw}, vh=#{vh})")
        end
        scale = max_size.to_f / [vw, vh].max
        out_w = (vw * scale).round
        out_h = (vh * scale).round

        data = nil
        begin
          # 2. Preset — direct camera assignment (synchronous; send_action is async).
          # `visible_bounds(model)` is used instead of `model.bounds` so the
          # preset frames only the geometry the user currently sees — consistent
          # with design §5.6 (screenshot captures the user-visible state and
          # does not temporarily unhide anything). Falls back to model.bounds
          # when nothing is visible (empty model or everything hidden).
          if view_preset != "current"
            bb = SU_MCP::Helpers::Geometry.visible_bounds(model)
            view.camera = build_preset_camera(view_preset, bb, view.camera)
          end

          # 3. Style — RenderMode write (verified writeable in SU 2026).
          if style != "default"
            STYLE_RO[style].each { |k, v| model.rendering_options[k] = v }
          end

          # 4. zoom_extents — empty-model dialog tolerated.
          if zoom_extents
            begin
              view.zoom_extents
            rescue StandardError => e
              SU_MCP::Core::Logger.warn("zoom_extents failed: #{e.class}: #{e.message}")
            end
          end

          # 5..7. write_image → size check → binread, all inside Tempfile block.
          Tempfile.create(["sumcp_vp_", ".png"]) do |tmp|
            tmp.close
            ok = view.write_image(
              filename: tmp.path,
              width: out_w,
              height: out_h,
              antialias: true,
              compression: 1.0,
              transparent: false,
            )
            raise E.new(-32000, "viewport write_image failed") unless ok

            size = File.size(tmp.path)
            if size > MAX_RAW_BYTES
              raise E.new(-32000,
                "screenshot too large: #{size} bytes — reduce max_size")
            end
            data = File.binread(tmp.path)
          end
        ensure
          # 8. Restore — runs on success AND on any exception path.
          if restore_view
            view.camera = snap_camera if snap_camera
            snap_ro&.each { |k, v| model.rendering_options[k] = v }
          end
        end

        {
          "png_base64"   => Base64.strict_encode64(data),
          "width"        => out_w,
          "height"       => out_h,
          "preset_used"  => view_preset,
          "style_used"   => style,
        }
      end

      # Build a Sketchup::Camera for one of the named presets, framed on the
      # given bounding box. Falls back to a sensible default when the box is
      # empty (`diag == 0`).
      #
      # IMPORTANT: framing differs for perspective vs orthographic cameras.
      # - Perspective: framing is governed by `eye-to-target distance` and `fov`.
      #   `dist = diag * 1.5` gives a comfortable margin around the bbox.
      # - Orthographic (parallel projection): framing is governed by
      #   `Camera#height` (the world-space vertical extent visible in the
      #   viewport). Copying the *current* camera's `height` here would clip
      #   or empty-frame the model when the saved height bears no relation to
      #   the new preset direction. We override `height` with a bbox-derived
      #   value so `view_preset="top"` (or any other ortho preset) frames the
      #   model regardless of where the camera was before.
      def self.build_preset_camera(preset, bounds, current_camera)
        dir, up = PRESET_DIR[preset]
        center  = bounds.center
        diag    = bounds.diagonal
        diag    = 1000.0 if diag.nil? || diag <= 0   # fallback for empty/hidden model
        dist    = diag * 1.5
        offset  = Geom::Vector3d.new(dir.x, dir.y, dir.z); offset.length = dist
        eye     = center + offset
        cam = Sketchup::Camera.new(eye, center, up)
        cam.perspective = current_camera.perspective?
        if cam.perspective?
          cam.fov = current_camera.fov
        else
          # Orthographic: frame the bbox via height. `diag * 0.6` matches the
          # apparent scale of the perspective fallback for typical fov=35°.
          cam.height = diag * 0.6
        end
        cam
      end

      def self.require_max_size(params)
        v = params["max_size"]
        raise E.new(-32602, "missing required field: max_size") if v.nil?
        raise E.new(-32602, "field max_size must be an integer") unless v.is_a?(Integer)
        unless v.between?(MIN_MAX_SIZE, MAX_MAX_SIZE)
          raise E.new(-32602,
                      "field max_size must be in [#{MIN_MAX_SIZE}, #{MAX_MAX_SIZE}], got #{v}")
        end
        v
      end
    end
  end
end
```

- [ ] **Step 6.2: Wire into `su_mcp/su_mcp/main.rb`**

Open `su_mcp/su_mcp/main.rb`. Find the `LOAD_ORDER` array (lines 17-38). Find the line `handlers/eval` and add `handlers/view` immediately after it:

```ruby
    handlers/model
    handlers/eval
    handlers/view
    core/server
    core/application
```

- [ ] **Step 6.3: Wire into `su_mcp/su_mcp/handlers/dispatch.rb`**

Open `su_mcp/su_mcp/handlers/dispatch.rb`. Find the `call_handler` method (lines 90-115). Add a new branch in the `case` block. Insert it alphabetically — right after the `get_selection` branch (line 111):

```ruby
        when "get_selection"           then Handlers::Model.get_selection(params)
        when "get_viewport_screenshot" then Handlers::View.viewport_screenshot(params)
        else
```

- [ ] **Step 6.4: Run Ruby tests**

Run: `ruby test/test_view.rb`

Expected: all tests pass.

If some validation tests fail because `require_enum` raises a slightly different message, that's fine — the test only asserts class, not message.

If `test_tempfile_deleted_on_success` fails: confirm the `ensure` block in `view.rb` runs unconditionally, and the file is opened only after `write_image` succeeds.

- [ ] **Step 6.5: Run full Ruby test suite**

Run: `ruby test/run_all.rb`

Expected: previous 120 runs + new view tests, all green. No regressions.

- [ ] **Step 6.6: Commit**

```bash
git add su_mcp/su_mcp/helpers/geometry.rb su_mcp/su_mcp/handlers/view.rb \
        su_mcp/su_mcp/main.rb su_mcp/su_mcp/handlers/dispatch.rb \
        test/test_view.rb
git commit -m "feat(handlers): add view handler for viewport screenshot

Handlers::View.viewport_screenshot snapshots camera + rendering options,
optionally switches view_preset via direct view.camera = Sketchup::Camera.new(...)
(synchronous, locale-independent — Sketchup.send_action was rejected as
async in SU 2026, see review iter 1), applies a RenderMode-enum subset for
style (shaded/hidden_line/wireframe), calls View#write_image into a tmpfile,
base64-encodes the bytes, restores state, and returns
{png_base64, width, height, preset_used, style_used}.

Wired into handlers/dispatch.rb#call_handler and main.rb#LOAD_ORDER.
Camera and RO mutations are UI state — no start_operation wrapper, so
the screenshot does not pollute the undo stack."
```

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
