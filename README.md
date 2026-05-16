# SketchupMCP - Sketchup Model Context Protocol Integration

> Originally forked from [mhyrr/sketchup-mcp](https://github.com/mhyrr/sketchup-mcp).
> Diverged at v0.0.1 with a new wire protocol (4-byte length-prefix framing),
> modular handler architecture, expanded introspection / joinery / edge-op tools,
> and full unit-test coverage on both Ruby and Python sides.
> Published to PyPI as `sketchup-mcp2` (the original `sketchup-mcp` package is the upstream).

SketchupMCP connects Sketchup to Claude AI through the Model Context Protocol (MCP), allowing Claude to directly interact with and control Sketchup. This integration enables prompt-assisted 3D modeling, scene creation, and manipulation in Sketchup.

Big Shoutout to [Blender MCP](https://github.com/ahujasid/blender-mcp) for the inspiration and structure.

## Features

* **Two-way communication**: Connect Claude AI to Sketchup through a TCP socket connection
* **Component manipulation**: Create, modify, delete, and transform components in Sketchup
* **Material control**: Apply and modify materials and colors
* **Scene inspection**: Get detailed information about the current Sketchup scene
* **Selection handling**: Get and manipulate selected components
* **Ruby code evaluation**: Execute arbitrary Ruby code directly in SketchUp for advanced operations
* **Viewport snapshots**: `get_viewport_screenshot` returns the current viewport as an MCP `Image` for visual verification. Optional `view_preset` / `style` / `zoom_extents`; non-destructive by default.
* **Modeling-strategy prompt**: the MCP prompt `sketchup_modeling_strategy` (slash menu of MCP-aware clients) teaches Claude this project's conventions — pre-flight checks, typed-tools-vs-`eval_ruby`, millimeter units, post-mutation verification.
* **Automatic Python ↔ Ruby version compatibility check**: every JSON-RPC request/response carries `client_version`/`server_version`; both sides hard-fail with a reinstall/upgrade hint on mismatch. The `get_version` tool always returns the verdict for diagnostics, even when other tools are blocked.

## Components

The system consists of two main components:

1. **SketchUp Extension** (`su_mcp/su_mcp/`): a modular Ruby plugin that runs a TCP server inside SketchUp (`core/`, `handlers/`, `helpers/`).
2. **MCP Server** (`src/sketchup_mcp/`): a modular Python package built on FastMCP — `tools.py` exposes MCP tools, `connection.py` owns the persistent TCP socket with 4-byte length-prefix framing, `config.py` reads `SKETCHUP_MCP_*` env vars, `errors.py` surfaces structured Ruby errors.

## Installation

### Python Packaging

We're using uv so you'll need to ```brew install uv```

### Sketchup Extension

1. Download or build the latest `.rbz` file (see «Building the `.rbz` from source» below)
2. In Sketchup, go to Window > Extension Manager
3. Click "Install Extension" and select the downloaded `.rbz` file
4. Restart Sketchup

#### Building the `.rbz` from source

The packager (`su_mcp/package.rb`) depends on the `rubyzip` gem. Install it once:

```bash
gem install --user-install rubyzip
```

Then build:

```bash
cd su_mcp && ruby package.rb
```

The resulting `su_mcp_v<version>.rbz` lands in `su_mcp/`.

## Usage

### Starting the Connection

1. In Sketchup, go to Extensions > SketchupMCP > Start Server
2. The server will start on the default port (9876)
3. Make sure the MCP server is running in your terminal

### Using with Claude

Configure Claude to use the MCP server by adding the following to your Claude configuration:

```json
    "mcpServers": {
        "sketchup": {
            "command": "uvx",
            "args": [
                "sketchup-mcp2"
            ]
        }
    }
```

This will pull the [latest from PyPI](https://pypi.org/project/sketchup-mcp2/)

Once connected, Claude can interact with Sketchup using the following capabilities:

#### Tools

Geometry & transforms:
* `create_component` — Create a cube/cylinder/cone/sphere with specified dimensions (mm)
* `delete_component` — Remove a component from the scene
* `transform_component` — Move/rotate/scale a component (translation in mm)
* `set_material` — Apply named or hex (`#rrggbb`) colors to a component
* `export_scene` — Export to skp/obj/dae/stl/png/jpg

Booleans & edge ops:
* `boolean_operation` — Union/difference/intersection on two solids
* `chamfer_edge` — Chamfer all edges of a group/component (distance in mm)
* `fillet_edge` — Fillet (round) all edges (radius in mm, segments configurable)

Joinery:
* `create_mortise_tenon`, `create_dovetail`, `create_finger_joint` — Woodworking joints (dimensions in mm)

Introspection:
* `get_model_info` — Path, title, units, bbox of the active model
* `list_components` — Tree of groups/components with bboxes (recursive, max_depth)
* `get_component_info` — Details about one entity by id
* `find_components` — Search by name/type/layer
* `list_layers`, `create_layer` — Layer/tag management
* `get_selection` — IDs and metadata of currently selected entities
* `get_version` — Python + Ruby versions and a compatibility verdict; always succeeds even when other tools fail with `IncompatibleVersionError`
* `undo` — Roll back the last operation

Visual:
* `get_viewport_screenshot` — Capture the current viewport as a PNG (returns an MCP Image; optional `view_preset` / `style` / `zoom_extents`; requires SketchUp 2026+)

Escape hatch:
* `eval_ruby` — Execute arbitrary Ruby code in SketchUp for anything not covered above

### Example Commands

Here are some examples of what you can ask Claude to do:

* "Create a simple house model with a roof and windows"
* "Select all components and get their information"
* "Make the selected component red"
* "Move the selected component 10 units up"
* "Export the current scene as a 3D model"
* "Create a complex arts and crafts cabinet using Ruby code"

## Troubleshooting

* **Connection issues**: Make sure both the Sketchup extension server and the MCP server are running
* **Command failures**: Check the Ruby Console in Sketchup for error messages
* **Timeout errors**: Try simplifying your requests or breaking them into smaller steps

## Technical Details

### Communication Protocol

The system uses a simple JSON-based protocol over TCP sockets:

* **Commands** are sent as JSON objects with a `type` and optional `params`
* **Responses** are JSON objects with a `status` and `result` or `message`

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT

## MCP Configuration

Add to your `.mcp.json` (Claude Code) or equivalent client config:

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

Manual start (no MCP client):

```bash
uvx sketchup-mcp2
```

## Complex Scenarios

For working with full SketchUp models (walls, roofs, framing, joinery) via
`eval_ruby`, see the detailed Ruby snippets in
[`docs/sketchup-ruby-cookbook.md`](docs/sketchup-ruby-cookbook.md):

- «Inspect the open model» — query path, layers, bounding box.
- «Create geometry — reliable make_box helper» — `face.normal.z` safe extrusion.
- «Framed wall (studs + plates)» — full wall section.
- «Wall with opening» — coplanar-face hole punching.
- «Gable / hip roof» — manual triangle construction.
- «follow_me — profile along a path» — mauerlat around perimeter.
- «Common pitfalls» — including the `Group#subtract` reversed-semantics gotcha.

## Troubleshooting

### `SketchUp not running or extension not started: ...`

The Python MCP server tried to connect on port 9876 but found nothing listening.
Either:
- SketchUp is not running, or
- The MCP plugin is installed but not started — open Plugins → MCP Server → Start.

The server stays alive after this error; the next tool-call will retry the connect.
