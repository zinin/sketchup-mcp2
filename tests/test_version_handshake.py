"""Tests for the client_version outbound + server_version inbound handshake
inside SketchUpConnection._send_once. We exercise the method directly with
mocked StreamReader/StreamWriter rather than spinning up a real TCP server."""
from __future__ import annotations

import asyncio
import json
import struct
from unittest.mock import AsyncMock, MagicMock

import pytest

from sketchup_mcp import compat
from sketchup_mcp.connection import SketchUpConnection
from sketchup_mcp.errors import IncompatibleVersionError


def _frame(payload: dict) -> bytes:
    body = json.dumps(payload).encode("utf-8")
    return struct.pack(">I", len(body)) + body


def _frames_to_reader(*frames: bytes) -> AsyncMock:
    """Build an asyncio.StreamReader-like mock that yields the supplied frames
    in order via readexactly()."""
    chunks = list(frames)
    pos = {"i": 0}

    async def readexactly(n: int) -> bytes:
        if pos["i"] >= sum(len(c) for c in chunks):
            raise asyncio.IncompleteReadError(b"", n)
        # Concatenate all frames into one buffer so consumer can chop by byte.
        buf = b"".join(chunks)
        out = buf[pos["i"]:pos["i"] + n]
        pos["i"] += n
        return out

    reader = MagicMock()
    reader.readexactly = AsyncMock(side_effect=readexactly)
    return reader


def _capturing_writer():
    """Return (writer_mock, captured_list); writer.write appends to captured."""
    captured: list[bytes] = []
    writer = MagicMock()
    writer.write = MagicMock(side_effect=lambda b: captured.append(b))
    writer.drain = AsyncMock(return_value=None)
    writer.is_closing = MagicMock(return_value=False)
    writer.close = MagicMock(return_value=None)
    writer.wait_closed = AsyncMock(return_value=None)
    return writer, captured


def _decode_request(frame_bytes: bytes) -> dict:
    """Strip the 4-byte length prefix and parse the JSON body."""
    return json.loads(frame_bytes[4:])


@pytest.mark.asyncio
async def test_outbound_payload_carries_client_version():
    conn = SketchUpConnection(host="127.0.0.1", port=9876, timeout=5.0)
    conn._reader = _frames_to_reader(
        _frame({"jsonrpc": "2.0", "id": 1, "result": {"content": [{"type": "text", "text": "{}"}], "isError": False}, "server_version": compat.MAX_RUBY}),
    )
    conn._writer, captured = _capturing_writer()
    await conn.send_command("get_model_info", {})
    payload = _decode_request(captured[0])
    assert payload["client_version"] == compat.CLIENT_VERSION
    assert payload["method"] == "tools/call"
    assert payload["params"] == {"name": "get_model_info", "arguments": {}}


@pytest.mark.asyncio
async def test_compatible_server_version_does_not_raise():
    conn = SketchUpConnection(host="127.0.0.1", port=9876, timeout=5.0)
    conn._reader = _frames_to_reader(
        _frame({"jsonrpc": "2.0", "id": 1, "result": {"content": [{"type": "text", "text": "ok"}], "isError": False}, "server_version": compat.MAX_RUBY}),
    )
    conn._writer, _ = _capturing_writer()
    result = await conn.send_command("get_model_info", {})
    assert result["content"][0]["text"] == "ok"


@pytest.mark.asyncio
async def test_incompatible_server_version_raises_for_normal_tool(monkeypatch):
    monkeypatch.setattr(compat, "MIN_RUBY", "1.0.0")
    monkeypatch.setattr(compat, "MAX_RUBY", "1.0.0")
    conn = SketchUpConnection(host="127.0.0.1", port=9876, timeout=5.0)
    conn._reader = _frames_to_reader(
        _frame({"jsonrpc": "2.0", "id": 1, "result": {"content": [{"type": "text", "text": "ok"}], "isError": False}, "server_version": "0.0.3"}),
    )
    conn._writer, _ = _capturing_writer()
    with pytest.raises(IncompatibleVersionError):
        await conn.send_command("get_model_info", {})


