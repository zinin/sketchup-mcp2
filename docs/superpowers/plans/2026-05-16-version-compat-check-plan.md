# Python ↔ Ruby Version Compatibility Check — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a version handshake so Python and Ruby halves of `sketchup-mcp2` hard-fail with an actionable hint when their versions are incompatible — every JSON-RPC request carries `client_version`, every response carries `server_version`, and the new MCP tool `get_version` is a diagnostic bypass that always returns a payload.

**Architecture:** Two new modules — `src/sketchup_mcp/compat.py` and `su_mcp/su_mcp/core/compat.rb` — hold mirror-image `(MIN, MAX)` ranges. Inbound checks live in `connection.py::_send_once` (Python) and `handlers/dispatch.rb::handle` (Ruby). Outbound version injection is one-line edits in those same call-sites; the response gets `server_version` injected at the choke point `core/server.rb::encode_response_body` (covers happy path AND `JSON::GeneratorError` fallback envelope — single source of truth for every emitted envelope).

**Changelog vs design (iter-1 review fixes):**
- Server-side check moved from `core/server.rb` (per design §8.2 v0) to `handlers/dispatch.rb` (better — reuses structured-error rescue). Design §8.2 has been updated to match.
- `server_version` injection moved from `write_response` to `encode_response_body` so the JSON-generator-error fallback also carries the field.
- `request_id` and `is_notification` are captured BEFORE the version check so `-32001` responses preserve the correct id and notifications are silently dropped.
- Wire-level bypass uses `method == "tools/call" && params.name == "get_version"` (matches the actual protocol), not the simplified `method != "get_version"` pseudocode that appeared in design §8.2 v0.
- `get_version` tool catches both `ConnectionError` AND `SketchUpError` (the latter covers old-Ruby `-32601 "unknown tool"`).
- `get_version` added to `_RETRY_SAFE_TOOLS` so cold-start stale-socket auto-retries instead of bubbling.
- Compat verdict is TWO-WAY: Python's table accepts ruby_version AND Ruby's advertised range accepts CLIENT_VERSION. Catches table-drift.
- Python `_send_once` promotes inbound `error.code == -32001` to `IncompatibleVersionError` (instead of generic `SketchUpError`) so callers see the same class regardless of which side detected the mismatch.
- `tests/conftest.py::encode_response()` updated to inject `server_version` by default so existing `test_connection.py` stays green; a separate negative-case test exercises missing-field semantics.
- `test/test_server_compat.rb` uses the REAL `Dispatch.handle` + REAL `Core::Server` (with a captured-write fake socket) instead of overriding `write_response` with a hand-written copy — production code is actually exercised.
- Task 4 reordered: `handlers/system.rb` + dispatch route created BEFORE `test_server_compat.rb` so the integration test can exercise the real `get_version` path.

**Tech Stack:** Python 3.10+ (`asyncio`, FastMCP, Pydantic v2, pytest); Ruby 2.7 inside SketchUp (minitest, stdlib only).

**Reference spec:** `docs/superpowers/specs/2026-05-16-version-compat-check-design.md`.

**Branch (already on it):** `feature/viewport-screenshot-and-prompt` — version-compat bundles into the same 0.1.0 release as viewport-screenshot.

**Version state at implementation time vs at release time:**
- During implementation, `__version__` in `src/sketchup_mcp/__init__.py` is `"0.0.3"`; tests and the live smoke check run against that. Accordingly, `MIN_RUBY`, `MAX_RUBY`, `SERVER_VERSION`, `MIN_PYTHON`, `MAX_PYTHON` are all set to `"0.0.3"` initially. This keeps the matched-pair "compatible=true" invariant during development.
- At release time, a separate session bumps all seven version strings to `"0.1.0"` per `docs/release.md` §1 (which Task 9 extends from 5 → 7 places).

---

## File Structure

### Files to CREATE

| Path | Responsibility |
|---|---|
| `src/sketchup_mcp/compat.py` | Single source of truth for Python↔Ruby compatibility: CLIENT_VERSION (imported from `__init__.py`), MIN_RUBY, MAX_RUBY, `_parse`, `check_ruby_version`, canonical error-message strings. |
| `tests/test_compat.py` | Unit tests for `_parse`, `check_ruby_version`, MIN ≤ MAX sanity. |
| `tests/test_version_handshake.py` | Tests for outbound `client_version` injection, inbound `server_version` check on every response, get_version bypass. |
| `tests/test_version_tool.py` | Tests for `get_version` MCP tool: registration, compatible/incompatible payload shape, bypass works on mismatch. |
| `su_mcp/su_mcp/core/compat.rb` | Ruby mirror — SERVER_VERSION, MIN_PYTHON, MAX_PYTHON, `parse`, `check_python_version`, canonical error-message strings. |
| `su_mcp/su_mcp/handlers/system.rb` | `Handlers::System.get_version(_params)` — returns the Ruby-side compat metadata payload. |
| `test/test_compat.rb` | Symmetric to `test_compat.py`. |
| `test/test_server_compat.rb` | Tests for incoming `client_version` check (dispatch bypass for get_version), outgoing `server_version` injection on success/error/JSON-generator-fallback, `request_id` preserved on -32001, notification-with-mismatch silently dropped. Uses REAL `Dispatch.handle` + REAL `Core::Server` (no method-overriding double). |
| `test/test_system.rb` | `Handlers::System.get_version` handler unit tests + dispatch routing. |

### Files to MODIFY

| Path | Change |
|---|---|
| `src/sketchup_mcp/errors.py` | +1 class `IncompatibleVersionError(SketchUpError)` with JSON-RPC code `-32001`. |
| `src/sketchup_mcp/connection.py` | In `_send_once`: (a) outbound payload gets `"client_version": compat.CLIENT_VERSION`; (b) after JSON parse, `assert isinstance(response, dict)`; (c) if `name != "get_version"`, call `compat.check_ruby_version(response.get("server_version"))`; (d) if response carries `error.code == -32001`, promote to `IncompatibleVersionError`. Also: add `"get_version"` to `_RETRY_SAFE_TOOLS` frozenset. |
| `src/sketchup_mcp/tools.py` | +1 `@mcp.tool()` async function `get_version` that catches both `ConnectionError` AND `SketchUpError`, parses the Ruby payload, computes two-way `compatible` Python-side, returns JSON string. |
| `tests/conftest.py` | `encode_response()` helper injects `server_version=compat.MAX_RUBY` by default so existing `test_connection.py` mock responses don't trip the new inbound check; explicit `server_version=None` available for negative-case tests. |
| `su_mcp/su_mcp/core/server.rb` | `encode_response_body` injects `response["server_version"] = Core::Compat::SERVER_VERSION` for both the happy path AND the JSON-generator-error fallback envelope (single choke point). |
| `su_mcp/su_mcp/handlers/dispatch.rb` | In `handle`: capture `request_id = request["id"]` and `is_notification = !request.key?("id")` BEFORE the version check; then `Core::Compat.check_python_version(request["client_version"])` UNLESS the call is `tools/call` for `params.name == "get_version"`. The existing `rescue Core::StructuredError` already handles -32001 with the right id; for notifications the rescue must return `nil` (suppress response). Also: new `when "get_version"` branch in `call_handler`. |
| `su_mcp/su_mcp/main.rb` | `LOAD_ORDER` gains `core/compat` (after `core/errors`) and `handlers/system` (after `handlers/eval`). |
| `examples/smoke_check.py` | +1 step (22) calling `get_version`, asserting `compatible=true`. |
| `docs/release.md` | §1 grows from 5 places to 7 (add `src/sketchup_mcp/compat.py` and `su_mcp/su_mcp/core/compat.rb` to the bump list); new note on MIN/MAX maintenance policy. |
| `CLAUDE.md` | Add `get_version` to Introspection row; add Non-Obvious Constraints bullet on per-message version handshake; expand Architecture tables with new files. |
| `README.md` | One Features bullet + one tool catalog entry. |

### Files NOT touched (sanity)

- `src/sketchup_mcp/__init__.py` — `__version__` stays `"0.0.3"` until the release-time bump (separate session).
- `src/sketchup_mcp/app.py`, `config.py`, `prompts.py`, `server.py` — unchanged.
- `su_mcp/su_mcp/core/{config,errors,framing,logger,application}.rb` — unchanged.
- `su_mcp/su_mcp/handlers/{geometry,operations,joints,materials,export,model,eval,view}.rb` — unchanged.
- `pyproject.toml`, `uv.lock`, `su_mcp/extension.json`, `su_mcp/package.rb`, `su_mcp/su_mcp.rb` — unchanged until release-time bump.

---

## Task 1: Python `errors.py` — add `IncompatibleVersionError`

**Files:**
- Modify: `src/sketchup_mcp/errors.py`
- Test (in next task): `tests/test_compat.py` uses this class

- [ ] **Step 1.1: Add the new exception class**

Open `src/sketchup_mcp/errors.py`. After the `SketchUpError` class definition (around line 17), add:

```python
class IncompatibleVersionError(SketchUpError):
    """Raised on Python↔Ruby version mismatch (or missing handshake field).

    Maps to JSON-RPC code -32001 (sibling of -32000 used by StructuredError)
    so log-grep can distinguish 'version-mismatch' from 'plain server error'.
    """
    def __init__(self, message: str):
        super().__init__(code=-32001, message=message)
```

- [ ] **Step 1.2: Run existing tests to confirm nothing broke**

Run via build-runner agent: `uv run pytest tests/ -q`
Expected: same baseline as before — **81 passed, 0 failed, 0 skipped**.

- [ ] **Step 1.3: Commit**

