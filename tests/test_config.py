"""Tests for ENV-driven configuration in sketchup_mcp.config."""
import importlib
import logging

import pytest

import sketchup_mcp.config as config_module


def reload_config():
    """Reload config module so changes to environment take effect."""
    importlib.reload(config_module)
    return config_module


@pytest.fixture
def env_clean(monkeypatch):
    """Clear all SKETCHUP_MCP_* env vars before each test."""
    for key in [
        "SKETCHUP_MCP_PORT",
        "SKETCHUP_MCP_HOST",
        "SKETCHUP_MCP_TIMEOUT",
        "SKETCHUP_MCP_LOG_LEVEL",
    ]:
        monkeypatch.delenv(key, raising=False)


def test_defaults(env_clean):
    cfg = reload_config()
    assert cfg.PORT == 9876
    assert cfg.HOST == "127.0.0.1"
    assert cfg.TIMEOUT == 60.0
    assert cfg.LOG_LEVEL == "INFO"


def test_port_override(env_clean, monkeypatch):
    monkeypatch.setenv("SKETCHUP_MCP_PORT", "8080")
    assert reload_config().PORT == 8080


def test_log_level_normalized_to_upper(env_clean, monkeypatch):
    monkeypatch.setenv("SKETCHUP_MCP_LOG_LEVEL", "debug")
    assert reload_config().LOG_LEVEL == "DEBUG"


def test_timeout_parsed_as_float(env_clean, monkeypatch):
    monkeypatch.setenv("SKETCHUP_MCP_TIMEOUT", "10.5")
    assert reload_config().TIMEOUT == 10.5


def test_host_override(env_clean, monkeypatch):
    monkeypatch.setenv("SKETCHUP_MCP_HOST", "0.0.0.0")
    assert reload_config().HOST == "0.0.0.0"


# --- T-12: валидация ENV при импорте ---

def test_invalid_port_raises_with_variable_name(env_clean, monkeypatch):
    monkeypatch.setenv("SKETCHUP_MCP_PORT", "abc")
    with pytest.raises(ValueError, match="SKETCHUP_MCP_PORT"):
        reload_config()


@pytest.mark.parametrize("bad", ["0", "65536", "-5"])
def test_out_of_range_port_raises(env_clean, monkeypatch, bad):
    monkeypatch.setenv("SKETCHUP_MCP_PORT", bad)
    with pytest.raises(ValueError, match="1..65535"):
        reload_config()


@pytest.mark.parametrize("bad", ["abc", "0", "-1", "inf", "nan"])
def test_invalid_timeout_raises_with_variable_name(env_clean, monkeypatch, bad):
    monkeypatch.setenv("SKETCHUP_MCP_TIMEOUT", bad)
    with pytest.raises(ValueError, match="SKETCHUP_MCP_TIMEOUT"):
        reload_config()


def test_unknown_log_level_warns_and_falls_back_to_info(env_clean, monkeypatch, caplog):
    monkeypatch.setenv("SKETCHUP_MCP_LOG_LEVEL", "VERBOSE")
    with caplog.at_level(logging.WARNING):
        cfg = reload_config()
    assert cfg.LOG_LEVEL == "INFO"
    assert any("SKETCHUP_MCP_LOG_LEVEL" in r.getMessage() for r in caplog.records)


def test_warn_level_accepted(env_clean, monkeypatch):
    """Регрессия: задокументированный алиас WARN не должен попасть под warning."""
    monkeypatch.setenv("SKETCHUP_MCP_LOG_LEVEL", "warn")
    assert reload_config().LOG_LEVEL == "WARN"
