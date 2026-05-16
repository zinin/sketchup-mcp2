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
| `su_mcp/su_mcp/handlers/view.rb` | Ruby handler `Handlers::View.viewport_screenshot`: validation, camera/RO snapshot/restore, send_action for preset, write_image to tmpfile, base64 response. |
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

- `src/sketchup_mcp/connection.py` — wire protocol unchanged.
- `src/sketchup_mcp/config.py` — no new env vars.
- `src/sketchup_mcp/errors.py` — no new error types.
- `su_mcp/su_mcp/core/*.rb` — server, framing, errors unchanged.
- `su_mcp/su_mcp/handlers/{geometry,operations,joints,materials,export,model,eval}.rb` — all existing handlers untouched.
- `pyproject.toml`, `uv.lock` — no new dependencies (FastMCP already provides `Image`).

---

## Task 1: Python prompt — failing tests

**Files:**
- Create: `tests/test_prompts.py`

- [ ] **Step 1.1: Write failing tests**

Create `tests/test_prompts.py`:

```python
"""Tests for the SketchUp modeling-strategy MCP prompt.

The prompt is registered as a side-effect of importing
``sketchup_mcp.prompts``. Importing it from inside the test ensures the
registration ran by the time we query the prompt registry.
"""
import pytest

from sketchup_mcp.app import mcp


@pytest.fixture(autouse=True)
def _load_prompts():
    """Force import of the prompts module so the @mcp.prompt decorator runs."""
    import sketchup_mcp.prompts  # noqa: F401


@pytest.mark.asyncio
async def test_prompt_registered():
    prompts = await mcp.list_prompts()
    names = [p.name for p in prompts]
    assert "sketchup_modeling_strategy" in names


@pytest.mark.asyncio
async def test_prompt_returns_non_empty_text():
    result = await mcp.get_prompt("sketchup_modeling_strategy", {})
    text = result.messages[0].content.text
    assert len(text) > 200, f"prompt body suspiciously short: {len(text)} chars"


@pytest.mark.asyncio
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


@pytest.mark.asyncio
async def test_prompt_description_present():
    prompts = await mcp.list_prompts()
    p = next(p for p in prompts if p.name == "sketchup_modeling_strategy")
    assert p.description
    assert "SketchUp" in p.description
```

- [ ] **Step 1.2: Run tests, verify they fail**

Run: `uv run pytest tests/test_prompts.py -v`

Expected: 4 errors with `ModuleNotFoundError: No module named 'sketchup_mcp.prompts'`.

If `pytest-asyncio` is not configured, the failure may instead be `Failed: async def functions are not natively supported`. In that case, see Step 2.4 — we'll add a `pytest.ini` marker setting.

Do NOT commit at this step. Failing tests don't ship alone.

---

## Task 2: Python prompt — implementation

**Files:**
- Create: `src/sketchup_mcp/prompts.py`
- Modify: `src/sketchup_mcp/app.py` (one new import at end of file)
- Possibly modify: `pyproject.toml` or `pytest.ini` (asyncio marker — see Step 2.4)

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
- Tools that create or modify entities return {id, name, type, bbox_mm}.
  Read bbox_mm to confirm the result matches the intent before the
  next step.
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
- joint dimensions ~ 0.3-0.5 x board thickness;
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

Expected: 4 passes.

- [ ] **Step 2.4: If async tests skipped — configure asyncio mode**

If output shows `4 skipped` or `async def functions are not natively supported`, add asyncio-mode setting. Check `pyproject.toml` for an existing `[tool.pytest.ini_options]` table; if it lists `asyncio_mode = "auto"` or markers exist, async should already work. Otherwise, add to `pyproject.toml`:

```toml
[tool.pytest.ini_options]
asyncio_mode = "auto"
```

(If `pyproject.toml` already has this table, only add the missing key.)

Re-run Step 2.3 until 4 passes.

- [ ] **Step 2.5: Commit**

