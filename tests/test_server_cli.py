"""M-21: ``sketchup-mcp2 --version`` prints the version and exits; with no
arguments the command runs the MCP server, as before."""
import sys

import pytest

from sketchup_mcp import __version__, server


def test_version_flag_prints_the_version(monkeypatch, capsys):
    monkeypatch.setattr(sys, "argv", ["sketchup-mcp2", "--version"])
    monkeypatch.setattr(server.mcp, "run", lambda *a, **k: pytest.fail("the server must not start"))
    with pytest.raises(SystemExit) as ei:
        server.main()
    assert ei.value.code == 0
    assert capsys.readouterr().out == f"sketchup-mcp2 {__version__}\n"


def test_no_arguments_run_the_server(monkeypatch):
    monkeypatch.setattr(sys, "argv", ["sketchup-mcp2"])
    ran = []
    monkeypatch.setattr(server.mcp, "run", lambda *a, **k: ran.append(True))
    server.main()
    assert ran == [True]