```bash
git add src/sketchup_mcp/errors.py
git commit -m "feat(errors): add IncompatibleVersionError for -32001 mismatches"
```

---

## Task 2: Python `compat.py` — TDD pair

**Files:**
- Create: `src/sketchup_mcp/compat.py`
- Create: `tests/test_compat.py`

- [ ] **Step 2.1: Write the failing tests**

Create `tests/test_compat.py` with the full content below:

```python
"""Tests for sketchup_mcp.compat — version parsing and Ruby compatibility check."""
import pytest

from sketchup_mcp import compat
from sketchup_mcp.errors import IncompatibleVersionError


# -------- _parse --------

def test_parse_valid_tuple():
    assert compat._parse("0.1.0") == (0, 1, 0)
    assert compat._parse("1.2.3") == (1, 2, 3)
    assert compat._parse("10.20.30") == (10, 20, 30)


@pytest.mark.parametrize(
    "bad",
    [
        "0.1",
        "0.1.0.0",
        "abc",
        "",
        "0.1.0-rc1",
        "v1.0.0",
        " 0.1.0",     # leading whitespace
        "0.1.0 ",     # trailing whitespace
        "0.1.0+",     # sign char
        "+1.0.0",     # sign char
        "1_0.0.0",    # underscore separator (rejected by strict regex)
    ],
)
def test_parse_invalid_raises(bad):
    with pytest.raises(ValueError):
        compat._parse(bad)


def test_parse_non_string_raises():
    with pytest.raises(ValueError):
        compat._parse(None)  # type: ignore[arg-type]
    with pytest.raises(ValueError):
        compat._parse(123)  # type: ignore[arg-type]


# -------- check_ruby_version --------

def test_at_min_passes(monkeypatch):
    monkeypatch.setattr(compat, "MIN_RUBY", "0.1.0")
    monkeypatch.setattr(compat, "MAX_RUBY", "0.2.0")
    compat.check_ruby_version("0.1.0")


def test_at_max_passes(monkeypatch):
    monkeypatch.setattr(compat, "MIN_RUBY", "0.1.0")
    monkeypatch.setattr(compat, "MAX_RUBY", "0.2.0")
    compat.check_ruby_version("0.2.0")


def test_too_old_raises_with_reinstall_hint(monkeypatch):
    monkeypatch.setattr(compat, "MIN_RUBY", "0.1.0")
    monkeypatch.setattr(compat, "MAX_RUBY", "0.2.0")
    with pytest.raises(IncompatibleVersionError) as exc:
        compat.check_ruby_version("0.0.3")
    msg = str(exc.value)
    assert "0.0.3" in msg and "too old" in msg
    assert ".rbz" in msg  # reinstall hint
    assert "get_version" in msg  # diagnostic pointer


def test_too_new_raises_with_upgrade_hint(monkeypatch):
    monkeypatch.setattr(compat, "MIN_RUBY", "0.1.0")
    monkeypatch.setattr(compat, "MAX_RUBY", "0.2.0")
    with pytest.raises(IncompatibleVersionError) as exc:
        compat.check_ruby_version("0.3.0")
    msg = str(exc.value)
    assert "0.3.0" in msg and "newer" in msg
    assert "uv pip install --upgrade" in msg
    assert "get_version" in msg


def test_none_raises_with_pre_dates_hint():
    with pytest.raises(IncompatibleVersionError) as exc:
        compat.check_ruby_version(None)
    msg = str(exc.value)
    assert "pre-dates" in msg
    assert ".rbz" in msg
    assert "get_version" in msg


def test_unparseable_raises_clear_message():
    with pytest.raises(IncompatibleVersionError) as exc:
        compat.check_ruby_version("v1")
    msg = str(exc.value)
    assert "unparseable" in msg
    assert "v1" in msg


def test_min_le_max_invariant():
    """Sanity: declared range cannot be empty."""
    assert compat._parse(compat.MIN_RUBY) <= compat._parse(compat.MAX_RUBY)


def test_max_ruby_matches_python_version():
    """Release-time forgot-to-bump catcher: when releasing N, MAX_RUBY == N."""
    assert compat._parse(compat.MAX_RUBY) == compat._parse(compat.CLIENT_VERSION)


def test_python_version_is_imported_from_init():
    """compat.CLIENT_VERSION must mirror the package version."""
    from sketchup_mcp import __version__
    assert compat.CLIENT_VERSION == __version__
```

- [ ] **Step 2.2: Run tests to verify they fail**

Run via build-runner: `uv run pytest tests/test_compat.py -v`
Expected: **collection error or ImportError** — `sketchup_mcp.compat` does not exist yet.

- [ ] **Step 2.3: Create `compat.py`**

Create `src/sketchup_mcp/compat.py` with this content:

```python
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
MIN_RUBY = "0.0.3"
MAX_RUBY = "0.0.3"

_PART_RE = re.compile(r"\A\d+\Z")


def _parse(v: str) -> tuple[int, int, int]:
    """Parse 'X.Y.Z' → (X, Y, Z). Raise ValueError on anything else.

    Strict: each component must match `\\A\\d+\\Z` (no whitespace, no
    sign, no underscores). int() alone would accept "+1", " 1", etc.
    """
    if not isinstance(v, str):
        raise ValueError(f"version must be a string, got {type(v).__name__}")
    parts = v.split(".")
    if len(parts) != 3 or not all(_PART_RE.match(p) for p in parts):
        raise ValueError(f"version must be 'X.Y.Z' (numeric), got {v!r}")
    return (int(parts[0]), int(parts[1]), int(parts[2]))


def check_ruby_version(server_version: str | None) -> None:
    """Raise IncompatibleVersionError if the SketchUp plugin version is
    outside [MIN_RUBY, MAX_RUBY] or absent (pre-0.1.0 plugin)."""
    if server_version is None:
        raise IncompatibleVersionError(_msg_ruby_missing())
    try:
        rv = _parse(server_version)
    except ValueError:
        raise IncompatibleVersionError(
            f"unparseable server_version {server_version!r}; "
            f"expected X.Y.Z (numeric). "
            f"Call `get_version` to inspect handshake state."
        )
    if rv < _parse(MIN_RUBY):
        raise IncompatibleVersionError(_msg_ruby_too_old(server_version))
    if rv > _parse(MAX_RUBY):
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
```

- [ ] **Step 2.4: Run tests to verify they pass**

Run via build-runner: `uv run pytest tests/test_compat.py -v`
Expected: **all ~20 tests pass** (parametrized cases expand to many; exact count depends on collection).

- [ ] **Step 2.5: Run full test suite — no regressions**

Run via build-runner: `uv run pytest tests/ -q`
Expected: 81 baseline + ~20 new = **~101 passed**, 0 failed, 0 skipped. (Other tasks add more — final total in Task 12 step 12.1.)

- [ ] **Step 2.6: Commit**

```bash
git add tests/test_compat.py src/sketchup_mcp/compat.py
git commit -m "feat(compat): add Python-side version compatibility module

* New compat.py: CLIENT_VERSION (from __init__), MIN_RUBY/MAX_RUBY range,
  check_ruby_version() raising IncompatibleVersionError with reinstall/
  upgrade hints.
* Initial MIN/MAX = '0.0.3' (current __version__); bumped at release time
  per docs/release.md step 1.
* 11 unit tests cover parse, range edges, missing/unparseable input,
  MIN ≤ MAX invariant."
```

---

## Task 3: Ruby `core/compat.rb` — TDD pair

**Files:**
- Create: `su_mcp/su_mcp/core/compat.rb`
- Create: `test/test_compat.rb`
- Modify: `su_mcp/su_mcp/main.rb` (add `core/compat` to `LOAD_ORDER`)

- [ ] **Step 3.1: Write the failing tests**

Create `test/test_compat.rb`:

