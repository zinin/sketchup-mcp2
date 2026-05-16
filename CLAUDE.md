# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

## What This Project Does

SketchupMCP bridges Claude AI and SketchUp via the Model Context Protocol (MCP). Two components:

1. **Python MCP server** (`src/sketchup_mcp/`) — receives Claude's tool calls, forwards them over TCP
2. **Ruby SketchUp extension** (`su_mcp/su_mcp/`) — TCP server inside SketchUp, executes commands against the live model

## Non-Obvious Constraints

- **Units**: SketchUp's internal Ruby API uses **inches**; all MCP tools accept and return **mm**. Convert at the boundary via `MM = 25.4`.
- **`Group#subtract` is reversed**: `A.subtract(B)` returns `B - A`. To get «target minus tool», call `tool.subtract(target)`. Verified empirically against SketchUp 2026.
- **SketchUp is single-threaded**: the Ruby extension cannot use threads; all I/O runs in `UI.start_timer` callbacks.
- **Wire protocol** (v0.0.1+): 4-byte big-endian length-prefix framing, 64 MiB cap.
- **Persistent socket**: Python server holds one TCP connection; `asyncio.Lock` serializes tool-calls. Ruby reads non-blocking inside `UI.start_timer`, capped at 50 reads per tick (~3.2 MB) to keep SketchUp's UI responsive.
- **Entity IDs**: SketchUp's `find_entity_by_id` requires Integer; cast incoming string IDs with `.to_i`.
- **Solid tools are unreliable on non-manifold geometry**: `boolean_operation` and edge ops use copy-based + sequential-per-edge workarounds.
- **`Sketchup::Model#undo` does not exist**: programmatic undo dispatches `Sketchup.send_action("editUndo:")`.
- **Request IDs round-trip**: both sides preserve the JSON-RPC `id` so async responses can be matched.
- **Mutating handlers wrap edits in `model.start_operation`/`commit_operation`** so `undo` rolls back atomically.
- **Version handshake**: every JSON-RPC request carries `client_version` and every response carries `server_version`. Both sides hard-fail on mismatch (Python raises `IncompatibleVersionError`, Ruby returns JSON-RPC error code `-32001`; Python promotes inbound `-32001` envelopes to `IncompatibleVersionError` so callers catch one class). Notifications (no `id`) with mismatched `client_version` are logged WARN and silently dropped per JSON-RPC 2.0. The `get_version` tool is the only diagnostic bypass — it always returns a payload, even on mismatch, and lives in `_RETRY_SAFE_TOOLS`. Bypass is name-based: Python checks `name == "get_version"`; Ruby checks `method == "tools/call" && params.name == "get_version"` (the JSON-RPC `method` is never the bare tool name in this protocol). Compatibility ranges live in `src/sketchup_mcp/compat.py` and `su_mcp/su_mcp/core/compat.rb`; both use strict `\A\d+\Z` regex parsing.

## Development Commands

```bash
# Install Python package (editable)
uv pip install -e .

# Run the MCP server
python -m sketchup_mcp        # direct
uvx sketchup-mcp2             # production-style (from PyPI)

# Build the SketchUp .rbz extension package — run from inside su_mcp/
cd su_mcp && ruby package.rb && cd ..

# Unit tests
ruby test/run_all.rb           # Ruby (154 runs / 354 assertions)
uv run pytest tests/ -q        # Python (81 tests)

# Live integration smoke-check (requires SketchUp running + plugin started)
python examples/smoke_check.py # 22-step end-to-end (covers all handlers)
```

Other example scripts in `examples/`: `simple_test.py`, `simple_ruby_eval.py`, `arts_and_crafts_cabinet.py`, `behavior_tester.py`.

## Configuration

**Ruby (SketchUp extension)** — settings are edited through `Plugins → MCP Server → Settings...` and persisted in SketchUp preferences under section `SU_MCP`. No ENV variables are read on the Ruby side.

| Setting | Default | Notes |
|---|---|---|
| Host | `127.0.0.1` | bind address. **⚠ Security:** `0.0.0.0` exposes the MCP server (including `eval_ruby` — arbitrary Ruby execution) to the entire local network with **no authentication**. Use only on trusted networks (host→VM, isolated lab). For multi-machine setups consider a loopback SSH tunnel instead. |
| Port | `9876` | 1..65535 |
| Log Level | `INFO` | `DEBUG` / `INFO` / `WARN` / `ERROR` |

Log-level changes apply immediately. Host/port changes prompt the user to restart the server if it is running.

**Python (MCP server invoked by Claude)** — configured through ENV in the Claude Desktop MCP config:

- `SKETCHUP_MCP_HOST` (default `127.0.0.1`) — where to connect to the SketchUp extension
- `SKETCHUP_MCP_PORT` (default `9876`)
- `SKETCHUP_MCP_TIMEOUT` (default `60` seconds)
- `SKETCHUP_MCP_LOG_LEVEL` (`DEBUG` / `INFO` / `WARN` / `ERROR`; default `INFO`)

## Architecture

```
Claude → Python MCP (FastMCP) → TCP socket :9876 → Ruby extension → SketchUp model
```

JSON-RPC 2.0 envelopes; each MCP tool is a thin Python wrapper that builds a JSON-RPC payload and sends it over the persistent socket. Ruby dispatches by method name to a handler module.

### Python side — `src/sketchup_mcp/`