```bash
git add src/sketchup_mcp/prompts.py src/sketchup_mcp/app.py tests/test_prompts.py
# also pyproject.toml if Step 2.4 modified it
git add pyproject.toml 2>/dev/null || true
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

The wrapper performs Pydantic validation, sends a JSON-RPC call via the
SketchUpConnection singleton, base64-decodes the response, and wraps
the resulting bytes in mcp.server.fastmcp.Image.
"""
import base64
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from mcp.server.fastmcp import Image
from pydantic import ValidationError

from sketchup_mcp.errors import SketchUpError

# 1×1 transparent PNG, base64-encoded.
_TINY_PNG_B64 = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9Q"
    "DwADhgGAWjR9awAAAABJRU5ErkJggg=="
)
_TINY_PNG_BYTES = base64.b64decode(_TINY_PNG_B64)


def _mock_connection(result):
    """Return a context manager that patches get_connection to a mock
    whose send_command returns ``result``."""
    conn = MagicMock()
    conn.send_command = AsyncMock(return_value=result)
    return patch("sketchup_mcp.tools.get_connection", AsyncMock(return_value=conn))


@pytest.mark.asyncio
async def test_screenshot_minimal_payload():
    """Default call passes the full default param map to Ruby."""
    captured: dict = {}

    async def fake_send(name, args):
        captured["name"] = name
        captured["args"] = args
        return {
            "content": [
                {
                    "type": "text",
                    "text": (
                        '{"png_base64": "' + _TINY_PNG_B64 + '",'
                        '"width": 1, "height": 1,'
                        '"preset_used": "current", "style_used": "default"}'
                    ),
                }
            ],
            "isError": False,
        }

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


@pytest.mark.asyncio
async def test_screenshot_max_size_clamps():
    """max_size below 64 or above 4096 is rejected by Pydantic."""
    from sketchup_mcp.tools import get_viewport_screenshot

    with pytest.raises(ValidationError):
        await get_viewport_screenshot.fn(ctx=None, max_size=10)  # type: ignore[attr-defined]
    with pytest.raises(ValidationError):
        await get_viewport_screenshot.fn(ctx=None, max_size=99999)  # type: ignore[attr-defined]


@pytest.mark.asyncio
async def test_screenshot_view_preset_invalid():
    from sketchup_mcp.tools import get_viewport_screenshot

    with pytest.raises(ValidationError):
        await get_viewport_screenshot.fn(ctx=None, view_preset="diagonal")  # type: ignore[attr-defined]


@pytest.mark.asyncio
async def test_screenshot_style_invalid():
    from sketchup_mcp.tools import get_viewport_screenshot

    with pytest.raises(ValidationError):
        await get_viewport_screenshot.fn(ctx=None, style="cartoon")  # type: ignore[attr-defined]


@pytest.mark.asyncio
async def test_screenshot_returns_image():
    """On success, the wrapper returns a FastMCP Image with PNG bytes."""
    result_text = (
        '{"png_base64": "' + _TINY_PNG_B64 + '",'
        '"width": 1, "height": 1,'
        '"preset_used": "iso", "style_used": "shaded"}'
    )
    payload = {
        "content": [{"type": "text", "text": result_text}],
        "isError": False,
    }
    with _mock_connection(payload):
        from sketchup_mcp.tools import get_viewport_screenshot

        img = await get_viewport_screenshot(ctx=None)  # type: ignore[arg-type]

    assert isinstance(img, Image)
    assert img.data == _TINY_PNG_BYTES
    # Format hint surfaces as image/png in mime_type.
    assert img._mime_type == "image/png"


@pytest.mark.asyncio
async def test_screenshot_base64_decode_failure():
    """Invalid base64 in Ruby response surfaces as a clear error."""
    result_text = (
        '{"png_base64": "not-base64!@#$",'
        '"width": 1, "height": 1,'
        '"preset_used": "current", "style_used": "default"}'
    )
    payload = {
        "content": [{"type": "text", "text": result_text}],
        "isError": False,
    }
    with _mock_connection(payload):
        from sketchup_mcp.tools import get_viewport_screenshot

        with pytest.raises(SketchUpError):
            await get_viewport_screenshot(ctx=None)  # type: ignore[arg-type]


@pytest.mark.asyncio
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

Expected: All 7 tests fail with `ImportError: cannot import name 'get_viewport_screenshot' from 'sketchup_mcp.tools'`.

Do NOT commit yet.

---

## Task 4: Python screenshot wrapper — implementation

**Files:**
- Modify: `src/sketchup_mcp/tools.py` (add imports + new function near line 282)

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
    """
    try:
        sketchup = await get_connection()
    except ConnectionError as e:
        raise SketchUpError(-32000, f"SketchUp not running: {e}") from e
    try:
        raw = await sketchup.send_command(
            "get_viewport_screenshot",
            {
                "max_size": max_size,
                "view_preset": view_preset,
                "zoom_extents": zoom_extents,
                "style": style,
                "restore_view": restore_view,
            },
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

- [ ] **Step 4.3: Run tests**

Run: `uv run pytest tests/test_screenshot.py -v`

Expected: 7 passes.

If `test_screenshot_propagates_ruby_error` fails: check that the `except SketchUpError` is **not** caught — the wrapper should re-raise it as-is (Pydantic-level `ConnectionError` is the only one we rewrap).

- [ ] **Step 4.4: Run full Python test suite**

Run: `uv run pytest tests/ -q`

Expected: existing 56 tests + 4 prompt tests + 7 screenshot tests = 67 pass. No regressions.

- [ ] **Step 4.5: Commit**

```bash
git add src/sketchup_mcp/tools.py tests/test_screenshot.py
git commit -m "feat(tools): add get_viewport_screenshot wrapper returning MCP Image

