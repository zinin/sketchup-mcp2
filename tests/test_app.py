"""Tests for the FastMCP app lifespan (app.py) — review F6."""
import logging

import pytest

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
