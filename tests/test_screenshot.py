"""Tests for the get_viewport_screenshot MCP tool wrapper.

Validation tests go through FastMCP's full dispatch path
(`mcp.call_tool`), not via a non-existent `.fn` attribute or direct
function call — that's the only way Pydantic validation actually runs.
Mime-type assertions use the public ``to_image_content()`` method on
FastMCP's ``Image`` (it does not expose ``format`` or ``_mime_type``
as a public attribute).
"""
import base64
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from mcp.server.fastmcp import Image
from mcp.types import CallToolResult, ImageContent

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


async def test_screenshot_max_size_rejects_out_of_range():
    """max_size below 64 or above 2000 is rejected by FastMCP/Pydantic
    validation — exercised through the dispatcher (``mcp.call_tool``)
    because that's where validation lives."""
    # Connection is mocked so failed-validation paths don't try to touch sockets.
    conn = MagicMock(); conn.send_command = AsyncMock(return_value=_ruby_result_for())
    with patch("sketchup_mcp.tools.get_connection", AsyncMock(return_value=conn)):
        # Force the screenshot wrapper to be importable+registered.
        import sketchup_mcp.tools  # noqa: F401
        for bad in (10, 2001):
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
    """On success, the wrapper returns a FastMCP Image with PNG bytes
    and the capture metadata as a JSON text block (T-28)."""
    with _mock_connection(_ruby_result_for(preset="iso", style="shaded")):
        from sketchup_mcp.tools import get_viewport_screenshot
        img, meta_json = await get_viewport_screenshot(ctx=None)  # type: ignore[arg-type]

    assert isinstance(img, Image)
    assert img.data == _TINY_PNG_BYTES
    # mimeType via to_image_content() — pins the PNG marker the MCP client will see, not just raw bytes.
    assert img.to_image_content().mimeType == "image/png"
    # T-28: метаданные захвата больше не выбрасываются.
    import json as _json
    meta = _json.loads(meta_json)
    assert meta == {"width": 1, "height": 1,
                    "preset_used": "iso", "style_used": "shaded"}


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


async def test_screenshot_dispatch_includes_metadata_text():
    """T-28: в MCP-конверте рядом с ImageContent едет TextContent с
    width/height/preset_used/style_used — модель может проверить параметры
    захвата, не гадая."""
    import json as _json
    from mcp.types import TextContent
    with _mock_connection(_ruby_result_for(w=800, h=600, preset="iso", style="shaded")):
        import sketchup_mcp.tools  # noqa: F401
        result = await mcp.call_tool("get_viewport_screenshot",
                                     {"view_preset": "iso", "style": "shaded"})
    contents = list(result)
    text_block = next((c for c in contents if isinstance(c, TextContent)), None)
    assert text_block is not None, f"expected TextContent, got {contents!r}"
    meta = _json.loads(text_block.text)
    assert meta["width"] == 800
    assert meta["height"] == 600
    assert meta["preset_used"] == "iso"
    assert meta["style_used"] == "shaded"


# M-12 (spec §6.6, block A): the screenshot reports its errors like every
# other tool — an error result, isError true, with the [code] message text —
# instead of raising (FastMCP would prefix "Error executing tool …").
def _error_text(result) -> str:
    assert isinstance(result, CallToolResult), f"expected an error result, got {result!r}"
    assert result.isError is True
    return result.content[0].text


async def test_screenshot_max_size_schema_caps_at_2000():
    import sketchup_mcp.tools  # noqa: F401
    tool = next(t for t in await mcp.list_tools() if t.name == "get_viewport_screenshot")
    assert tool.inputSchema["properties"]["max_size"]["maximum"] == 2000


async def test_screenshot_base64_decode_failure():
    """Invalid base64 in Ruby response surfaces as a clear error."""
    bad = _ruby_result_for(png_b64="not-base64!@#$")
    with _mock_connection(bad):
        from sketchup_mcp.tools import get_viewport_screenshot
        text = _error_text(await get_viewport_screenshot(ctx=None))  # type: ignore[arg-type]
    assert text.startswith("[-32603] png_base64 decode failed")
    assert "tool=get_viewport_screenshot" in text


async def test_screenshot_non_dict_payload_is_an_error_result():
    """A JSON scalar/array in the Ruby text blob (valid JSON but not an object)
    must come back as a clean error, not leak an AttributeError from
    payload.get() (kimi review)."""
    bad = {
        "content": [{"type": "text", "text": "[1, 2, 3]"}],
        "isError": False,
    }
    with _mock_connection(bad):
        from sketchup_mcp.tools import get_viewport_screenshot
        text = _error_text(await get_viewport_screenshot(ctx=None))  # type: ignore[arg-type]
    assert text.startswith("[-32603]")
    assert "not a JSON object" in text


async def test_screenshot_reports_a_ruby_error():
    """A JSON-RPC error from Ruby reaches the client with its own text."""
    err = SketchUpError(-32000, "viewport write_image failed", {"tool": "get_viewport_screenshot"})
    conn = MagicMock()
    conn.send_command = AsyncMock(side_effect=err)
    with patch("sketchup_mcp.tools.get_connection", AsyncMock(return_value=conn)):
        from sketchup_mcp.tools import get_viewport_screenshot
        text = _error_text(await get_viewport_screenshot(ctx=None))  # type: ignore[arg-type]
    assert text.startswith("[-32000] viewport write_image failed")


async def test_screenshot_connection_error_is_an_error_result():
    """A ConnectionError from the transport layer reads as for every other
    tool. (The part-1 design raised SketchUpError here, unlike the text
    tools; one error shape for every tool replaces that asymmetry.)"""
    with patch(
        "sketchup_mcp.tools.get_connection",
        AsyncMock(side_effect=ConnectionError("refused")),
    ):
        from sketchup_mcp.tools import get_viewport_screenshot
        text = _error_text(await get_viewport_screenshot(ctx=None))  # type: ignore[arg-type]
    assert text == "SketchUp not running or extension not started: refused"
