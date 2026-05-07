"""SketchUp MCP error type and human-readable formatter."""
import json
from typing import Any


_PARAMS_TRUNCATE_AT = 512  # bytes of JSON; больше — обрезаем


class SketchUpError(Exception):
    """Wraps a JSON-RPC error returned by the Ruby side or raised locally."""

    def __init__(self, code: int, message: str, data: dict[str, Any] | None = None):
        self.code = code
        self.message = message
        self.data = data or {}
        super().__init__(message)


def _short_json(value: object) -> str:
    """Serialise ``value`` and truncate to ``_PARAMS_TRUNCATE_AT`` bytes.

    Truncation is byte-based (UTF-8) so non-ASCII payloads honour the cap;
    the boundary is decoded with ``errors='ignore'`` to drop a partial
    multi-byte character if the cut lands mid-codepoint.
    """
    text = json.dumps(value, ensure_ascii=False)
    encoded = text.encode("utf-8")
    if len(encoded) > _PARAMS_TRUNCATE_AT:
        return encoded[:_PARAMS_TRUNCATE_AT].decode("utf-8", errors="ignore") + "...<truncated>"
    return text


def format_error(err: SketchUpError, *, debug: bool = False) -> str:
    """Format ``err`` as one human-readable line for tool-response."""
    tool = err.data.get("tool", "?")
    params = err.data.get("params", {})
    line = (
        f"[{err.code}] {err.message} — "
        f"tool={tool}, params={_short_json(params)}"
    )
    if debug:
        ts = err.data.get("timestamp")
        bt = err.data.get("backtrace") or []
        if ts:
            line += f", ts={ts}"
        if bt:
            line += f", bt={bt[:3]}"
    return line
