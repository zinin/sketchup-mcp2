"""FastMCP application instance and lifecycle for SketchUp MCP.

``mcp`` and ``server_lifespan`` live here (not in ``server.py``) so that
``tools.py`` can do ``from sketchup_mcp.app import mcp`` without dragging in the
entry-point and creating a circular import.
"""
import asyncio
import logging
from contextlib import asynccontextmanager
from typing import AsyncIterator

from mcp.server.fastmcp import FastMCP

from sketchup_mcp import __version__, config
from sketchup_mcp.config import setup_logging
from sketchup_mcp.connection import close_connection, get_connection
from sketchup_mcp.errors import SketchUpError

logger = logging.getLogger("sketchup_mcp.app")

# §7.4: the eager connect at startup has a bound of its own, apart from
# SKETCHUP_MCP_TIMEOUT, so a SketchUp that accepts and then stalls cannot hold
# the server past Claude Code's 30-second start window. The first tool call
# connects lazily with the full timeout.
STARTUP_CONNECT_TIMEOUT = 5.0


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

    The eager connect is bounded by STARTUP_CONNECT_TIMEOUT; past it the server
    starts degraded the same way. A missing or malformed token is an
    AuthenticationError, a SketchUpError: no socket opens, and every tool
    answers with the instruction.
    """
    setup_logging()
    # M-21: one line says which version runs and where it looks for SketchUp.
    logger.info("sketchup-mcp2 %s starting; SketchUp plugin expected at %s:%s",
                __version__, config.HOST, config.PORT)
    try:
        conn = await get_connection()
        await asyncio.wait_for(conn.ensure_connected(), STARTUP_CONNECT_TIMEOUT)
    except asyncio.TimeoutError:
        logger.warning("SketchUp did not answer within %ss at startup; "
                       "the first tool call will connect", STARTUP_CONNECT_TIMEOUT)
    except (ConnectionError, SketchUpError) as e:
        logger.warning(f"Could not connect on startup: {e}")
    try:
        yield {}
    finally:
        await close_connection()


# M-12 (spec §6.6): what a client shows the model before any tool call — a
# condensed sketchup_modeling_strategy.
INSTRUCTIONS = """\
SketchUp modeling over MCP. Lengths are millimeters and angles degrees; every
position, bbox_mm and transform target is in world (model) coordinates, nested
entities included. Prefer the typed tools; use eval_ruby (inches, no undo step
of its own) only when none fits. After each change read the returned bbox_mm.
Boolean, edge and joinery results get new ids and keep their names. Edits
inside a component or group placed more than once are refused; new objects go
into a group open for editing. A refused call says what to change. The
sketchup_modeling_strategy prompt has the full guide."""

mcp = FastMCP(
    "MCP Server for SketchUp",
    instructions=INSTRUCTIONS,
    lifespan=server_lifespan,
)
# serverInfo.version (M-12): FastMCP 1.30 takes no version argument, and
# without this the client would see the mcp package's version, not ours.
mcp._mcp_server.version = __version__

# Side-effect imports: register tool/prompt handlers on `mcp`. Must come AFTER
# `mcp` is constructed (both modules do `from sketchup_mcp.app import mcp`).
# Without these imports a consumer of `sketchup_mcp.app.mcp` (the
# `sketchup-mcp2` CLI, `python -m sketchup_mcp`) would serve an EMPTY tool
# list — registration happens at import time.
import sketchup_mcp.tools  # noqa: E402, F401
import sketchup_mcp.prompts  # noqa: E402, F401
