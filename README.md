# MCP Server for SketchUp

[![test](https://github.com/zinin/sketchup-mcp2/actions/workflows/test.yml/badge.svg)](https://github.com/zinin/sketchup-mcp2/actions/workflows/test.yml)

> Connect Claude (or any MCP-aware AI client) to SketchUp for prompt-driven 3D modeling.

[![Claude Code + SketchUp MCP: A Real Chimney, Brick by Brick](https://img.youtube.com/vi/drLMmd4pmNw/maxresdefault.jpg)](https://www.youtube.com/watch?v=drLMmd4pmNw)

**[Watch the demo on YouTube](https://www.youtube.com/watch?v=drLMmd4pmNw)**: from one prompt and three scanned pages of a stove-making book, Claude Code lays a brick chimney and its ceiling corbel through a frame-house ceiling, course by course, on a stove model from the internet.

The bridge has two parts:

- **Python MCP server** (`sketchup-mcp2` on [PyPI](https://pypi.org/project/sketchup-mcp2/)) gives the AI client typed tools over the [Model Context Protocol](https://modelcontextprotocol.io/).
- **SketchUp extension** (Ruby) runs a TCP server inside SketchUp and applies those tool calls to the live model.

## Quickstart

1. **Install the extension.** Download the latest `.rbz` from the [Releases page](https://github.com/zinin/sketchup-mcp2/releases), install it with `Window → Extension Manager → Install Extension`, and restart SketchUp.
2. **Start the server:** `Extensions → MCP Server → Start Server`. It listens on `127.0.0.1:9876`.
3. **Copy the token.** Open `Extensions → MCP Server → Settings...` and press **Copy** next to **MCP token**.
4. **Add the server to your MCP client.** For Claude Code or Claude Desktop, put this into `.mcp.json` (or `claude_desktop_config.json`) and restart the client:

   ```json
   {
     "mcpServers": {
       "sketchup": {
         "command": "uvx",
         "args": ["sketchup-mcp2"],
         "env": {
           "SKETCHUP_MCP_TOKEN": "<the token from Settings>"
         }
       }
     }
   }
   ```

   `uvx` fetches `sketchup-mcp2` from PyPI; install [uv](https://docs.astral.sh/uv/) if you don't have it. Other settings are in [Configuration](#configuration).

> **Note:** the extension ships with `eval_ruby` — arbitrary Ruby inside SketchUp — **enabled**. To close it, uncheck **Enable Ruby evaluation** in Settings. See [Security model](#security-model).

Then ask Claude things like:

- *"Create a simple dining table — 1.2 × 0.8 m, 760 mm tall, oak finish"*
- *"Highlight every component smaller than 100 mm in any dimension"*
- *"Make the selected component red, then move it 100 mm up"*
- *"Export the scene as STL for 3D printing"*
- *"Build a small arts-and-crafts cabinet using `eval_ruby` with dovetails"*

## Tools

| Category | Tools |
|---|---|
| **Geometry** | `create_component` (cube / cylinder / cone / sphere), `delete_component`, `transform_component` |
| **Materials** | `set_material` — a group, component instance, face or edge; a material name, a named color or `#rrggbb` |
| **Booleans** | `boolean_operation` — union / difference / intersection |
| **Edge ops** | `chamfer_edge`, `fillet_edge` |
| **Joinery** | `create_mortise_tenon` |
| **Export** | `export_scene` — skp / obj / dae / stl / png / jpg (skp needs a saved model) |
| **Introspection** | `get_model_info`, `list_components`, `get_component_info`, `find_components`, `list_layers`, `create_layer`, `get_selection`, `get_version` |
| **View** | `get_viewport_screenshot` — the viewport as an image, from a preset view if asked (**SketchUp 2026+**) |
| **Lifecycle** | `undo` |
| **Escape hatch** | `eval_ruby` — arbitrary Ruby inside SketchUp, for anything the tools above don't cover |

- Lengths are in **millimeters**, angles in **degrees**. Every position and `bbox_mm` is in **world** coordinates, for nested entities too.
- Each call is one undo step: a single **Edit → Undo** rolls back the whole call.
- Edits inside a component or group placed more than once are refused: changing one copy would change them all.
- Several MCP clients can be connected at once; their calls run one at a time on SketchUp's UI thread.
- The MCP prompt `sketchup_modeling_strategy`, in your client's slash menu, teaches the model the project's conventions and known traps.

For Ruby recipes that drive the SketchUp API directly — framed walls, roofs, joist arrays, `follow_me` extrusions — see the [cookbook](https://github.com/zinin/sketchup-mcp2/blob/master/docs/sketchup-ruby-cookbook.md).

## Configuration

**MCP server** — environment variables in the `env` block of `.mcp.json`:

| Variable | Default | Description |
|---|---|---|
| `SKETCHUP_MCP_TOKEN` | — | The token from the extension's Settings (**Copy**). Required: without it every tool answers with instructions and no connection is opened |
| `SKETCHUP_MCP_HOST` | `127.0.0.1` | Where the extension listens |
| `SKETCHUP_MCP_PORT` | `9876` | Its TCP port |
| `SKETCHUP_MCP_TIMEOUT` | `60` | Per-call timeout in seconds. Keep it well above 30: a chamfer or fillet starts no new cut after 30 s and rolls back, and a client that gives up first can miss an edit that still commits |
| `SKETCHUP_MCP_LOG_LEVEL` | `INFO` | `DEBUG` / `INFO` / `WARN` / `ERROR` |

**SketchUp extension** — `Extensions → MCP Server → Settings...`; the values persist in SketchUp's preferences.

| Setting | Default | Notes |
|---|---|---|
| Host, Port | `127.0.0.1`, `9876` | A change asks to restart the server. For a host other than loopback, see [Security model](#security-model) |
| MCP token | made on first start | Read-only, with **Copy** and **Regenerate** (a new token; every connected client is disconnected and needs it) |
| Log level | `WARN` | Applies at once. Every line in the Ruby Console starts with `[MCPforSU]` |
| Enable Ruby evaluation | on | Gates `eval_ruby`. Turning it back on asks you to confirm the risk |
| Log to file | off | Copies every line to a file (`Extensions → MCP Server → Show Log`); append-only, with no rotation |

## Security model

- **The token decides who can connect.** The extension makes it — 32 random bytes — on its first start and keeps it in `MCPforSketchUp\auth_token` under `%APPDATA%` (macOS: `~/Library/Application Support/MCPforSketchUp/auth_token`). Every client must prove it knows the token, on every address, loopback included. The proof is an HMAC over fresh nonces, so the token never crosses the wire, and a client refuses a server that cannot prove the same.
- **The traffic is not encrypted.** Someone between the client and SketchUp can read it, and change it after the handshake.
- **`eval_ruby` gives full access.** While **Enable Ruby evaluation** is on, which is the default, any client with the token can run arbitrary Ruby with full filesystem, network and shell access. Treat the token like a password.
- **Approval in your MCP client covers only that client.** Claude Code and Claude Desktop show each call's arguments, `eval_ruby` code included, before it runs, unless you skip approvals (e.g. `--dangerously-skip-permissions`). A process that has the token and talks to the socket directly bypasses that review.
- **Regenerate** the token in Settings if it may have leaked. Every client is disconnected and needs the new token in `SKETCHUP_MCP_TOKEN`, then a restart.
- **An upgrade can open the eval gate without a dialog**: on an install that never saved its Settings and upgrades from a `-warehouse` build (0.2.0 or 0.3.0, where `eval_ruby` shipped closed). Open Settings once and uncheck **Enable Ruby evaluation** if you don't want it.

**SketchUp and the MCP client on different machines:** keep the extension on `127.0.0.1` and tunnel instead of binding to the LAN. Run this on the SketchUp machine (Windows 10/11 has the OpenSSH client built in; the other machine needs `sshd`):

```bash
ssh -N -R 9876:127.0.0.1:9876 user@linux-vm
```

The MCP server on the other machine then connects to `127.0.0.1:9876`, the default, with the token in `SKETCHUP_MCP_TOKEN`. The tunnel encrypts the traffic. Its far end listens on that machine's loopback only (sshd's default `GatewayPorts no`), so every process there can reach the extension but still needs the token.

Binding the host to a LAN address or `0.0.0.0` instead lets every machine that can reach the port try to connect: the token keeps out those without it, but the traffic stays unencrypted. Settings warns about such a host, and the server logs a WARN when it binds to one.

To report a vulnerability, see [SECURITY.md](https://github.com/zinin/sketchup-mcp2/blob/master/SECURITY.md).

## Troubleshooting

[docs/troubleshooting.md](https://github.com/zinin/sketchup-mcp2/blob/master/docs/troubleshooting.md) covers the common problems: SketchUp not reachable, a missing or rejected token, `IncompatibleVersionError`, tool-call timeouts, a frozen UI on big requests, and a client that times out at startup.

## Contributing

Pull requests are welcome. [CONTRIBUTING.md](https://github.com/zinin/sketchup-mcp2/blob/master/CONTRIBUTING.md) explains how the two halves fit together, how to build the extension from source, and how to run the tests and the live smokes.

## License

MIT — see [`LICENSE`](https://github.com/zinin/sketchup-mcp2/blob/master/LICENSE).

## Credits

- Forked from [**mhyrr/sketchup-mcp**](https://github.com/mhyrr/sketchup-mcp) at v0.0.1, and since rewritten: a new wire protocol, token authentication, a multi-client server, a modular handler architecture, new tools and full test suites on both sides. It is published to PyPI as `sketchup-mcp2`; the upstream package is `sketchup-mcp`.
- Bridge-pattern inspiration from [**ahujasid/blender-mcp**](https://github.com/ahujasid/blender-mcp).
