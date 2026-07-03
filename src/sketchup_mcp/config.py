"""Environment-driven configuration for sketchup-mcp.

All values are read at module import. Tests reload the module via
``importlib.reload`` to pick up monkey-patched environment variables.
Invalid values raise ``ValueError`` naming the offending variable at
import time — fail-fast beats a silent fallback hiding a typo'd deploy
(T-12). Unknown LOG_LEVEL degrades to INFO with a warning instead of
silently masquerading as INFO.
"""
import logging
import math
import os

logger = logging.getLogger("sketchup_mcp.config")

_VALID_LOG_LEVELS = frozenset({"DEBUG", "INFO", "WARN", "WARNING", "ERROR", "CRITICAL"})


def _env_port(name: str, default: str) -> int:
    raw = os.getenv(name, default)
    try:
        port = int(raw)
    except ValueError:
        raise ValueError(f"{name} must be an integer, got {raw!r}") from None
    if not 1 <= port <= 65535:
        raise ValueError(f"{name} must be in 1..65535, got {port}")
    return port


def _env_timeout(name: str, default: str) -> float:
    raw = os.getenv(name, default)
    try:
        timeout = float(raw)
    except ValueError:
        raise ValueError(f"{name} must be a number (seconds), got {raw!r}") from None
    if not math.isfinite(timeout) or timeout <= 0:
        raise ValueError(f"{name} must be a finite number > 0 seconds, got {raw!r}")
    return timeout


def _env_log_level(name: str, default: str) -> str:
    raw = os.getenv(name, default).upper()
    if raw not in _VALID_LOG_LEVELS:
        logger.warning(
            "%s: unknown log level %r, falling back to INFO "
            "(valid: DEBUG, INFO, WARN, ERROR)",
            name,
            raw,
        )
        return "INFO"
    return raw


PORT: int = _env_port("SKETCHUP_MCP_PORT", "9876")
HOST: str = os.getenv("SKETCHUP_MCP_HOST", "127.0.0.1")
TIMEOUT: float = _env_timeout("SKETCHUP_MCP_TIMEOUT", "60")
LOG_LEVEL: str = _env_log_level("SKETCHUP_MCP_LOG_LEVEL", "INFO")

MAX_MESSAGE_SIZE: int = 64 * 1024 * 1024  # 64 MiB; запас для PNG/DAE/SKP-экспортов


def setup_logging() -> None:
    """Initialise root logger from ``LOG_LEVEL`` (force overrides existing handlers)."""
    logging.basicConfig(
        level=getattr(logging, LOG_LEVEL, logging.INFO),
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
        force=True,
    )