Thin wrapper around the new Ruby handler: Pydantic-validates
max_size/view_preset/zoom_extents/style/restore_view, round-trips a
JSON-RPC call, base64-decodes the png_base64 field, and returns
mcp.server.fastmcp.Image so Claude can see the scene between steps."
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
# Sketchup::Model, Sketchup::View, Sketchup::Camera.

require "minitest/autorun"
require "base64"
require "tmpdir"

# --- Minimal SketchUp stubs ---------------------------------------------------
# We stub only the API our handler touches. Other tests in test/ already
# define some of these — that's fine, Ruby ``module`` declarations are
# additive. Avoid redefining methods if they're already there.

module Sketchup
  class Camera
    attr_accessor :eye, :target, :up
    def initialize(eye = [0, 0, 0], target = [0, 0, 0], up = [0, 0, 1])
      @eye, @target, @up = eye, target, up
    end
    def ==(other) other.is_a?(Camera) && eye == other.eye && target == other.target && up == other.up; end
  end

  class View
    attr_accessor :camera, :vpwidth, :vpheight, :model
    attr_reader :write_image_calls, :zoom_extents_calls

    def initialize(model:)
      @camera = Camera.new([10, 10, 10], [0, 0, 0], [0, 0, 1])
      @vpwidth = 1920
      @vpheight = 1080
      @model = model
      @write_image_calls = []
      @zoom_extents_calls = 0
      @write_image_result = true
    end

    def write_image(filename:, width:, height:, antialias: nil, compression: nil, transparent: nil)
      @write_image_calls << {filename: filename, width: width, height: height}
      File.binwrite(filename, "FAKE_PNG_BYTES") if @write_image_result
      @write_image_result
    end

    def force_write_image_failure!
      @write_image_result = false
    end

    def zoom_extents
      @zoom_extents_calls += 1
    end
  end

  class Model
    attr_reader :rendering_options
    def initialize
      @rendering_options = {
        "DisplayShaded" => true,
        "DisplayShadedUsingAllSameObject" => false,
        "DrawEdges" => true,
        "DrawHidden" => false,
        "DrawProfilesOnly" => false,
        "DrawFaces" => true,
      }
    end
  end

  class << self
    attr_reader :send_action_calls

    def send_action(name)
      @send_action_calls ||= []
      @send_action_calls << name
      true
    end

    def reset_send_action_calls!
      @send_action_calls = []
    end

    def active_model
      @active_model ||= Model.new
    end

    def reset_active_model!
      @active_model = Model.new
    end
  end
