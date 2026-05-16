"""Tests for SketchUpConnection.send_command and module singleton."""
import asyncio
import json
import struct
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from sketchup_mcp import config
from sketchup_mcp.errors import SketchUpError

pytestmark = pytest.mark.asyncio


def encode_response(payload: dict) -> bytes:
    body = json.dumps(payload).encode("utf-8")
    return struct.pack(">I", len(body)) + body


def decode_writer_frames(buffer: bytes) -> list[dict]:
    """Split ``buffer`` into JSON frames produced by send_command."""
    frames: list[dict] = []
    offset = 0
    while offset < len(buffer):
        (length,) = struct.unpack(">I", buffer[offset : offset + 4])
        body = buffer[offset + 4 : offset + 4 + length]
        frames.append(json.loads(body))
        offset += 4 + length
    return frames


async def test_send_command_happy_path(make_connection, fake_streams):
    reader, writer = fake_streams
    conn = make_connection()
    reader.feed_data(
        encode_response(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "result": {"content": [{"type": "text", "text": "ok"}]},
            }
        )
    )
    result = await conn.send_command("test_tool", {"x": 1})
    assert result == {"content": [{"type": "text", "text": "ok"}]}
    sent = decode_writer_frames(bytes(writer.buffer))
    assert len(sent) == 1
    assert sent[0]["method"] == "tools/call"
    assert sent[0]["params"]["name"] == "test_tool"
    assert sent[0]["params"]["arguments"] == {"x": 1}
    assert sent[0]["id"] == 1


async def test_send_command_id_mismatch_disconnects(make_connection, fake_streams):
    reader, _ = fake_streams
    conn = make_connection()
    reader.feed_data(encode_response({"jsonrpc": "2.0", "id": 999, "result": {}}))
    with pytest.raises(SketchUpError) as exc_info:
        await conn.send_command("a", {})
    assert exc_info.value.code == -32603
    assert conn._writer is None


async def test_send_command_jsonrpc_error_propagates_data(make_connection, fake_streams):
    reader, _ = fake_streams
    conn = make_connection()
    reader.feed_data(
        encode_response(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "error": {
                    "code": -32000,
                    "message": "boom",
                    "data": {"tool": "x", "params": {"id": "1"}},
                },
            }
        )
    )
    with pytest.raises(SketchUpError) as exc_info:
        await conn.send_command("x", {"id": "1"})
    assert exc_info.value.code == -32000
    assert exc_info.value.message == "boom"
    assert exc_info.value.data == {"tool": "x", "params": {"id": "1"}}


async def test_send_command_oversized_request_raises(make_connection, fake_streams):
    conn = make_connection()
    big = "x" * (config.MAX_MESSAGE_SIZE + 100)
    with pytest.raises(SketchUpError) as exc_info:
        await conn.send_command("x", {"data": big})
    assert exc_info.value.code == -32600


async def test_send_command_parse_error_disconnects(make_connection, fake_streams):
    reader, _ = fake_streams
    conn = make_connection()
    bad = b"not json"
    reader.feed_data(struct.pack(">I", len(bad)) + bad)
    with pytest.raises(SketchUpError) as exc_info:
        await conn.send_command("x", {})
    assert exc_info.value.code == -32700
    assert conn._writer is None


async def test_send_command_oversized_response_disconnects(make_connection, fake_streams):
    """Если Ruby пришлёт frame > MAX_MESSAGE_SIZE, send_command должен disconnect'нуть.

    Иначе в reader'е остаётся «хвост» необработанных байт и stream
    рассинхронизируется на следующий вызов.
    """
    reader, _ = fake_streams
    conn = make_connection()
    huge = config.MAX_MESSAGE_SIZE + 1
    reader.feed_data(struct.pack(">I", huge))  # only the header — body never sent
    with pytest.raises(SketchUpError) as exc_info:
        await conn.send_command("x", {})
    assert exc_info.value.code == -32600
    assert conn._writer is None  # critical: disconnect happened


