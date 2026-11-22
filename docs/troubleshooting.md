# Troubleshooting

## `SketchUp not running or extension not started: ...`

The Python MCP server connected to the configured host/port but found nothing listening. Either:

- SketchUp isn't running, or
- The extension is installed but not started — open `Extensions → MCP Server → Start Server`.

The Python server stays alive after this error; the next tool-call retries the connect.

## `SKETCHUP_MCP_TOKEN is not set`, `does not know this token`, `rejected the token`

The client has no token, a malformed one, or one the plugin does not know — it was regenerated, or copied from another SketchUp. Open `Extensions → MCP Server → Settings...`, press **Copy**, put the token into `SKETCHUP_MCP_TOKEN` in the MCP client's config, and restart the client. "Does not know this token" can also mean that something other than the plugin listens on that port.

## `IncompatibleVersionError`

One side is older than the other accepts. The message names the outdated side and the minimum version it needs:

- **Client too old** — upgrade the Python package: run `uvx sketchup-mcp2@latest` once (or `uv pip install -U sketchup-mcp2` for a pip install), then restart your MCP client. A plain `uvx sketchup-mcp2` keeps running its cached version.
- **Plugin too old** — install the latest `.rbz` from [GitHub Releases](https://github.com/zinin/sketchup-mcp2/releases).

A client or plugin that predates socket authentication counts as too old as well: the message says it "pre-dates socket authentication".

Each side declares only the oldest counterpart it works with, so being newer never fails the handshake. Releases up to 0.3.1 are the exception: they accept only a counterpart of their own version, so moving past 0.3.1 means upgrading both once. The floors live in `src/sketchup_mcp/compat.py` (`MIN_RUBY`) and `mcp_for_sketchup/mcp_for_sketchup/core/compat.rb` (`MIN_PYTHON`).

## Tool-call timeouts on long operations

Bump `SKETCHUP_MCP_TIMEOUT` in your `.mcp.json` env block. Default is 60 seconds. Keep it well above 30 s: a chamfer or fillet call starts no new cut after 30 s inside SketchUp and then rolls back, and a client that gives up sooner can walk away from an edit that still commits.

SketchUp does not learn that the client gave up. After a timed-out call that changes the model, check the model with `get_component_info` or `list_components` before retrying — a blind retry can apply the edit twice (a double chamfer). The error message says the same. Read-only calls are safe to repeat.

## SketchUp UI freezes during big requests

Frame-decoding is capped at 50 reads × 64 KiB per client per tick (~3.2 MB) to keep the UI responsive, but a very large `eval_ruby` body or a runaway loop inside it will still freeze SketchUp until it returns. Break the work into smaller calls if you can.

## MCP client reports `connection timed out after 30000ms` at startup

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

The `uvx sketchup-mcp2` setup from the README isn't affected — `uvx` already keeps its environment under uv's local cache.

> **Why is the venv on a shared folder at all?** This bridge is typically run in an isolated VM setup — both Claude Code launched with `--dangerously-skip-permissions` and `eval_ruby` (arbitrary Ruby, full filesystem/shell access) enabled are risky enough to want a disposable VM. Typical layout: a Linux VM (Claude Code + MCP server) ↔ a Windows VM (SketchUp) connected through the SSH tunnel described in [README → Security model](../README.md#security-model), project on a host-shared folder — which is exactly why the `UV_PROJECT_ENVIRONMENT` note above matters.