@pytest.mark.asyncio
async def test_missing_server_version_raises_for_normal_tool():
    conn = SketchUpConnection(host="127.0.0.1", port=9876, timeout=5.0)
    conn._reader = _frames_to_reader(
        _frame({"jsonrpc": "2.0", "id": 1, "result": {"content": [{"type": "text", "text": "ok"}], "isError": False}}),
    )
    conn._writer, _ = _capturing_writer()
    with pytest.raises(IncompatibleVersionError) as exc:
        await conn.send_command("get_model_info", {})
    assert "pre-dates" in str(exc.value)


@pytest.mark.asyncio
async def test_get_version_bypasses_inbound_check(monkeypatch):
    """When name == 'get_version', a mismatch in server_version must NOT raise:
    the diagnostic must reach the caller so it can build the verdict payload."""
    monkeypatch.setattr(compat, "MIN_RUBY", "1.0.0")
    monkeypatch.setattr(compat, "MAX_RUBY", "1.0.0")
    conn = SketchUpConnection(host="127.0.0.1", port=9876, timeout=5.0)
    payload_text = json.dumps({
        "ruby_version": "0.0.3",
        "min_compatible_python": "0.0.3",
        "max_compatible_python": "0.0.3",
    })
    conn._reader = _frames_to_reader(
        _frame({"jsonrpc": "2.0", "id": 1,
                "result": {"content": [{"type": "text", "text": payload_text}], "isError": False},
                "server_version": "0.0.3"}),
    )
    conn._writer, _ = _capturing_writer()
    result = await conn.send_command("get_version", {})
    # No raise — payload comes through.
    text = result["content"][0]["text"]
    assert json.loads(text)["ruby_version"] == "0.0.3"


@pytest.mark.asyncio
async def test_inbound_check_runs_on_every_response(monkeypatch):
    """Two successive calls each trigger check_ruby_version — no per-connection
    cache that would skip subsequent verifications."""
    call_count = {"n": 0}

    def spying_check(v):
        call_count["n"] += 1

    monkeypatch.setattr(compat, "check_ruby_version", spying_check)
    conn = SketchUpConnection(host="127.0.0.1", port=9876, timeout=5.0)
    conn._reader = _frames_to_reader(
        _frame({"jsonrpc": "2.0", "id": 1, "result": {"content": [{"type": "text", "text": "a"}], "isError": False}, "server_version": "0.0.3"}),
        _frame({"jsonrpc": "2.0", "id": 2, "result": {"content": [{"type": "text", "text": "b"}], "isError": False}, "server_version": "0.0.3"}),
    )
    conn._writer, _ = _capturing_writer()
    await conn.send_command("get_model_info", {})
    await conn.send_command("get_model_info", {})
    assert call_count["n"] == 2


@pytest.mark.asyncio
async def test_ruby_side_minus_32001_promoted_to_incompatible_version_error():
    """When Ruby returns error.code == -32001 (its own mismatch verdict),
    _send_once must raise IncompatibleVersionError, not generic SketchUpError.
    Ensures callers can catch one class regardless of which side detected."""
    conn = SketchUpConnection(host="127.0.0.1", port=9876, timeout=5.0)
    conn._reader = _frames_to_reader(
        _frame({
            "jsonrpc": "2.0", "id": 1,
            "error": {"code": -32001, "message": "sketchup-mcp2 v0.0.0 is too old..."},
            "server_version": compat.MAX_RUBY,
        }),
    )
    conn._writer, _ = _capturing_writer()
    with pytest.raises(IncompatibleVersionError) as exc:
        await conn.send_command("get_model_info", {})
    assert "too old" in str(exc.value)


def test_get_version_in_retry_safe_tools():
    """Regression for CRITICAL-4: get_version must be retry-safe so
    cold-start stale-socket auto-retries."""
    from sketchup_mcp.connection import _RETRY_SAFE_TOOLS
    assert "get_version" in _RETRY_SAFE_TOOLS