async def test_send_command_timeout_disconnects(make_connection, fake_streams):
    conn = make_connection(timeout=0.05)
    # Re-create reader in the running test loop to avoid cross-loop Future issues
    # (the conftest fixture creates StreamReader before the test loop is active).
    conn._reader = asyncio.StreamReader()
    # не подаём ответ — wait_for должен сработать
    with pytest.raises(SketchUpError) as exc_info:
        await conn.send_command("x", {})
    assert exc_info.value.code == -32000
    assert "timeout" in exc_info.value.message
    assert conn._writer is None


async def test_send_command_incomplete_read_disconnects(make_connection, fake_streams):
    reader, _ = fake_streams
    conn = make_connection()
    reader.feed_data(struct.pack(">I", 5) + b"only")  # claim 5, give 4
    reader.feed_eof()
    with pytest.raises(SketchUpError) as exc_info:
        await conn.send_command("x", {})
    assert exc_info.value.code == -32000
    assert conn._writer is None


async def test_send_command_retries_on_zero_byte_eof_for_readonly(make_connection, fake_streams):
    """Stale-socket для read-only tool: peer закрыл соединение, 0 байт ответа.

    Сценарий — Ruby-side idle_timeout убил клиента в простое между tool-вызовами.
    asyncio.StreamWriter.is_closing() от peer-side FIN не становится True, поэтому
    send_command идёт в _send_frame → drain ok → _recv_frame → readexactly(4) →
    IncompleteReadError(partial=b"", expected=4). Для READ-ONLY tools повтор
    безопасен (даже если Ruby выполнил handler, повторное чтение модели
    идемпотентно). Прозрачно retry'им.
    """
    reader, _ = fake_streams
    conn = make_connection()
    # 1) первый запрос: peer закрыл соединение, ни одного байта ответа
    reader.feed_eof()

    # 2) подменяем connect, чтобы он подложил свежие streams под retry
    new_reader = asyncio.StreamReader()
    new_writer = MagicMock()
    new_writer.buffer = bytearray()
    new_writer.write = MagicMock(side_effect=lambda d: new_writer.buffer.extend(d))
    new_writer.drain = AsyncMock()
    new_writer.close = MagicMock()
    new_writer.wait_closed = AsyncMock()
    new_writer.is_closing = MagicMock(return_value=False)

    async def fake_connect():
        conn._reader = new_reader
        conn._writer = new_writer

    conn.connect = fake_connect

    # 3) Подаём успешный ответ для retry-попытки.
    #    _next_id уже инкрементнут до 2 первой попыткой; retry получит rid=2.
    new_reader.feed_data(
        encode_response({"jsonrpc": "2.0", "id": 2, "result": {"ok": True}})
    )

    # get_model_info ∈ _RETRY_SAFE_TOOLS → retry разрешён
    result = await conn.send_command("get_model_info", {})
    assert result == {"ok": True}

    # Retry прошёл на свежем сокете
    assert conn._writer is new_writer
    sent_on_retry = decode_writer_frames(bytes(new_writer.buffer))
    assert len(sent_on_retry) == 1
    assert sent_on_retry[0]["params"]["name"] == "get_model_info"


async def test_send_command_no_retry_on_zero_byte_eof_for_mutating(make_connection, fake_streams):
    """Stale-socket для МУТАТИВНОГО tool — retry ЗАПРЕЩЁН (Codex review, PR #1).

    Контр-пример: Ruby `write_response` имеет `IO.select` write-timeout 1 сек.
    Если истекает, `reset_client` закрывает сокет **уже после**
    `model.commit_operation`. Python видит partial=b"", но мутация применена —
    retry задвоит её. Поэтому для мутативных — только пробрасываем ошибку
    наверх, caller (LLM) явно решает, что делать.
    """
    reader, _ = fake_streams
    conn = make_connection()
    reader.feed_eof()  # 0 bytes — выглядит как stale socket

    # connect не должен быть вызван — гарантия отсутствия retry
    conn.connect = AsyncMock(side_effect=AssertionError("retry forbidden for mutating tool"))

    with pytest.raises(SketchUpError) as exc_info:
        await conn.send_command("create_component", {"type": "cube"})
    assert exc_info.value.code == -32000
    assert conn._writer is None
    conn.connect.assert_not_called()