```ruby
# test/test_compat.rb
require "minitest/autorun"
require_relative "test_helper"  # if missing, use the same require pattern as test/test_view.rb

require_relative "../su_mcp/su_mcp/core/errors"
require_relative "../su_mcp/su_mcp/core/compat"

class TestCompat < Minitest::Test
  # -------- parse --------

  def test_parse_valid
    assert_equal [0, 1, 0], SU_MCP::Core::Compat.parse("0.1.0")
    assert_equal [10, 20, 30], SU_MCP::Core::Compat.parse("10.20.30")
  end

  ["0.1", "0.1.0.0", "abc", "", "v1"].each_with_index do |bad, i|
    define_method("test_parse_invalid_#{i}_#{bad.gsub(/\W/, '_')}") do
      assert_raises(ArgumentError) { SU_MCP::Core::Compat.parse(bad) }
    end
  end

  def test_parse_non_string_raises
    assert_raises(ArgumentError) { SU_MCP::Core::Compat.parse(nil) }
    assert_raises(ArgumentError) { SU_MCP::Core::Compat.parse(123) }
  end

  # -------- check_python_version --------

  # Safe swap of compat constants per-test. Uses defined?-guards in the
  # ensure block so a partial setup (e.g. exception between the two
  # remove_const calls) doesn't mask the original error with a secondary
  # NameError.
  def with_range(min, max)
    orig_min = SU_MCP::Core::Compat::MIN_PYTHON
    orig_max = SU_MCP::Core::Compat::MAX_PYTHON
    SU_MCP::Core::Compat.send(:remove_const, :MIN_PYTHON)
    SU_MCP::Core::Compat.send(:remove_const, :MAX_PYTHON)
    SU_MCP::Core::Compat.const_set(:MIN_PYTHON, min)
    SU_MCP::Core::Compat.const_set(:MAX_PYTHON, max)
    yield
  ensure
    if SU_MCP::Core::Compat.const_defined?(:MIN_PYTHON, false)
      SU_MCP::Core::Compat.send(:remove_const, :MIN_PYTHON)
    end
    if SU_MCP::Core::Compat.const_defined?(:MAX_PYTHON, false)
      SU_MCP::Core::Compat.send(:remove_const, :MAX_PYTHON)
    end
    SU_MCP::Core::Compat.const_set(:MIN_PYTHON, orig_min) if defined?(orig_min)
    SU_MCP::Core::Compat.const_set(:MAX_PYTHON, orig_max) if defined?(orig_max)
  end

  def test_at_min_passes
    with_range("0.1.0", "0.2.0") do
      SU_MCP::Core::Compat.check_python_version("0.1.0")  # no raise
    end
  end

  def test_at_max_passes
    with_range("0.1.0", "0.2.0") do
      SU_MCP::Core::Compat.check_python_version("0.2.0")
    end
  end

  def test_too_old_raises_with_upgrade_hint
    with_range("0.1.0", "0.2.0") do
      err = assert_raises(SU_MCP::Core::StructuredError) do
        SU_MCP::Core::Compat.check_python_version("0.0.3")
      end
      assert_equal(-32001, err.code)
      assert_includes err.message, "0.0.3"
      assert_includes err.message, "too old"
      assert_includes err.message, "uv pip install --upgrade"
    end
  end

  def test_too_new_raises_with_reinstall_hint
    with_range("0.1.0", "0.2.0") do
      err = assert_raises(SU_MCP::Core::StructuredError) do
        SU_MCP::Core::Compat.check_python_version("0.3.0")
      end
      assert_equal(-32001, err.code)
      assert_includes err.message, "0.3.0"
      assert_includes err.message, "newer"
      assert_includes err.message, ".rbz"
    end
  end

  def test_nil_raises_with_pre_dates_hint
    err = assert_raises(SU_MCP::Core::StructuredError) do
      SU_MCP::Core::Compat.check_python_version(nil)
    end
    assert_equal(-32001, err.code)
    assert_includes err.message, "pre-dates"
  end

  def test_unparseable_raises_clear_message
    err = assert_raises(SU_MCP::Core::StructuredError) do
      SU_MCP::Core::Compat.check_python_version("v1")
    end
    assert_equal(-32001, err.code)
    assert_includes err.message, "unparseable"
    assert_includes err.message, "v1"
  end

  def test_min_le_max_invariant
    min = SU_MCP::Core::Compat.parse(SU_MCP::Core::Compat::MIN_PYTHON)
    max = SU_MCP::Core::Compat.parse(SU_MCP::Core::Compat::MAX_PYTHON)
    assert (min <=> max) <= 0,
      "MIN_PYTHON (#{min}) must be <= MAX_PYTHON (#{max})"
  end

  def test_max_python_matches_server_version
    # Release-time forgot-to-bump catcher: when releasing version N,
    # MAX_PYTHON == N == plugin SERVER_VERSION.
    max = SU_MCP::Core::Compat.parse(SU_MCP::Core::Compat::MAX_PYTHON)
    sv  = SU_MCP::Core::Compat.parse(SU_MCP::Core::Compat::SERVER_VERSION)
    assert_equal sv, max,
      "MAX_PYTHON (#{max}) must match plugin SERVER_VERSION (#{sv})"
  end
end
```

Note on `test_helper`: check whether `test/run_all.rb` requires a helper. If `test/test_view.rb` works without one, drop the `require_relative "test_helper"` line.

- [ ] **Step 3.2: Run tests to verify they fail**

Run via build-runner: `ruby test/test_compat.rb`
Expected: **LoadError** — `core/compat` does not exist yet.

- [ ] **Step 3.3: Create `core/compat.rb`**

Create `su_mcp/su_mcp/core/compat.rb`:

```ruby
# su_mcp/su_mcp/core/compat.rb
module SU_MCP
  module Core
    module Compat
      # SERVER_VERSION mirrors the wire-field `server_version` and avoids
      # shadowing Ruby's global `::RUBY_VERSION` (the interpreter version).
      # This is the SketchUp PLUGIN version, bumped at release time.
      SERVER_VERSION = "0.0.3"
      MIN_PYTHON   = "0.0.3"
      MAX_PYTHON   = "0.0.3"

      PART_RE = /\A\d+\z/.freeze

      # Parse "X.Y.Z" → [X, Y, Z] (Integers). Raise ArgumentError on any
      # other shape. Strict: each component must match /\A\d+\z/ — Integer()
      # alone would accept "+1", "0x10", etc.
      def self.parse(v)
        unless v.is_a?(String)
          raise ArgumentError, "version must be a string, got #{v.class}"
        end
        parts = v.split(".")
        unless parts.length == 3 && parts.all? { |p| PART_RE.match?(p) }
          raise ArgumentError, "version must be 'X.Y.Z' (numeric), got #{v.inspect}"
        end
        parts.map { |p| Integer(p, 10) }
      end

      # Raise SU_MCP::Core::StructuredError(-32001) if client_version is nil,
      # unparseable, or outside [MIN_PYTHON, MAX_PYTHON].
      def self.check_python_version(client_version)
        if client_version.nil?
          raise SU_MCP::Core::StructuredError.new(-32001, msg_python_missing)
        end
        begin
          cv = parse(client_version)
        rescue ArgumentError
          raise SU_MCP::Core::StructuredError.new(
            -32001,
            "unparseable client_version #{client_version.inspect}; " \
              "expected X.Y.Z (numeric). " \
              "Call `get_version` to inspect handshake state."
          )
        end
        min = parse(MIN_PYTHON)
        max = parse(MAX_PYTHON)
        if (cv <=> min) < 0
          raise SU_MCP::Core::StructuredError.new(-32001, msg_python_too_old(client_version))
        end
        if (cv <=> max) > 0
          raise SU_MCP::Core::StructuredError.new(-32001, msg_python_too_new(client_version))
        end
      end

      def self.msg_python_too_old(cv)
        "sketchup-mcp2 v#{cv} is too old for SketchUp plugin v#{SERVER_VERSION} " \
        "(requires v#{MIN_PYTHON}..v#{MAX_PYTHON}). " \
        "Run: uv pip install --upgrade sketchup-mcp2. " \
        "Call `get_version` to inspect handshake state."
      end

      def self.msg_python_too_new(cv)
        "sketchup-mcp2 v#{cv} is newer than SketchUp plugin v#{SERVER_VERSION} " \
        "supports (max v#{MAX_PYTHON}). " \
        "Reinstall su_mcp_v#{MAX_PYTHON}.rbz from the GitHub release. " \
        "Call `get_version` to inspect handshake state."
      end

      def self.msg_python_missing
        "sketchup-mcp2 client pre-dates version-compat checking. " \
        "Run: uv pip install --upgrade sketchup-mcp2. " \
        "Call `get_version` to inspect handshake state."
      end
    end
  end
end
```

- [ ] **Step 3.4: Wire `core/compat` into `LOAD_ORDER`**

Open `su_mcp/su_mcp/main.rb`. In `LOAD_ORDER` (lines ~17–39), insert `core/compat` immediately after `core/errors`:

```ruby
LOAD_ORDER = %w[
  core/config
  core/errors
  core/compat
  helpers/units
  ...
].freeze
```

- [ ] **Step 3.5: Run tests to verify they pass**

Run via build-runner: `ruby test/test_compat.rb -v`
Expected: **all tests green** (~12–13 tests depending on parametrization expansion).

- [ ] **Step 3.6: Run full Ruby suite — no regressions**

Run via build-runner: `ruby test/run_all.rb`
Expected: prior baseline + new tests, **0 failures, 0 errors, 0 skips**.

- [ ] **Step 3.7: Commit**

```bash
git add test/test_compat.rb su_mcp/su_mcp/core/compat.rb su_mcp/su_mcp/main.rb
git commit -m "feat(compat): add Ruby-side version compatibility module

* New core/compat.rb mirrors src/sketchup_mcp/compat.py: SERVER_VERSION,
  MIN_PYTHON/MAX_PYTHON range, check_python_version raising
  StructuredError(-32001) with upgrade/reinstall hints.
* Initial values all '0.0.3' (current state); bumped to '0.1.0' at
  release time per docs/release.md step 1.
* main.rb::LOAD_ORDER gains 'core/compat' after 'core/errors'.
* Symmetric ~12 unit tests."
```

---

## Task 4: Ruby `handlers/system.rb` + dispatch routing — TDD pair (was Task 5)

**Reordered per iter-1 review fix CRITICAL-6:** the `system.rb` handler
and the `tools/call → get_version` dispatch route must exist BEFORE
`test_server_compat.rb` (the next task) can exercise the real bypass
path end-to-end. Test-doubles that re-implement `write_response` are
forbidden — see Task 5.

**Files:**
- Create: `su_mcp/su_mcp/handlers/system.rb`
- Create: `test/test_system.rb`
- Modify: `su_mcp/su_mcp/handlers/dispatch.rb` (route `get_version` only — the version check itself comes in Task 5)
- Modify: `su_mcp/su_mcp/main.rb` (LOAD_ORDER)

- [ ] **Step 4.1: Write the failing unit tests** (was step 5.1)

Create `test/test_system.rb`:

