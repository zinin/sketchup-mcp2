"""Unit-tests for SketchUpConnection._send_frame / _recv_frame."""
import asyncio
import json
import struct

import pytest

from sketchup_mcp import config
from sketchup_mcp.errors import SketchUpError

pytestmark = pytest.mark.asyncio


async def test_send_frame_simple(make_connection, fake_streams):
    _, writer = fake_streams
    conn = make_connection()
    body = b'{"hello": "world"}'
    await conn._send_frame(body)
    assert bytes(writer.buffer) == struct.pack(">I", len(body)) + body


async def test_send_frame_unicode(make_connection, fake_streams):
    _, writer = fake_streams
    conn = make_connection()
    body = json.dumps({"msg": "Привет"}, ensure_ascii=False).encode("utf-8")
    await conn._send_frame(body)
    assert bytes(writer.buffer) == struct.pack(">I", len(body)) + body


async def test_recv_frame_simple(make_connection, fake_streams):
    reader, _ = fake_streams
    conn = make_connection()
    body = b'{"ok": true}'
    reader.feed_data(struct.pack(">I", len(body)) + body)
    assert await conn._recv_frame() == body


async def test_recv_frame_chunked(make_connection, fake_streams):
    reader, _ = fake_streams
    conn = make_connection()
    body = b'{"ok": true}'
    full = struct.pack(">I", len(body)) + body
    reader.feed_data(full[:2])
    reader.feed_data(full[2:5])
    reader.feed_data(full[5:])
    assert await conn._recv_frame() == body


async def test_recv_frame_eof_in_length(make_connection, fake_streams):
    reader, _ = fake_streams
    conn = make_connection()
    reader.feed_data(b"\x00\x00")  # only 2 of 4 length bytes
    reader.feed_eof()
    with pytest.raises(asyncio.IncompleteReadError):
        await conn._recv_frame()


async def test_recv_frame_eof_in_body(make_connection, fake_streams):
    reader, _ = fake_streams
    conn = make_connection()
    reader.feed_data(struct.pack(">I", 100) + b"only some bytes")
    reader.feed_eof()
    with pytest.raises(asyncio.IncompleteReadError):
        await conn._recv_frame()


async def test_recv_frame_too_large_raises(make_connection, fake_streams):
    reader, _ = fake_streams
    conn = make_connection()
    huge = config.MAX_MESSAGE_SIZE + 1
    reader.feed_data(struct.pack(">I", huge))
    with pytest.raises(SketchUpError) as exc_info:
        await conn._recv_frame()
    assert exc_info.value.code == -32600
    assert str(huge) in exc_info.value.message


async def test_recv_frame_zero_length_raises(make_connection, fake_streams):
    reader, _ = fake_streams
    conn = make_connection()
    reader.feed_data(struct.pack(">I", 0))
    with pytest.raises(SketchUpError) as exc_info:
        await conn._recv_frame()
    assert exc_info.value.code == -32600
    assert "zero-length" in exc_info.value.message


async def test_send_frame_without_writer_raises(make_connection):
    conn = make_connection()
    conn._writer = None
    with pytest.raises(SketchUpError) as exc_info:
        await conn._send_frame(b'{"x": 1}')
    assert exc_info.value.code == -32603
