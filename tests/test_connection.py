"""Tests for SketchUpConnection.send_command and module singleton."""
import asyncio
import json
import struct
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from sketchup_mcp import compat, config
from sketchup_mcp.connection import SketchUpConnection
from sketchup_mcp.errors import IncompatibleVersionError, SketchUpError

pytestmark = pytest.mark.asyncio


def encode_response(payload: dict) -> bytes:
    """Build a fake 4-byte-length-prefixed JSON-RPC response frame."""
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

    Сценарий — Ruby server (или сетевой layer) закрыл сокет в простое между
    tool-вызовами; idle deadline сам по себе удалён в multi-client редизайне,
    но half-open detection / explicit server.stop / OS-level RST дают тот же
    эффект — peer закрыл, клиент об этом ещё не знает.
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


async def test_send_command_stale_socket_eof_for_mutating_enriches_error(
    make_connection, fake_streams
):
    """Stale-socket (zero-byte EOF, connection.py:262) для мутативного tool:
    ошибку ОБОГАЩАЕМ — имя инструмента в data + actionable recovery-hint для
    агента, вместо голого "connection error … tool=?". Retry по-прежнему ЗАПРЕЩЁН.
    """
    reader, _ = fake_streams
    conn = make_connection()
    reader.feed_eof()  # 0 байт — выглядит как stale socket
    conn.connect = AsyncMock(side_effect=AssertionError("retry forbidden for mutating tool"))

    with pytest.raises(SketchUpError) as exc_info:
        await conn.send_command("create_component", {"type": "cube"})

    err = exc_info.value
    assert err.code == -32000
    assert err.data.get("tool") == "create_component"
    assert "NOT auto-retried" in err.message
    assert "get_model_info" in err.message
    assert "do NOT retry" in err.message
    conn.connect.assert_not_called()


async def test_send_command_stale_socket_connreset_for_mutating_enriches_error(
    make_connection, fake_streams
):
    """Второй источник _StaleSocketError — ConnectionError (ECONNRESET) mid-write
    (connection.py:273). Тоже обогащаем: tool + hint. Retry ЗАПРЕЩЁН.
    """
    _, writer = fake_streams
    conn = make_connection()
    writer.drain = AsyncMock(side_effect=ConnectionResetError("Connection lost"))
    conn.connect = AsyncMock(side_effect=AssertionError("retry forbidden for mutating tool"))

    with pytest.raises(SketchUpError) as exc_info:
        await conn.send_command("create_component", {"type": "cube"})

    err = exc_info.value
    assert err.code == -32000
    assert err.data.get("tool") == "create_component"
    assert "NOT auto-retried" in err.message
    assert "get_model_info" in err.message
    assert "do NOT retry" in err.message
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
    # asyncio.wait_for spawns a child task on CPython <=3.11 (inline on 3.12+,
    # gh-96764), so the number of event-loop iterations before task1's write()
    # lands in the buffer is version-dependent — poll (bounded) instead of a
    # single sleep(0). With a broken lock both frames land in the same
    # iteration, so the `== 1` assertion below still detects interleaving.
    for _ in range(100):
        await asyncio.sleep(0)
        if writer.buffer:
            break

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

    # Build a handshake-success frame that get_connection's connect() will
    # consume during the hello roundtrip (one-time handshake protocol).
    hello_ok_frame = encode_response({
        "jsonrpc": "2.0",
        "id": 0,
        "result": {"server_version": compat.MAX_RUBY, "client_id": 0},
    })

    async def slow_open(*_args, **_kwargs):
        nonlocal open_call_count
        open_call_count += 1
        # Удерживаем первое открытие до явного триггера, чтобы дать второму
        # вызову шанс пройти cold-start path параллельно — без lock'а он бы
        # тоже инициировал open_connection.
        await gate.wait()
        reader = asyncio.StreamReader()
        reader.feed_data(hello_ok_frame)
        writer = MagicMock()
        # write/drain must be present so _handshake's outbound hello write
        # succeeds before the reader supplies the response.
        writer.write = MagicMock()
        writer.drain = AsyncMock()
        writer.close = MagicMock()
        writer.wait_closed = AsyncMock()
        # is_closing() должен явно вернуть False, иначе второй get_connection
        # увидит «writer is closing» и инициирует второй connect() уже не
        # из-за cold-start race, а из-за реконнекта. Это замаскировало бы
        # настоящий cold-start race в проверяемом коде.
        writer.is_closing = MagicMock(return_value=False)
        return reader, writer

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


async def test_get_viewport_screenshot_is_retry_safe():
    """get_viewport_screenshot is read-only (no document state changes
    in either restore_view mode); regression guard against accidental
    removal from the retry whitelist."""
    from sketchup_mcp.connection import _RETRY_SAFE_TOOLS
    assert "get_viewport_screenshot" in _RETRY_SAFE_TOOLS


# ---------------------------------------------------------------------------
# One-time handshake tests (Task 6 — protocol change from per-request to
# one-time hello roundtrip on connect()).
# ---------------------------------------------------------------------------