```ruby
# test/test_system.rb — get_version handler unit + dispatch routing test.

require "minitest/autorun"
require "json"

require_relative "../su_mcp/su_mcp/core/errors"
require_relative "../su_mcp/su_mcp/core/compat"
require_relative "../su_mcp/su_mcp/core/logger"
require_relative "../su_mcp/su_mcp/handlers/dispatch"
require_relative "../su_mcp/su_mcp/handlers/system"

class TestSystem < Minitest::Test
  def test_get_version_returns_compat_metadata
    result = SU_MCP::Handlers::System.get_version(nil)
    assert_kind_of Hash, result
    assert_equal SU_MCP::Core::Compat::SERVER_VERSION,    result[:ruby_version]
    assert_equal SU_MCP::Core::Compat::MIN_PYTHON,      result[:min_compatible_python]
    assert_equal SU_MCP::Core::Compat::MAX_PYTHON,      result[:max_compatible_python]
  end

  def test_get_version_ignores_params
    result = SU_MCP::Handlers::System.get_version({ "foo" => "bar" })
    assert_equal SU_MCP::Core::Compat::SERVER_VERSION, result[:ruby_version]
  end

  def test_dispatch_routes_get_version_to_system
    req = {
      "jsonrpc" => "2.0",
      "method"  => "tools/call",
      "params"  => { "name" => "get_version", "arguments" => {} },
      "id"      => 7,
      "client_version" => SU_MCP::Core::Compat::MIN_PYTHON,
    }
    resp = SU_MCP::Handlers::Dispatch.handle(req)
    refute_nil resp["result"]
    text = resp["result"]["content"][0]["text"]
    payload = JSON.parse(text)
    assert_equal SU_MCP::Core::Compat::SERVER_VERSION, payload["ruby_version"]
  end
end
```

- [ ] **Step 4.2: Run tests to verify they fail** — LoadError (no handlers/system) or "unknown tool: get_version".

- [ ] **Step 4.3: Create `handlers/system.rb`**

Create `su_mcp/su_mcp/handlers/system.rb`:

```ruby
# su_mcp/su_mcp/handlers/system.rb
module SU_MCP
  module Handlers
    module System
      # Returns the Ruby-side compat metadata. Used by the MCP tool
      # `get_version` (Python wrapper computes the `compatible` flag).
      def self.get_version(_params)
        {
          ruby_version:           SU_MCP::Core::Compat::SERVER_VERSION,
          min_compatible_python:  SU_MCP::Core::Compat::MIN_PYTHON,
          max_compatible_python:  SU_MCP::Core::Compat::MAX_PYTHON,
        }
      end
    end
  end
end
```

- [ ] **Step 4.4: Route `get_version` in `dispatch.rb::call_handler`**

Open `su_mcp/su_mcp/handlers/dispatch.rb`. In `call_handler` (around line 90), add:

```ruby
when "get_viewport_screenshot" then Handlers::View.viewport_screenshot(params)
when "get_version"             then Handlers::System.get_version(params)
else
  ...
```

- [ ] **Step 4.5: Wire `handlers/system` into `LOAD_ORDER`**

Open `su_mcp/su_mcp/main.rb`. Add `handlers/system` after `handlers/eval`.

- [ ] **Step 4.6: Run tests to verify they pass** — all green.

- [ ] **Step 4.7: Run full Ruby suite — no regressions** — 0 failures.

- [ ] **Step 4.8: Commit**

```bash
git add test/test_system.rb su_mcp/su_mcp/handlers/system.rb su_mcp/su_mcp/handlers/dispatch.rb su_mcp/su_mcp/main.rb
git commit -m "feat(handlers): add get_version system handler + dispatch route

* New handlers/system.rb with Handlers::System.get_version returning
  {ruby_version, min_compatible_python, max_compatible_python}.
* dispatch.rb gains 'when get_version' route in call_handler.
* main.rb LOAD_ORDER adds handlers/system after handlers/eval.
* This task is sequenced BEFORE the client_version check so the next
  task's integration tests can exercise the real get_version bypass
  path end-to-end."
```

---

## Task 5: Ruby server-compat handshake — request check + response injection (was Task 4 content, restructured)

**Files:**
- Modify: `su_mcp/su_mcp/handlers/dispatch.rb` (client_version check with proper ordering — `request_id` and `is_notification` captured BEFORE the check; notification mismatches log WARN and return nil)
- Modify: `su_mcp/su_mcp/core/server.rb` (`server_version` injection in `encode_response_body` — covers happy path AND JSON-generator-error fallback)
- Create: `test/test_server_compat.rb` (uses REAL `Dispatch.handle` + REAL `Core::Server` with captured-write fake socket — NO method-overriding double)

- [ ] **Step 5.1: Write the failing tests**

Create `test/test_server_compat.rb`:

```ruby
# test/test_server_compat.rb — server-side version-handshake integration tests.
# Uses REAL Dispatch.handle + REAL Core::Server with a fake socket (no
# method-overriding double — production code is actually exercised).

require "minitest/autorun"
require "json"

require_relative "../su_mcp/su_mcp/core/errors"
require_relative "../su_mcp/su_mcp/core/compat"
require_relative "../su_mcp/su_mcp/core/logger"
require_relative "../su_mcp/su_mcp/core/framing"
require_relative "../su_mcp/su_mcp/core/server"
require_relative "../su_mcp/su_mcp/handlers/dispatch"
require_relative "../su_mcp/su_mcp/handlers/system"  # routed in Task 4

class TestServerCompat < Minitest::Test
  PYTHON = SU_MCP::Core::Compat::MIN_PYTHON  # current matched value "0.0.3"

  def make_request(method:, params: {}, client_version: PYTHON, id: 1)
    req = {
      "jsonrpc" => "2.0",
      "method"  => method,
      "params"  => params,
    }
    req["id"] = id unless id == :omit
    req["client_version"] = client_version unless client_version == :omit
    req
  end

  # -------- Dispatch.handle: client_version check --------

  def test_dispatch_with_valid_client_version_returns_id
    req = make_request(
      method: "tools/call",
      params: { "name" => "get_version", "arguments" => {} },
      client_version: PYTHON, id: 42,
    )
    resp = SU_MCP::Handlers::Dispatch.handle(req)
    assert_equal 42, resp["id"]
    refute_nil resp["result"]
    refute resp.key?("error")
  end

  def test_dispatch_incompatible_client_version_preserves_request_id
    # Regression for the request_id=nil bug found in iter-1 review:
    # the check must run AFTER request_id is captured.
    req = make_request(
      method: "tools/call",
      params: { "name" => "list_layers", "arguments" => {} },
      client_version: "0.0.0",
      id: 42,
    )
    # MIN_PYTHON is "0.0.3" by default; 0.0.0 is too old.
    resp = SU_MCP::Handlers::Dispatch.handle(req)
    refute_nil resp["error"]
    assert_equal 42, resp["id"], "id must be preserved on -32001"
    assert_equal(-32001, resp["error"]["code"])
    assert_includes resp["error"]["message"], "too old"
  end

  def test_dispatch_get_version_bypasses_client_version_check
    req = make_request(
      method: "tools/call",
      params: { "name" => "get_version", "arguments" => {} },
      client_version: "0.0.0",  # would normally trip the check
    )
    resp = SU_MCP::Handlers::Dispatch.handle(req)
    refute_nil resp["result"]
    refute resp.key?("error")
  end

  def test_dispatch_missing_client_version_treated_as_pre_0_1_0
    req = make_request(
      method: "tools/call",
      params: { "name" => "list_layers", "arguments" => {} },
      client_version: :omit,
      id: 7,
    )
    resp = SU_MCP::Handlers::Dispatch.handle(req)
    refute_nil resp["error"]
    assert_equal 7, resp["id"]
    assert_equal(-32001, resp["error"]["code"])
    assert_includes resp["error"]["message"], "pre-dates"
  end

  def test_dispatch_notification_with_mismatch_silently_dropped
    # JSON-RPC 2.0: server MUST NOT reply to a notification (no id).
    req = make_request(
      method: "tools/call",
      params: { "name" => "list_layers", "arguments" => {} },
      client_version: "0.0.0",
      id: :omit,
    )
    resp = SU_MCP::Handlers::Dispatch.handle(req)
    assert_nil resp, "notification with mismatch must return nil (no response)"
  end

  # -------- Core::Server.encode_response_body: server_version on every envelope --------

  def encode(response)
    # Build a real Server, drive the real encode_response_body via send.
    server = SU_MCP::Core::Server.new
    server.send(:encode_response_body, response)
  end

  def test_encode_response_body_injects_server_version_on_success
    body = encode({ "jsonrpc" => "2.0", "id" => 1, "result" => { "k" => "v" } })
    payload = JSON.parse(body)
    assert_equal SU_MCP::Core::Compat::SERVER_VERSION, payload["server_version"]
  end

  def test_encode_response_body_injects_server_version_on_error
    body = encode({
      "jsonrpc" => "2.0", "id" => 2,
      "error" => { "code" => -32000, "message" => "boom", "data" => {} },
    })
    payload = JSON.parse(body)
    assert_equal SU_MCP::Core::Compat::SERVER_VERSION, payload["server_version"]
    assert_equal(-32000, payload["error"]["code"])
  end

  def test_encode_response_body_injects_server_version_on_json_generator_fallback
    # Force JSON.generate to fail on the first call; fallback envelope
    # must still carry server_version.
    server = SU_MCP::Core::Server.new
    bad_response = {
      "jsonrpc" => "2.0", "id" => 9,
      "result" => Object.new,  # not JSON-serializable
    }
    body = server.send(:encode_response_body, bad_response)
    payload = JSON.parse(body)
    assert_equal SU_MCP::Core::Compat::SERVER_VERSION, payload["server_version"],
      "fallback envelope must carry server_version"
    assert payload.key?("error"), "fallback must be an error envelope"
  end
end
```

- [ ] **Step 5.2: Run tests to verify they fail**

Run via build-runner: `ruby test/test_server_compat.rb`
Expected: most tests fail — `dispatch.rb` doesn't yet check `client_version`, `encode_response_body` doesn't inject `server_version`, the JSON-generator fallback test is the only one Ruby raises on its own.