| File | Role |
|---|---|
| `app.py`, `__main__.py` | FastMCP server entry point |
| `tools.py` | One MCP tool wrapper per Ruby handler (FastMCP definitions) |
| `prompts.py` | MCP prompt definitions (`sketchup_modeling_strategy`) |
| `connection.py` | Persistent TCP socket, length-prefix framing, `asyncio.Lock` |
| `config.py` | ENV-driven config |
| `errors.py` | `SketchUpError` parsed from JSON-RPC error envelopes |
| `server.py` | Legacy connection helpers (kept for compat) |
| `compat.py` | Single source of truth for Python↔Ruby version compatibility (MIN_RUBY, MAX_RUBY, check_ruby_version) |

`eval_ruby` is the escape hatch — passes arbitrary Ruby code straight through.

### Ruby side — `su_mcp/su_mcp/`

| Subtree | Role |
|---|---|
| `main.rb` (~70 lines) | Loads modules in order, registers Plugins → MCP Server menu |
| `core/` | `application.rb`, `server.rb`, `framing.rb`, `config.rb`, `compat.rb`, `logger.rb`, `errors.rb` |
| `handlers/` | One file per tool group: `dispatch.rb`, `geometry.rb`, `operations.rb`, `joints.rb`, `materials.rb`, `export.rb`, `model.rb`, `eval.rb`, `view.rb`, `system.rb` |
| `helpers/` | Shared utilities: `units.rb`, `validation.rb`, `entities.rb`, `geometry.rb` |
| `ui/` | Settings dialog: `settings_dialog.rb`, `settings_validator.rb`, `settings.html` |

All created geometry lives inside SketchUp **Groups** so it can be selected/moved/deleted as a unit.

### Tool categories

| Category | Tools |
|---|---|
| Geometry | `create_component`, `delete_component`, `transform_component` |
| Materials | `set_material` (named colors + hex `#rrggbb`) |
| Booleans | `boolean_operation` (union / difference / intersection) |
| Edge ops | `chamfer_edge`, `fillet_edge` (Ruby-side names are plural — `chamfer_edges`/`fillet_edges`) |
| Joinery | `create_mortise_tenon`, `create_dovetail`, `create_finger_joint` |
| Export | `export_scene` (skp / obj / dae / stl / png / jpg) |
| Introspection | `get_model_info`, `list_components`, `get_component_info`, `find_components`, `list_layers`, `create_layer`, `get_selection`, `get_version` |
| View | `get_viewport_screenshot` (returns MCP Image; optional view_preset/style/zoom_extents; non-destructive by default; **requires SketchUp 2026+** — see below) |
| Lifecycle | `undo` |
| Scripting | `eval_ruby` |

> **SketchUp version requirement (viewport screenshot only):** the
> `get_viewport_screenshot` tool was verified on SketchUp 2026. Only
> `Sketchup::Camera#is_2d?` is a hard floor (introduced in SU 2018); the
> behaviors of `view.camera=` (synchronous) and
> `Sketchup::RenderingOptions["RenderMode"]` (writable enum) were
> empirically confirmed on 2026 and may differ on earlier versions. Older
> SketchUp builds are not tested and not officially supported by this
> tool. All other tools target the same baseline as the rest of the plugin.

All entity-returning handlers respond `{id, name, type, bbox_mm}` so Claude can re-locate entities by bounding box if their IDs become stale after destructive operations.

## Working with eval_ruby

For recipes that drive the SketchUp Ruby API directly — walls, roofs, framing, joist arrays, follow_me extrusions, transforms, world-space conversions, common pitfalls — see [`docs/sketchup-ruby-cookbook.md`](docs/sketchup-ruby-cookbook.md).

## Project Layout

```
src/sketchup_mcp/         # Python MCP server (FastMCP, modular)
su_mcp/su_mcp/            # Ruby SketchUp extension (modular)
  ├── main.rb             # Module loader + menu registration
  ├── core/               # TCP server, dispatch, framing, config, errors, logger
  ├── handlers/           # One file per tool group
  └── helpers/            # Shared utils (units, validation, entities, geometry)
su_mcp/package.rb         # Builds the .rbz installer
examples/                 # Integration / smoke scripts
test/                     # Ruby unit tests (minitest, stdlib only)
tests/                    # Python unit tests (pytest)
docs/sketchup-ruby-cookbook.md  # eval_ruby reference snippets
pyproject.toml            # Python package config (version, deps)
LICENSE / NOTICE          # MIT license + upstream attribution
```

## MCP Prompts

The server exposes one MCP prompt — `sketchup_modeling_strategy` —
defined in `src/sketchup_mcp/prompts.py`. It teaches Claude the
project conventions (pre-flight checks, typed-tools-vs-`eval_ruby`,
millimeter/degree units, post-mutation `bbox_mm` verification, known
traps). MCP-aware clients (e.g. Claude Desktop) surface it in the
slash menu.

> **Note:** `su_mcp/su_mcp/handlers/dispatch.rb` still has a dormant
> `prompts/list → []` branch. FastMCP serves prompts Python-side and
> never forwards `prompts/*` to Ruby, so the branch is never exercised
> but left in place for safety.

## Releasing

For the step-by-step PyPI + GitHub release workflow (version bump → build → TestPyPI → PyPI → tag → release), see [`docs/release.md`](docs/release.md).
