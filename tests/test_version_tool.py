"""Tests for the get_version MCP tool — registration, payload shape on
compatible/incompatible Ruby responses, bypass works when ordinary tools
would have raised."""
import json

import pytest

from sketchup_mcp import compat
from sketchup_mcp.app import mcp


def test_get_version_is_registered():
    # FastMCP exposes the tool registry; the exact attribute name has
    # historically been _tool_manager._tools. We use the public call_tool
    # path to be robust to internal renames.
    names = set()
    for tool in (mcp._tool_manager._tools if hasattr(mcp, "_tool_manager") else mcp._tools).values():
        names.add(tool.name if hasattr(tool, "name") else tool.fn.__name__)
    assert "get_version" in names


@pytest.mark.asyncio
async def test_get_version_compatible_payload(monkeypatch):
    """Mock the underlying _raw_call so the tool sees a Ruby response with
    matched versions; result must report compatible=true, error=None."""
    from sketchup_mcp import tools

    async def fake_raw_call(ctx, tool_name, /, **kwargs):
        assert tool_name == "get_version"
        return {
            "content": [{
                "type": "text",
                "text": json.dumps({
                    "ruby_version": compat.MAX_RUBY,
                    "min_compatible_python": "0.0.3",
                    "max_compatible_python": "0.0.3",
                }),
            }],
            "isError": False,
        }

    monkeypatch.setattr(tools, "_raw_call", fake_raw_call)
    result = await mcp.call_tool("get_version", {})
    # FastMCP's call_tool returns (content_blocks, structured_dict).
    # Extract text from the first content block.
    blocks = result[0] if isinstance(result, tuple) else result
    text = blocks[0].text if hasattr(blocks[0], "text") else blocks[0]["text"]
    payload = json.loads(text)
    assert payload["python_version"] == compat.CLIENT_VERSION
    assert payload["ruby_version"] == compat.MAX_RUBY
    assert payload["compatible"] is True
    assert payload["error"] is None
    assert payload["min_compatible_ruby"] == compat.MIN_RUBY
    assert payload["max_compatible_ruby"] == compat.MAX_RUBY


@pytest.mark.asyncio
async def test_get_version_incompatible_payload(monkeypatch):
    """Mock Ruby response with ruby_version outside the supported range —
    result must report compatible=false with descriptive error."""
    from sketchup_mcp import tools

    monkeypatch.setattr(compat, "MIN_RUBY", "1.0.0")
    monkeypatch.setattr(compat, "MAX_RUBY", "1.0.0")

    async def fake_raw_call(ctx, tool_name, /, **kwargs):
        return {
            "content": [{
                "type": "text",
                "text": json.dumps({
                    "ruby_version": "0.0.3",
                    "min_compatible_python": "0.0.3",
                    "max_compatible_python": "0.0.3",
                }),
            }],
            "isError": False,
        }

    monkeypatch.setattr(tools, "_raw_call", fake_raw_call)
    result = await mcp.call_tool("get_version", {})
    blocks = result[0] if isinstance(result, tuple) else result
    text = blocks[0].text if hasattr(blocks[0], "text") else blocks[0]["text"]
    payload = json.loads(text)
    assert payload["compatible"] is False
    assert payload["ruby_version"] == "0.0.3"
    assert "too old" in payload["error"]
    assert ".rbz" in payload["error"]


@pytest.mark.asyncio
async def test_get_version_handles_connection_error(monkeypatch):
    """If get_connection raises ConnectionError, the tool still returns a
    payload (with ruby_version=None, compatible=false)."""
    from sketchup_mcp import tools

    async def failing_raw_call(ctx, tool_name, /, **kwargs):
        raise ConnectionError("not running")

    monkeypatch.setattr(tools, "_raw_call", failing_raw_call)
    result = await mcp.call_tool("get_version", {})
    blocks = result[0] if isinstance(result, tuple) else result
    text = blocks[0].text if hasattr(blocks[0], "text") else blocks[0]["text"]
    payload = json.loads(text)
    assert payload["python_version"] == compat.CLIENT_VERSION
    assert payload["ruby_version"] is None
    assert payload["compatible"] is False
    assert "not running" in payload["error"].lower() or "connect" in payload["error"].lower()
