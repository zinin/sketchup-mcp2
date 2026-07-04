"""Asynchronous JSON-RPC client to the SketchUp Ruby extension.

This module owns the wire protocol: 4-byte big-endian length prefix + JSON body,
``asyncio.Lock`` serialisation, lazy reconnect, total per-request timeout.

Public entry points are :func:`get_connection`/:func:`close_connection` for
singleton management, :meth:`SketchUpConnection.ensure_connected` /
:meth:`SketchUpConnection.aclose` for explicit connect/close (all socket
mutation is serialized under the instance lock), and
:meth:`SketchUpConnection.send_command` for actual JSON-RPC traffic.
"""
import asyncio
import json
import logging
import struct
from dataclasses import dataclass, field
from typing import Any

from sketchup_mcp import compat, config
from sketchup_mcp.errors import IncompatibleVersionError, SketchUpError

logger = logging.getLogger("sketchup_mcp.connection")

_DISCONNECT_TIMEOUT = 5.0  # секунд на graceful close сокета


class _StaleSocketError(SketchUpError):
    """Маркер «транспорт умер посреди roundtrip'а» (EOF/RST до полного ответа).

    Сам по себе индикатор НЕДОСТАТОЧЕН для безопасного retry: Ruby-сторонний
    `write_response` может закрыть сокет **уже после** `model.commit_operation`
    (IO.select-таймаут 1 сек → reset_client). Даже partial == b"" не
    гарантирует, что мутация не применена (см. Codex review на PR #1).

    Поэтому retry ограничен whitelist'ом side-effect-free tools
    (`_RETRY_SAFE_TOOLS`) — их безопасно переспрашивать независимо от того,
    успел ли peer обработать запрос. Для мутативных — поднимаем наверх как
    транспортную ошибку с recovery-подсказкой (см. send_command).

    Цена MR-1: обрыв посреди большого ответа (например ~43 MiB скриншота)
    означает второй полный захват и передачу — безопасно, но дорого;
    осознанная цена за автовосстановление read-only вызовов.
    """


# Tools без побочных эффектов на модель — безопасно retry'ить при stale-socket.
# Список синхронизирован с handlers/* на Ruby: всё, что не пишет в модель и не
# выполняет произвольный Ruby. Любая правка списка требует ревью соответствующего
# Ruby-handler'а на side effects.
_RETRY_SAFE_TOOLS: frozenset[str] = frozenset(
    {
        "get_model_info",
        "list_components",
        "get_component_info",
        "find_components",
        "list_layers",
        "get_selection",
        "get_viewport_screenshot",  # read-only viewport capture; idempotent in
                                    # both restore_view modes (no document state changes)
        "get_version",              # read-only diagnostic; no side effects
    }
)


