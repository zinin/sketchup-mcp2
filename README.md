# MCP Server for SketchUp

> Connect Claude (or any MCP-aware AI client) to SketchUp for prompt-driven 3D modeling.

Two-process bridge:

- **Python MCP server** (`sketchup-mcp2` on PyPI) — exposes typed tools to the LLM via the [Model Context Protocol](https://modelcontextprotocol.io/).
- **Ruby SketchUp extension** — runs a TCP server inside SketchUp and executes commands against the live model.

## Distribution variants

This extension ships in two `.rbz` builds from the same source — they differ in one bit, the default state of `eval_ruby`:

| Variant | Where to get it | `eval_ruby` default | Audience |
|---|---|---|---|
| **Warehouse** | SketchUp Extension Warehouse | **off** (must enable in Settings) | Trimble-vetted, general SketchUp users |
| **GitHub** | This repo's [Releases page](https://github.com/zinin/sketchup-mcp2/releases) | **on** | Developers / MCP-aware users who know what `eval_ruby` does |

If you installed from the warehouse and your MCP client tries `eval_ruby`, the call returns a message like:

> `eval_ruby is disabled. Open Plugins → MCP Server → Settings... and check 'Enable Ruby evaluation'. WARNING: this grants the MCP server arbitrary code execution including filesystem and shell access.`

That's intentional — enable it once via Settings if you trust the connected MCP client. The setting persists across SketchUp restarts.

## Quickstart

### 1. Install the SketchUp extension

Either grab the latest `.rbz` from GitHub Releases (or the Extension Warehouse) or build it from source. The build accepts `--variant=warehouse|github` (default: `warehouse`); see [Distribution variants](#distribution-variants):

```bash
gem install --user-install rubyzip
cd mcp_for_sketchup && ruby package.rb --variant=warehouse
# → mcp_for_sketchup/mcp_for_sketchup_v<version>-warehouse.rbz
# For the dev/power-user build with eval_ruby on by default:
cd mcp_for_sketchup && ruby package.rb --variant=github
# → mcp_for_sketchup/mcp_for_sketchup_v<version>-github.rbz
```

In SketchUp: `Window → Extension Manager → Install Extension`, pick the `.rbz`, restart SketchUp.

### 2. Start the server inside SketchUp

`Plugins → MCP Server → Start` — by default listens on `127.0.0.1:9876`.

### 3. Configure your MCP client

For Claude Code / Claude Desktop, add to `.mcp.json` (or `claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "sketchup": {
      "command": "uvx",
      "args": ["sketchup-mcp2"],
      "env": {
        "SKETCHUP_MCP_HOST": "127.0.0.1",
        "SKETCHUP_MCP_PORT": "9876",
        "SKETCHUP_MCP_TIMEOUT": "60",
        "SKETCHUP_MCP_LOG_LEVEL": "INFO"
      }
    }
  }
}
```

`uvx` will pull `sketchup-mcp2` from [PyPI](https://pypi.org/project/sketchup-mcp2/) automatically — install [uv](https://docs.astral.sh/uv/) if you don't have it.

That's it. Ask Claude things like *"create a 1.2 × 0.8 m oak dining table"* and watch it happen.

## Features

### Tool catalogue

| Category | Tools |
|---|---|
| **Geometry** | `create_component` (cube / cylinder / cone / sphere), `delete_component`, `transform_component` — all dimensions in **mm** |
| **Materials** | `set_material` — named colors and hex `#rrggbb` |
| **Booleans** | `boolean_operation` — union / difference / intersection |
| **Edge ops** | `chamfer_edge`, `fillet_edge` — distance/radius in mm, segments configurable |
| **Joinery** | `create_mortise_tenon`, `create_dovetail`, `create_finger_joint` |
| **Export** | `export_scene` — skp / obj / dae / stl / png / jpg |
| **Introspection** | `get_model_info`, `list_components`, `get_component_info`, `find_components`, `list_layers`, `create_layer`, `get_selection`, `get_version` |
| **View** | `get_viewport_screenshot` — captures the viewport as a PNG (returns an MCP `Image`; optional `view_preset` / `style` / `zoom_extents`; **requires SketchUp 2026+**) |
| **Lifecycle** | `undo` |
| **Escape hatch** | `eval_ruby` — arbitrary Ruby inside SketchUp for anything not covered above. **Disabled by default in the warehouse build; enable via Plugins → MCP Server → Settings...** See [Distribution variants](#distribution-variants). |

All dimensions in **millimeters**; angles in **degrees**. Every entity-returning handler also responds with `bbox_mm` so the LLM can re-locate entities by bounding box if their IDs go stale after destructive ops.

### Capabilities

- **Multi-client support** — N concurrent MCP clients can be connected at once (e.g. Claude Desktop + a smoke-test script + your own Python notebook). Operations are still serialised on the SketchUp UI thread; frames are dispatched in a single global FIFO ordered by decode arrival.
- **One-time version handshake** — every TCP connection begins with a JSON-RPC `hello` carrying `client_version`; the server validates against its supported range and replies with `server_version` + `client_id`. Incompatible pairs surface immediately as `IncompatibleVersionError` and the socket is closed.
- **Atomic undo** — every mutating handler wraps the edit in `model.start_operation`/`commit_operation`, so a single `Edit → Undo` rolls back the whole call.
- **MCP prompt `sketchup_modeling_strategy`** — surfaced in MCP-aware clients' slash menu; teaches the model project conventions (mm units, typed-tools-vs-`eval_ruby`, pitfalls like reversed `Group#subtract`).
- **Settings dialog** — `Plugins → MCP Server → Settings...` for host / port / log level. Log level applies immediately; host/port changes prompt for a restart.

## Configuration

### Python side (env vars in `.mcp.json`)

| Variable | Default | Description |
|---|---|---|
| `SKETCHUP_MCP_HOST` | `127.0.0.1` | Where to connect to the SketchUp extension |
| `SKETCHUP_MCP_PORT` | `9876` | TCP port |
| `SKETCHUP_MCP_TIMEOUT` | `60` | Per-tool-call timeout (seconds) |
| `SKETCHUP_MCP_LOG_LEVEL` | `INFO` | `DEBUG` / `INFO` / `WARN` / `ERROR` |

### Ruby side (Settings dialog inside SketchUp)

Open `Plugins → MCP Server → Settings...` to change **Host**, **Port**, and **Log Level**. Values persist in SketchUp's preferences under section `MCPforSketchUp`. No environment variables are read on the Ruby side.

> **⚠ Security warning:** binding the host to `0.0.0.0` exposes the MCP server — including `eval_ruby`, which runs arbitrary Ruby inside SketchUp — to the entire local network with **no authentication**. Use only on trusted networks (host → VM, isolated lab). For multi-machine setups consider a loopback SSH tunnel instead.

## Examples

Things you can ask Claude:

- *"Create a simple dining table — 1.2 × 0.8 m, 760 mm tall, oak finish"*
- *"Highlight every component smaller than 100 mm in any dimension"*
- *"Make the selected component red, then move it 100 mm up"*
- *"Export the scene as STL for 3D printing"*
- *"Build a small arts-and-crafts cabinet using `eval_ruby` with dovetails"*

For richer Ruby recipes that drive the SketchUp API directly — framed walls, gable/hip roofs, joist arrays, `follow_me` extrusions, world-space transforms, common pitfalls — see [`docs/sketchup-ruby-cookbook.md`](docs/sketchup-ruby-cookbook.md).

Working examples and load tests live in [`examples/`](examples/):

- `smoke_check.py` — 22-step end-to-end verification of every tool category.
- `smoke_multi_client.py` — concurrent multi-client load test.
- `arts_and_crafts_cabinet.py` — a non-trivial generative model via `eval_ruby`.
- `simple_test.py`, `simple_ruby_eval.py`, `behavior_tester.py` — minimal scaffolds.

## Architecture

```
Claude (MCP client)
   ↕  MCP (stdio)
Python MCP server  (FastMCP)               src/sketchup_mcp/
   ↕  TCP — JSON-RPC 2.0, 4-byte big-endian length-prefix framing, 64 MiB cap
Ruby SketchUp extension (server)            mcp_for_sketchup/mcp_for_sketchup/
   ↕  SketchUp Ruby API
Live SketchUp model
```

The Ruby side runs entirely on the SketchUp UI thread via `UI.start_timer` callbacks (SketchUp's Ruby is single-threaded — no native threads allowed). The Python side holds one persistent TCP socket per process and serialises tool-calls with an `asyncio.Lock`.

Source layout:

- **Python**: `src/sketchup_mcp/{tools,connection,config,compat,errors,prompts}.py`
- **Ruby**: `mcp_for_sketchup/mcp_for_sketchup/{core,handlers,helpers,ui}/`

See [`CLAUDE.md`](CLAUDE.md) for the project's working notes and non-obvious constraints (unit conversions, reversed boolean semantics, framing details, etc.).

## Development

### Python package (editable install)

```bash
uv pip install -e .
python -m sketchup_mcp          # direct
uvx sketchup-mcp2               # production-style (from PyPI)
```

### Tests

```bash
ruby test/run_all.rb             # Ruby unit tests (minitest, stdlib only)
uv run pytest tests/ -q          # Python unit tests
```

### Live smoke (requires SketchUp running with the extension started)

```bash
uv run python examples/smoke_check.py          # 22-step end-to-end
uv run python examples/smoke_multi_client.py   # concurrent multi-client
```

For a split-host setup (e.g. Linux dev box + Windows SketchUp), prefix with `SKETCHUP_MCP_HOST=<sketchup-host>`.

## Troubleshooting

### `SketchUp not running or extension not started: ...`

The Python MCP server connected to the configured host/port but found nothing listening. Either:

- SketchUp isn't running, or
- The extension is installed but not started — open `Plugins → MCP Server → Start`.

The Python server stays alive after this error; the next tool-call retries the connect.

### `IncompatibleVersionError`

Your installed `sketchup-mcp2` Python package and the `.rbz` extension are outside the supported version range. Rebuild the `.rbz` from the same commit as the Python package, or `pip install -U sketchup-mcp2`. The current supported range lives in `src/sketchup_mcp/compat.py` and `mcp_for_sketchup/mcp_for_sketchup/core/compat.rb`.

### Tool-call timeouts on long operations

Bump `SKETCHUP_MCP_TIMEOUT` in your `.mcp.json` env block. Default is 60 seconds.

### SketchUp UI freezes during big requests

Frame-decoding is capped at 50 reads × 64 KiB per client per tick (~3.2 MB) to keep the UI responsive, but a very large `eval_ruby` body or a runaway loop inside it will still freeze SketchUp until it returns. Break the work into smaller calls if you can.

## License

MIT — see [`LICENSE`](LICENSE).

## Credits and attribution

- Originally forked from [**mhyrr/sketchup-mcp**](https://github.com/mhyrr/sketchup-mcp). The fork diverged at v0.0.1 with a new wire protocol (4-byte length-prefix framing, JSON-RPC 2.0 envelopes), modular handler architecture, expanded introspection / joinery / edge-op tools, multi-client server with one-time `hello` handshake, MCP prompt, viewport screenshot, settings dialog, and full unit-test coverage on both Ruby and Python sides.
- Published to PyPI as [`sketchup-mcp2`](https://pypi.org/project/sketchup-mcp2/); the upstream package is `sketchup-mcp`.
- Bridge-pattern inspiration from [**ahujasid/blender-mcp**](https://github.com/ahujasid/blender-mcp).

## Contributing

Pull requests welcome. Before opening one, please run both test suites (`ruby test/run_all.rb` and `uv run pytest tests/`) and — if you've touched anything in the IO path — the live smokes against a running SketchUp.