- [ ] **Step 5.3: Add client_version check to `dispatch.rb` with correct ordering**

Open `su_mcp/su_mcp/handlers/dispatch.rb`. Modify `self.handle(request)`:

```ruby
def self.handle(request)
  request_id = nil
  is_notification = false
  tool = nil
  params = {}
  begin
    validate_envelope!(request)

    # Capture id and notification flag BEFORE the version check so:
    #  - -32001 error responses preserve the real request id
    #  - notifications (no "id") are silently dropped on mismatch
    request_id = request["id"]
    is_notification = !request.key?("id")
    method = request["method"]

    # Version handshake — diagnostic bypass for tools/call → get_version
    # (matches the actual wire format; Python NEVER sends method == "get_version").
    is_get_version_call =
      method == "tools/call" &&
      request["params"].is_a?(Hash) &&
      request.dig("params", "name") == "get_version"

    unless is_get_version_call
      Core::Compat.check_python_version(request["client_version"])
    end

    # ... existing dispatch code (case-when on method) follows unchanged ...
  rescue Core::StructuredError => e
    return nil if is_notification    # ← suppress response for notifications
    Logger.log_warn("dispatch.version", "client_version mismatch: #{e.message}") if e.code == -32001 && is_notification == false
    Errors.build_error_response(e.code, e.message, e.data, request_id)
  end
end
```

Note: the existing `rescue` already returns a -32001 envelope for regular requests; the only additions are (a) move `request_id`/`is_notification` capture up, (b) return `nil` for notifications, (c) log WARN on -32001 (helpful for operators watching logs of unrouted notification mismatches).

- [ ] **Step 5.4: Add server_version injection to `core/server.rb::encode_response_body`**

Open `su_mcp/su_mcp/core/server.rb`. The injection moves from `write_response` (per old plan) into `encode_response_body` so the JSON-generator-error fallback path also benefits:

```ruby
def encode_response_body(response)
  response["server_version"] = Core::Compat::SERVER_VERSION if response.is_a?(Hash)
  JSON.generate(response)
rescue JSON::GeneratorError, Encoding::UndefinedConversionError => e
  Logger.log_error("server.encode", e)
  rid = response.is_a?(Hash) ? response["id"] : nil
  fallback = Errors.build_error_response(
    -32603,
    "response not serializable: #{e.class}: #{e.message}",
    { "exception" => e.class.name },
    rid,
  )
  fallback["server_version"] = Core::Compat::SERVER_VERSION  # also on fallback
  JSON.generate(fallback)
end
```

The exact existing structure of `encode_response_body` may differ; the rule is: **both** `JSON.generate` calls (happy path + rescue fallback) must precede an injection step.

- [ ] **Step 5.5: Verify all `test_server_compat.rb` tests pass** — `ruby test/test_server_compat.rb -v`.

- [ ] **Step 5.6: Run full Ruby suite — no regressions** — `ruby test/run_all.rb`.

Note: if existing tests in `test/test_view.rb` or elsewhere call `Dispatch.handle` without `client_version`, they'll start failing with -32001. Either (a) add `"client_version" => Core::Compat::MIN_PYTHON` to those fixture builders, or (b) leave them as documented "regression test for pre-0.1.0 client rejection" if that's what they're asserting. Walk the failure list before committing.

- [ ] **Step 5.7: Commit**

```bash
git add test/test_server_compat.rb su_mcp/su_mcp/handlers/dispatch.rb su_mcp/su_mcp/core/server.rb
git commit -m "feat(handshake): check client_version in dispatch, inject server_version in encode_response_body

* dispatch.rb: capture request_id/is_notification BEFORE the compat check
  so -32001 preserves the real id; notifications with mismatch return nil.
  Bypass logic uses method=='tools/call' && params.name=='get_version'
  (matches actual wire form, not the simplified design pseudocode).
* server.rb::encode_response_body: inject Core::Compat::SERVER_VERSION on
  BOTH the happy path and the JSON-generator-error fallback envelope —
  single choke point covers every emitted response.
* test_server_compat.rb uses REAL Dispatch.handle + REAL Core::Server
  with no method-overriding double; production code is exercised."
```

---

## Task 6: Python `connection.py` — outbound `client_version` + inbound `server_version` check + conftest update (TDD pair)

**Files:**
- Modify: `src/sketchup_mcp/connection.py` (outbound client_version, dict assert, name-based bypass, check_ruby_version, -32001 → IncompatibleVersionError remap, _RETRY_SAFE_TOOLS += "get_version")
- Modify: `tests/conftest.py` (`encode_response()` injects `server_version=compat.MAX_RUBY` by default so existing `test_connection.py` tests stay green)
- Create: `tests/test_version_handshake.py`

- [ ] **Step 6.1: Write the failing tests**

Create `tests/test_version_handshake.py`:

```python
"""Tests for the client_version outbound + server_version inbound handshake
inside SketchUpConnection._send_once. We exercise the method directly with
mocked StreamReader/StreamWriter rather than spinning up a real TCP server."""
from __future__ import annotations

import asyncio
import json
import struct
from unittest.mock import AsyncMock, MagicMock

import pytest

from sketchup_mcp import compat
from sketchup_mcp.connection import SketchUpConnection
from sketchup_mcp.errors import IncompatibleVersionError


def _frame(payload: dict) -> bytes:
    body = json.dumps(payload).encode("utf-8")
    return struct.pack(">I", len(body)) + body


def _frames_to_reader(*frames: bytes) -> AsyncMock:
    """Build an asyncio.StreamReader-like mock that yields the supplied frames
    in order via readexactly()."""
    chunks = list(frames)
    pos = {"i": 0}

    async def readexactly(n: int) -> bytes:
        if pos["i"] >= sum(len(c) for c in chunks):
            raise asyncio.IncompleteReadError(b"", n)
        # Concatenate all frames into one buffer so consumer can chop by byte.
        buf = b"".join(chunks)
        out = buf[pos["i"]:pos["i"] + n]
        pos["i"] += n
        return out

    reader = MagicMock()
    reader.readexactly = AsyncMock(side_effect=readexactly)
    return reader


def _capturing_writer():
    """Return (writer_mock, captured_list); writer.write appends to captured."""
    captured: list[bytes] = []
    writer = MagicMock()
    writer.write = MagicMock(side_effect=lambda b: captured.append(b))
    writer.drain = AsyncMock(return_value=None)
    writer.is_closing = MagicMock(return_value=False)
    writer.close = MagicMock(return_value=None)
    writer.wait_closed = AsyncMock(return_value=None)
    return writer, captured


def _decode_request(frame_bytes: bytes) -> dict:
    """Strip the 4-byte length prefix and parse the JSON body."""
    return json.loads(frame_bytes[4:])


@pytest.mark.asyncio
async def test_outbound_payload_carries_client_version():
    conn = SketchUpConnection(host="127.0.0.1", port=9876, timeout=5.0)
    conn._reader = _frames_to_reader(
        _frame({"jsonrpc": "2.0", "id": 1, "result": {"content": [{"type": "text", "text": "{}"}], "isError": False}, "server_version": compat.MAX_RUBY}),
    )
    conn._writer, captured = _capturing_writer()
    await conn.send_command("get_model_info", {})
    payload = _decode_request(captured[0])
    assert payload["client_version"] == compat.CLIENT_VERSION
    assert payload["method"] == "tools/call"
    assert payload["params"] == {"name": "get_model_info", "arguments": {}}


@pytest.mark.asyncio
async def test_compatible_server_version_does_not_raise():
    conn = SketchUpConnection(host="127.0.0.1", port=9876, timeout=5.0)
    conn._reader = _frames_to_reader(
        _frame({"jsonrpc": "2.0", "id": 1, "result": {"content": [{"type": "text", "text": "ok"}], "isError": False}, "server_version": compat.MAX_RUBY}),
    )
    conn._writer, _ = _capturing_writer()
    result = await conn.send_command("get_model_info", {})
    assert result["content"][0]["text"] == "ok"


@pytest.mark.asyncio
async def test_incompatible_server_version_raises_for_normal_tool(monkeypatch):
    monkeypatch.setattr(compat, "MIN_RUBY", "1.0.0")
    monkeypatch.setattr(compat, "MAX_RUBY", "1.0.0")
    conn = SketchUpConnection(host="127.0.0.1", port=9876, timeout=5.0)
    conn._reader = _frames_to_reader(
        _frame({"jsonrpc": "2.0", "id": 1, "result": {"content": [{"type": "text", "text": "ok"}], "isError": False}, "server_version": "0.0.3"}),
    )
    conn._writer, _ = _capturing_writer()
    with pytest.raises(IncompatibleVersionError):
        await conn.send_command("get_model_info", {})


@pytest.mark.asyncio
async def test_missing_server_version_raises_for_normal_tool():
    conn = SketchUpConnection(host="127.0.0.1", port=9876, timeout=5.0)
    conn._reader = _frames_to_reader(
        _frame({"jsonrpc": "2.0", "id": 1, "result": {"content": [{"type": "text", "text": "ok"}], "isError": False}}),
    )
    conn._writer, _ = _capturing_writer()
    with pytest.raises(IncompatibleVersionError) as exc:
        await conn.send_command("get_model_info", {})
    assert "pre-dates" in str(exc.value)


@pytest.mark.asyncio
async def test_get_version_bypasses_inbound_check(monkeypatch):
    """When name == 'get_version', a mismatch in server_version must NOT raise:
    the diagnostic must reach the caller so it can build the verdict payload."""
    monkeypatch.setattr(compat, "MIN_RUBY", "1.0.0")
    monkeypatch.setattr(compat, "MAX_RUBY", "1.0.0")
    conn = SketchUpConnection(host="127.0.0.1", port=9876, timeout=5.0)
    payload_text = json.dumps({
        "ruby_version": "0.0.3",
        "min_compatible_python": "0.0.3",
        "max_compatible_python": "0.0.3",
    })
    conn._reader = _frames_to_reader(
        _frame({"jsonrpc": "2.0", "id": 1,
                "result": {"content": [{"type": "text", "text": payload_text}], "isError": False},
                "server_version": "0.0.3"}),
    )
    conn._writer, _ = _capturing_writer()
    result = await conn.send_command("get_version", {})
    # No raise — payload comes through.
    text = result["content"][0]["text"]
    assert json.loads(text)["ruby_version"] == "0.0.3"


@pytest.mark.asyncio
async def test_inbound_check_runs_on_every_response(monkeypatch):
    """Two successive calls each trigger check_ruby_version — no per-connection
    cache that would skip subsequent verifications."""
    call_count = {"n": 0}

    def spying_check(v):
        call_count["n"] += 1

    monkeypatch.setattr(compat, "check_ruby_version", spying_check)
    conn = SketchUpConnection(host="127.0.0.1", port=9876, timeout=5.0)
    conn._reader = _frames_to_reader(
        _frame({"jsonrpc": "2.0", "id": 1, "result": {"content": [{"type": "text", "text": "a"}], "isError": False}, "server_version": "0.0.3"}),
        _frame({"jsonrpc": "2.0", "id": 2, "result": {"content": [{"type": "text", "text": "b"}], "isError": False}, "server_version": "0.0.3"}),
    )
    conn._writer, _ = _capturing_writer()
    await conn.send_command("get_model_info", {})
    await conn.send_command("get_model_info", {})
    assert call_count["n"] == 2


@pytest.mark.asyncio
async def test_ruby_side_minus_32001_promoted_to_incompatible_version_error():
    """When Ruby returns error.code == -32001 (its own mismatch verdict),
    _send_once must raise IncompatibleVersionError, not generic SketchUpError.
    Ensures callers can catch one class regardless of which side detected."""
    conn = SketchUpConnection(host="127.0.0.1", port=9876, timeout=5.0)
    conn._reader = _frames_to_reader(
        _frame({
            "jsonrpc": "2.0", "id": 1,
            "error": {"code": -32001, "message": "sketchup-mcp2 v0.0.0 is too old..."},
            "server_version": compat.MAX_RUBY,
        }),
    )
    conn._writer, _ = _capturing_writer()
    with pytest.raises(IncompatibleVersionError) as exc:
        await conn.send_command("get_model_info", {})
    assert "too old" in str(exc.value)


def test_get_version_in_retry_safe_tools():
    """Regression for CRITICAL-4: get_version must be retry-safe so
    cold-start stale-socket auto-retries."""
    from sketchup_mcp.connection import _RETRY_SAFE_TOOLS
    assert "get_version" in _RETRY_SAFE_TOOLS
```

