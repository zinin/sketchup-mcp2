"""Python↔Ruby version compatibility — single source of truth (Python side).

Mirrored in mcp_for_sketchup/mcp_for_sketchup/core/compat.rb. Each side
declares only the OLDEST counterpart it works with; there is no upper bound.
The newer side of a pair knows what changed, so the newer side rejects the
older one. docs/release.md §1 says when the floors move.
"""
from __future__ import annotations

import re

from sketchup_mcp import __version__ as CLIENT_VERSION
from sketchup_mcp.errors import IncompatibleVersionError

# Oldest SketchUp plugin this client works with. It moves only when this client
# needs a newer plugin: a contract break raises both floors to that release (as
# 0.3.0 did for the absolute transform position, stricter validation and
# changed response shapes), and a one-sided requirement — say, a new tool that
# calls a new Ruby handler — raises this one alone. A hotfix leaves it put,
# which is what lets a Python-only or plugin-only release talk to the
# counterpart the user already has. Releases up to 0.3.1 cap the counterpart at
# their own version, so 0.4.0, the first release under this rule, ships both
# sides and raises both floors to its own version.
MIN_RUBY = "0.4.0"

# JSON-RPC application-error code returned by the Ruby handler when the
# eval gate is closed. Single source of truth for Python callers — see
# spec §4.4 and Ruby `handlers/eval.rb::EVAL_DISABLED_CODE`.
EVAL_DISABLED_CODE = -32010

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
    older than MIN_RUBY, unparseable, or absent (handshake reply missing
    ``server_version``). A newer plugin always passes: there is no upper
    bound."""
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


def _msg_ruby_too_old(rv: str) -> str:
    # Names the floor and points at the latest plugin: with no upper bound,
    # any plugin at or above MIN_RUBY works, and the newest one is the safe
    # advice.
    return (
        f"SketchUp plugin v{rv} is too old for sketchup-mcp2 v{CLIENT_VERSION} "
        f"(needs plugin v{MIN_RUBY} or newer). "
        "Install the latest mcp_for_sketchup .rbz from the GitHub releases page. "
        "Call `get_version` to inspect handshake state."
    )


def _msg_ruby_missing() -> str:
    return (
        "SketchUp plugin pre-dates version-compat checking. "
        "Install the latest mcp_for_sketchup .rbz from the GitHub releases page. "
        "Call `get_version` to inspect handshake state."
    )
