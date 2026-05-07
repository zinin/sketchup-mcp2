"""Environment-driven configuration for sketchup-mcp.

All values are read at module import. Tests reload the module via
``importlib.reload`` to pick up monkey-patched environment variables.
"""
import logging
import os

PORT: int = int(os.getenv("SKETCHUP_MCP_PORT", "9876"))
HOST: str = os.getenv("SKETCHUP_MCP_HOST", "127.0.0.1")
TIMEOUT: float = float(os.getenv("SKETCHUP_MCP_TIMEOUT", "60"))
LOG_LEVEL: str = os.getenv("SKETCHUP_MCP_LOG_LEVEL", "INFO").upper()

MAX_MESSAGE_SIZE: int = 64 * 1024 * 1024  # 64 MiB; запас для PNG/DAE/SKP-экспортов


def setup_logging() -> None:
    """Initialise root logger from ``LOG_LEVEL`` (force overrides existing handlers)."""
    logging.basicConfig(
        level=getattr(logging, LOG_LEVEL, logging.INFO),
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
        force=True,
    )