- [ ] **Step 6.2: Run tests to verify they fail**

Run via build-runner: `uv run pytest tests/test_version_handshake.py -v`
Expected: tests fail — `_send_once` doesn't yet add `client_version` or check `server_version`.

- [ ] **Step 6.3: Update `tests/conftest.py::encode_response()` (prevents existing-test regressions)**

Per CRITICAL-7: existing `tests/test_connection.py` uses an
`encode_response()` helper from `conftest.py` to build mock responses;
none of those carry `server_version`, so the new inbound check would
fail them all. Update the helper to default-inject `server_version`:

```python
# tests/conftest.py — find encode_response() and update its signature:
def encode_response(payload, *, server_version: str | None = "INJECT_MAX"):
    """Build a fake 4-byte-length-prefixed JSON-RPC response frame.

    server_version: defaults to the matched Ruby version (compat.MAX_RUBY)
    so existing tests don't trip the new inbound handshake check.
    Pass server_version=None explicitly for negative-case tests that
    want to verify "missing-field treated as pre-0.1.0" behavior.
    """
    from sketchup_mcp import compat
    if server_version == "INJECT_MAX":
        server_version = compat.MAX_RUBY
    if server_version is not None and isinstance(payload, dict):
        payload = {**payload, "server_version": server_version}
    body = json.dumps(payload).encode("utf-8")
    return struct.pack(">I", len(body)) + body
```

(The exact pre-existing signature in `conftest.py` may differ — preserve it; just add the default-injection behavior.)

- [ ] **Step 6.4: Modify `_send_once` in `connection.py`**

Open `src/sketchup_mcp/connection.py`.

(a) Add an import near the top, after `from sketchup_mcp.errors import SketchUpError` (line 18):

```python
from sketchup_mcp import compat
from sketchup_mcp.errors import IncompatibleVersionError
```

(b) In `_send_once` (around line 124), the `request` dict (lines 129–134) gains the new field:

```python
request = {
    "jsonrpc": "2.0",
    "method": "tools/call",
    "params": {"name": name, "arguments": args},
    "id": rid,
    "client_version": compat.CLIENT_VERSION,
}
```

(c) After the `response = json.loads(response_body)` parsing (around line 184), AFTER the `id` mismatch check (line 188–192) and BEFORE the `if "error" in response:` block (line 193), insert:

```python
# Defensive: malformed plugin response could send a non-dict at the top
# level; existing id-match check above usually catches this, but make
# the assumption explicit.
assert isinstance(response, dict), \
    f"malformed JSON-RPC response (not a dict): {type(response).__name__}"

# Version handshake — bypassed for the diagnostic tool get_version so users
# on mismatched versions can still query the verdict.
if name != "get_version":
    compat.check_ruby_version(response.get("server_version"))
```

(d) Replace the existing `if "error" in response:` block (line ~193) with the -32001 remapping:

```python
if "error" in response:
    err = response["error"]
    # Promote Ruby-detected version mismatches from generic SketchUpError
    # to IncompatibleVersionError so callers can catch a single class
    # regardless of which side detected the mismatch.
    if err.get("code") == -32001:
        raise IncompatibleVersionError(err.get("message", "version mismatch"))
    raise SketchUpError(code=err.get("code"), message=err.get("message"))
```

(e) Add `"get_version"` to `_RETRY_SAFE_TOOLS` (line ~43-54):

```python
_RETRY_SAFE_TOOLS: frozenset[str] = frozenset({
    # ... existing entries ...
    "get_viewport_screenshot",
    "get_version",          # read-only diagnostic; no side effects
})
```

