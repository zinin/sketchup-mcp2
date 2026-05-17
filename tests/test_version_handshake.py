"""Tests for the one-time `hello` handshake performed during
``SketchUpConnection.connect()``. Per-request `client_version` and per-response
`server_version` checks were dropped when the protocol moved to a single
roundtrip at connection time; the tests below cover what's left:

- Post-handshake tool calls do NOT carry `client_version` (covered in
  ``tests/test_connection.py::test_send_once_does_not_include_client_version``).
- Server replies do NOT need to include `server_version`
  (``tests/test_connection.py::test_send_once_does_not_require_server_version_in_response``).
- Handshake-time success populates the connection state
  (``tests/test_connection.py::test_handshake_happy_path_populates_*``).
- Ruby-side -32001 in the handshake response surfaces as
  ``IncompatibleVersionError`` (also exercised at handshake time via
  ``test_handshake_version_mismatch_raises_incompatible_version_error``).

What remains here is the regression guard for `_RETRY_SAFE_TOOLS` membership
of `get_version`, since that is independent of the handshake protocol.
"""
from __future__ import annotations


def test_get_version_in_retry_safe_tools():
    """Regression guard: ``get_version`` must remain retry-safe so that
    stale-socket auto-retry covers cold-start diagnostic probes."""
    from sketchup_mcp.connection import _RETRY_SAFE_TOOLS
    assert "get_version" in _RETRY_SAFE_TOOLS
