"""Shared pytest fixtures."""
import asyncio
import re
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock

import pytest
import pytest_asyncio

_COMPAT_RB = (
    Path(__file__).resolve().parent.parent
    / "mcp_for_sketchup" / "mcp_for_sketchup" / "core" / "compat.rb"
)


@pytest.fixture
def ruby_const():
    """``ruby_const(name, path=compat.rb)``: read a constant such as
    ``SERVER_VERSION = "0.3.1"`` or ``EDGE_OP_BUDGET_S = 30.0`` from a Ruby file
    (compat.rb unless ``path`` names another): the text of its string or number
    literal.

    A fixture, not a function that one test module imports from another: that
    import works only while pytest puts ``tests/`` on ``sys.path`` (its default
    import mode)."""
    def read(name: str, path: Path = _COMPAT_RB) -> str:
        source = path.read_text(encoding="utf-8")
        m = re.search(rf'^\s*{name}\s*=\s*(?:"([^"]*)"|([\d_.]+))', source, re.M)
        assert m, f"{name} not found in {path}"
        return m.group(1) if m.group(1) is not None else m.group(2)

    return read


@pytest_asyncio.fixture
async def fake_streams():
    """Return ``(reader, writer)`` ready to inject into SketchUpConnection.

    ``reader`` is a real ``asyncio.StreamReader``; tests push bytes via
    ``reader.feed_data(...)`` and signal close via ``reader.feed_eof()``.

    ``writer`` is a MagicMock that mimics ``asyncio.StreamWriter``:
    - ``writer.write(data)`` appends to ``writer.buffer`` (bytearray)
    - ``writer.drain()`` is an AsyncMock
    - ``writer.close()`` and ``writer.wait_closed()`` are tracked
    - ``writer.is_closing()`` returns False by default
    """
    reader = asyncio.StreamReader()

    writer = MagicMock()
    writer.buffer = bytearray()
    writer.write = MagicMock(side_effect=lambda data: writer.buffer.extend(data))
    writer.drain = AsyncMock()
    writer.close = MagicMock()
    writer.wait_closed = AsyncMock()
    writer.is_closing = MagicMock(return_value=False)

    return reader, writer


@pytest_asyncio.fixture
async def make_connection(fake_streams):
    """Factory that returns a ``SketchUpConnection`` with injected streams."""
    from sketchup_mcp.connection import SketchUpConnection

    reader, writer = fake_streams

    def _make(timeout: float = 1.0):
        conn = SketchUpConnection(host="x", port=0, timeout=timeout)
        conn._reader = reader
        conn._writer = writer
        return conn

    return _make


# One handshake's values (spec §7.2), computed with Python's hmac and Ruby's
# OpenSSL::HMAC and pinned in both suites — test/support/auth_vectors.rb holds
# the same ones — so the two halves of the handshake cannot drift apart.
_AUTH_VECTORS = SimpleNamespace(
    token="0123456789abcdef" * 4,
    client_nonce="a" * 64,
    server_nonce="b" * 64,
    server_proof="a1069e0a855573049322f60ceb171ea5e84780060a85dbd060bcbbec96df272d",
    client_proof="c968a257091ddea88a25001b219ab21a1609e2d5991b92adb3445c5bfdc7e279",
)


@pytest.fixture
def auth_vectors(monkeypatch):
    """The pinned handshake values, with the client's nonce fixed to
    ``client_nonce``: a scripted server can answer ``hello`` with
    ``server_nonce`` and ``server_proof`` and expect ``client_proof`` in
    ``auth``. Build connections with ``token=auth_vectors.token``."""
    monkeypatch.setattr("sketchup_mcp.auth.new_nonce", lambda: _AUTH_VECTORS.client_nonce)
    return _AUTH_VECTORS
