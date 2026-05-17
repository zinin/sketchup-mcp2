"""Python↔Ruby version compatibility — single source of truth (Python side).

Mirrored in su_mcp/su_mcp/core/compat.rb. Both files are updated together
by docs/release.md step 1 at release time.
"""
from __future__ import annotations

import re

from sketchup_mcp import __version__ as CLIENT_VERSION
from sketchup_mcp.errors import IncompatibleVersionError

# Bumped together with CLIENT_VERSION at release time. See docs/release.md.
# Policy: MAX_* tracks the new release; MIN_* moves only on a release
# that breaks wire/handler contract with the previous counterpart.
# Initial dev state: MIN == MAX (exact match) — bumped together at 0.1.0.
MIN_RUBY = "0.1.0"
MAX_RUBY = "0.1.0"

_PART_RE = re.compile(r"\A[0-9]+\Z")


def parse(v: str) -> tuple[int, int, int]:
    """Parse 'X.Y.Z' → (X, Y, Z). Raise ValueError on anything else.

    Strict: each component must match `\\A[0-9]+\\Z` (ASCII only — no
    whitespace, sign, underscores, or Unicode digits like "١٢٣"). int()
    alone would accept "+1", " 1", "١٢٣", etc.; the regex `\\d+` in
    Python also accepts Unicode digits, hence the explicit `[0-9]+` to
    stay consistent with Ruby's ASCII-by-default `\\d`.
    """
    if not isinstance(v, str):
        raise ValueError(f"version must be a string, got {type(v).__name__}")
    parts = v.split(".")
    if len(parts) != 3 or not all(_PART_RE.match(p) for p in parts):
        raise ValueError(f"version must be 'X.Y.Z' (numeric), got {v!r}")
    return (int(parts[0]), int(parts[1]), int(parts[2]))


def check_ruby_version(server_version: str | None) -> None:
    """Raise IncompatibleVersionError if the SketchUp plugin version is
    outside [MIN_RUBY, MAX_RUBY] or absent (handshake reply missing
    ``server_version``)."""
    if server_version is None:
        raise IncompatibleVersionError(_msg_ruby_missing())
    try:
        rv = parse(server_version)
    except ValueError:
        raise IncompatibleVersionError(
            f"unparseable server_version {server_version!r}; "
            f"expected X.Y.Z (numeric). "
            f"Call `get_version` to inspect handshake state."
        )
    if rv < parse(MIN_RUBY):
        raise IncompatibleVersionError(_msg_ruby_too_old(server_version))
    if rv > parse(MAX_RUBY):
        raise IncompatibleVersionError(_msg_ruby_too_new(server_version))


def _msg_ruby_too_old(rv: str) -> str:
    return (
        f"SketchUp plugin v{rv} is too old for sketchup-mcp2 v{CLIENT_VERSION} "
        f"(requires v{MIN_RUBY}..v{MAX_RUBY}). "
        f"Reinstall su_mcp_v{MAX_RUBY}.rbz from the GitHub release. "
        f"Call `get_version` to inspect handshake state."
    )


def _msg_ruby_too_new(rv: str) -> str:
    return (
        f"SketchUp plugin v{rv} is newer than sketchup-mcp2 v{CLIENT_VERSION} "
        f"supports (max v{MAX_RUBY}). "
        f"Run: uv pip install --upgrade sketchup-mcp2. "
        f"Call `get_version` to inspect handshake state."
    )


def _msg_ruby_missing() -> str:
    return (
        f"SketchUp plugin pre-dates version-compat checking. "
        f"Reinstall su_mcp_v{MAX_RUBY}.rbz from the GitHub release. "
        f"Call `get_version` to inspect handshake state."
    )
