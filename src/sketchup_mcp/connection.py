"""Asynchronous JSON-RPC client to the SketchUp Ruby extension.

This module owns the wire protocol: 4-byte big-endian length prefix + JSON body,
``asyncio.Lock`` serialisation, lazy reconnect, total per-request timeout.

Public entry points are :func:`get_connection`/:func:`close_connection` for
singleton management, and :class:`SketchUpConnection.send_command` for
actual JSON-RPC traffic.
"""
import asyncio
import json
import logging
import struct
from dataclasses import dataclass, field
from typing import Any

from sketchup_mcp import config
from sketchup_mcp.errors import SketchUpError

logger = logging.getLogger("sketchup_mcp.connection")

_DISCONNECT_TIMEOUT = 5.0  # секунд на graceful close сокета


@dataclass
class SketchUpConnection:
    host: str
    port: int
    timeout: float
    _reader: asyncio.StreamReader | None = None
    _writer: asyncio.StreamWriter | None = None
    _lock: asyncio.Lock | None = field(default=None, init=False, repr=False)
    _next_id: int = 1

    def __post_init__(self) -> None:
        # Lock создаётся при инстанциации (всегда внутри running event loop —
        # `get_connection()` зовётся из lifespan/test'ов, оба под `asyncio.run`).
        # Через `default_factory=asyncio.Lock` это работало бы тоже, но Python
        # 3.14+ может ужесточить требования; `__post_init__` — переносимо.
        self._lock = asyncio.Lock()

    async def connect(self) -> None:
        self._reader, self._writer = await asyncio.open_connection(
            self.host, self.port
        )

    async def disconnect(self) -> None:
        if self._writer is not None:
            try:
                self._writer.close()
                await asyncio.wait_for(
                    self._writer.wait_closed(), timeout=_DISCONNECT_TIMEOUT
                )
            except (OSError, RuntimeError, asyncio.TimeoutError) as e:
                logger.debug("disconnect: ignored error during close: %s", e)
        self._reader = None
        self._writer = None

    async def _send_frame(self, body: bytes) -> None:
        if self._writer is None:
            raise SketchUpError(-32603, "internal: writer is None in _send_frame")
        self._writer.write(struct.pack(">I", len(body)) + body)
        await self._writer.drain()

    async def _recv_frame(self) -> bytes:
        if self._reader is None:
            raise SketchUpError(-32603, "internal: reader is None in _recv_frame")
        header = await self._reader.readexactly(4)
        (length,) = struct.unpack(">I", header)
        if length == 0:
            raise SketchUpError(-32600, "received zero-length frame")
        if length > config.MAX_MESSAGE_SIZE:
            raise SketchUpError(
                -32600,
                f"message too large: {length} bytes (cap {config.MAX_MESSAGE_SIZE})",
            )
        return await self._reader.readexactly(length)

    async def send_command(self, name: str, args: dict[str, Any]) -> Any:
        async with self._lock:
            if self._writer is None or self._writer.is_closing():
                await self._connect_or_raise()
            rid = self._next_id
            self._next_id += 1
            request = {
                "jsonrpc": "2.0",
                "method": "tools/call",
                "params": {"name": name, "arguments": args},
                "id": rid,
            }
            body = json.dumps(request).encode("utf-8")
            if len(body) > config.MAX_MESSAGE_SIZE:
                raise SketchUpError(
                    -32600,
                    f"request too large: {len(body)} bytes (cap {config.MAX_MESSAGE_SIZE})",
                )
            try:
                response_body = await asyncio.wait_for(
                    self._roundtrip(body), timeout=self.timeout
                )
            except asyncio.TimeoutError:
                # NB: cancel of `_roundtrip` happens after potential partial
                # write — `disconnect()` форсирует свежий TCP-сокет.
                await self.disconnect()
                raise SketchUpError(
                    -32000, f"timeout after {self.timeout}s"
                ) from None
            except (ConnectionError, asyncio.IncompleteReadError) as e:
                await self.disconnect()
                raise SketchUpError(-32000, f"connection error: {e}") from e
            except SketchUpError:
                # Транспортные ошибки (-32600 oversize/zero-length от _recv_frame).
                # Stream после них рассинхронизирован — обязательно disconnect.
                await self.disconnect()
                raise
            except asyncio.CancelledError:
                # SIGTERM/Ctrl+C во время roundtrip: writer мог отправить часть
                # запроса. Без disconnect сокет остаётся half-open, и Ruby видит
                # «висящего клиента» при следующем подключении. Disconnect перед
                # пробросом гарантирует чистый стейт.
                await self.disconnect()
                raise
            try:
                response = json.loads(response_body)
            except json.JSONDecodeError as e:
                await self.disconnect()
                raise SketchUpError(-32700, f"parse error: {e}") from e
            if response.get("id") != rid:
                await self.disconnect()
                raise SketchUpError(
                    -32603, f"id mismatch: sent {rid}, got {response.get('id')}"
                )
            if "error" in response:
                err = response["error"]
                raise SketchUpError(
                    err.get("code", -32000),
                    err.get("message", "unknown"),
                    err.get("data"),
                )
            return response.get("result", {})

    async def _connect_or_raise(self) -> None:
        """Wrap `connect()` so any `OSError` (incl. `gaierror`) → `ConnectionError`.

        `_call` ловит только `ConnectionError`/`SketchUpError`. Без обёртки
        `socket.gaierror` (наследник `OSError`) утекал бы наружу при reconnect.
        """
        try:
            await self.connect()
        except OSError as e:
            raise ConnectionError(
                f"cannot reconnect to {self.host}:{self.port}: {e}"
            ) from e

    async def _roundtrip(self, body: bytes) -> bytes:
        await self._send_frame(body)
        return await self._recv_frame()


# Module-level singleton mutated by `get_connection`/`close_connection`.
# Declared at module scope (rather than inside `get_connection`) so tests can
# `monkeypatch.setattr(conn_module, "_connection", ...)` without `raising=False`.
_connection: SketchUpConnection | None = None
# Lock guarding cold-start race: without it, two concurrent first-callers of
# `get_connection` could each create their own `SketchUpConnection` and orphan
# one of the resulting sockets. Created at module import (asyncio.Lock since
# 3.10 does not bind to a loop until first use, so this is loop-safe). Lazy
# init was racy: two parallel cold callers could both observe `None` and
# instantiate distinct Lock objects, defeating the purpose.
_get_connection_lock: asyncio.Lock = asyncio.Lock()


async def get_connection() -> SketchUpConnection:
    """Lazy singleton accessor — connects on first call or after disconnect.

    Защищён `_get_connection_lock` от cold-start race: два параллельных
    `get_connection()` на холодном старте без lock'а могли бы оба создать
    `SketchUpConnection` и вызвать `connect()` на разных объектах, оставив
    один сокет бесхозным.

    Raises ``ConnectionError`` if connect to ``config.HOST:config.PORT`` fails;
    callers (``_call`` in tools) translate this into a graceful tool-response.
    """
    global _connection
    async with _get_connection_lock:
        if _connection is None:
            _connection = SketchUpConnection(
                host=config.HOST, port=config.PORT, timeout=config.TIMEOUT
            )
        if _connection._writer is None or _connection._writer.is_closing():
            try:
                await _connection.connect()
            except OSError as e:
                raise ConnectionError(
                    f"cannot connect to {config.HOST}:{config.PORT}: {e}"
                ) from e
        return _connection


async def close_connection() -> None:
    """Close and forget the module singleton."""
    global _connection
    if _connection is not None:
        await _connection.disconnect()
        _connection = None
