# Design: Python ↔ Ruby version compatibility check

- **Date**: 2026-05-16
- **Status**: Draft — awaiting user review
- **Branch**: `feature/viewport-screenshot-and-prompt` (bundled with viewport-screenshot for release 0.1.0)
- **Author**: Alexander V. Zinin (with Claude Code)

## 1. Context

`sketchup-mcp2` ships as two independently-installable artifacts: a Python
package (`pyproject.toml` on PyPI) and a SketchUp Ruby extension (`.rbz`
attached to the GitHub Release). The release pipeline in `docs/release.md`
bumps version strings in five places at once, so a "matched pair" exists
in theory, but in practice the two are installed by separate user actions:

- `uv pip install --upgrade sketchup-mcp2` (Claude Desktop may also cache
  `uvx`-launched servers, so a Python upgrade isn't always immediate).
- Open SketchUp → Extension Manager → install the new `.rbz` (entirely
  manual; users routinely forget this step after a `pip` upgrade).

The two halves communicate over a JSON-RPC channel that has so far been
**version-blind**: a 0.0.3 plugin happily talks to a 0.2.0 server even
when their handler tables have diverged. Symptoms range from silent
no-ops (a tool that exists Python-side but is missing in Ruby returns a
"method not found" wrapped in some unfamiliar message) to wrong-result
geometry (a handler signature changed between versions).

This document specifies an explicit **version handshake** that gives both
sides a chance to fail fast with a user-actionable message instead of
producing confusing downstream failures.

## 2. Goals

- Add a single MCP tool `get_version` exposing the Python + Ruby
  versions and a compatibility flag, usable as a diagnostic by humans
  and LLMs even when normal tools are blocked.
- Add a per-message version channel: every JSON-RPC **request** carries
  `client_version`, every **response** carries `server_version`. Both
  fields are optional at the protocol level (so older plugins/clients
  don't crash), but the runtime treats their absence as "pre-0.1.0,
  unsupported".
- Each side maintains its own copy of a compatibility range
  (`MIN_*`, `MAX_*`). On any mismatch the side that detects it
  **hard-fails the request** — no silent continuation, no warning-only
  mode.
- The check is symmetric: Ruby refuses old Python clients exactly as
  Python refuses old `.rbz` plugins.
- Keep the design additive — no breaking changes to existing wire
  protocol, frame format, or handler dispatch.

## 3. Non-goals

- **No** semver auto-resolution (no PEP 440, no `~>` operators). Tuple
  comparison on `(major, minor, patch)` only. Versions outside that
  shape (`"0.1.0-rc1"`, `"1.0"`) are invalid input.
- **No** runtime override. If a release ships a wrong compat range, the
  fix is a patch release, not an env var.
- **No** auto-update / auto-download of the `.rbz` from the plugin
  itself.
- **No** persistent compat cache on disk. Each new TCP connection
  re-handshakes — the check is cheap (≤ 5 microseconds for tuple
  compare).
- **No** "telemetry" of seen-version pairs.

## 4. Scope and packaging

This feature ships **bundled with the viewport-screenshot feature** as
the 0.1.0 release. The user has opted to keep the work on the same
branch (`feature/viewport-screenshot-and-prompt`) so that one PR and one
PyPI/GitHub release covers both. From the release-pipeline standpoint
the two features are independent commits with independent tests; from
the user standpoint they are "what's new in 0.1.0".

## 5. High-level structure of changes

```
src/sketchup_mcp/
  compat.py             NEW — PYTHON_VERSION, MIN_RUBY, MAX_RUBY,
                        check_ruby_version(), error-message strings,
                        IncompatibleVersionError import.
  connection.py         MODIFY — every outbound payload gets
                        client_version; every inbound response triggers
                        check_ruby_version(server_version) (no cache —
                        run on every response per design discussion).
                        Bypass: get_version path tolerates mismatch.
  tools.py              MODIFY — +1 wrapper get_version (always returns
                        payload, never raises, surfaces compatible=bool
                        + descriptive error).
  errors.py             MODIFY — +1 class IncompatibleVersionError
                        (subclass of SketchUpError, JSON-RPC code -32001).

su_mcp/su_mcp/
  core/compat.rb        NEW — RUBY_VERSION, MIN_PYTHON, MAX_PYTHON,
                        check_python_version, error-message strings.
  core/server.rb        MODIFY — read client_version from every request
                        (skip check for method "get_version"); inject
                        server_version into every response envelope
                        (both success and error paths).
  handlers/system.rb    NEW — get_version handler.
  handlers/dispatch.rb  MODIFY — one new `when "get_version"` branch.
  main.rb               MODIFY — LOAD_ORDER adds `core/compat` (before
                        `core/server`) and `handlers/system` (after
                        `handlers/eval`).

tests/
  test_compat.py            NEW — version parsing + range check tests.
  test_version_handshake.py NEW — client_version outbound, server_version
                            inbound, bypass for get_version, missing-
                            version-field treated as pre-0.1.0.
  test_version_tool.py      NEW — MCP tool registration, compatible /
                            incompatible payload shape, bypass works.

test/
  test_compat.rb        NEW — version parsing + check_python_version.
  test_server.rb        NEW (or EXTEND existing dispatch test) —
                        compatible/incompatible client_version paths,
                        get_version bypass, server_version emitted on
                        every response.
  test_system.rb        NEW — get_version handler returns expected hash.

examples/
  smoke_check.py        MODIFY — +1 step (22): call get_version, assert
                        compatible=true.

docs/
  release.md            MODIFY — 5-places bump → 7-places, plus new
                        rule on MIN/MAX maintenance.
CLAUDE.md               MODIFY — add Introspection row for get_version,
                        add wire-protocol constraint note, expand
                        Architecture tables (compat.py / core/compat.rb /
                        handlers/system.rb).
README.md               MODIFY — one feature bullet + one tool catalog
                        entry.
```

## 6. Wire-level extensions

The framing layer (4-byte big-endian length prefix, 64 MiB cap) is
unchanged. Only the JSON-RPC envelope picks up two new optional fields.

### Request

```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "method": "get_model_info",
  "params": {},
  "client_version": "0.1.0"
}
```

### Response (success)

```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "result": { ... },
  "server_version": "0.1.0"
}
```

### Response (error)

```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "error": { "code": -32001, "message": "..." },
  "server_version": "0.1.0"
}
```

Both `client_version` and `server_version` are emitted on **every**
message. The per-response check is intentional (rather than first-only
caching) — it's microseconds of cost and catches the unlikely but real
case of a long-lived connection silently being re-routed to a different
SketchUp instance (e.g. socket hijack during testing).

### First-release backward-compat

When 0.1.0 ships, some users will still have the 0.0.3 `.rbz`
installed. Their plugin will not emit `server_version`; their Python
won't emit `client_version` until they `pip` upgrade. Both halves
treat the missing field as **pre-0.1.0 (unsupported)** and hard-fail
with a "reinstall" hint. This is a one-time shearline at upgrade
time — from 0.1.0 onward, both sides always emit the fields.

## 7. Python side

### 7.1 `src/sketchup_mcp/compat.py` (NEW, ~80 lines)

```python
"""Python↔Ruby version compatibility — single source of truth (Python side).

Mirrored in su_mcp/su_mcp/core/compat.rb. Both files are updated together
by docs/release.md step 1.
"""
from __future__ import annotations
from sketchup_mcp import __version__ as PYTHON_VERSION
from sketchup_mcp.errors import IncompatibleVersionError

# Bumped together with PYTHON_VERSION at release time. See docs/release.md.
MIN_RUBY = "0.1.0"
MAX_RUBY = "0.1.0"


def _parse(v: str) -> tuple[int, int, int]:
    """Parse 'X.Y.Z' → (X, Y, Z). Raise ValueError on anything else."""
    parts = v.split(".")
    if len(parts) != 3:
        raise ValueError(f"version must be 'X.Y.Z', got {v!r}")
    return tuple(int(p) for p in parts)  # int() raises ValueError on non-digit


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
            f"expected X.Y.Z (numeric)"
        )
    if rv < _parse(MIN_RUBY):
        raise IncompatibleVersionError(_msg_ruby_too_old(server_version))
    if rv > _parse(MAX_RUBY):
        raise IncompatibleVersionError(_msg_ruby_too_new(server_version))


def _msg_ruby_too_old(rv: str) -> str:
    return (
        f"SketchUp plugin v{rv} is too old for sketchup-mcp2 v{PYTHON_VERSION} "
        f"(requires v{MIN_RUBY}..v{MAX_RUBY}). "
        f"Reinstall su_mcp_v{MAX_RUBY}.rbz from the GitHub release."
    )


def _msg_ruby_too_new(rv: str) -> str:
    return (
        f"SketchUp plugin v{rv} is newer than sketchup-mcp2 v{PYTHON_VERSION} "
        f"supports (max v{MAX_RUBY}). Run: "
        f"uv pip install --upgrade sketchup-mcp2"
    )


def _msg_ruby_missing() -> str:
    return (
        f"SketchUp plugin pre-dates version-compat checking. "
        f"Reinstall su_mcp_v{MAX_RUBY}.rbz from the GitHub release."
    )
```

### 7.2 `src/sketchup_mcp/errors.py` (MODIFY)

```python
class IncompatibleVersionError(SketchUpError):
    """Raised on Python↔Ruby version mismatch (or missing handshake field).

    Maps to JSON-RPC code -32001 (sibling of StructuredError's -32000)
    so log-grep can distinguish 'version-mismatch' from 'plain server
    error'.
    """
    def __init__(self, message: str):
        super().__init__(code=-32001, message=message)
```

### 7.3 `src/sketchup_mcp/connection.py` (MODIFY)

Two surgical changes inside the existing send/recv logic — exact patch
locations identified during implementation, but the shape is:

```python
from sketchup_mcp import compat
from sketchup_mcp.errors import IncompatibleVersionError

# On outbound:
payload = {
    "jsonrpc": "2.0",
    "id": next_id(),
    "method": tool_name,
    "params": params,
    "client_version": compat.PYTHON_VERSION,   # ← NEW
}

# On inbound (after JSON parse, before returning to caller):
server_version = response.get("server_version")
if not skip_version_check:
    compat.check_ruby_version(server_version)   # raises on mismatch
```

`skip_version_check` is a new keyword on the internal `_raw_call` (default
`False`). The only caller that sets it to `True` is the `get_version`
tool wrapper — see §7.4. State on the `SketchUpConnection` instance: no
new fields, no cache (per design discussion).

### 7.4 `src/sketchup_mcp/tools.py` (MODIFY)

```python
@mcp.tool()
async def get_version(*, ctx: Context | None = None) -> dict:
    """Return Python + Ruby versions and the compatibility verdict.

    Always succeeds — on mismatch the result has compatible=false and
    error=<message>, so the LLM / user can see the problem instead of
    getting a raised error. Use this as a diagnostic when ordinary
    tools fail with IncompatibleVersionError."""
    raw = await _raw_call(ctx, "get_version", skip_version_check=True)
    # raw["content"][0]["text"] is JSON with the Ruby-side payload:
    #   { ruby_version, min_compatible_python, max_compatible_python }
    ruby_payload = json.loads(raw["content"][0]["text"])
    ruby_version = ruby_payload.get("ruby_version")
    try:
        compat.check_ruby_version(ruby_version)
        compatible = True
        error_msg = None
    except IncompatibleVersionError as e:
        compatible = False
        error_msg = str(e)
    return {
        "python_version": compat.PYTHON_VERSION,
        "ruby_version": ruby_version,
        "min_compatible_ruby": compat.MIN_RUBY,
        "max_compatible_ruby": compat.MAX_RUBY,
        "compatible": compatible,
        "error": error_msg,
    }
```

The "Ruby-side payload" is what `Handlers::System.get_version` returns
(§8.3). FastMCP serializes the dict to JSON inside the standard text
content envelope; Python re-parses it. (This mirrors how every other
typed tool round-trips structured data.)

## 8. Ruby side

### 8.1 `su_mcp/su_mcp/core/compat.rb` (NEW, ~70 lines)

```ruby
module SU_MCP
  module Core
    module Compat
      RUBY_VERSION = "0.1.0"      # ← bumped at release time
      MIN_PYTHON   = "0.1.0"
      MAX_PYTHON   = "0.1.0"

      def self.parse(v)
        raise ArgumentError, "expected X.Y.Z, got #{v.inspect}" unless v.is_a?(String)
        parts = v.split(".")
        raise ArgumentError, "expected X.Y.Z, got #{v.inspect}" unless parts.length == 3
        parts.map { |p| Integer(p) }  # raises ArgumentError on non-digit
      end

      def self.check_python_version(client_version)
        if client_version.nil?
          raise SU_MCP::Core::StructuredError.new(-32001, msg_python_missing)
        end
        begin
          cv = parse(client_version)
        rescue ArgumentError
          raise SU_MCP::Core::StructuredError.new(
            -32001, "unparseable client_version #{client_version.inspect}; expected X.Y.Z (numeric)"
          )
        end
        if cv < parse(MIN_PYTHON)
          raise SU_MCP::Core::StructuredError.new(-32001, msg_python_too_old(client_version))
        end
        if cv > parse(MAX_PYTHON)
          raise SU_MCP::Core::StructuredError.new(-32001, msg_python_too_new(client_version))
        end
      end

      def self.msg_python_too_old(cv)
        "sketchup-mcp2 v#{cv} is too old for SketchUp plugin v#{RUBY_VERSION} " \
        "(requires v#{MIN_PYTHON}..v#{MAX_PYTHON}). " \
        "Run: uv pip install --upgrade sketchup-mcp2"
      end

      def self.msg_python_too_new(cv)
        "sketchup-mcp2 v#{cv} is newer than SketchUp plugin v#{RUBY_VERSION} " \
        "supports (max v#{MAX_PYTHON}). Reinstall su_mcp_v#{MAX_PYTHON}.rbz."
      end

      def self.msg_python_missing
        "sketchup-mcp2 client pre-dates version-compat checking. " \
        "Run: uv pip install --upgrade sketchup-mcp2"
      end
    end
  end
end
```

### 8.2 `su_mcp/su_mcp/core/server.rb` (MODIFY)

In the per-request handling block (exact site located during
implementation):

```ruby
method = req["method"]
client_version = req["client_version"]

begin
  # get_version is the diagnostic escape hatch — never blocked.
  if method != "get_version"
    SU_MCP::Core::Compat.check_python_version(client_version)
  end
  result = SU_MCP::Handlers::Dispatch.call(method, req["params"])
  response = { "jsonrpc" => "2.0", "id" => req["id"], "result" => result }
rescue SU_MCP::Core::StructuredError => e
  response = {
    "jsonrpc" => "2.0",
    "id" => req["id"],
    "error" => { "code" => e.code, "message" => e.message },
  }
end

# EVERY response — success or error — carries server_version.
response["server_version"] = SU_MCP::Core::Compat::RUBY_VERSION
write_response(response)
```

### 8.3 `su_mcp/su_mcp/handlers/system.rb` (NEW)

```ruby
module SU_MCP
  module Handlers
    module System
      def self.get_version(_params)
        {
          ruby_version: SU_MCP::Core::Compat::RUBY_VERSION,
          min_compatible_python: SU_MCP::Core::Compat::MIN_PYTHON,
          max_compatible_python: SU_MCP::Core::Compat::MAX_PYTHON,
        }
      end
    end
  end
end
```

### 8.4 `su_mcp/su_mcp/handlers/dispatch.rb` (MODIFY)

One additional branch:

```ruby
when "get_version"
  Handlers::System.get_version(params)
```

### 8.5 `su_mcp/su_mcp/main.rb` (MODIFY)

`LOAD_ORDER` gains two entries:
- `"core/compat"` — before `"core/server"` (server.rb references `Compat`)
- `"handlers/system"` — after `"handlers/eval"` (or anywhere among the
  handlers; alphabetical placement is fine)

## 9. Tests

### 9.1 Python (pytest)

**`tests/test_compat.py`** (NEW)

| Test | Asserts |
|---|---|
| `test_parse_valid` | `_parse("0.1.0")` → `(0,1,0)` |
| `test_parse_invalid_raises` | `"0.1"`, `"abc"`, `"0.1.0-rc1"`, `""` → `ValueError` |
| `test_check_ruby_at_min_passes` | with `MIN=MAX="0.1.0"`, `check_ruby_version("0.1.0")` does not raise |
| `test_check_ruby_too_old_raises` | `"0.0.3"` with `MIN="0.1.0"` → `IncompatibleVersionError` with "reinstall" in message |
| `test_check_ruby_too_new_raises` | `"0.2.0"` with `MAX="0.1.0"` → raise with "uv pip install --upgrade" in message |
| `test_check_ruby_none_raises` | `None` → raise with "pre-dates" in message |
| `test_check_ruby_unparseable_raises` | `"v1"`, `"0.1.0-beta"` → raise with "unparseable" in message |
| `test_min_le_max_invariant` | sanity: `_parse(MIN_RUBY) <= _parse(MAX_RUBY)` |

**`tests/test_version_handshake.py`** (NEW)

| Test | Asserts |
|---|---|
| `test_outgoing_payload_has_client_version` | intercept send → `payload["client_version"] == compat.PYTHON_VERSION` |
| `test_compatible_server_version_no_raise` | mock Ruby response with `server_version=MAX_RUBY` → call returns normally |
| `test_incompatible_server_version_raises` | mock response with `server_version="0.0.3"` (MIN="0.1.0") → `IncompatibleVersionError` |
| `test_missing_server_version_raises` | mock response without `server_version` → raise (treated as pre-0.1.0) |
| `test_check_runs_every_response` | spy: two successive calls each invoke `check_ruby_version` (no cache) |
| `test_get_version_bypass_returns_payload_on_mismatch` | call `_raw_call(..., skip_version_check=True)` with incompatible mock response → data returned, no raise |

**`tests/test_version_tool.py`** (NEW)

| Test | Asserts |
|---|---|
| `test_get_version_registered` | tool present in FastMCP tool registry |
| `test_get_version_compatible_payload` | mock Ruby `ruby_version=MAX_RUBY` → result has `compatible=true, error=null`, plus python/ruby/min/max fields |
| `test_get_version_incompatible_payload` | mock Ruby `ruby_version="0.0.3"` → result has `compatible=false, error` containing the canonical too-old message; **no raise** |
| `test_get_version_works_when_other_tools_blocked` | env where ordinary tools raise `IncompatibleVersionError`; `get_version` still returns the payload (bypass) |

### 9.2 Ruby (minitest)

**`test/test_compat.rb`** (NEW) — symmetric to `test_compat.py`:

| Test | Asserts |
|---|---|
| `test_parse_valid` | `Compat.parse("0.1.0")` → `[0,1,0]` |
| `test_parse_invalid_raises` | `"0.1"`, `"abc"`, `""` → `ArgumentError` |
| `test_check_python_at_min_passes` | does not raise on `"0.1.0"` |
| `test_check_python_too_old_raises` | `"0.0.3"` → `StructuredError(-32001)` with "upgrade" hint |
| `test_check_python_too_new_raises` | `"0.2.0"` → raise with "reinstall" hint |
| `test_check_python_nil_raises` | `nil` → raise with "pre-dates" message |
| `test_check_python_unparseable_raises` | `"v1"` → raise with "unparseable" |
| `test_min_le_max_invariant` | `parse(MIN_PYTHON) <= parse(MAX_PYTHON)` |

**`test/test_server.rb`** (NEW or EXTEND)

| Test | Asserts |
|---|---|
| `test_request_with_valid_client_version_dispatches` | mocked request with `client_version=MIN_PYTHON`, method `get_model_info` → handler called, success response |
| `test_request_with_incompatible_client_version_returns_error` | `client_version="0.0.3"`, method `get_model_info` → response has `error.code == -32001`, handler NOT called |
| `test_get_version_bypasses_client_check` | `client_version="0.0.3"`, method `get_version` → handler called, success response (diagnostic path works on mismatched setups) |
| `test_response_carries_server_version` | every success response has `server_version == RUBY_VERSION` |
| `test_error_response_also_carries_server_version` | error response (e.g. from incompatible client_version, or from a handler raising `StructuredError`) also has `server_version` |

**`test/test_system.rb`** (NEW)

| Test | Asserts |
|---|---|
| `test_handler_returns_metadata` | `Handlers::System.get_version(nil)` → `{ruby_version: RUBY_VERSION, min_compatible_python: MIN_PYTHON, max_compatible_python: MAX_PYTHON}` |
| `test_dispatch_routes_get_version` | `Dispatch.call("get_version", nil)` invokes `Handlers::System.get_version` |

### 9.3 Live smoke — `examples/smoke_check.py`

Append step 22 (after step 21 from viewport-screenshot):

```python
# 22. Version handshake (matched pair → compatible=true)
result = await session.call_tool("get_version", {})
data = json.loads(result.content[0].text)
assert data["compatible"] is True, f"version mismatch: {data}"
print(f"versions: python={data['python_version']} ruby={data['ruby_version']}")
```

### 9.4 TDD order

1. `test_compat.py` (red) → `compat.py` (green).
2. `test_compat.rb` (red) → `core/compat.rb` (green).
3. `test_server.rb` (red) → patch `core/server.rb` request loop (green).
4. `test_version_handshake.py` + `test_system.rb` (red) →
   `handlers/system.rb` + `connection.py` updates (green).
5. `test_version_tool.py` (red) → `tools.py::get_version` (green).
6. Update `examples/smoke_check.py` step 22; run manually against live SU.

## 10. Documentation updates

- `docs/release.md` — §1 "Bump version in 5 places" → **7 places** (add
  `compat.py` and `core/compat.rb`). New rule appended: "MAX_* keys
  default to the new release; only bump MIN_* on a release that breaks
  wire/handler contract with the previous version. The pytest sanity
  test `test_min_le_max_invariant` will catch typos."
- `CLAUDE.md`:
  - **Introspection** row in Tool categories gains `get_version`.
  - **Non-Obvious Constraints**: add bullet on per-message
    `client_version` / `server_version`.
  - **Architecture → Python/Ruby tables**: add rows for `compat.py`,
    `core/compat.rb`, `handlers/system.rb`.
- `README.md`:
  - One Features bullet: "Automatic Python ↔ Ruby version
    compatibility check — hard-fail with reinstall hint on mismatch."
  - Tools catalog: one line under Introspection for `get_version`.

## 11. Release plan

The feature is bundled into the 0.1.0 release alongside
viewport-screenshot. End-to-end pipeline:

1. Implement on `feature/viewport-screenshot-and-prompt` using the TDD
   order in §9.4.
2. `uv run pytest tests/ -q` and `ruby test/run_all.rb` green.
3. Live smoke check against SketchUp.
4. Per global CLAUDE.md rule: `git rm` **both** sets of design / plan
   docs under `docs/superpowers/` (viewport-screenshot + version-compat)
   in a single cleanup commit before opening the PR.
5. Open PR to `master`.
6. After merge: bump version to `0.1.0` everywhere per the now-7-place
   list in `docs/release.md`, `uv lock`, build → twine check → TestPyPI
   verify → PyPI → tag `v0.1.0` → GitHub release. `.rbz` rebuild
   already covered there.

## 12. Out of scope (rationale)

| Idea | Why deferred |
|---|---|
| Plugin auto-update from a manifest URL | Significant trust-store + signing infrastructure; not justified by current install base. |
| Compat range stored in `extension.json` | Yet another file to bump in sync; would also require runtime JSON-parse from inside the Ruby plugin on every connect. `compat.rb` constants are simpler. |
| Soft-fail / warning-only mode | Explicitly rejected during brainstorming — hard-fail with reinstall hint is the safe default; warning-only invites silent breakage. |
| Cache the first compatible verdict on the connection | Per design discussion: check on every response. The cost is microseconds and protects against unlikely-but-real mid-session switch. |
| PEP 440 / semver_spec dependency | Tuple compare on `X.Y.Z` is sufficient; avoids pulling in another package. |
| Telemetry of mismatch events | Privacy- and dependency-cost-wise undesirable; consistent with existing project policy. |

## 13. Open decisions (resolved during brainstorming)

| Decision | Resolution |
|---|---|
| Symmetric vs client-only table | **Two identical tables**, one per side, both fail-fast independently. |
| When the check runs | **Every response** carries `server_version`; **every request** carries `client_version`. Both sides verify on every message. |
| Behavior on mismatch | **Hard fail**, blocking all tools. `get_version` is the only exception (diagnostic bypass). |
| Table shape | **(MIN, MAX) range** — two constants per side. Holes inside the range are not expressible; per-release bumps just move MAX. |
| Where in `get_version` payload `compatible` is computed | **Python side** — Ruby returns raw `ruby_version`/`min`/`max`, Python compares with its own table and emits the verdict. Avoids duplicating compat logic in runtime. |
| Cache vs always-check | **Always-check** on every response. Microseconds of cost, catches mid-session re-route. |
| Test file placement | **Separate `tests/test_version_handshake.py`** — keeps `test_connection.py` focused on transport. |
| Where the Ruby runtime version constant lives | **In `core/compat.rb`** (option A1 from brainstorming) — single hard-coded constant; no extra `version.rb` until a second consumer appears (YAGNI). |
| `get_version` handler location | **`handlers/system.rb`** — new file; concept-clean separation from model/geometry/eval. |
| Tool category for `get_version` | **Introspection** in CLAUDE.md — concept already covers meta-info queries like `get_model_info`. |
| Branch strategy | **Continue on `feature/viewport-screenshot-and-prompt`** — one bundled PR for the 0.1.0 release. |

## 14. Risks

- **First-release shearline**: existing 0.0.3 users will see a hard-fail
  the first time they run 0.1.0 Python against the 0.0.3 plugin (and
  vice versa). Mitigation: the message itself tells them exactly what
  to do ("Reinstall su_mcp_v0.1.0.rbz from the GitHub release" / "Run:
  uv pip install --upgrade sketchup-mcp2"). The release notes should
  call this out explicitly.
- **Bidirectional bumps are easy to forget**: dropping the Ruby-side
  bump while bumping Python (or vice versa) would ship a release that
  rejects itself in pre-release smoke tests. Mitigation:
  `test_min_le_max_invariant` on both sides + the live `smoke_check.py`
  step 22 + a strengthened `docs/release.md` §1 list.
- **Symmetric error messages drifting between Python and Ruby**: if
  one side updates its message wording and the other doesn't, the user
  may see different text depending on which side detects the mismatch.
  Mitigation: not a correctness risk; the unit tests on each side
  cover the canonical message strings. Drift will be caught the next
  time those tests are revisited.
- **`client_version` injection in Python `_send`**: if a developer
  introduces a second code path that sends raw payloads without going
  through the central `_raw_call`, those payloads won't carry
  `client_version` and Ruby will reject them. Mitigation: keep
  `_raw_call` as the only sender; the existing test that asserts
  `client_version` is in the outbound payload guards against
  accidental new senders losing the field (if a new path is added,
  its tests will need to assert the field too).
- **`get_version` itself depending on the dispatch path**: if a
  regression breaks the `get_version` bypass in `core/server.rb`, the
  diagnostic tool becomes unavailable exactly when it's needed most
  (mismatch). Mitigation: dedicated `test_server.rb` test
  `test_get_version_bypasses_client_check` covers this regression
  surface.

## 15. Acceptance criteria

The work is complete when:

- [ ] `get_version` is registered as an MCP tool and visible in the
      slash menu of a compliant client.
- [ ] Every JSON-RPC request from Python carries `client_version` ==
      `compat.PYTHON_VERSION`; every JSON-RPC response from Ruby carries
      `server_version` == `Core::Compat::RUBY_VERSION` (success and
      error responses alike). Verified by `test_version_handshake.py`
      (Python) and `test_server.rb` (Ruby).
- [ ] When `server_version` is outside `[MIN_RUBY, MAX_RUBY]` (or
      missing), Python raises `IncompatibleVersionError` on every tool
      call **except** `get_version`. Verified by
      `test_version_handshake.py`.
- [ ] When `client_version` is outside `[MIN_PYTHON, MAX_PYTHON]` (or
      missing), Ruby returns a JSON-RPC error with code `-32001` for
      every method **except** `get_version`. Verified by
      `test_server.rb`.
- [ ] `get_version` returns a payload with `compatible: bool` and a
      descriptive `error: string | null` field on every call regardless
      of mismatch state. Verified by `test_version_tool.py`.
- [ ] All Python tests pass (`uv run pytest tests/ -q`).
- [ ] All Ruby tests pass (`ruby test/run_all.rb`).
- [ ] `examples/smoke_check.py` step 22 reports `compatible=true`
      against a matched-pair live SketchUp instance.
- [ ] `CLAUDE.md`, `docs/release.md`, `README.md` are updated.
- [ ] Design and plan docs (both viewport-screenshot and
      version-compat-check) are removed from `docs/superpowers/`
      before the PR is opened.
