"""Tests for the get_version MCP tool — registration, payload shape on
compatible/incompatible Ruby responses, and that it always returns a
payload (never raises) even when the underlying call fails."""
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


@pytest.mark.asyncio
async def test_get_version_returns_payload_on_unknown_tool_error(monkeypatch):
    """Pre-handshake Ruby plugin returns -32601 'unknown tool: get_version'.
    The tool MUST still return a payload (compatible=false, ruby_version=null,
    error=<msg>), NOT raise — preserves the 'always returns a payload'
    contract for the diagnostic tool."""
    from sketchup_mcp import tools
    from sketchup_mcp.errors import SketchUpError

    async def unknown_tool_raw_call(ctx, tool_name, /, **kwargs):
        raise SketchUpError(-32601, "unknown tool: get_version")

    monkeypatch.setattr(tools, "_raw_call", unknown_tool_raw_call)
    result = await mcp.call_tool("get_version", {})
    blocks = result[0] if isinstance(result, tuple) else result
    text = blocks[0].text if hasattr(blocks[0], "text") else blocks[0]["text"]
    payload = json.loads(text)
    assert payload["python_version"] == compat.CLIENT_VERSION
    assert payload["ruby_version"] is None
    assert payload["compatible"] is False
    assert "unknown tool" in payload["error"]


@pytest.mark.asyncio
async def test_two_way_compat_drift_detected(monkeypatch):
    """Tables-drifted-in-opposite-directions edge case: Python's MIN_RUBY/
    MAX_RUBY accepts the ruby_version that Ruby reports, BUT Ruby's
    advertised min/max_compatible_python excludes CLIENT_VERSION.
    Two-way verdict must catch this and report compatible=false with a
    descriptive error about Ruby-side exclusion."""
    from sketchup_mcp import tools

    # Pin Python's view of Ruby so check_ruby_version("1.0.0") passes.
    monkeypatch.setattr(compat, "MIN_RUBY", "1.0.0")
    monkeypatch.setattr(compat, "MAX_RUBY", "1.0.0")

    async def fake_raw_call(ctx, tool_name, /, **kwargs):
        return {
            "content": [{
                "type": "text",
                "text": json.dumps({
                    "ruby_version": "1.0.0",
                    # Ruby's advertised Python range excludes CLIENT_VERSION
                    # (currently 0.0.3) — that's the drift case.
                    "min_compatible_python": "2.0.0",
                    "max_compatible_python": "2.0.0",
                }),
            }],
            "isError": False,
        }

    monkeypatch.setattr(tools, "_raw_call", fake_raw_call)
    result = await mcp.call_tool("get_version", {})
    blocks = result[0] if isinstance(result, tuple) else result
    text = blocks[0].text if hasattr(blocks[0], "text") else blocks[0]["text"]
    payload = json.loads(text)
    # Python's local check accepts ruby_version=1.0.0; but Ruby's advertised
    # range [2.0.0, 2.0.0] excludes CLIENT_VERSION → final verdict is false.
    assert payload["compatible"] is False
    assert payload["ruby_version"] == "1.0.0"
    assert "advertises" in payload["error"], \
        f"error must mention Ruby's advertised range: {payload['error']!r}"
    assert "2.0.0" in payload["error"]