def encode_frame(body_bytes: bytes) -> bytes:
    return struct.pack(">I", len(body_bytes)) + body_bytes


def hello_success(server_version: str, client_id: int = 0) -> bytes:
    return encode_frame(json.dumps({
        "jsonrpc": "2.0",
        "result": {"server_version": server_version, "client_id": client_id},
        "id": 0,
    }).encode("utf-8"))


def hello_error(code: int, message: str) -> bytes:
    return encode_frame(json.dumps({
        "jsonrpc": "2.0",
        "error": {"code": code, "message": message},
        "id": 0,
    }).encode("utf-8"))


class FakeServer:
    """In-process TCP server that scripts the byte stream for one client."""

    def __init__(self, script: list[bytes]):
        self._script = script
        self._received = bytearray()
        self._server: asyncio.base_events.Server | None = None
        self.host = "127.0.0.1"
        self.port = 0

    async def __aenter__(self):
        self._server = await asyncio.start_server(
            self._handle, host=self.host, port=0)
        self.port = self._server.sockets[0].getsockname()[1]
        return self

    async def __aexit__(self, exc_type, exc, tb):
        self._server.close()
        await self._server.wait_closed()

    async def _handle(self, reader, writer):
        for chunk in self._script:
            writer.write(chunk)
            await writer.drain()
        try:
            while True:
                data = await reader.read(4096)
                if not data:
                    break
                self._received.extend(data)
        except Exception:
            pass
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass

    @property
    def received(self) -> bytes:
        return bytes(self._received)


class FakeServerMulti:
    """Like FakeServer but serves each new TCP connection with its own script.

    Each script entry is ``(chunks, close_immediately)``: ``chunks`` is the
    list of byte frames to send; ``close_immediately=True`` closes the
    socket right after the writes (simulates a server that dropped us),
    ``False`` keeps the socket open while draining the client's outbound
    traffic (simulates a server that wants the next request from us).
    """

    def __init__(self, scripts: list[tuple[list[bytes], bool]]):
        self._scripts = list(scripts)
        self._idx = 0
        self._server: asyncio.base_events.Server | None = None
        self.host = "127.0.0.1"
        self.port = 0
        # Per-connection captured-bytes log; indexed by connection order.
        self.received: list[bytes] = []

    async def __aenter__(self):
        self._server = await asyncio.start_server(
            self._handle, host=self.host, port=0)
        self.port = self._server.sockets[0].getsockname()[1]
        return self

    async def __aexit__(self, exc_type, exc, tb):
        self._server.close()
        await self._server.wait_closed()

    async def _handle(self, reader, writer):
        if self._idx >= len(self._scripts):
            writer.close()
            return
        chunks, close_immediately = self._scripts[self._idx]
        self._idx += 1
        my_log_idx = len(self.received)
        self.received.append(b"")
        for chunk in chunks:
            writer.write(chunk)
            await writer.drain()
        if not close_immediately:
            # Stay open and drain the client's outbound traffic so it can
            # send follow-up frames (e.g., tool/call after handshake reply).
            try:
                buf = bytearray()
                while True:
                    data = await reader.read(4096)
                    if not data:
                        break
                    buf.extend(data)
                self.received[my_log_idx] = bytes(buf)
            except Exception:
                pass
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass


async def test_handshake_happy_path_populates_server_version_and_client_id():
    script = [hello_success(compat.MAX_RUBY, client_id=7)]
    async with FakeServer(script) as fs:
        conn = SketchUpConnection(host=fs.host, port=fs.port, timeout=2.0)
        await conn.connect()
        assert conn._server_version == compat.MAX_RUBY
        assert conn._client_id == 7
        await conn.disconnect()


async def test_handshake_version_mismatch_raises_incompatible_version_error():
    script = [hello_error(-32001, "client too old")]
    async with FakeServer(script) as fs:
        conn = SketchUpConnection(host=fs.host, port=fs.port, timeout=2.0)
        with pytest.raises(IncompatibleVersionError):
            await conn.connect()


async def test_handshake_generic_error_raises_sketchup_error():
    script = [hello_error(-32602, "handshake malformed")]
    async with FakeServer(script) as fs:
        conn = SketchUpConnection(host=fs.host, port=fs.port, timeout=2.0)
        with pytest.raises(SketchUpError) as ei:
            await conn.connect()
        assert ei.value.code == -32602


async def test_connect_sends_hello_first_with_client_version():
    script = [hello_success(compat.MAX_RUBY)]
    async with FakeServer(script) as fs:
        conn = SketchUpConnection(host=fs.host, port=fs.port, timeout=2.0)
        await conn.connect()
        await conn.disconnect()
        # Bounded busy-loop to wait for the server to receive the hello body.
        # Avoid hardcoded sleep — flaky on slow CI.
        def _hello_received() -> bool:
            buf = fs.received
            if len(buf) < 4:
                return False
            body_len = int.from_bytes(buf[:4], "big")
            return len(buf) >= 4 + body_len
        for _ in range(100):
            if _hello_received():
                break
            await asyncio.sleep(0.01)
        assert _hello_received(), "server never received hello"
        body_len = int.from_bytes(fs.received[:4], "big")
        body = json.loads(fs.received[4:4 + body_len])
        assert body["method"] == "hello"
        assert body["params"]["client_version"] == compat.CLIENT_VERSION
        assert body["id"] == 0