end

# --- Load production code -----------------------------------------------------
require_relative "../su_mcp/su_mcp/core/errors"
require_relative "../su_mcp/su_mcp/helpers/validation"
require_relative "../su_mcp/su_mcp/handlers/view"

# Dispatch loads errors itself; we require it last so its sibling
# requires don't override our stubs.
require_relative "../su_mcp/su_mcp/handlers/dispatch"

class TestView < Minitest::Test
  V = SU_MCP::Handlers::View

  def setup
    Sketchup.reset_send_action_calls!
    Sketchup.reset_active_model!
    # Inject a fresh View into the model for each test so call counts reset.
    @view = Sketchup::View.new(model: Sketchup.active_model)
    Sketchup.active_model.define_singleton_method(:active_view) { @__view ||= nil }
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
    assert_raises(SU_MCP::Core::StructuredError) do
      call("view_preset" => "diagonal")
    end
  end

  def test_invalid_style_raises
    assert_raises(SU_MCP::Core::StructuredError) do
      call("style" => "cartoon")
    end
  end

  def test_invalid_max_size_too_small_raises
    assert_raises(SU_MCP::Core::StructuredError) do
      call("max_size" => 10)
    end
  end

  def test_invalid_max_size_too_large_raises
    assert_raises(SU_MCP::Core::StructuredError) do
      call("max_size" => 99999)
    end
  end

  # --- camera/RO snapshot+restore --------------------------------------------

  def test_camera_restored_when_flag_true
    snapshot = @view.camera
    call("view_preset" => "top", "restore_view" => true)
    assert_equal snapshot.eye, @view.camera.eye
    assert_equal snapshot.target, @view.camera.target
  end

  def test_camera_not_restored_when_flag_false
    # We replace the camera via send_action; our stub doesn't really change
    # the camera, but the handler logic should NOT issue a restore call.
    # Verify by tracking whether camera was reassigned post-write_image.
    # Simpler: track that the handler did NOT re-assign view.camera after
    # write_image. We expose a tap on camera= for that.
    assigns = []
    @view.define_singleton_method(:camera=) do |c|
      assigns << c
      instance_variable_set(:@camera, c)
    end
    call("view_preset" => "top", "restore_view" => false)
    assert_empty assigns, "camera= should not be called when restore_view=false"
  end

  def test_rendering_options_restored_for_style
    snap = Sketchup.active_model.rendering_options.dup
    call("style" => "wireframe", "restore_view" => true)
    snap.each do |k, v|
      assert_equal v, Sketchup.active_model.rendering_options[k],
                   "RO key #{k} not restored: was #{v.inspect}, got #{Sketchup.active_model.rendering_options[k].inspect}"
    end
  end

  # --- preset / zoom_extents --------------------------------------------------

  def test_send_action_called_for_preset
    call("view_preset" => "iso")
    assert_includes Sketchup.send_action_calls, "viewIso:"
  end

  def test_send_action_not_called_for_current_preset
    call("view_preset" => "current")
    refute_includes (Sketchup.send_action_calls || []), "viewCurrent:"
  end

  def test_zoom_extents_called_when_flag_true
    call("zoom_extents" => true)
    assert_equal 1, @view.zoom_extents_calls
  end

  def test_zoom_extents_not_called_when_flag_false
    call("zoom_extents" => false)
    assert_equal 0, @view.zoom_extents_calls
  end

  # --- write_image / response shape ------------------------------------------

  def test_write_image_failure_raises
    @view.force_write_image_failure!
    assert_raises(SU_MCP::Core::StructuredError) do
      call
    end
  end

  def test_tempfile_deleted_on_success
    before = Dir.entries(Dir.tmpdir).count
    call
    after = Dir.entries(Dir.tmpdir).count
    assert_operator after.abs, :<=, before + 1,
                    "tmp file leaked after successful call"
    # Stronger check: no file matching our pattern remains.
    leftovers = Dir.glob(File.join(Dir.tmpdir, "sumcp_vp_*.png"))
    assert_empty leftovers, "leftover tmp files: #{leftovers.inspect}"
  end

  def test_tempfile_deleted_on_failure
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
    # Encoded "FAKE_PNG_BYTES" → strict_encode64
    expected = Base64.strict_encode64("FAKE_PNG_BYTES")
    assert_equal expected, result["png_base64"]
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
- Create: `su_mcp/su_mcp/handlers/view.rb`
- Modify: `su_mcp/su_mcp/main.rb` (LOAD_ORDER)
- Modify: `su_mcp/su_mcp/handlers/dispatch.rb` (case branch)

