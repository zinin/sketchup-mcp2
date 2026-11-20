"""Tests for the get_version MCP tool — registration, payload shape on
compatible/incompatible Ruby responses, and that it always returns a
payload (never raises) even when the underlying call fails."""
import json

import pytest

from sketchup_mcp import compat
from sketchup_mcp.app import mcp

PAYLOAD_KEYS = {
    "python_version",
    "ruby_version",
    "min_compatible_ruby",
    "ruby_min_compatible_python",
    "compatible",
    "error",
}


def _extract_payload(result) -> dict:
    # FastMCP's call_tool returns (content_blocks, structured_dict).
    # Extract text from the first content block.
    blocks = result[0] if isinstance(result, tuple) else result
    text = blocks[0].text if hasattr(blocks[0], "text") else blocks[0]["text"]
    return json.loads(text)


async def _get_version_with_ruby_payload(monkeypatch, ruby_payload: dict) -> dict:
    """Run the tool against a mocked Ruby get_version response."""
    from sketchup_mcp import tools

    async def fake_raw_call(ctx, tool_name, /, **kwargs):
        assert tool_name == "get_version"
        return {
            "content": [{"type": "text", "text": json.dumps(ruby_payload)}],
            "isError": False,
        }

    monkeypatch.setattr(tools, "_raw_call", fake_raw_call)
    return _extract_payload(await mcp.call_tool("get_version", {}))


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
    """A plugin at the client's floor that admits this client: compatible,
    and the payload carries no max_* fields."""
    payload = await _get_version_with_ruby_payload(monkeypatch, {
        "ruby_version": compat.MIN_RUBY,
        "min_compatible_python": compat.CLIENT_VERSION,
    })
    assert set(payload) == PAYLOAD_KEYS
    assert payload["python_version"] == compat.CLIENT_VERSION
    assert payload["ruby_version"] == compat.MIN_RUBY
    assert payload["min_compatible_ruby"] == compat.MIN_RUBY
    assert payload["ruby_min_compatible_python"] == compat.CLIENT_VERSION
    assert payload["compatible"] is True
    assert payload["error"] is None


@pytest.mark.asyncio
async def test_get_version_newer_plugin_is_compatible(monkeypatch):
    """No upper bound: a plugin far newer than the client (a plugin-only
    hotfix) is compatible as long as its floor admits the client."""
    payload = await _get_version_with_ruby_payload(monkeypatch, {
        "ruby_version": "99.0.0",
        "min_compatible_python": compat.CLIENT_VERSION,
    })
    assert payload["compatible"] is True
    assert payload["error"] is None


@pytest.mark.asyncio
async def test_get_version_incompatible_payload(monkeypatch):
    """A plugin older than MIN_RUBY: compatible=false, the error names the floor."""
    monkeypatch.setattr(compat, "MIN_RUBY", "1.0.0")
    payload = await _get_version_with_ruby_payload(monkeypatch, {
        "ruby_version": "0.0.3",
        "min_compatible_python": "0.0.3",
    })
    assert payload["compatible"] is False
    assert payload["ruby_version"] == "0.0.3"
    assert "too old" in payload["error"]
    assert "needs plugin v1.0.0 or newer" in payload["error"]


@pytest.mark.asyncio
async def test_get_version_handles_connection_error(monkeypatch):
    """If get_connection raises ConnectionError, the tool still returns a
    payload (with ruby_version=None, compatible=false)."""
    from sketchup_mcp import tools

    async def failing_raw_call(ctx, tool_name, /, **kwargs):
        raise ConnectionError("not running")

    monkeypatch.setattr(tools, "_raw_call", failing_raw_call)
    payload = _extract_payload(await mcp.call_tool("get_version", {}))
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
    payload = _extract_payload(await mcp.call_tool("get_version", {}))
    assert payload["python_version"] == compat.CLIENT_VERSION
    assert payload["ruby_version"] is None
    assert payload["compatible"] is False
    assert "unknown tool" in payload["error"]


@pytest.mark.asyncio
async def test_two_way_compat_drift_detected(monkeypatch):
    """Python's floor admits the plugin, but the plugin's floor
    (min_compatible_python) is above this client. The two-way verdict must
    report compatible=false and name the plugin's requirement."""
    monkeypatch.setattr(compat, "MIN_RUBY", "1.0.0")
    payload = await _get_version_with_ruby_payload(monkeypatch, {
        "ruby_version": "1.0.0",
        "min_compatible_python": "2.0.0",
    })
    assert payload["compatible"] is False
    assert payload["ruby_version"] == "1.0.0"
    assert payload["error"] == (
        "SketchUp plugin v1.0.0 requires sketchup-mcp2 v2.0.0 or newer."
    )


@pytest.mark.asyncio
async def test_get_version_missing_min_compatible_python(monkeypatch):
    """A plugin that advertises no floor: compatible=false, no exception."""
    payload = await _get_version_with_ruby_payload(monkeypatch, {
        "ruby_version": compat.MIN_RUBY,
    })
    assert payload["compatible"] is False
    assert payload["error"] == (
        f"SketchUp plugin v{compat.MIN_RUBY} sent no valid "
        f"min_compatible_python (None)."
    )


@pytest.mark.asyncio
async def test_get_version_non_string_min_compatible_python(monkeypatch):
    """Review focus 2: a non-string floor must not raise out of the tool."""
    payload = await _get_version_with_ruby_payload(monkeypatch, {
        "ruby_version": compat.MIN_RUBY,
        "min_compatible_python": 3,
    })
    assert payload["compatible"] is False
    assert payload["error"] == (
        f"SketchUp plugin v{compat.MIN_RUBY} sent no valid "
        f"min_compatible_python (3)."
    )


@pytest.mark.asyncio
async def test_get_version_ignores_released_plugin_max(monkeypatch):
    """Review focus 1: plugins up to 0.3.1 also send max_compatible_python.
    The tool ignores it — even a max that excludes this client — and never
    echoes a max_* field."""
    payload = await _get_version_with_ruby_payload(monkeypatch, {
        "ruby_version": compat.MIN_RUBY,
        "min_compatible_python": compat.CLIENT_VERSION,
        "max_compatible_python": "0.0.1",
    })
    assert set(payload) == PAYLOAD_KEYS
    assert payload["compatible"] is True
    assert payload["error"] is None


@pytest.mark.asyncio
async def test_missing_token_is_in_the_payload(monkeypatch):
    """M-06: without SKETCHUP_MCP_TOKEN, get_version answers with the
    instruction and opens no socket."""
    from unittest.mock import patch

    from sketchup_mcp import config
    from sketchup_mcp import connection as conn_module

    monkeypatch.setattr(conn_module, "_connection", None)
    monkeypatch.setattr(config, "TOKEN", None)
    with patch(
        "sketchup_mcp.connection.asyncio.open_connection",
        side_effect=AssertionError("no socket without a token"),
    ):
        payload = _extract_payload(await mcp.call_tool("get_version", {}))
    assert payload["compatible"] is False
    assert payload["ruby_version"] is None
    assert payload["error"].startswith("SKETCHUP_MCP_TOKEN is not set.")
