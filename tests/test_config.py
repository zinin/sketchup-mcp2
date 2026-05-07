"""Tests for ENV-driven configuration in sketchup_mcp.config."""
import importlib

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