@dataclass
class SketchUpConnection:
    host: str
    port: int
    timeout: float
    _reader: asyncio.StreamReader | None = None
    _writer: asyncio.StreamWriter | None = None
    _lock: asyncio.Lock | None = field(default=None, init=False, repr=False)
    _next_id: int = 1
    _server_version: str | None = field(default=None, init=False, repr=False)
    _client_id: int | None = field(default=None, init=False, repr=False)

    def __post_init__(self) -> None:
        # Lock создаётся при инстанциации (всегда внутри running event loop —
        # `get_connection()` зовётся из lifespan/test'ов, оба под `asyncio.run`).
        # Через `default_factory=asyncio.Lock` это работало бы тоже, но Python
        # 3.14+ может ужесточить требования; `__post_init__` — переносимо.
        self._lock = asyncio.Lock()

    async def connect(self) -> None:
        """Open TCP socket and perform the one-time `hello` handshake.

        On success ``_server_version`` and ``_client_id`` are populated.
        On failure the socket is closed and the original exception is
        re-raised (``IncompatibleVersionError`` if Ruby replied -32001,
        ``SketchUpError`` for any other malformed/erroring envelope or
        for timeout).

        CRITICAL: the handshake roundtrip is wrapped in
        ``asyncio.wait_for(..., timeout=self.timeout)`` — without it, a
        Ruby that accepted TCP but never replied would block this
        coroutine forever.

        Low-level/internal: мутирует ``_reader``/``_writer`` БЕЗ замка. Вызывать
        только из-под ``self._lock`` (ensure_connected / aclose / _send_once) или
        в заведомо однозадачном контексте (examples/smoke_check.py). Внешний
        API — ``ensure_connected()`` / ``aclose()``.
        """
        # CRITICAL: the TCP connect itself is wrapped in wait_for too, not just
        # the handshake below. A host that accepts the SYN but never finishes
        # the connect (firewall DROP, half-dead peer) would otherwise block this
        # coroutine until the OS connect timeout (~minutes), hanging MCP startup
        # and defeating app.py's degraded-start design (codex review).
        try:
            self._reader, self._writer = await asyncio.wait_for(
                asyncio.open_connection(self.host, self.port),
                timeout=self.timeout,
            )
        except asyncio.TimeoutError:
            raise SketchUpError(
                -32000, f"connect timed out after {self.timeout}s"
            ) from None
        try:
            await asyncio.wait_for(self._handshake(), timeout=self.timeout)
        except asyncio.TimeoutError:
            await self.disconnect()
            raise SketchUpError(
                -32000, f"handshake timed out after {self.timeout}s"
            ) from None
        except BaseException:
            # Any failure (IncompatibleVersionError, SketchUpError,
            # ConnectionError, CancelledError, ...) must leave the
            # socket cleanly closed so callers don't observe a
            # half-open connection.
            await self.disconnect()
            raise

    async def _handshake(self) -> None:
        """Send `hello` + parse the server's first response.

        Every malformed-envelope path (non-dict response, missing
        result/error dict, JSON decode failure, parse failure) is
        funneled into ``SketchUpError`` so callers catch a single class.
        ``IncompatibleVersionError`` is raised only for Ruby's
        ``-32001`` verdict.
        """
        request = {
            "jsonrpc": "2.0",
            "method": "hello",
            "params": {"client_version": compat.CLIENT_VERSION},
            "id": 0,
        }
        body = json.dumps(request).encode("utf-8")
        if self._writer is None:
            raise SketchUpError(-32603, "internal: writer is None in _handshake")
        self._writer.write(struct.pack(">I", len(body)) + body)
        await self._writer.drain()
        try:
            response_body = await self._recv_frame()
        except asyncio.IncompleteReadError as e:
            # Peer accepted TCP but closed before sending the hello reply
            # (network blip, Ruby crash, sigkill between accept and write).
            # Surface as SketchUpError so callers don't see raw asyncio exns.
            raise SketchUpError(
                -32000, f"peer closed before handshake reply: {e}"
            ) from e
        except ConnectionError as e:
            # ECONNRESET / EPIPE on the recv path mid-handshake. Same as above.
            raise SketchUpError(
                -32000, f"connection error during handshake: {e}"
            ) from e
        try:
            response = json.loads(response_body)
        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            # UnicodeDecodeError: json.loads(bytes) декодирует UTF-8 сам;
            # не-UTF8 тело кидало голый UnicodeDecodeError мимо таксономии
            # (валил lifespan вместо degraded-старта). T-11/PY-CONN-02.
            raise SketchUpError(-32700, f"handshake parse error: {e}") from e
        if not isinstance(response, dict):
            raise SketchUpError(
                -32603,
                f"malformed handshake response: {type(response).__name__}",
            )
        if "error" in response:
            err = response["error"] if isinstance(response.get("error"), dict) else {}
            code = err.get("code", -32000)
            if code == -32001:
                raise IncompatibleVersionError(err.get("message", "version mismatch"))
            raise SketchUpError(
                code, err.get("message", "handshake failed"), err.get("data")
            )
        result = response.get("result") or {}
        if not isinstance(result, dict):
            raise SketchUpError(
                -32603,
                f"malformed handshake result: {type(result).__name__}",
            )
        server_version = result.get("server_version")
        if server_version is None:
            # New-protocol server replied success but omitted server_version.
            # Distinct from the "old plugin pre-dates handshake" case that
            # check_ruby_version handles — surface a clear protocol-violation
            # error instead of misleading "plugin pre-dates" wording.
            raise SketchUpError(
                -32603, "handshake reply missing server_version"
            )
        self._server_version = server_version
        self._client_id = result.get("client_id")
        # Belt-and-suspenders: Ruby validated, we validate too. Cheap.
        # Drift between Python and Ruby compat tables could let one side
        # accept a peer the other side would reject; this catches it.
        compat.check_ruby_version(server_version)

    async def disconnect(self) -> None:
        """Close the socket and null the ``_reader``/``_writer`` pair.

        Low-level/internal: мутирует ``_reader``/``_writer`` БЕЗ замка. Вызывать
        только из-под ``self._lock`` (ensure_connected / aclose / _send_once) или
        в заведомо однозадачном контексте (examples/smoke_check.py). Внешний
        API — ``ensure_connected()`` / ``aclose()``.
        """
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

    async def ensure_connected(self) -> None:
        """Открыть сокет (и выполнить handshake), если он ещё не открыт.

        Берёт тот же ``self._lock``, что и ``send_command`` — ЕДИНСТВЕННЫЙ
        замок, под которым мутируются ``_reader``/``_writer`` (T-08:
        connect из get_connection под модульным замком гонялся с
        ``disconnect()`` внутри in-flight ``send_command`` — терял свежую
        пару сокетов или утекал соединением).

        Raises ``ConnectionError`` при сетевом отказе (как раньше поднимал
        ``get_connection``) — lifespan ловит и стартует degraded.
        """
        async with self._lock:
            # Health-check намеренно продублирован с _send_once, а не вынесен
            # в общий «проверь-и-коннекть» хелпер, берущий замок: asyncio.Lock
            # нереентерабелен — вызов такого хелпера из-под уже взятого
            # self._lock (как в _send_once) был бы дедлоком.
            if self._writer is None or self._writer.is_closing():
                await self._connect_or_raise()

    async def aclose(self) -> None:
        """Закрыть сокет под ``self._lock`` — дождавшись in-flight запроса."""
        async with self._lock:
            await self.disconnect()

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
            try:
                return await self._send_once(name, args)
            except _StaleSocketError as e:
                # `disconnect()` уже сделан внутри `_send_once`.
                # Retry ТОЛЬКО для side-effect-free tools: Ruby `write_response`
                # может закрыть сокет уже после `commit_operation`, и тогда
                # partial=b"" не гарантирует, что мутации не было.
                if name in _RETRY_SAFE_TOOLS:
                    return await self._send_once(name, args)
                # Мутативный / eval tool — НЕ ретраим (слепой retry мог бы
                # задвоить уже закоммиченную мутацию). Но обогащаем ошибку именем
                # инструмента + actionable recovery-hint'ом, чтобы агент не
                # сдавался на голом "connection error … tool=?" и при этом не
                # ретраил вслепую. Формулировка намеренно ADVISORY (spec Important-1):
                # для произвольного eval_ruby агент часто не может доказать «применилось».
                raise SketchUpError(
                    e.code,
                    f"{e.message} — the persistent socket was stale (the SketchUp "
                    f"server likely restarted) and has been reset. '{name}' was NOT "
                    f"auto-retried because it can modify the model and the request "
                    f"may have committed before the socket closed; a blind retry "
                    f"could double-apply it. Recovery: call a read-only tool (e.g. "
                    f"get_model_info / list_components) to reconnect and inspect the "
                    f"model, then retry '{name}' only if you can confirm it did NOT "
                    f"apply — if you cannot confirm, do NOT retry.",
                    {"tool": name, **(e.data or {})},
                ) from e

    async def _send_once(self, name: str, args: dict[str, Any]) -> Any:
        # Health-check продублирован с ensure_connected (не общий хелпер):
        # asyncio.Lock нереентерабелен, а обе точки уже выполняются под
        # self._lock — общий «проверь-и-коннекть» под замком дедлочился бы.
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
            # write — `disconnect()` форсирует свежий TCP-сокет. НЕ retry:
            # peer мог успеть commit мутацию, второй вызов задвоил бы её.
            await self.disconnect()
            raise SketchUpError(
                -32000, f"timeout after {self.timeout}s"
            ) from None
        except asyncio.IncompleteReadError as e:
            # EOF до полного ответа — заголовок не пришёл вовсе (partial == b"")
            # или оборван посреди фрейма. Различие partial-пустоты больше НЕ
            # влияет на решение: безопасность retry целиком решает whitelist
            # в send_command (read-only тулы безопасно переспросить, даже если
            # Ruby успел выполнить хендлер; мутативные не ретраятся никогда).
            # MR-1 из финального ревью батча 1.
            await self.disconnect()
            raise _StaleSocketError(-32000, f"connection error: {e}") from e
        except ConnectionError as e:
            # ECONNRESET / BrokenPipe = разрыв транспорта на любой фазе
            # (_send_frame, drain, _recv_frame). Помечаем как _StaleSocketError;
            # фактическая безопасность retry решается в send_command по
            # whitelist _RETRY_SAFE_TOOLS — для мутативных tool'ов
            # _StaleSocketError будет проброшен наверх caller'у.
            await self.disconnect()
            raise _StaleSocketError(-32000, f"connection error: {e}") from e
        except OSError as e:
            # Голый OSError вне ConnectionError-подсемейства: EHOSTUNREACH /
            # ENETUNREACH (split-host из README), ETIMEDOUT на py3.10. Порядок
            # важен: ConnectionError ⊂ OSError, поэтому эта ветка стоит ПОСЛЕ.
            # НЕ _StaleSocketError: это не «peer закрыл сокет», гарантий о
            # необработанности запроса нет — retry не предлагаем. T-11.
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
        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            # См. _handshake: не-UTF8 тело = тот же parse-класс ошибок. T-11.
            await self.disconnect()
            raise SketchUpError(-32700, f"parse error: {e}") from e
        # Reject malformed non-dict top-level JSON before any .get() call.
        # `assert` is unsuitable: stripped by `python -O`, leaving the
        # subsequent .get() to raise AttributeError under optimized runs.
        if not isinstance(response, dict):
            await self.disconnect()
            raise SketchUpError(
                -32603,
                f"malformed JSON-RPC response (not a dict): {type(response).__name__}",
            )
        if response.get("id") != rid:
            await self.disconnect()
            raise SketchUpError(
                -32603, f"id mismatch: sent {rid}, got {response.get('id')}"
            )
        # Version compatibility is validated once at handshake time
        # (see ``_handshake``); per-response checks were removed when the
        # protocol moved to a single hello roundtrip on connect.
        if "error" in response:
            err = response["error"]
            # Mirror the top-level non-dict guard above: a malformed peer can
            # put a string/list under "error", and err.get() would surface as
            # AttributeError instead of SketchUpError.
            if not isinstance(err, dict):
                await self.disconnect()
                raise SketchUpError(
                    -32603,
                    f"malformed JSON-RPC error envelope (not a dict): {type(err).__name__}",
                )
            # Promote Ruby-detected version mismatches from generic SketchUpError
            # to IncompatibleVersionError so callers can catch a single class
            # regardless of which side detected the mismatch.
            if err.get("code") == -32001:
                raise IncompatibleVersionError(err.get("message", "version mismatch"))
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
                f"cannot connect to {self.host}:{self.port}: {e}"
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
    """Singleton accessor — только создаёт/возвращает объект, НЕ коннектит.

    Коннект выполняется исключительно под инстансным ``conn._lock``: лениво
    в ``_send_once`` или явно через ``ensure_connected()`` (eager-connect в
    lifespan). Раньше здесь жил health-check + connect под модульным
    ``_get_connection_lock`` — он гонялся с ``disconnect()`` параллельного
    ``send_command`` (T-08/PY-CONN-01): ложные «internal: reader is None»
    и утечка сокетов при рестарте SketchUp.
    """
    global _connection
    async with _get_connection_lock:
        if _connection is None:
            _connection = SketchUpConnection(
                host=config.HOST, port=config.PORT, timeout=config.TIMEOUT
            )
        return _connection


async def close_connection() -> None:
    """Close and forget the module singleton (ждёт in-flight запрос под conn._lock).

    Тело — под ``_get_connection_lock``: без него параллельный
    ``get_connection()`` может получить полузакрытый объект, а после
    обнуления ``_connection`` создать ВТОРОЙ «singleton» с собственным
    сокетом (регрессия инварианта одного соединения).
    """
    global _connection
    async with _get_connection_lock:
        if _connection is not None:
            await _connection.aclose()
            _connection = None
