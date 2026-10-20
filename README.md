# MCP Server for SketchUp

[![test](https://github.com/zinin/sketchup-mcp2/actions/workflows/test.yml/badge.svg)](https://github.com/zinin/sketchup-mcp2/actions/workflows/test.yml)

> Connect Claude (or any MCP-aware AI client) to SketchUp for prompt-driven 3D modeling.

Two-process bridge:

- **Python MCP server** (`sketchup-mcp2` on PyPI) — exposes typed tools to the LLM via the [Model Context Protocol](https://modelcontextprotocol.io/).
- **Ruby SketchUp extension** — runs a TCP server inside SketchUp and executes commands against the live model.

## Quickstart

### 1. Install the SketchUp extension

Either grab the latest `.rbz` from the [Releases page](https://github.com/zinin/sketchup-mcp2/releases) or build it from source:

```bash
gem install --user-install rubyzip
(cd mcp_for_sketchup && ruby package.rb)
# → mcp_for_sketchup/mcp_for_sketchup_v<version>.rbz
```

In SketchUp: `Window → Extension Manager → Install Extension`, pick the `.rbz`, restart SketchUp. The plugin ships with `eval_ruby` — arbitrary Ruby execution inside SketchUp — **enabled by default**; uncheck **Enable Ruby evaluation** in `Plugins → MCP Server → Settings...` to close the gate.

### 2. Start the server inside SketchUp

`Plugins → MCP Server → Start Server` — by default listens on `127.0.0.1:9876`.

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
| **Geometry** | `create_component` (cube / cylinder / cone / sphere), `delete_component`, `transform_component` — all dimensions in **mm**; `position` is an **absolute** bbox-min target |
| **Materials** | `set_material` — named colors and hex `#rrggbb` |
| **Booleans** | `boolean_operation` — union / difference / intersection |
| **Edge ops** | `chamfer_edge`, `fillet_edge` — distance/radius in mm, segments configurable |
| **Joinery** | `create_mortise_tenon`, `create_dovetail`, `create_finger_joint` |
| **Export** | `export_scene` — skp / obj / dae / stl / png / jpg |
| **Introspection** | `get_model_info`, `list_components`, `get_component_info`, `find_components`, `list_layers`, `create_layer`, `get_selection`, `get_version` |
| **View** | `get_viewport_screenshot` — captures the viewport as a PNG (returns an MCP `Image` + JSON metadata text block; optional `view_preset` / `style` / `zoom_extents`; **requires SketchUp 2026+**) |
| **Lifecycle** | `undo` |
| **Escape hatch** | `eval_ruby` — arbitrary Ruby inside SketchUp for anything not covered above. Enabled by default; close the gate in the Settings dialog — see [Configuration](#ruby-side-settings-dialog-inside-sketchup). |

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
| `SKETCHUP_MCP_TIMEOUT` | `60` | Per-tool-call timeout (seconds); keep it at 30 or more — chamfer/fillet stop themselves after 30 s inside SketchUp |
| `SKETCHUP_MCP_LOG_LEVEL` | `INFO` | `DEBUG` / `INFO` / `WARN` / `ERROR` |

### Ruby side (Settings dialog inside SketchUp)

Open `Plugins → MCP Server → Settings...` to change **Host**, **Port**, **Log Level**, the **Ruby evaluation** gate, and **log-to-file** options. Values persist in SketchUp's preferences under section `MCPforSketchUp`. No environment variables are read on the Ruby side.

The Ruby side logs at **`WARN` by default**, so it stays quiet in SketchUp's shared Ruby console; any line it does print is prefixed `[MCPforSU]` with a UTC timestamp. Enable **Log to file** to mirror every line to a UTF-8 log file **in addition to** the console (`Plugins → MCP Server → Show Log` opens it). The file is written append-only — there is no automatic rotation or size cap, so rotate or clean it up yourself for long-lived sessions.

`eval_ruby` — the arbitrary-Ruby escape hatch — is **enabled by default**. Uncheck **Enable Ruby evaluation** in the Settings dialog to close the gate; the setting persists across SketchUp restarts, and re-enabling it pops a blocking confirmation spelling out the risk (arbitrary Ruby ⇒ full filesystem / network / shell access). With the gate closed, a client's `eval_ruby` call comes back as a plain message telling the user how to re-open it.

**Per-call review.** Open gate or not, the exact Ruby a client sends stays visible in your MCP client — Claude Desktop and Claude Code display every tool call's arguments and let you approve or deny each one before it runs, so you can review each snippet case by case. (That per-call prompt is skipped only if you opt out of approvals, e.g. Claude Code's `--dangerously-skip-permissions`.)

> **⚠ Security warning:** binding the host to `0.0.0.0` exposes the MCP server — including `eval_ruby`, which runs arbitrary Ruby inside SketchUp — to the entire local network with **no authentication**. Use only on trusted networks (host → VM, isolated lab). See [Security model](#security-model); for multi-machine setups use the SSH tunnel described there.

## Security model

The plugin's TCP socket has **no authentication**. Anything that can open a connection to its port can call every tool, including `eval_ruby` (arbitrary Ruby with full filesystem, network and shell access): any process on the SketchUp machine, and other machines too when **Host** is not a loopback address.

- **Approval in your MCP client covers only calls made through that client.** Claude Desktop and Claude Code show each call's arguments before it runs; a process that talks to the socket directly bypasses that review.
- **The defaults are safe on a single-user machine.** The plugin listens on `127.0.0.1`, so only local processes can connect, and they already run with your permissions.
- **An upgrade can open the eval gate without a dialog.** If you never saved the Settings, the shipped default applies after an upgrade (`eval_ruby` is on since 0.3.1) and no confirmation appears. Open Settings once and uncheck **Enable Ruby evaluation** if you do not want it.
- **Split host (MCP client on a Linux VM, SketchUp on Windows): tunnel instead of binding to the LAN.** Keep the plugin on `127.0.0.1` and run this on the Windows machine:

  ```bash
  ssh -N -R 9876:127.0.0.1:9876 user@linux-vm
  ```

  The MCP server on the Linux side then connects to `127.0.0.1:9876`, the default. You need the OpenSSH client on Windows (built into Windows 10/11) and `sshd` on the VM.
- **Binding Host to a LAN address or `0.0.0.0` exposes `eval_ruby` to every machine that can reach the port.** The Settings dialog warns only for `0.0.0.0`-style hosts, not for an explicit LAN IP.

## Examples

Things you can ask Claude:

- *"Create a simple dining table — 1.2 × 0.8 m, 760 mm tall, oak finish"*
- *"Highlight every component smaller than 100 mm in any dimension"*
- *"Make the selected component red, then move it 100 mm up"*
- *"Export the scene as STL for 3D printing"*
- *"Build a small arts-and-crafts cabinet using `eval_ruby` with dovetails"*

For richer Ruby recipes that drive the SketchUp API directly — framed walls, gable/hip roofs, joist arrays, `follow_me` extrusions, world-space transforms, common pitfalls — see [`docs/sketchup-ruby-cookbook.md`](docs/sketchup-ruby-cookbook.md).

Working examples and load tests live in [`examples/`](examples/):

- `smoke_check.py` — 25-step end-to-end verification of every tool category.
- `smoke_multi_client.py` — concurrent multi-client load test.

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
ruby test/run_all.rb             # Ruby unit tests (minitest; stdlib + rubyzip for the package test)
uv run pytest tests/ -q          # Python unit tests
```

### Live smoke (requires SketchUp running with the extension started)

```bash
uv run python examples/smoke_check.py          # 25-step end-to-end
uv run python examples/smoke_multi_client.py   # concurrent multi-client
```

For a split-host setup (e.g. Linux dev box + Windows SketchUp), run the smokes on the Linux side. The file `export_scene` writes in step 18 of `smoke_check.py` then lands on the SketchUp machine, so that step only asserts that a path came back. Two ways to reach SketchUp:

- **SSH tunnel** (preferred, see [Security model](#security-model)): the host stays `127.0.0.1`, so the script cannot tell that SketchUp is remote. Run `SKETCHUP_MCP_SMOKE_REMOTE=1 uv run python examples/smoke_check.py`; without the variable step 18 looks for the export file on the Linux machine and fails. `smoke_multi_client.py` needs nothing extra.
- **LAN address**: prefix either script with `SKETCHUP_MCP_HOST=<sketchup-host>`. A non-loopback host is recognized as remote on its own. The plugin has to listen on that address, with the risks described in the Security model.

## Troubleshooting

### `SketchUp not running or extension not started: ...`

The Python MCP server connected to the configured host/port but found nothing listening. Either:

- SketchUp isn't running, or
- The extension is installed but not started — open `Plugins → MCP Server → Start Server`.

The Python server stays alive after this error; the next tool-call retries the connect.

### `IncompatibleVersionError`

One side is older than the other accepts. The message names the outdated side and the minimum version it needs:

- **Client too old** — upgrade the Python package: run `uvx sketchup-mcp2@latest` once (or `uv pip install -U sketchup-mcp2` for a pip install), then restart your MCP client. A plain `uvx sketchup-mcp2` keeps running its cached version.
- **Plugin too old** — install the latest `.rbz` from [GitHub Releases](https://github.com/zinin/sketchup-mcp2/releases).

Each side declares only the oldest counterpart it works with, so being newer never fails the handshake. Releases up to 0.3.1 are the exception: they accept only a counterpart of their own version, so moving past 0.3.1 means upgrading both once. The floors live in `src/sketchup_mcp/compat.py` (`MIN_RUBY`) and `mcp_for_sketchup/mcp_for_sketchup/core/compat.rb` (`MIN_PYTHON`).

### Tool-call timeouts on long operations

Bump `SKETCHUP_MCP_TIMEOUT` in your `.mcp.json` env block. Default is 60 seconds.

### SketchUp UI freezes during big requests

Frame-decoding is capped at 50 reads × 64 KiB per client per tick (~3.2 MB) to keep the UI responsive, but a very large `eval_ruby` body or a runaway loop inside it will still freeze SketchUp until it returns. Break the work into smaller calls if you can.

### MCP client reports `connection timed out after 30000ms` at startup

If the client can't connect **but SketchUp itself is reachable** (e.g. `telnet <host> 9876` succeeds), the bottleneck is the Python server's own startup, not the link to SketchUp.

The usual culprit is running the server from a source checkout whose virtual environment lives on a **slow filesystem** — VMware Shared Folders (`vmhgfs-fuse`), VirtualBox shared folders, NFS/CIFS network drives, or WSL's `/mnt/...`. Python touches hundreds of small files at startup, and importing the FastMCP dependency stack from such a filesystem can take 30 s+ — past the client's init timeout. (A quick check: `time uv run python -c "import sketchup_mcp.app"` — if that takes tens of seconds, the filesystem is the problem.)

Keep the **virtualenv on a local disk**. With `uv`, point it there via `UV_PROJECT_ENVIRONMENT` in the server's `.mcp.json` env block — the project source can stay on the shared folder (it's small, and editable installs pick up changes live); only the dependency-heavy venv needs to be local:

```json
"sketchup": {
  "command": "uv",
  "args": ["run", "--directory", "/path/to/sketchup-mcp2", "python", "-m", "sketchup_mcp"],
  "env": {
    "UV_PROJECT_ENVIRONMENT": "/home/you/.venvs/sketchup-mcp2",
    "SKETCHUP_MCP_HOST": "127.0.0.1"
  }
}
```

The `uvx sketchup-mcp2` setup shown earlier isn't affected — `uvx` already keeps its environment under uv's local cache.

> **Why is the venv on a shared folder at all?** This bridge is typically run in an isolated VM setup — both Claude Code launched with `--dangerously-skip-permissions` and `eval_ruby` (arbitrary Ruby, full filesystem/shell access) enabled are risky enough to want a disposable VM. Typical layout: a Linux VM (Claude Code + MCP server) ↔ a Windows VM (SketchUp) connected through the SSH tunnel from [Security model](#security-model), project on a host-shared folder — which is exactly why the `UV_PROJECT_ENVIRONMENT` note above matters.

## License

MIT — see [`LICENSE`](LICENSE).

## Credits and attribution

- Originally forked from [**mhyrr/sketchup-mcp**](https://github.com/mhyrr/sketchup-mcp). The fork diverged at v0.0.1 with a new wire protocol (4-byte length-prefix framing, JSON-RPC 2.0 envelopes), modular handler architecture, expanded introspection / joinery / edge-op tools, multi-client server with one-time `hello` handshake, MCP prompt, viewport screenshot, settings dialog, and full unit-test coverage on both Ruby and Python sides.
- Published to PyPI as [`sketchup-mcp2`](https://pypi.org/project/sketchup-mcp2/); the upstream package is `sketchup-mcp`.
- Bridge-pattern inspiration from [**ahujasid/blender-mcp**](https://github.com/ahujasid/blender-mcp).

## Contributing

Pull requests welcome. Before opening one, please run both test suites (`ruby test/run_all.rb` and `uv run pytest tests/`) and — if you've touched anything in the IO path — the live smokes against a running SketchUp.