- [ ] **Step 6.1: Create `su_mcp/su_mcp/handlers/view.rb`**

```ruby
# su_mcp/su_mcp/handlers/view.rb
require "base64"
require "tmpdir"

module SU_MCP
  module Handlers
    module View
      V = SU_MCP::Helpers::Validation
      E = SU_MCP::Core::StructuredError

      ALLOWED_PRESETS = %w[current front back left right top bottom iso].freeze
      ALLOWED_STYLES  = %w[default shaded hidden_line wireframe].freeze
      MIN_MAX_SIZE = 64
      MAX_MAX_SIZE = 4096

      # rendering_options key sets per style. ``default`` does not touch RO.
      STYLE_RO = {
        "shaded" => {
          "DisplayShaded" => true,
          "DisplayShadedUsingAllSameObject" => false,
          "DrawEdges" => true,
        },
        "hidden_line" => {
          "DisplayShaded" => false,
          "DrawEdges" => true,
          "DrawHidden" => true,
          "DrawProfilesOnly" => false,
        },
        "wireframe" => {
          "DrawEdges" => true,
          "DrawFaces" => false,
        },
      }.freeze

      def self.viewport_screenshot(params)
        max_size = require_max_size(params)
        view_preset = V.require_enum(params, "view_preset", ALLOWED_PRESETS)
        style = V.require_enum(params, "style", ALLOWED_STYLES)
        zoom_extents = V.optional_bool(params, "zoom_extents", false)
        restore_view = V.optional_bool(params, "restore_view", true)

        model = Sketchup.active_model
        view  = model.active_view

        # Snapshot for restoration. Camera is always cheap to snapshot; RO
        # only if a style change is requested.
        snap_camera = restore_view ? view.camera : nil
        snap_ro = {}
        if restore_view && style != "default"
          STYLE_RO[style].each_key { |k| snap_ro[k] = model.rendering_options[k] }
        end

        # Apply preset (skipped if "current").
        if view_preset != "current"
          Sketchup.send_action("view#{view_preset.capitalize}:")
        end

        # Apply style (skipped if "default").
        if style != "default"
          STYLE_RO[style].each { |k, v| model.rendering_options[k] = v }
        end

        # Optionally call zoom_extents.
        view.zoom_extents if zoom_extents

        # Compute output dimensions preserving aspect ratio.
        vw = view.vpwidth.to_f
        vh = view.vpheight.to_f
        if vw <= 0 || vh <= 0
          raise E.new(-32603, "viewport has zero dimensions (vw=#{vw}, vh=#{vh})")
        end
        scale = max_size.to_f / [vw, vh].max
        out_w = (vw * scale).round
        out_h = (vh * scale).round

        ts = Time.now.strftime("%Y%m%d%H%M%S%6N")
        tmp = File.join(Dir.tmpdir, "sumcp_vp_#{ts}_#{Process.pid}.png")

        begin
          ok = view.write_image(
            filename: tmp,
            width: out_w,
            height: out_h,
            antialias: true,
            compression: 0.9,
            transparent: false,
          )
          raise E.new(-32000, "viewport write_image failed") unless ok
          data = File.binread(tmp)
        ensure
          File.delete(tmp) if File.exist?(tmp)
        end

        # Restore camera and rendering options.
        if restore_view
          view.camera = snap_camera if snap_camera
          snap_ro.each { |k, v| model.rendering_options[k] = v }
        end

        {
          "png_base64"   => Base64.strict_encode64(data),
          "width"        => out_w,
          "height"       => out_h,
          "preset_used"  => view_preset,
          "style_used"   => style,
        }
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
git add su_mcp/su_mcp/handlers/view.rb su_mcp/su_mcp/main.rb \
        su_mcp/su_mcp/handlers/dispatch.rb test/test_view.rb
git commit -m "feat(handlers): add view handler for viewport screenshot

Handlers::View.viewport_screenshot snapshots camera + rendering options,
optionally switches view_preset via Sketchup.send_action, applies a
rendering_options subset for style (shaded/hidden_line/wireframe), calls
View#write_image into a tmpfile, base64-encodes the bytes, restores
state, and returns {png_base64, width, height, preset_used, style_used}.

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

- [ ] **Step 7.2: Add the screenshot step**

Append a new step before the cleanup section. Use the pattern of existing steps (number, call, assert, print). Suggested code:

```python
    # 21. Screenshot
    print("step 21: get_viewport_screenshot")
    result = await session.call_tool(
        "get_viewport_screenshot",
        {"view_preset": "iso", "zoom_extents": True, "max_size": 640},
    )
    assert not result.isError, f"screenshot returned isError: {result}"
    img = result.content[0]
    assert img.type == "image", f"expected image, got {img.type}"
    assert img.mimeType == "image/png", f"expected png mime, got {img.mimeType}"
    assert len(img.data) > 1000, f"PNG suspiciously small: {len(img.data)} chars b64"
    print(f"  screenshot ok: {len(img.data)} chars base64 PNG")
