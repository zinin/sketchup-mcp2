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


async def test_screenshot_max_size_rejects_out_of_range():
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
    # FastMCP's Image class doesn't expose `format` as a public attribute —
    # only `_format` / `_mime_type` (private). Use `to_image_content()`,
    # the public conversion method that yields a typed ImageContent with
    # `mimeType`. MIME/format is additionally verified end-to-end via the
    # dispatch path in `test_screenshot_via_mcp_dispatch`.
    assert img.to_image_content().mimeType == "image/png"


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


async def test_screenshot_connection_error_becomes_sketchuperror():
    """Design §5.8 contract: ConnectionError from the transport layer is
    re-raised as ``SketchUpError(-32000, …)``, NOT silently swallowed and
    NOT converted to the legacy ``"SketchUp not running…"`` string used
    by the 22 text-returning tools. Locks in the asymmetric error-handling
    decision so it cannot regress without a test failure."""
    with patch(
        "sketchup_mcp.tools.get_connection",
        AsyncMock(side_effect=ConnectionError("refused")),
    ):
        from sketchup_mcp.tools import get_viewport_screenshot
        with pytest.raises(SketchUpError) as exc_info:
            await get_viewport_screenshot(ctx=None)  # type: ignore[arg-type]
    assert exc_info.value.code == -32000
    assert "SketchUp not running" in str(exc_info.value)