The placement of (c) matters: after the id-match check (so we don't validate the wrong response) and before the `error` extraction (so a -32001 from Ruby reaches caller as `IncompatibleVersionError`).

- [ ] **Step 6.4: Run tests to verify they pass**

Run via build-runner: `uv run pytest tests/test_version_handshake.py -v`
Expected: **all 6 tests green**.

- [ ] **Step 6.5: Run full Python suite — no regressions**

Run via build-runner: `uv run pytest tests/ -q`
Expected: 92 from before + 6 new = **98 passed**, 0 failed, 0 skipped.

- [ ] **Step 6.6: Commit**

```bash
git add tests/test_version_handshake.py src/sketchup_mcp/connection.py
git commit -m "feat(handshake): wire client_version outbound + server_version check inbound

* _send_once outbound: every JSON-RPC request gains client_version=
  compat.CLIENT_VERSION.
* _send_once inbound: after id-match, if name != 'get_version', call
  compat.check_ruby_version(response['server_version']) — raises
  IncompatibleVersionError on absent/out-of-range plugin.
* 6 new tests cover outbound/inbound success, mismatch raise, missing
  field raise, get_version bypass, per-response (no cache)."
```

---

## Task 7: Python `tools.py` — `get_version` MCP tool (TDD pair)

**Files:**
- Modify: `src/sketchup_mcp/tools.py`
- Create: `tests/test_version_tool.py`

- [ ] **Step 7.1: Write the failing tests**

Create `tests/test_version_tool.py`:

```python
"""Tests for the get_version MCP tool — registration, payload shape on
compatible/incompatible Ruby responses, bypass works when ordinary tools
would have raised."""
import json

import pytest

from sketchup_mcp import compat
from sketchup_mcp.app import mcp


def test_get_version_is_registered():
    # FastMCP exposes the tool registry; the exact attribute name has
    # historically been _tool_manager._tools. We use the public call_tool
    # path to be robust to internal renames.
    names = set()
    for tool in (mcp._tool_manager._tools if hasattr(mcp, "_tool_manager") else mcp._tools).values():
        names.add(tool.name if hasattr(tool, "name") else tool.fn.__name__)
    assert "get_version" in names


@pytest.mark.asyncio
async def test_get_version_compatible_payload(monkeypatch):
    """Mock the underlying _raw_call so the tool sees a Ruby response with
    matched versions; result must report compatible=true, error=None."""
    from sketchup_mcp import tools

    async def fake_raw_call(ctx, tool_name, /, **kwargs):
        assert tool_name == "get_version"
        return {
            "content": [{
                "type": "text",
                "text": json.dumps({
                    "ruby_version": compat.MAX_RUBY,
                    "min_compatible_python": "0.0.3",
                    "max_compatible_python": "0.0.3",
                }),
            }],
            "isError": False,
        }

    monkeypatch.setattr(tools, "_raw_call", fake_raw_call)
    result = await mcp.call_tool("get_version", {})
    # result is a list of content blocks; text content carries our JSON.
    text = result[0].text if hasattr(result[0], "text") else result[0]["text"]
    payload = json.loads(text)
    assert payload["python_version"] == compat.CLIENT_VERSION
    assert payload["ruby_version"] == compat.MAX_RUBY
    assert payload["compatible"] is True
    assert payload["error"] is None
    assert payload["min_compatible_ruby"] == compat.MIN_RUBY
    assert payload["max_compatible_ruby"] == compat.MAX_RUBY


@pytest.mark.asyncio
async def test_get_version_incompatible_payload(monkeypatch):
    """Mock Ruby response with ruby_version outside the supported range —
    result must report compatible=false with descriptive error."""
    from sketchup_mcp import tools

    monkeypatch.setattr(compat, "MIN_RUBY", "1.0.0")
    monkeypatch.setattr(compat, "MAX_RUBY", "1.0.0")

    async def fake_raw_call(ctx, tool_name, /, **kwargs):
        return {
            "content": [{
                "type": "text",
                "text": json.dumps({
                    "ruby_version": "0.0.3",
                    "min_compatible_python": "0.0.3",
                    "max_compatible_python": "0.0.3",
                }),
            }],
            "isError": False,
        }

    monkeypatch.setattr(tools, "_raw_call", fake_raw_call)
    result = await mcp.call_tool("get_version", {})
    text = result[0].text if hasattr(result[0], "text") else result[0]["text"]
    payload = json.loads(text)
    assert payload["compatible"] is False
    assert payload["ruby_version"] == "0.0.3"
    assert "too old" in payload["error"]
    assert ".rbz" in payload["error"]


@pytest.mark.asyncio
async def test_get_version_handles_connection_error(monkeypatch):
    """If get_connection raises ConnectionError, the tool still returns a
    payload (with ruby_version=None, compatible=false)."""
    from sketchup_mcp import tools

    async def failing_raw_call(ctx, tool_name, /, **kwargs):
        raise ConnectionError("not running")

    monkeypatch.setattr(tools, "_raw_call", failing_raw_call)
    result = await mcp.call_tool("get_version", {})
    text = result[0].text if hasattr(result[0], "text") else result[0]["text"]
    payload = json.loads(text)
    assert payload["python_version"] == compat.CLIENT_VERSION
    assert payload["ruby_version"] is None
    assert payload["compatible"] is False
    assert "not running" in payload["error"].lower() or "connect" in payload["error"].lower()
```

- [ ] **Step 7.2: Run tests to verify they fail**

Run via build-runner: `uv run pytest tests/test_version_tool.py -v`
Expected: **`test_get_version_is_registered` and downstream tests fail** — the tool doesn't exist yet.

- [ ] **Step 7.3: Add `get_version` to `tools.py`**

Open `src/sketchup_mcp/tools.py`. Add the imports:

```python
from sketchup_mcp import compat
from sketchup_mcp.errors import IncompatibleVersionError, SketchUpError
```

Add the tool:

```python
@mcp.tool()
async def get_version(ctx: Context) -> str:
    """Return Python + Ruby SketchUp-MCP versions and a compatibility verdict.

    Diagnostic tool — always returns a payload even when versions are
    incompatible (ordinary tools hard-fail in that case). Use this to
    inspect the version handshake state when other tools surface
    `IncompatibleVersionError`. The result is a JSON string with fields:
    python_version, ruby_version, min_compatible_ruby, max_compatible_ruby,
    ruby_min_compatible_python, ruby_max_compatible_python,
    compatible (bool), error (string | null).
    """
    def _payload(ruby_version, ruby_min, ruby_max, compatible, error_msg):
        return json.dumps({
            "python_version": compat.CLIENT_VERSION,
            "ruby_version": ruby_version,
            "min_compatible_ruby": compat.MIN_RUBY,
            "max_compatible_ruby": compat.MAX_RUBY,
            "ruby_min_compatible_python": ruby_min,
            "ruby_max_compatible_python": ruby_max,
            "compatible": compatible,
            "error": error_msg,
        })

    try:
        raw = await _raw_call(ctx, "get_version")
    except ConnectionError as e:
        return _payload(None, None, None, False,
                        f"SketchUp not running or extension not started: {e}")
    except SketchUpError as e:
        # Covers old Ruby returning -32601 "unknown tool: get_version",
        # any other JSON-RPC error envelope. Also catches the
        # IncompatibleVersionError subclass (which inherits from
        # SketchUpError) but here name=='get_version' bypasses
        # check_ruby_version, so this branch fires only on Ruby-side
        # errors that survive the bypass.
        return _payload(None, None, None, False, str(e))

    ruby_payload = json.loads(raw["content"][0]["text"])
    ruby_version = ruby_payload.get("ruby_version")
    ruby_min = ruby_payload.get("min_compatible_python")
    ruby_max = ruby_payload.get("max_compatible_python")

    # Two-way compatibility: BOTH sides' tables must accept the counterpart.
    try:
        compat.check_ruby_version(ruby_version)
        python_accepts_ruby, py_error = True, None
    except IncompatibleVersionError as e:
        python_accepts_ruby, py_error = False, str(e)

    try:
        ruby_accepts_python = bool(
            ruby_min and ruby_max and
            compat._parse(ruby_min)
            <= compat._parse(compat.CLIENT_VERSION)
            <= compat._parse(ruby_max)
        )
    except ValueError:
        ruby_accepts_python = False

    compatible = python_accepts_ruby and ruby_accepts_python
    if py_error:
        error_msg = py_error
    elif not ruby_accepts_python:
        error_msg = (
            f"SketchUp plugin advertises Python compatibility "
            f"{ruby_min}..{ruby_max}, which excludes v{compat.CLIENT_VERSION}."
        )
    else:
        error_msg = None

    return _payload(ruby_version, ruby_min, ruby_max, compatible, error_msg)
```

- [ ] **Step 7.4: Run tests to verify they pass**

Run via build-runner: `uv run pytest tests/test_version_tool.py -v`
Expected: **all 4 tests green**.

- [ ] **Step 7.5: Run full Python suite — no regressions**

Run via build-runner: `uv run pytest tests/ -q`
Expected: 98 + 4 = **102 passed**, 0 failed, 0 skipped.

- [ ] **Step 7.6: Commit**

```bash
git add tests/test_version_tool.py src/sketchup_mcp/tools.py
git commit -m "feat(tools): add get_version MCP tool — diagnostic that always succeeds

* New @mcp.tool() get_version returning JSON string with python_version,
  ruby_version, min/max_compatible_ruby, compatible flag, descriptive
  error or null.
* Handles ConnectionError gracefully (ruby_version=None, compatible=false,
  error explains 'SketchUp not running').
* Compat verdict computed Python-side from Ruby's raw version payload
  (Ruby just returns the numbers, Python applies the table)."
```

---

## Task 8: Live smoke check step 22

**Files:**
- Modify: `examples/smoke_check.py`

- [ ] **Step 8.1: Read the current step 21 to confirm append location**

Run: `grep -n "step\|step_21\|21\." examples/smoke_check.py | head -20`
Identify the line where step 21 ends; the new step goes right after.

- [ ] **Step 8.2: Append step 22**

Open `examples/smoke_check.py`. Right after step 21 (viewport screenshot), add:

```python
# ---------------------------------------------------------------------------
# Step 22: version handshake — matched pair must report compatible=true.
# ---------------------------------------------------------------------------
print("\n[22] Version handshake")
result = await session.call_tool("get_version", {})
data = json.loads(result.content[0].text)
print(f"  python={data['python_version']} ruby={data['ruby_version']}")
print(f"  compatible={data['compatible']} error={data['error']}")
assert data["compatible"] is True, f"version mismatch: {data}"
```

If `json` is not already imported at the top of `smoke_check.py`, add `import json` to the import block (per the viewport-screenshot follow-up `883a903`, it was already hoisted).

- [ ] **Step 8.3: Commit (script only — live run is in Task 12)**

```bash
git add examples/smoke_check.py
git commit -m "test(smoke): exercise get_version handshake in step 22"
```

---

## Task 9: `docs/release.md` update — 5 places → 7 places

**Files:**
- Modify: `docs/release.md`

- [ ] **Step 9.1: Update the bump list in §1**

Open `docs/release.md`. Replace the §1 bullet list:

```
## 1. Bump version in 5 places (must match)

- `pyproject.toml` — `version = "X.Y.Z"`
- `src/sketchup_mcp/__init__.py` — `__version__ = "X.Y.Z"`
- `su_mcp/extension.json` — `"version": "X.Y.Z"`
- `su_mcp/package.rb` — `VERSION = 'X.Y.Z'`
- `su_mcp/su_mcp.rb` — `ext.version = 'X.Y.Z'`
```

with:

```
## 1. Bump version in 7 places (must match)

- `pyproject.toml` — `version = "X.Y.Z"`
- `src/sketchup_mcp/__init__.py` — `__version__ = "X.Y.Z"`
- `src/sketchup_mcp/compat.py` — `MAX_RUBY = "X.Y.Z"` (and `MIN_RUBY` only if this release breaks wire/handler contract with the previous Ruby plugin)
- `su_mcp/extension.json` — `"version": "X.Y.Z"`
- `su_mcp/package.rb` — `VERSION = 'X.Y.Z'`
- `su_mcp/su_mcp.rb` — `ext.version = 'X.Y.Z'`
- `su_mcp/su_mcp/core/compat.rb` — `SERVER_VERSION = "X.Y.Z"` and `MAX_PYTHON = "X.Y.Z"` (and `MIN_PYTHON` only if this release breaks wire/handler contract with the previous Python client)

**MIN/MAX policy:** default to bumping only `MAX_*` to the new release;
keep `MIN_*` pointing to the oldest counterpart still supported. Three
invariant tests defend against typos and forgotten bumps:
* `test_min_le_max_invariant` (Python + Ruby) — range cannot be empty.
* `test_max_ruby_matches_python_version` (Python) — Python's view of
  Ruby max must equal current `CLIENT_VERSION` at release time.
* `test_max_python_matches_ruby_version` (Ruby) — Ruby's view of Python
  max must equal plugin `SERVER_VERSION` at release time.
```

- [ ] **Step 9.2: Commit**

```bash
git add docs/release.md
git commit -m "docs(release): grow version bump list 5 → 7 places (compat.py + compat.rb)

Includes the MIN/MAX maintenance policy: bump MAX_* by default, MIN_*
only on breaking releases. Sanity invariant test_min_le_max_invariant
guards against typos."
```

---

## Task 10: `CLAUDE.md` update — Introspection row, wire-protocol constraint, architecture tables

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 10.1: Update Tool categories table — Introspection row**

Open `CLAUDE.md`. Find the "Tool categories" table. The current Introspection row is:

```
| Introspection | `get_model_info`, `list_components`, `get_component_info`, `find_components`, `list_layers`, `create_layer`, `get_selection` |
```

Append `, \`get_version\`` to the right column.

- [ ] **Step 10.2: Add Non-Obvious Constraints bullet**

Find the "Non-Obvious Constraints" section. After the existing bullet about `Mutating handlers wrap edits in model.start_operation/commit_operation`, add:

```markdown
- **Version handshake**: every JSON-RPC request carries `client_version`
  and every response carries `server_version`. Both sides hard-fail on
  mismatch (Python raises `IncompatibleVersionError`, Ruby returns
  JSON-RPC error code `-32001`; Python promotes inbound `-32001`
  envelopes to `IncompatibleVersionError` so callers catch one class).
  Notifications (no `id`) with mismatched `client_version` are logged
  WARN and silently dropped per JSON-RPC 2.0. The `get_version` tool is
  the only diagnostic bypass — it always returns a payload, even on
  mismatch, and lives in `_RETRY_SAFE_TOOLS`. Bypass is name-based:
  Python checks `name == "get_version"`; Ruby checks
  `method == "tools/call" && params.name == "get_version"` (the JSON-RPC
  `method` is never the bare tool name in this protocol).
  Compatibility ranges live in `src/sketchup_mcp/compat.py` and
  `su_mcp/su_mcp/core/compat.rb`; both use strict `\A\d+\Z` regex
  parsing.
```

- [ ] **Step 10.3: Add rows to Architecture / Python side table**

Find the "Architecture → Python side" table (currently `app.py`, `tools.py`, `prompts.py`, `connection.py`, `config.py`, `errors.py`, `server.py`). Add:

```
| `compat.py` | Single source of truth for Python↔Ruby version compatibility (MIN_RUBY, MAX_RUBY, check_ruby_version) |
```

- [ ] **Step 10.4: Add rows to Architecture / Ruby side table**

Find the "Architecture → Ruby side" table. Under `core/` subtree, add `compat.rb` to the file list:

```
| `core/` | `application.rb`, `server.rb`, `framing.rb`, `config.rb`, `compat.rb`, `logger.rb`, `errors.rb` |
```

Under `handlers/` subtree, append `system.rb` to the file list (it joins the existing handlers).

- [ ] **Step 10.5: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude-md): document version handshake + get_version tool