async def test_send_once_does_not_include_client_version():
    tool_reply = encode_frame(json.dumps({
        "jsonrpc": "2.0",
        "result": {"content": [{"type": "text", "text": "ok"}], "isError": False},
        "id": 1,
    }).encode("utf-8"))
    script = [hello_success(compat.MAX_RUBY), tool_reply]
    async with FakeServer(script) as fs:
        conn = SketchUpConnection(host=fs.host, port=fs.port, timeout=2.0)
        await conn.connect()
        await conn.send_command("get_version", {})
        await conn.disconnect()
        # Bounded wait for the server's read loop to drain both client
        # frames into fs.received. The disconnect above sends FIN, the
        # server's reader.read() returns b"" and the handler completes
        # — but that happens on a separate asyncio task that may not
        # have run yet by the time disconnect() returns to us.
        def _two_frames_present() -> bool:
            buf = fs.received
            if len(buf) < 4:
                return False
            l1 = int.from_bytes(buf[:4], "big")
            if len(buf) < 4 + l1 + 4:
                return False
            l2 = int.from_bytes(buf[4 + l1:4 + l1 + 4], "big")
            return len(buf) >= 4 + l1 + 4 + l2
        for _ in range(100):
            if _two_frames_present():
                break
            await asyncio.sleep(0.01)
        assert _two_frames_present(), \
            f"server never received both client frames (got {len(fs.received)} bytes)"
        buf = fs.received
        # frame 1: hello — skip
        l1 = int.from_bytes(buf[:4], "big")
        offset = 4 + l1
        # frame 2: tools/call
        l2 = int.from_bytes(buf[offset:offset + 4], "big")
        body = json.loads(buf[offset + 4:offset + 4 + l2])
        assert body["method"] == "tools/call"
        assert "client_version" not in body, \
            "post-handshake request must not carry client_version"


async def test_send_once_does_not_require_server_version_in_response():
    """Response without server_version field must still parse successfully."""
    tool_reply = encode_frame(json.dumps({
        "jsonrpc": "2.0",
        "result": {"content": [{"type": "text", "text": "ok"}], "isError": False},
        "id": 1,
    }).encode("utf-8"))
    script = [hello_success(compat.MAX_RUBY), tool_reply]
    async with FakeServer(script) as fs:
        conn = SketchUpConnection(host=fs.host, port=fs.port, timeout=2.0)
        await conn.connect()
        result = await conn.send_command("some_tool", {})
        assert result["isError"] is False
        await conn.disconnect()


async def test_stale_socket_retry_redoes_handshake():
    """After a stale socket is detected, retry must re-handshake on the new socket."""
    tool_reply = encode_frame(json.dumps({
        "jsonrpc": "2.0",
        "result": {"content": [{"type": "text", "text": "ok"}], "isError": False},
        "id": 2,
    }).encode("utf-8"))
    async with FakeServerMulti([
        # client 1: handshake then close (simulates Ruby server-side close
        # — explicit stop, half-open detection, OS RST, etc.)
        ([hello_success(compat.MAX_RUBY)], True),
        # client 2: handshake; stay open to accept tool/call, then reply
        ([hello_success(compat.MAX_RUBY), tool_reply], False),
    ]) as fs:
        conn = SketchUpConnection(host=fs.host, port=fs.port, timeout=2.0)
        await conn.connect()
        # Stale socket detected on next send; retry should re-handshake on second connection
        result = await conn.send_command("get_model_info", {})
        assert result["isError"] is False
        await conn.disconnect()


async def test_handshake_timeout_raises_sketchup_error():
    """Ruby that accepts TCP but never replies must surface as timeout, not a hang."""
    async with FakeServer([]) as fs:   # no script — server never writes
        conn = SketchUpConnection(host=fs.host, port=fs.port, timeout=0.5)
        with pytest.raises(SketchUpError) as ei:
            await conn.connect()
        assert "timed out" in str(ei.value).lower()


async def test_connect_timeout_when_open_connection_hangs():
    """A host that accepts the SYN but never finishes the TCP connect (firewall
    DROP, half-dead peer) must surface as a timeout SketchUpError instead of
    hanging MCP startup forever (codex review). The connect itself is wrapped in
    wait_for, mirroring the handshake-timeout guard above."""
    async def _never_completes(*_args, **_kwargs):
        await asyncio.Event().wait()  # block until cancelled — simulates a stalled connect

    conn = SketchUpConnection(host="10.255.255.1", port=9, timeout=0.1)
    with patch(
        "sketchup_mcp.connection.asyncio.open_connection",
        side_effect=_never_completes,
    ):
        with pytest.raises(SketchUpError) as ei:
            await conn.connect()
    assert ei.value.code == -32000
    assert "connect timed out" in str(ei.value).lower()
    assert conn._writer is None  # no half-open socket left behind
