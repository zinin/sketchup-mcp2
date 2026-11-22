# Contributing

Pull requests are welcome. Before opening one, run both test suites (`ruby test/run_all.rb` and `uv run pytest tests/`) and — if you've touched anything in the IO path — the live smokes against a running SketchUp.

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

The Ruby side runs entirely on the SketchUp UI thread via `UI.start_timer` callbacks (SketchUp's Ruby is single-threaded — no native threads allowed). It serves several clients at once and dispatches their frames in a single global FIFO, ordered by decode arrival. The Python side holds one persistent TCP socket per process and serialises tool-calls with an `asyncio.Lock`.

Every TCP connection begins with a JSON-RPC `hello` (the client's version and a random nonce), then `auth`. Each side proves it knows the token with an HMAC over both nonces. The version check comes first, so an incompatible pair surfaces as `IncompatibleVersionError` and a wrong token as an authentication error; either way the socket is closed before any tool runs.

Source layout:

- **Python**: `src/sketchup_mcp/{tools,connection,config,compat,errors,prompts,auth}.py`
- **Ruby**: `mcp_for_sketchup/mcp_for_sketchup/{core,handlers,helpers,ui}/`

[`CLAUDE.md`](CLAUDE.md) holds the project's working notes and non-obvious constraints (unit conversions, reversed boolean semantics, framing details, etc.).

## Build the extension from source

```bash
gem install --user-install rubyzip
(cd mcp_for_sketchup && ruby package.rb)
# → mcp_for_sketchup/mcp_for_sketchup_v<version>.rbz
```

## Python package (editable install)

```bash
uv pip install -e .
python -m sketchup_mcp          # direct
uvx sketchup-mcp2               # production-style (from PyPI)
```

## Tests

```bash
ruby test/run_all.rb             # Ruby unit tests (minitest; stdlib + rubyzip for the package test)
uv run pytest tests/ -q          # Python unit tests
```

## Live smoke (requires SketchUp running with the extension started)

Both scripts need the token: set `SKETCHUP_MCP_TOKEN` to the one Settings shows.

```bash
SKETCHUP_MCP_TOKEN=<token> uv run python examples/smoke_check.py          # 28-step end-to-end
SKETCHUP_MCP_TOKEN=<token> uv run python examples/smoke_multi_client.py   # concurrent multi-client
```

For a split-host setup (e.g. Linux dev box + Windows SketchUp), run the smokes on the Linux side. The file `export_scene` writes in step 18 of `smoke_check.py` then lands on the SketchUp machine, so that step only asserts that a path came back. Two ways to reach SketchUp:

- **SSH tunnel** (preferred, see [README → Security model](README.md#security-model)): the host stays `127.0.0.1`, so the script cannot tell that SketchUp is remote. Run `SKETCHUP_MCP_SMOKE_REMOTE=1 uv run python examples/smoke_check.py`; without the variable step 18 looks for the export file on the Linux machine and fails. `smoke_multi_client.py` needs nothing extra.
- **LAN address**: prefix either script with `SKETCHUP_MCP_HOST=<sketchup-host>`. A non-loopback host is recognized as remote on its own. The plugin has to listen on that address, with the risks described in the Security model.

Unattended live checks on a Windows VM — installing a build over SSH, restarting SketchUp, real clicks in the Settings dialog — are described in [`docs/live-testing.md`](docs/live-testing.md). Releases follow [`docs/release.md`](docs/release.md).
