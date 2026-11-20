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

In SketchUp: `Window → Extension Manager → Install Extension`, pick the `.rbz`, restart SketchUp. The plugin ships with `eval_ruby` — arbitrary Ruby execution inside SketchUp — **enabled by default**; uncheck **Enable Ruby evaluation** in `Extensions → MCP Server → Settings...` to close the gate.

### 2. Start the server inside SketchUp

`Extensions → MCP Server → Start Server` — by default listens on `127.0.0.1:9876`.

### 3. Copy the token

Open `Extensions → MCP Server → Settings...` and press **Copy** next to **MCP token**. The plugin made the token on its first start; every MCP client needs it to connect (see [Security model](#security-model)).

### 4. Configure your MCP client

For Claude Code / Claude Desktop, add to `.mcp.json` (or `claude_desktop_config.json`), with the token in `SKETCHUP_MCP_TOKEN`:

```json
{
  "mcpServers": {
    "sketchup": {
      "command": "uvx",
      "args": ["sketchup-mcp2"],
      "env": {
        "SKETCHUP_MCP_TOKEN": "<the token from Settings>",
        "SKETCHUP_MCP_HOST": "127.0.0.1",
        "SKETCHUP_MCP_PORT": "9876",
        "SKETCHUP_MCP_TIMEOUT": "60",
        "SKETCHUP_MCP_LOG_LEVEL": "INFO"
      }
    }
  }
}
```

`uvx` will pull `sketchup-mcp2` from [PyPI](https://pypi.org/project/sketchup-mcp2/) automatically — install [uv](https://docs.astral.sh/uv/) if you don't have it. Restart the MCP client after changing the token.

That's it. Ask Claude things like *"create a 1.2 × 0.8 m oak dining table"* and watch it happen.

## Features

### Tool catalogue

| Category | Tools |
|---|---|
| **Geometry** | `create_component` (cube / cylinder / cone / sphere), `delete_component`, `transform_component` — all dimensions in **mm**; `position` is an **absolute world** bbox-min target, for nested entities too |
| **Materials** | `set_material` — paints a group, component instance, face or edge with an existing material (by name), a named color or hex `#rrggbb` |
| **Booleans** | `boolean_operation` — union / difference / intersection |
| **Edge ops** | `chamfer_edge`, `fillet_edge` — feature edges only (seams and concave edges skipped; fillet also skips curved rims and refuses a body without straight feature edges); distance/radius in mm, segments configurable |
| **Joinery** | `create_mortise_tenon` |
| **Export** | `export_scene` — skp / obj / dae / stl / png / jpg; skp is refused for an untitled model |
| **Introspection** | `get_model_info`, `list_components`, `get_component_info`, `find_components`, `list_layers`, `create_layer`, `get_selection`, `get_version` |
| **View** | `get_viewport_screenshot` — captures the viewport as a PNG (returns an MCP `Image` + JSON metadata text block; optional `view_preset` / `style` / `zoom_extents`; **requires SketchUp 2026+**) |
| **Lifecycle** | `undo` |
| **Escape hatch** | `eval_ruby` — arbitrary Ruby inside SketchUp for anything not covered above. Enabled by default; close the gate in the Settings dialog — see [Configuration](#ruby-side-settings-dialog-inside-sketchup). |

All dimensions in **millimeters**; angles in **degrees**. Every coordinate is in **world** (model) coordinates, for nested entities and while a group is open for editing. Every entity-returning handler also responds with `bbox_mm` so the LLM can re-locate entities by bounding box if their IDs go stale after destructive ops.

Edits inside a component or group placed more than once are refused: changing one copy would change them all. `list_components` and `find_components` flag such entities `shared`, and `find_components` also matches a component's definition name.

### Capabilities

- **Multi-client support** — N concurrent MCP clients can be connected at once (e.g. Claude Desktop + a smoke-test script + your own Python notebook). Operations are still serialised on the SketchUp UI thread; frames are dispatched in a single global FIFO ordered by decode arrival.
- **Authenticated handshake** — every TCP connection begins with a JSON-RPC `hello` (the client's version and a random nonce), then `auth`. Each side proves it knows the token with an HMAC over both nonces, so the token itself never crosses the wire. The version check comes first: an incompatible pair surfaces as `IncompatibleVersionError`, a wrong token as an authentication error that says where to copy the token from; either way the socket is closed before any tool runs.
- **Atomic undo** — every mutating handler runs its edit through `Helpers::Operation.run` (one `model.start_operation`/`commit_operation`, aborted on any failure), so a single `Edit → Undo` rolls back the whole call.
- **MCP prompt `sketchup_modeling_strategy`** — surfaced in MCP-aware clients' slash menu; teaches the model project conventions (mm units, typed-tools-vs-`eval_ruby`, pitfalls like reversed `Group#subtract`).
- **Settings dialog** — `Extensions → MCP Server → Settings...` for host / port / log level and the token (Copy, Regenerate). Log level applies immediately; host/port changes prompt for a restart.

## Configuration

### Python side (env vars in `.mcp.json`)

| Variable | Default | Description |
|---|---|---|
| `SKETCHUP_MCP_TOKEN` | — | The token from the plugin's Settings (**Copy**). Required: without a well-formed one every tool answers with an instruction and no connection is opened |
| `SKETCHUP_MCP_HOST` | `127.0.0.1` | Where to connect to the SketchUp extension |
| `SKETCHUP_MCP_PORT` | `9876` | TCP port |
| `SKETCHUP_MCP_TIMEOUT` | `60` | Per-tool-call timeout (seconds); keep it well above 30 s (the default 60 is fine) — a chamfer/fillet call starts no new cut after 30 s inside SketchUp and then rolls back, and a client that gives up first can miss an edit that still commits |
| `SKETCHUP_MCP_LOG_LEVEL` | `INFO` | `DEBUG` / `INFO` / `WARN` / `ERROR` |

### Ruby side (Settings dialog inside SketchUp)

Open `Extensions → MCP Server → Settings...` to change **Host**, **Port**, **Log Level**, the **Ruby evaluation** gate, and **log-to-file** options, and to see the **MCP token**: read-only, with **Copy** and **Regenerate** (a new token; every connected client is disconnected and needs the new one). Values persist in SketchUp's preferences under section `MCPforSketchUp`. The plugin reads no settings from the environment (`export_scene` takes its temp directory from `TEMP` / `TMP`).

The Ruby side logs at **`WARN` by default**, so it stays quiet in SketchUp's shared Ruby console; any line it does print is prefixed `[MCPforSU]` with a UTC timestamp. Enable **Log to file** to mirror every line to a UTF-8 log file **in addition to** the console (`Extensions → MCP Server → Show Log` opens it). The file is written append-only — there is no automatic rotation or size cap, so rotate or clean it up yourself for long-lived sessions.

`eval_ruby` — the arbitrary-Ruby escape hatch — is **enabled by default**. Uncheck **Enable Ruby evaluation** in the Settings dialog to close the gate; the setting persists across SketchUp restarts, and re-enabling it pops a blocking confirmation spelling out the risk (arbitrary Ruby ⇒ full filesystem / network / shell access). With the gate closed, a client's `eval_ruby` call comes back as a plain message telling the user how to re-open it.

**Per-call review.** Open gate or not, the exact Ruby a client sends stays visible in your MCP client — Claude Desktop and Claude Code display every tool call's arguments and let you approve or deny each one before it runs, so you can review each snippet case by case. (That per-call prompt is skipped only if you opt out of approvals, e.g. Claude Code's `--dangerously-skip-permissions`.) This review covers only calls made through that client — see [Security model](#security-model).

> **⚠ Security warning:** binding the host to a LAN address or `0.0.0.0` lets every machine that can reach the port try to connect. A client still needs the token, but the traffic is **not encrypted**: someone on the path can read it, and change it after the handshake — `eval_ruby` calls included. See [Security model](#security-model); for multi-machine setups use the SSH tunnel described there.

## Security model

The plugin's TCP server requires a **token** from every client, on every address, loopback included. The plugin makes the token — 32 random bytes — on its first start and keeps it in a file of its own, `MCPforSketchUp\auth_token` under `%APPDATA%` (macOS: `~/Library/Application Support/MCPforSketchUp/auth_token`), written at once so that a crash cannot bring back a token you regenerated. **Settings** shows it read-only, with **Copy** and **Regenerate**; each MCP client gets it through `SKETCHUP_MCP_TOKEN`.

- **What the token protects: who can connect.** In the handshake each side proves it knows the token with an HMAC over two fresh nonces; the token itself never crosses the wire. A process without it — another user's, a machine on the LAN, a page in a browser — is refused and disconnected before any tool runs: a wrong proof gets `-32003 authentication failed`, anything but the handshake gets `-32600`. A client refuses a server that cannot prove it knows the token, so a program that took the port cannot pose as the plugin.
- **What it does not protect: the traffic.** Nothing is encrypted, and the messages after the handshake are not authenticated. Someone who can sit between the client and SketchUp can read the traffic and change it. On a network you do not trust, keep the plugin on `127.0.0.1` and use the SSH tunnel below.
- **`eval_ruby` is open to any client with the token** while **Enable Ruby evaluation** is on, which it is by default: arbitrary Ruby with full filesystem, network and shell access. Treat the token like a password.
- **Approval in your MCP client covers only calls made through that client.** Claude Desktop and Claude Code show each call's arguments before it runs; a process that has the token and talks to the socket directly bypasses that review.
- **Regenerate** when a token may have leaked: the plugin makes a new one and disconnects every client, and each needs the new token in `SKETCHUP_MCP_TOKEN` (then a restart) before it can connect again.
- **An upgrade can open the eval gate without a dialog.** It affects an install that never saved the Settings and upgrades from a `-warehouse` build (the eval-disabled variant published with 0.2.0 and 0.3.0), where `eval_ruby` shipped closed: with no stored preference the shipped default applies (`eval_ruby` is on since 0.3.1) and no confirmation appears. Open Settings once and uncheck **Enable Ruby evaluation** if you do not want it. An install where it was unchecked explicitly stays that way.
- **One machine** — the defaults: the plugin listens on `127.0.0.1`, and the client's `.mcp.json` carries the token.
- **Split host (MCP client on a Linux VM, SketchUp on Windows): tunnel instead of binding to the LAN.** Keep the plugin on `127.0.0.1` and run this on the Windows machine:
  ```bash
  ssh -N -R 9876:127.0.0.1:9876 user@linux-vm
  ```
  The MCP server on the Linux side then connects to `127.0.0.1:9876`, the default, with the token in `SKETCHUP_MCP_TOKEN`. You need the OpenSSH client on Windows (built into Windows 10/11) and `sshd` on the VM. The tunnel's VM end listens on the VM's loopback, so every process on the VM, under any user, reaches the plugin through it — and still needs the token; the tunnel also encrypts the traffic. sshd's default `GatewayPorts no` is what keeps the port off the VM's network.
- **A LAN address or `0.0.0.0` in Host** lets every machine that can reach the port try to connect: the token keeps out those without it, the traffic stays unencrypted. The Settings dialog warns about any host that is not a loopback address, and the server logs a WARN when it binds to one (in SketchUp's Ruby Console, and in the log file if you enabled it).

## Examples

Things you can ask Claude:

- *"Create a simple dining table — 1.2 × 0.8 m, 760 mm tall, oak finish"*
- *"Highlight every component smaller than 100 mm in any dimension"*
- *"Make the selected component red, then move it 100 mm up"*
- *"Export the scene as STL for 3D printing"*
- *"Build a small arts-and-crafts cabinet using `eval_ruby` with dovetails"*

For richer Ruby recipes that drive the SketchUp API directly — framed walls, gable/hip roofs, joist arrays, `follow_me` extrusions, world-space transforms, common pitfalls — see [`docs/sketchup-ruby-cookbook.md`](docs/sketchup-ruby-cookbook.md).

Working examples and load tests live in [`examples/`](examples/):

- `smoke_check.py` — 28-step end-to-end verification of every tool category (needs `SKETCHUP_MCP_TOKEN`).
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

Both scripts need the token: set `SKETCHUP_MCP_TOKEN` to the one Settings shows.

```bash
SKETCHUP_MCP_TOKEN=<token> uv run python examples/smoke_check.py          # 28-step end-to-end
SKETCHUP_MCP_TOKEN=<token> uv run python examples/smoke_multi_client.py   # concurrent multi-client
```

For a split-host setup (e.g. Linux dev box + Windows SketchUp), run the smokes on the Linux side. The file `export_scene` writes in step 18 of `smoke_check.py` then lands on the SketchUp machine, so that step only asserts that a path came back. Two ways to reach SketchUp:

- **SSH tunnel** (preferred, see [Security model](#security-model)): the host stays `127.0.0.1`, so the script cannot tell that SketchUp is remote. Run `SKETCHUP_MCP_SMOKE_REMOTE=1 uv run python examples/smoke_check.py`; without the variable step 18 looks for the export file on the Linux machine and fails. `smoke_multi_client.py` needs nothing extra.
- **LAN address**: prefix either script with `SKETCHUP_MCP_HOST=<sketchup-host>`. A non-loopback host is recognized as remote on its own. The plugin has to listen on that address, with the risks described in the Security model.

## Troubleshooting

### `SketchUp not running or extension not started: ...`

The Python MCP server connected to the configured host/port but found nothing listening. Either:

- SketchUp isn't running, or
- The extension is installed but not started — open `Extensions → MCP Server → Start Server`.

The Python server stays alive after this error; the next tool-call retries the connect.

### `SKETCHUP_MCP_TOKEN is not set`, `does not know this token`, `rejected the token`

The client has no token, a malformed one, or one the plugin does not know — it was regenerated, or copied from another SketchUp. Open `Extensions → MCP Server → Settings...`, press **Copy**, put the token into `SKETCHUP_MCP_TOKEN` in the MCP client's config, and restart the client. "Does not know this token" can also mean that something other than the plugin listens on that port.

### `IncompatibleVersionError`

One side is older than the other accepts. The message names the outdated side and the minimum version it needs:

- **Client too old** — upgrade the Python package: run `uvx sketchup-mcp2@latest` once (or `uv pip install -U sketchup-mcp2` for a pip install), then restart your MCP client. A plain `uvx sketchup-mcp2` keeps running its cached version.
- **Plugin too old** — install the latest `.rbz` from [GitHub Releases](https://github.com/zinin/sketchup-mcp2/releases).

A client or plugin that predates socket authentication counts as too old as well: the message says it "pre-dates socket authentication".

Each side declares only the oldest counterpart it works with, so being newer never fails the handshake. Releases up to 0.3.1 are the exception: they accept only a counterpart of their own version, so moving past 0.3.1 means upgrading both once. The floors live in `src/sketchup_mcp/compat.py` (`MIN_RUBY`) and `mcp_for_sketchup/mcp_for_sketchup/core/compat.rb` (`MIN_PYTHON`).

### Tool-call timeouts on long operations

Bump `SKETCHUP_MCP_TIMEOUT` in your `.mcp.json` env block. Default is 60 seconds. Keep it well above 30 s: a chamfer or fillet call starts no new cut after 30 s inside SketchUp and then rolls back, and a client that gives up sooner can walk away from an edit that still commits.

SketchUp does not learn that the client gave up. After a timed-out call that changes the model, check the model with `get_component_info` or `list_components` before retrying — a blind retry can apply the edit twice (a double chamfer). The error message says the same. Read-only calls are safe to repeat.

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

> **Why is the venv on a shared folder at all?** This bridge is typically run in an isolated VM setup — both Claude Code launched with `--dangerously-skip-permissions` and `eval_ruby` (arbitrary Ruby, full filesystem/shell access) enabled are risky enough to want a disposable VM. Typical layout: a Linux VM (Claude Code + MCP server) ↔ a Windows VM (SketchUp) connected through the SSH tunnel described in [Security model](#security-model), project on a host-shared folder — which is exactly why the `UV_PROJECT_ENVIRONMENT` note above matters.

## License

MIT — see [`LICENSE`](LICENSE).

## Credits and attribution

- Originally forked from [**mhyrr/sketchup-mcp**](https://github.com/mhyrr/sketchup-mcp). The fork diverged at v0.0.1 with a new wire protocol (4-byte length-prefix framing, JSON-RPC 2.0 envelopes), modular handler architecture, expanded introspection / joinery / edge-op tools, multi-client server with one-time `hello` handshake, MCP prompt, viewport screenshot, settings dialog, and full unit-test coverage on both Ruby and Python sides.
- Published to PyPI as [`sketchup-mcp2`](https://pypi.org/project/sketchup-mcp2/); the upstream package is `sketchup-mcp`.
- Bridge-pattern inspiration from [**ahujasid/blender-mcp**](https://github.com/ahujasid/blender-mcp).

## Contributing

Pull requests welcome. Before opening one, please run both test suites (`ruby test/run_all.rb` and `uv run pytest tests/`) and — if you've touched anything in the IO path — the live smokes against a running SketchUp.