* Introspection row gains get_version.
* New Non-Obvious Constraints bullet on the per-message handshake.
* Architecture tables list compat.py / core/compat.rb / handlers/system.rb."
```

---

## Task 11: `README.md` update — features bullet + tool catalog entry

**Files:**
- Modify: `README.md`

- [ ] **Step 11.1: Add Features bullet**

Open `README.md`. Find the "Features" section. Add at the end of the list:

```markdown
- **Automatic Python ↔ Ruby version compatibility check** — hard-fail
  with a reinstall/upgrade hint on mismatch; `get_version` tool exposes
  the verdict for diagnostics.
```

- [ ] **Step 11.2: Add tool catalog entry**

Find the detailed Tools section. Under Introspection (or wherever introspection tools are listed), add:

```markdown
- `get_version` — returns Python + Ruby versions and a compatibility
  flag. Always succeeds even when versions are incompatible (use as a
  diagnostic when other tools fail with IncompatibleVersionError).
```

- [ ] **Step 11.3: Commit**

```bash
git add README.md
git commit -m "docs(readme): mention version handshake feature + get_version tool"
```

---

## Task 12: Final verification

**Files:** none modified — pure verification.

- [ ] **Step 12.1: Python — full test suite green**

Run via build-runner: `uv run pytest tests/ -q`
Expected: **all tests green, 0 failed, 0 skipped**. Exact count depends
on parametrize expansion; rough math: 81 baseline + ~20 compat (with
strict-shape negatives) + ~8 handshake (added `-32001` remap and
retry-safe tests) + ~5 version_tool (added unknown-tool and two-way
drift tests) ≈ **~114 expected**.

- [ ] **Step 12.2: Ruby — full test suite green**

Run via build-runner: `ruby test/run_all.rb`
Expected: prior baseline + ~14 compat + ~9 server_compat (added
`request_id` regression, notification suppression, JSON-generator
fallback tests) + ~3 system, ≈ **~26 new tests**, **0 failures**.

- [ ] **Step 12.3: Rebuild `.rbz` and reinstall in SketchUp for live verification**

```bash
cd su_mcp && ruby package.rb && cd ..
ls -la su_mcp/su_mcp_v0.0.3.rbz
```

Manual steps (the agent CANNOT do these — they require the user):
1. In SketchUp Extension Manager: uninstall the previous `su_mcp` extension and install the freshly built `.rbz`.
2. Restart SketchUp (or Plugins → MCP Server → Start Server).
3. Restart the Claude Code session so it picks up the freshly built `uv pip install -e .` Python side.

- [ ] **Step 12.4: Live smoke — direct MCP calls**

After the user confirms steps 12.3.1–3 are done, call from a fresh Claude Code session against the live MCP server:

```
get_version()
```

Expected response (a JSON string parsed by the LLM):

```json
{
  "python_version": "0.0.3",
  "ruby_version": "0.0.3",
  "min_compatible_ruby": "0.0.3",
  "max_compatible_ruby": "0.0.3",
  "compatible": true,
  "error": null
}
```

Then call any normal tool (e.g. `get_model_info()`) to verify the handshake doesn't break ordinary traffic.

- [ ] **Step 12.5: Live smoke — full smoke_check.py run**

Run from a terminal where SketchUp + plugin are running:

```bash
python examples/smoke_check.py
```

Expected: all 22 steps green, including the final `versions: python=0.0.3 ruby=0.0.3`.

- [ ] **Step 12.6: No commit — verification only.**

If everything passes, the implementation is complete and ready for the
branch-finish workflow (cleanup of design/plan docs + PR/merge — handled
in a separate session per global CLAUDE.md rule).

---

## Self-Review Checklist (already completed by author)

- [x] **Spec coverage**: every section of `2026-05-16-version-compat-check-design.md` maps to ≥1 task.
  - §5 file structure → File Structure section here.
  - §6 wire-level → Tasks 4 (Ruby outbound) + Task 6 (Python both directions).
  - §7.1 compat.py → Task 2.
  - §7.2 errors.py → Task 1.
  - §7.3 connection.py → Task 6.
  - §7.4 tools.py::get_version → Task 7.
  - §8.1 core/compat.rb → Task 3.
  - §8.2 core/server.rb → Task 4 (step 4.4).
  - §8.3 handlers/system.rb → Task 5.
  - §8.4 dispatch.rb (get_version route) → Task 5 (step 5.4).
  - §8.5 main.rb LOAD_ORDER → Task 3 (step 3.4) + Task 5 (step 5.5).
  - §9.1 Python tests → Tasks 2, 6, 7.
  - §9.2 Ruby tests → Tasks 3, 4, 5.
  - §9.3 smoke step 22 → Task 8.
  - §9.4 TDD order → Tasks are arranged in exactly that order.
  - §10 docs → Tasks 9, 10, 11.
  - §11 release plan → Task 9 covers the bump-list update; the actual bump + PR cleanup happen in a separate session.
  - §13 decisions → all reflected in code/test stubs.
  - §15 acceptance criteria → covered by Tasks 1–12.

- [x] **Placeholder scan**: no `TBD`/`TODO`/"implement later"/"add validation" wording in steps; all code is concrete.

- [x] **Type consistency**:
  - Tool name `get_version` everywhere (Python `@mcp.tool` name, Ruby dispatch case, Ruby handler method, test assertions, smoke step).
  - Constants `MIN_RUBY`, `MAX_RUBY`, `MIN_PYTHON`, `MAX_PYTHON`, `CLIENT_VERSION`, `SERVER_VERSION` spelled identically across compat.py, compat.rb, tests, and design doc.
  - Exception name `IncompatibleVersionError` consistent (Python class + Ruby StructuredError mapping via code `-32001`).
  - JSON envelope field names (`client_version`, `server_version`) match between Ruby producers and Python consumers and vice versa.

- [x] **Initial-values sanity**: all version strings start at `"0.0.3"` (matches current `__version__`); the matched-pair smoke test (`compatible=true`) holds without any bump. Release-time bump to `"0.1.0"` happens in a separate session per `docs/release.md`.

- [x] **Test count math**:
  - Python: baseline 81 + 11 (test_compat.py) + 6 (test_version_handshake.py) + 4 (test_version_tool.py) = **102 expected**.
  - Ruby: baseline 154 runs + ~13 (test_compat.rb) + 5 (test_server_compat.rb) + 3 (test_system.rb) = **~175 runs** (exact number depends on minitest's expansion of parametrized cases).