async def test_send_command_no_retry_on_partial_read(make_connection, fake_streams):
    """Partial read = peer уже начал отвечать → НЕЛЬЗЯ retry (риск задвоения мутации).

    Если Ruby успел прислать хотя бы один байт заголовка ответа, значит он уже
    прошёл model.commit_operation. Перевыполнять — задвоить мутацию.
    Регрессионный guard: при partial != b"" должна быть raise, БЕЗ retry.
    """
    reader, _ = fake_streams
    conn = make_connection()
    reader.feed_data(b"\x00\x00")  # 2 байта из 4 header'а
    reader.feed_eof()

    # connect не должен быть вызван — гарантия отсутствия retry
    conn.connect = AsyncMock(side_effect=AssertionError("retry forbidden for partial read"))

    with pytest.raises(SketchUpError) as exc_info:
        await conn.send_command("mutate", {})
    assert exc_info.value.code == -32000
    assert conn._writer is None
    conn.connect.assert_not_called()


async def test_send_command_lock_serializes_concurrent(make_connection, fake_streams):
    """Реально проверяем, что lock сериализует roundtrip'ы.

    Без lock второй send_command мог бы вклинить свой write до получения первого
    response. Делаем `drain()` блокирующимся через `asyncio.Event`: первый
    drain ждёт, пока тест не разрешит. Если lock работает — второй send_command
    ждёт под локом и не пишет; без lock — пишет немедленно и буфер показывает
    interleaving в неверном порядке.
    """
    _, writer = fake_streams
    conn = make_connection()
    # Re-create reader in the running test loop (see timeout test for rationale).
    reader = asyncio.StreamReader()
    conn._reader = reader

    drain_gate = asyncio.Event()
    drain_call_count = 0

    async def gated_drain():
        nonlocal drain_call_count
        drain_call_count += 1
        if drain_call_count == 1:
            # первый drain ждёт; второй вызов уже после release_gate
            await drain_gate.wait()

    writer.drain = gated_drain  # type: ignore[assignment]

    # Запускаем оба send_command. Первый "застрянет" в drain.
    task1 = asyncio.create_task(conn.send_command("a", {}))
    task2 = asyncio.create_task(conn.send_command("b", {}))
    await asyncio.sleep(0)  # отдать управление, чтобы оба попали в _send_frame

    # На этом этапе при работающем lock:
    #   - task1 в gated_drain, держит lock
    #   - task2 ждёт acquire lock, ещё не вызвал _send_frame
    # Без lock task2 уже бы записал свой frame.
    sent_so_far = decode_writer_frames(bytes(writer.buffer))
    assert len(sent_so_far) == 1, (
        f"lock failed: writer buffer has {len(sent_so_far)} frames before drain release"
    )
    assert sent_so_far[0]["id"] == 1

    # Разрешаем drain, подаём response для id=1 и затем для id=2.
    reader.feed_data(encode_response({"jsonrpc": "2.0", "id": 1, "result": {"a": 1}}))
    drain_gate.set()
    r1 = await task1
    reader.feed_data(encode_response({"jsonrpc": "2.0", "id": 2, "result": {"b": 2}}))
    r2 = await task2

    assert r1 == {"a": 1}
    assert r2 == {"b": 2}
    sent = decode_writer_frames(bytes(writer.buffer))
    assert [f["id"] for f in sent] == [1, 2]


async def test_send_command_reconnects_after_disconnect(make_connection, fake_streams):
    reader, writer = fake_streams
    conn = make_connection()
    # 1) первый вызов: id mismatch → disconnect
    reader.feed_data(encode_response({"jsonrpc": "2.0", "id": 999, "result": {}}))
    with pytest.raises(SketchUpError):
        await conn.send_command("a", {})
    assert conn._writer is None

    # 2) подменяем connect, чтобы он подложил новые streams
    new_reader = asyncio.StreamReader()
    new_writer = MagicMock()
    new_writer.buffer = bytearray()
    new_writer.write = MagicMock(side_effect=lambda d: new_writer.buffer.extend(d))
    new_writer.drain = AsyncMock()
    new_writer.close = MagicMock()
    new_writer.wait_closed = AsyncMock()
    new_writer.is_closing = MagicMock(return_value=False)

    async def fake_connect():
        conn._reader = new_reader
        conn._writer = new_writer

    conn.connect = fake_connect

    # _next_id уже = 2 (инкрементировался до raise) — проверяем, что не сбросился
    assert conn._next_id == 2, "_next_id must NOT reset on disconnect"
    new_reader.feed_data(
        encode_response({"jsonrpc": "2.0", "id": 2, "result": {"ok": True}})
    )
    result = await conn.send_command("b", {})
    assert result == {"ok": True}
    assert conn._writer is new_writer


