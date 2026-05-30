"""Shared pytest fixtures."""
import asyncio
from unittest.mock import AsyncMock, MagicMock

import pytest_asyncio


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
