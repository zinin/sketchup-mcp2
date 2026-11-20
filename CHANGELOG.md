# Changelog

Both parts of the project share one version line: the MCP server (`sketchup-mcp2` on PyPI) and the SketchUp plugin (`mcp_for_sketchup_vX.Y.Z-signed.rbz` on the [GitHub Releases](https://github.com/zinin/sketchup-mcp2/releases) page). A release that ships one side leaves the other's version as it was; [`docs/release.md`](docs/release.md) describes how releases are made.

## 0.5.0 — 2026-11-21

Ships both sides. Each rejects a 0.4.x counterpart, so upgrade both once:

1. In SketchUp's Extension Manager, uninstall the old plugin, restart SketchUp, install `mcp_for_sketchup_v0.5.0-signed.rbz`, and restart again.
2. Run `uvx sketchup-mcp2@latest` once (or `uv pip install --upgrade sketchup-mcp2` for a pip install).
3. Start the server, open `Extensions → MCP Server → Settings...`, press **Copy** next to **MCP token**, and put the token into `SKETCHUP_MCP_TOKEN` in the MCP client's config. Restart the MCP client.

### Breaking

- **A token on every connection.** The plugin makes a token on its first start and accepts only clients that know it, on every address, loopback included. In the handshake each side proves it knows the token with an HMAC over fresh nonces; the token itself never crosses the wire, and the client refuses a server that cannot prove it. Without `SKETCHUP_MCP_TOKEN` every tool answers with the instruction above. See [README → Security model](README.md#security-model).
- **World coordinates everywhere.** Every `bbox_mm` and the `transform_component.position` target are in world (model) coordinates, for entities nested in groups and components too, and the same whether or not a group is open for editing. `rotation` and `scale` turn and scale about the world axes through the world box centre.
- **Edits inside shared components are refused.** A mutating tool refuses an entity inside a component or group placed more than once (`-32602`, with the number of copies and what to do), and `create_component` refuses while such a group is open. Read-only rows carry `shared`.
- **`create_dovetail` and `create_finger_joint` are withdrawn**: they built the wrong geometry. `create_mortise_tenon` builds a joint that fits two solid boards touching face to face, or refuses and says why; it never commits a half-built joint.
- **Tool arguments are strict**: an unknown argument is refused with `-32602`.
- **Tool errors are MCP error results** (`isError: true`, the same `[code] message` text) instead of exceptions.

### Added

- Settings shows the token read-only, with **Copy** and **Regenerate** (which disconnects every client). The token lives in `MCPforSketchUp/auth_token` under `%APPDATA%` (macOS: `~/Library/Application Support`), written at once, so a crash cannot bring back a token you regenerated.
- Settings and the server log warn about any host that is not loopback: other machines can connect (they need the token), and the traffic is not encrypted.
- `get_model_info.editing` lists the groups open for editing; `find_components(name=…)` also matches a component's definition name.
- `sketchup-mcp2 --version`; [`SECURITY.md`](SECURITY.md) for reporting vulnerabilities privately.

### Changed

- A compact Settings window: the server state first, Host and Port in one row, one-line warnings with **(?)** for the details, Cancel and Save always in view.
- Boolean, edge and joinery results keep the target's name, tag and material; ids still change.
- Every mutating tool is one undo step; the menu is named **Extensions** in all texts.
- The startup connect gives up after 5 s, so an MCP client starts even when SketchUp is not running.
- `get_viewport_screenshot.max_size` is at most 2000.

### Fixed

- The server stays responsive under floods and broken peers: small frames only before the handshake, per-client queue and accept caps, a write deadline that closes only a client whose socket makes no progress, and an error reply for a response that cannot be encoded.
- Log lines cannot be forged by control characters in a message, and keep only an excerpt of a peer's text.
- A server that is not the plugin cannot crash the client with a malformed handshake reply.
