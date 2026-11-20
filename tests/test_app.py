"""Tests for the FastMCP app lifespan (app.py) — review F6."""
import asyncio
import logging

import pytest

from sketchup_mcp import __version__, config
from sketchup_mcp import app as app_module
from sketchup_mcp.errors import IncompatibleVersionError, SketchUpError

pytestmark = pytest.mark.asyncio


async def test_lifespan_degrades_on_incompatible_version(monkeypatch, caplog):
    """Review F6: a version mismatch at startup must NOT crash the server.

    server_lifespan eager-connects; if the handshake reports an incompatible
    version, get_connection raises IncompatibleVersionError (a SketchUpError
    subclass, NOT a ConnectionError). The lifespan must catch it and start
    degraded — so get_version can later surface the mismatch — rather than
    propagating and aborting FastMCP startup.
    """
    async def boom():
        raise IncompatibleVersionError("server 9.9.9 not in 0.2.0..0.2.0")

    closed = {"called": False}

    async def fake_close():
        closed["called"] = True

    # Stub setup_logging so its basicConfig(force=True) doesn't tear down
    # caplog's root handler mid-test.
    monkeypatch.setattr(app_module, "setup_logging", lambda: None)
    monkeypatch.setattr(app_module, "get_connection", boom)
    monkeypatch.setattr(app_module, "close_connection", fake_close)

    with caplog.at_level(logging.WARNING, logger="sketchup_mcp.app"):
        async with app_module.server_lifespan(app_module.mcp) as state:
            assert state == {}

    assert closed["called"], "close_connection must run on shutdown"
    assert any("startup" in r.getMessage().lower() for r in caplog.records), \
        "version mismatch at startup must be logged as a warning, not raised"


async def test_lifespan_still_degrades_on_connection_error(monkeypatch):
    """Sanity: the pre-existing ConnectionError degrade path still holds."""
    async def boom():
        raise ConnectionError("SketchUp not running")

    async def fake_close():
        pass

    monkeypatch.setattr(app_module, "setup_logging", lambda: None)
    monkeypatch.setattr(app_module, "get_connection", boom)
    monkeypatch.setattr(app_module, "close_connection", fake_close)

    async with app_module.server_lifespan(app_module.mcp) as state:
        assert state == {}


async def test_lifespan_degrades_on_sketchup_error(monkeypatch, caplog):
    """Review: a handshake fault at startup (timeout / malformed reply /
    zero-length frame) raises a plain SketchUpError — NOT a ConnectionError and
    NOT IncompatibleVersionError. The lifespan must catch it too and start
    degraded, so the MCP server loads and surfaces the fault per-tool instead of
    failing to start with no diagnostics in Claude Desktop.
    """
    async def boom():
        raise SketchUpError(-32000, "timeout after 60s")

    closed = {"called": False}

    async def fake_close():
        closed["called"] = True

    monkeypatch.setattr(app_module, "setup_logging", lambda: None)
    monkeypatch.setattr(app_module, "get_connection", boom)
    monkeypatch.setattr(app_module, "close_connection", fake_close)

    with caplog.at_level(logging.WARNING, logger="sketchup_mcp.app"):
        async with app_module.server_lifespan(app_module.mcp) as state:
            assert state == {}

    assert closed["called"], "close_connection must run on shutdown"
    assert any("startup" in r.getMessage().lower() for r in caplog.records), \
        "a handshake SketchUpError at startup must be logged as a warning, not raised"


async def test_lifespan_degrades_when_eager_connect_fails(monkeypatch):
    """Eager-connect теперь двухфазный: get_connection() отдаёт singleton,
    ensure_connected() коннектит под инстансным замком. Отказ второй фазы
    так же деградирует, а не роняет старт."""
    class FakeConn:
        async def ensure_connected(self):
            raise ConnectionError("refused")

    async def fake_get():
        return FakeConn()

    async def fake_close():
        pass

    monkeypatch.setattr(app_module, "setup_logging", lambda: None)
    monkeypatch.setattr(app_module, "get_connection", fake_get)
    monkeypatch.setattr(app_module, "close_connection", fake_close)

    async with app_module.server_lifespan(app_module.mcp) as state:
        assert state == {}


# M-12 (spec §6.6): the server's instructions are a condensed strategy.
INSTRUCTIONS = """\
SketchUp modeling over MCP. Lengths are millimeters and angles degrees; every
position, bbox_mm and transform target is in world (model) coordinates, nested
entities included. Prefer the typed tools; use eval_ruby (inches, no undo step
of its own) only when none fits. After each change read the returned bbox_mm.
Boolean, edge and joinery results get new ids and keep their names. Edits
inside a component or group placed more than once are refused; new objects go
into a group open for editing. A refused call says what to change. The
sketchup_modeling_strategy prompt has the full guide."""


async def test_server_instructions_are_the_condensed_strategy():
    assert app_module.mcp.instructions == INSTRUCTIONS


async def test_startup_connect_is_bounded(monkeypatch, caplog):
    """§7.4: the eager connect has 5 s of its own, apart from
    SKETCHUP_MCP_TIMEOUT, so the server starts within Claude Code's 30-second
    window even when SketchUp hangs; the first tool call connects later."""
    class SlowConnection:
        async def ensure_connected(self):
            await asyncio.sleep(10)

    async def slow_connection():
        return SlowConnection()

    async def fake_close():
        pass

    monkeypatch.setattr(app_module, "setup_logging", lambda: None)
    monkeypatch.setattr(app_module, "get_connection", slow_connection)
    monkeypatch.setattr(app_module, "close_connection", fake_close)
    monkeypatch.setattr(app_module, "STARTUP_CONNECT_TIMEOUT", 0.05)
    loop = asyncio.get_running_loop()
    started = loop.time()
    with caplog.at_level(logging.WARNING, logger="sketchup_mcp.app"):
        async with app_module.server_lifespan(app_module.mcp) as state:
            assert state == {}
    assert loop.time() - started < 1.0
    assert app_module.STARTUP_CONNECT_TIMEOUT == 0.05
    assert any("did not answer" in r.getMessage() and "startup" in r.getMessage()
               for r in caplog.records), [r.getMessage() for r in caplog.records]


async def test_startup_bound_is_five_seconds():
    assert app_module.STARTUP_CONNECT_TIMEOUT == 5.0


async def test_startup_logs_version_host_and_port(monkeypatch, caplog):
    """M-21: one line at start says which version runs and where it looks."""
    async def refused():
        raise ConnectionError("refused")

    async def fake_close():
        pass

    monkeypatch.setattr(app_module, "setup_logging", lambda: None)
    monkeypatch.setattr(app_module, "get_connection", refused)
    monkeypatch.setattr(app_module, "close_connection", fake_close)
    with caplog.at_level(logging.INFO, logger="sketchup_mcp.app"):
        async with app_module.server_lifespan(app_module.mcp):
            pass
    lines = [r.getMessage() for r in caplog.records if r.levelno == logging.INFO]
    assert any(__version__ in line and f"{config.HOST}:{config.PORT}" in line for line in lines), lines