async def test_get_connection_raises_connection_error_when_refused(monkeypatch):
    """get_connection should raise ConnectionError if open_connection refuses."""
    from sketchup_mcp import connection as conn_module

    # сбросить singleton, если оставлен предыдущим тестом
    monkeypatch.setattr(conn_module, "_connection", None)

    with patch(
        "sketchup_mcp.connection.asyncio.open_connection",
        side_effect=ConnectionRefusedError("nope"),
    ):
        with pytest.raises(ConnectionError) as exc_info:
            await conn_module.get_connection()
    assert "cannot connect" in str(exc_info.value)


async def test_close_connection_resets_singleton(monkeypatch):
    from sketchup_mcp import connection as conn_module
    from sketchup_mcp.connection import SketchUpConnection

    fake = SketchUpConnection(host="x", port=0, timeout=1.0)
    monkeypatch.setattr(conn_module, "_connection", fake)
    await conn_module.close_connection()
    assert conn_module._connection is None


async def test_get_connection_cold_start_race_creates_singleton_once(monkeypatch):
    """Concurrent first-callers of get_connection() must not each create a connection.

    Без `_get_connection_lock` (connection.py:225) две параллельные холодные
    точки могли бы обе увидеть `_connection is None`, инстанциировать свой
    SketchUpConnection и вызвать open_connection дважды — один сокет осиротел
    бы. Тест регрессионно фиксирует: один общий singleton, один реальный
    open_connection.
    """
    from sketchup_mcp import connection as conn_module

    monkeypatch.setattr(conn_module, "_connection", None)

    open_call_count = 0
    gate = asyncio.Event()

    async def slow_open(*_args, **_kwargs):
        nonlocal open_call_count
        open_call_count += 1
        # Удерживаем первое открытие до явного триггера, чтобы дать второму
        # вызову шанс пройти cold-start path параллельно — без lock'а он бы
        # тоже инициировал open_connection.
        await gate.wait()
        writer = MagicMock()
        # is_closing() должен явно вернуть False, иначе второй get_connection
        # увидит «writer is closing» и инициирует второй connect() уже не
        # из-за cold-start race, а из-за реконнекта. Это замаскировало бы
        # настоящий cold-start race в проверяемом коде.
        writer.is_closing = MagicMock(return_value=False)
        return asyncio.StreamReader(), writer

    with patch("sketchup_mcp.connection.asyncio.open_connection", side_effect=slow_open):
        t1 = asyncio.create_task(conn_module.get_connection())
        t2 = asyncio.create_task(conn_module.get_connection())
        # Дать обеим coroutines дойти до lock'а.
        await asyncio.sleep(0)
        await asyncio.sleep(0)
        gate.set()
        c1, c2 = await asyncio.gather(t1, t2)

    assert c1 is c2, "get_connection must return the same singleton for concurrent callers"
    assert open_call_count == 1, (
        f"open_connection called {open_call_count}× — cold-start race not guarded"
    )

    # Cleanup для последующих тестов.
    monkeypatch.setattr(conn_module, "_connection", None)


def test_get_viewport_screenshot_is_retry_safe():
    """get_viewport_screenshot is read-only (no document state changes
    in either restore_view mode); regression guard against accidental
    removal from the retry whitelist."""
    from sketchup_mcp.connection import _RETRY_SAFE_TOOLS
    assert "get_viewport_screenshot" in _RETRY_SAFE_TOOLS
