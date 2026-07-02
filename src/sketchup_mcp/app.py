"""FastMCP application instance and lifecycle for SketchUp MCP.

``mcp`` and ``server_lifespan`` live here (not in ``server.py``) so that
``tools.py`` can do ``from sketchup_mcp.app import mcp`` without dragging in the
entry-point and creating a circular import.
"""
import logging
from contextlib import asynccontextmanager
from typing import AsyncIterator

from mcp.server.fastmcp import FastMCP

from sketchup_mcp.config import setup_logging
from sketchup_mcp.connection import close_connection, get_connection
from sketchup_mcp.errors import SketchUpError

logger = logging.getLogger("sketchup_mcp.app")


@asynccontextmanager
async def server_lifespan(server: FastMCP) -> AsyncIterator[dict]:
    """Configure logging, eager-connect once, clean up on shutdown.

    `ConnectionError` (включая ConnectionRefusedError, gaierror, BrokenPipeError —
    `_connect_or_raise` приводит весь OSError-семейный сетевой failure к этому
    типу) — ожидаемая ситуация: SketchUp ещё не запущен, lazy reconnect
    отработает на первом tool-call. Логируем warning, продолжаем.
    `SketchUpError` (its subclass `IncompatibleVersionError` for a Python↔Ruby
    handshake mismatch — review F6 — plus raw handshake faults from
    conn.ensure_connected(): timeout, malformed reply, zero-length frame) is also
    caught: all mean "SketchUp side not ready", so we start degraded and let
    `get_version` and every tool surface the problem as a graceful error,
    instead of the server failing to load with no diagnostics in Claude Desktop.
    Любое другое исключение — конфиг или баг кода — пробрасываем, сервер
    падает на старте с точной ошибкой вместо молчаливого деградирования.
    """
    setup_logging()
    try:
        conn = await get_connection()
        await conn.ensure_connected()
    except (ConnectionError, SketchUpError) as e:
        logger.warning(f"Could not connect on startup: {e}")
    try:
        yield {}
    finally:
        await close_connection()


mcp = FastMCP(
    "MCP Server for SketchUp",
    instructions="Sketchup integration through the Model Context Protocol",
    lifespan=server_lifespan,
)

# Side-effect import: registers tool handlers on `mcp`. Must come AFTER `mcp`
# is constructed (tools.py does `from sketchup_mcp.app import mcp`). Required
# here so MCP hosts loading the published `[project.entry-points.mcp]` get a
# FastMCP with tools registered, not an empty instance.
import sketchup_mcp.tools  # noqa: E402, F401
import sketchup_mcp.prompts  # noqa: E402, F401