```

If the existing steps use a different convention (e.g. `await client.call_tool(...)`), match it instead of literally copying the snippet.

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

Expected: all 21 steps print success; final exit code 0.

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
| View | `get_viewport_screenshot` (returns MCP Image; optional view_preset/style/zoom_extents; non-destructive by default) |
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

For non-destructive screenshots, snapshot camera and the rendering-options
keys you intend to change, mutate, write the image, then restore.
`View#camera=` and `RenderingOptions[]=` are UI state — they don't enter
the undo stack — so you don't need `model.start_operation`.

```ruby
view = Sketchup.active_model.active_view
model = view.model

snap_camera = view.camera                                  # snapshot
ro_keys     = ["DrawEdges", "DrawFaces"]
snap_ro     = ro_keys.map { |k| [k, model.rendering_options[k]] }.to_h

Sketchup.send_action("viewIso:")                           # mutate
model.rendering_options["DrawEdges"] = true
view.zoom_extents

tmp = "#{Dir.tmpdir}/snap_#{Time.now.to_i}.png"
ok = view.write_image(
  filename: tmp,
  width: 800, height: 450,
  antialias: true,
  compression: 0.9,
  transparent: false,
)
raise "write_image failed" unless ok

begin
  bytes = File.binread(tmp)
  # ... use bytes (Base64.strict_encode64 for transport) ...
ensure
  File.delete(tmp) if File.exist?(tmp)
end

view.camera = snap_camera                                  # restore
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

Expected: all green (existing 56 + 4 prompt + 7 screenshot = 67 tests).

- [ ] **Step 11.2: Run full Ruby test suite**

Run: `ruby test/run_all.rb`

Expected: all green (existing 120 runs + new test_view.rb runs).

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
