# Releasing a New Version

Step-by-step for the next PyPI/GitHub release. PyPI tokens live in `~/.pypirc` (chmod 600); `twine` reads them automatically.

## Breaking changes (v0.1.0)

- **Wire protocol: one-time handshake on connect.** Every TCP connection
  must now begin with a JSON-RPC `hello` request carrying
  `params.client_version`; the server replies with `server_version` and
  `client_id`. Per-request `client_version` / per-response
  `server_version` envelopes are **removed**. Old Python clients (any
  release prior to this one) lack the `hello` handshake entirely and
  the server rejects their first frame with JSON-RPC `-32600`
  (`"first method must be 'hello'"`); the client and the `.rbz` must
  be upgraded together.
- **Multi-client support.** The Ruby plugin now accepts N concurrent TCP
  clients; the previous "single-client-at-a-time" behavior is gone — a
  second concurrent connection no longer blocks until Python's
  `SKETCHUP_MCP_TIMEOUT` fires. The previous workaround (restart the
  plugin or temporarily disable the `sketchup` MCP server in Claude
  Code to run `smoke_check.py` alongside an attached MCP session) is no
  longer necessary.

## 0. Pre-flight

```bash
git fetch origin
git log --oneline origin/master..HEAD   # local-only commits ahead of remote
git status                              # tree should have no tracked-file modifications
```

If HEAD has diverged from `origin/master`, decide **rebase** vs **merge** before the bump commit.

## 1. Bump version in 7 places (must match)

- `pyproject.toml` — `version = "X.Y.Z"`
- `src/sketchup_mcp/__init__.py` — `__version__ = "X.Y.Z"`
- `src/sketchup_mcp/compat.py` — `MAX_RUBY = "X.Y.Z"` (and `MIN_RUBY` only if this release breaks wire/handler contract with the previous Ruby plugin)
- `su_mcp/extension.json` — `"version": "X.Y.Z"`
- `su_mcp/package.rb` — `VERSION = 'X.Y.Z'`
- `su_mcp/su_mcp.rb` — `ext.version = 'X.Y.Z'`
- `su_mcp/su_mcp/core/compat.rb` — `SERVER_VERSION = "X.Y.Z"` and `MAX_PYTHON = "X.Y.Z"` (and `MIN_PYTHON` only if this release breaks wire/handler contract with the previous Python client)

**MIN/MAX policy:** default to bumping only `MAX_*` to the new release; keep `MIN_*` pointing to the oldest counterpart still supported. Three invariant tests defend against typos and forgotten bumps:

* `test_min_le_max_invariant` (Python + Ruby) — range cannot be empty.
* `test_max_ruby_matches_python_version` (Python) — Python's view of Ruby max must equal current `CLIENT_VERSION` at release time.
* `test_max_python_matches_server_version` (Ruby) — Ruby's view of Python max must equal plugin `SERVER_VERSION` at release time.

Run `uv lock` to refresh `uv.lock` with the new project version (otherwise the next `uv` call updates it post-release and you end up with a stray `chore: sync uv.lock` commit). Commit (`chore: bump to vX.Y.Z`) and push.

## 2. Pre-flight tests

```bash
uv run pytest tests/ -q          # Python — must be green
ruby test/run_all.rb             # Ruby — must be green
```

## 3. Build artifacts

```bash
rm -rf dist/ su_mcp/*.rbz
uv build                                     # → dist/*.whl + dist/*.tar.gz
uvx twine check dist/*                       # validate metadata / README rendering
(cd su_mcp && ruby package.rb)               # → su_mcp/su_mcp_vX.Y.Z.rbz
```

`package.rb` needs the `rubyzip` gem: `gem install --user-install rubyzip`.

## 4. TestPyPI rehearsal

```bash
uvx twine upload --repository testpypi dist/*
```

Verify install in a fresh venv (the project's own `.venv` would conflict):

```bash
mkdir -p /tmp/verify && cd /tmp/verify && uv venv -q && \
  uv pip install -q --index-url https://test.pypi.org/simple/ \
    --extra-index-url https://pypi.org/simple/ \
    --index-strategy unsafe-best-match \
    sketchup-mcp2==X.Y.Z && \
  .venv/bin/python -c "import sketchup_mcp; print(sketchup_mcp.__version__)"
rm -rf /tmp/verify
```

`--extra-index-url` is required — TestPyPI doesn't host the `mcp` dependency.
`--index-strategy unsafe-best-match` is required because uv otherwise locks onto the first index that contains the package at all; once `sketchup-mcp2` exists on pypi.org, uv won't look at TestPyPI for the new version without this flag.

## 5. Production PyPI

```bash
uvx twine upload dist/*
```

**Warning:** PyPI versions are **immutable**. Once `X.Y.Z` is uploaded, it can never be re-uploaded — even after deletion. If something is broken post-upload, bump to `X.Y.(Z+1)`.

## 6. Git tag + GitHub Release

```bash
git tag vX.Y.Z -m "Release X.Y.Z" && git push origin vX.Y.Z
gh release create vX.Y.Z \
  --title "vX.Y.Z" \
  --notes "..." \
  dist/sketchup_mcp2-X.Y.Z-py3-none-any.whl \
  dist/sketchup_mcp2-X.Y.Z.tar.gz \
  su_mcp/su_mcp_vX.Y.Z.rbz
```

## 7. Extension Warehouse submission (optional, ~2–3 day review)

Submitting to SketchUp Extension Warehouse (EW) is an **independent, optional** flow on top of steps 0–6. It only makes sense for major / first releases — EW review takes 2–3 business days per submission, so don't churn it for every patch bump.

### Critical gotcha: EW rejects pre-encrypted `.rbz`

The `su_mcp_v<X.Y.Z>.rbz` produced by the **Trimble Signing Portal** (the file attached to the GitHub release) is already encrypted (`.rbe` files + `.susig`). EW rejects it on submit with:

> The following errors were found:
> • Invalid extension is encrypted

EW does its own signing + encryption server-side during review. You must upload an **unencrypted source `.rbz`** with plain `.rb` files. EW then encrypts per the "Encryption Type" form field and serves the encrypted result through the catalog.

This means a major-release ship produces **two `.rbz` artifacts** for the same version:

| Artifact | How built | Where it goes |
|---|---|---|
| `su_mcp_v<X.Y.Z>.rbz` | Trimble Signing Portal (external, manual upload) | GitHub release asset, direct downloads |
| `su_mcp_v<X.Y.Z>-ew-source.rbz` | `ruby package.rb` (local, plain) | EW submission only |

Both are gitignored (`*.rbz` in `.gitignore`).

### Build the EW-source `.rbz`

```bash
cd su_mcp

# Preserve the Trimble-signed .rbz (it's the GH release asset)
mv su_mcp_v<X.Y.Z>.rbz su_mcp_v<X.Y.Z>-signed.rbz

ruby package.rb
# → su_mcp_v<X.Y.Z>.rbz (plain, no .rbe, no .susig)

# Rename to make the role obvious; restore the signed name
mv su_mcp_v<X.Y.Z>.rbz su_mcp_v<X.Y.Z>-ew-source.rbz
mv su_mcp_v<X.Y.Z>-signed.rbz su_mcp_v<X.Y.Z>.rbz
```

Verify the plain `.rbz` is well-formed before uploading:

```bash
python3 -c "
import zipfile
z = zipfile.ZipFile('su_mcp/su_mcp_v<X.Y.Z>-ew-source.rbz')
names = sorted(z.namelist())
print('total=', len(names))
print('  .rb=',  sum(1 for n in names if n.endswith('.rb')))
print('  .rbe=', sum(1 for n in names if n.endswith('.rbe')))
print('  .susig=', sum(1 for n in names if n.endswith('.susig')))
print('root files:', [n for n in names if '/' not in n])
"
```

Expected:
- 26 plain `.rb` files (1 root `su_mcp.rb` + 25 inside `su_mcp/`).
- 1 `.html` (`su_mcp/ui/settings.html`).
- 0 `.rbe`, 0 `.susig`.
- Root files: only `['su_mcp.rb']`. No `extension.json` at root — Trimble/EW signing backend rejects "extra files at root" (see commit 839466c). `extension.json` is also **not** required by EW because the loader (`su_mcp.rb`) declares all metadata via `Sketchup::Extension.new(...)`.

### EW form values (stable — copy across releases)

Only Version Number, Release Notes, and the Description occasionally change. Everything else is one-time setup.

| Field | Value |
|---|---|
| Account / Organization | your personal developer account |
| Listing Page checkbox | ☐ off (we ship a real Extension, not a marketing page) |
| Extension Title | **MCP Server for SketchUp** |
| Extension Summary (≤120 chars) | **Connect Claude (or any MCP-aware AI client) to SketchUp for prompt-driven 3D modeling.** |
| Categories (≤3) | Developer Tools, Productivity, Woodworking |
| Version Number | matches the `.rbz` contents (e.g. `0.1.0`) |
| Encryption Type | **Encrypt** (EW encrypts server-side) |
| Mark as NVIDIA CUDA-Enabled | ☐ off |
| SketchUp Compatibility | 2024, 2025, 2026 (only versions where the plugin has been exercised; 2026 required for `get_viewport_screenshot`) |
| OS Compatibility | Windows, Mac OS X (Ruby code uses stdlib only — no platform-specific API) |
| Supported Languages | English |
| Website | https://github.com/zinin/sketchup-mcp2 |
| Promo Video | (blank — optional) |
| Keywords | `mcp`, `claude`, `ai`, `model-context-protocol`, `automation`, `developer-tools`, `llm` (5–7 strong tags) |
| Description radio | **Markdown** |
| Upload file | `su_mcp/su_mcp_v<X.Y.Z>-ew-source.rbz` (filename irrelevant — EW renames on its side) |

Naming conventions / why:
- EW dislikes "SketchUp" as the first word of the title. `<X> for SketchUp` is the convention used by most listings.
- Categories: Developer Tools (it's a dev tool), Productivity (workflow automation), Woodworking (the joinery handlers — `create_mortise_tenon`, `create_dovetail`, `create_finger_joint` — make this surprisingly niche-relevant).
- Compatibility: list what's been actually tested. Don't claim SU 2023 or below — `Sketchup::Camera#is_2d?` requires 2018+ and `RenderingOptions["RenderMode"]` behavior is not verified on older builds.

### Description template (Markdown, paste verbatim)

```markdown
# MCP Server for SketchUp

Bridge SketchUp with Claude and other MCP-aware AI clients. Drive 3D modeling, edits, materials, and exports from natural-language prompts via the [Model Context Protocol](https://modelcontextprotocol.io/).

## What it does

This extension runs a local TCP server inside SketchUp that exposes the live model to any AI assistant that speaks MCP. A companion Python package (`sketchup-mcp2` on PyPI) acts as the MCP server your AI client connects to.

**Architecture:** `Claude → Python MCP → TCP socket :9876 → Ruby extension → SketchUp model`

## Features

- **30+ typed tools** for modeling: create components, transforms, booleans (union / difference / intersection), fillet / chamfer, joinery (mortise-tenon, dovetail, finger-joint), materials, layers, selection, exports (skp / obj / dae / stl / png / jpg).
- **Multi-client TCP server** — N concurrent MCP clients can connect simultaneously; per-client error isolation.
- **`get_viewport_screenshot`** tool — captures the SketchUp viewport as a PNG (returns an MCP Image; requires SketchUp 2026+).
- **`sketchup_modeling_strategy`** MCP prompt — teaches your AI assistant project conventions; surfaced in MCP-aware clients' slash menu.
- **One-time `hello` handshake** with version compatibility check between Python client and Ruby server.
- **`eval_ruby` escape hatch** — execute arbitrary Ruby for power-user workflows.
- **Settings dialog** — Host / Port / Log Level configurable via `Plugins → MCP Server → Settings...` (persisted in SketchUp preferences).
- **Modular Ruby architecture** — clean `core / handlers / helpers / ui` separation.
- **Trimble-signed** — appears as "Signed" in Extension Manager.

## Who it's for

- Architects, designers, and woodworkers using SketchUp who want to drive modeling tasks via natural language.
- Developers building agentic AI workflows that touch 3D / CAD.
- Anyone exploring AI-assisted design.

## Quickstart

1. **Install this extension**: download the `.rbz`, install via `Window → Extension Manager → Install Extension`, restart SketchUp.
2. **Start the server** inside SketchUp: `Plugins → MCP Server → Start`.
3. **Run the Python MCP server**: `uvx sketchup-mcp2` (or `pip install sketchup-mcp2` + `python -m sketchup_mcp`).
4. **Configure your MCP client** (Claude Desktop, Claude Code, etc.) to talk to `sketchup-mcp2`.

Full Quickstart with example client configs: https://github.com/zinin/sketchup-mcp2#quickstart

## Compatibility

- **SketchUp**: 2024+ (full features including `get_viewport_screenshot` require 2026+).
- **OS**: Windows, macOS.
- **Python**: 3.10+ (for the companion MCP server).
- **AI clients**: any MCP-aware client — Claude Desktop, Claude Code, custom MCP clients.

## Source & license

- Source: https://github.com/zinin/sketchup-mcp2
- License: MIT
- PyPI: https://pypi.org/project/sketchup-mcp2/

## Security note

By default the TCP server binds to `127.0.0.1` (loopback only). If you bind it to `0.0.0.0` for cross-machine use, the MCP server — including `eval_ruby` (arbitrary Ruby execution) — is exposed to the entire local network with **no authentication**. Use only on trusted networks.
```

### Testing Instructions template (≤1000 chars, paste verbatim)

Critical: moderators don't run a Python MCP client. Keep this 100% verifiable inside SketchUp — anything that requires extra installs risks rejection because the moderator couldn't reproduce.

```text
Quick in-SketchUp test (no external client or Python needed):

1. Install the .rbz: Window → Extension Manager → Install Extension; restart SketchUp.
2. Menu: "Plugins → MCP Server" shows Start, Stop, Settings...
3. Settings: click Settings... — a dialog opens (Host=127.0.0.1, Port=9876, Log Level=INFO). Change Port to 9877, Save — closes without errors. Reopen: value persists.
4. Start: "Plugins → MCP Server → Start". Ruby Console (Window → Ruby Console) shows "[INFO] server listening on 127.0.0.1:9877". Repeated Start is idempotent.
5. Stop: "Plugins → MCP Server → Stop". Stops cleanly.

Local TCP server (loopback only — no firewall prompt) awaiting MCP-aware AI clients (e.g. Claude). Steps 1-5 cover the in-SketchUp surface; no external service or login required.

License: MIT. Source: https://github.com/zinin/sketchup-mcp2
```

### Release Notes template (≤1000 chars)

```text
v<X.Y.Z> — <one-line summary>

<2–3 line overview of what's new at the SketchUp-plugin layer specifically (multi-client, signing, new menu items, etc.) — see the GitHub release for the full PyPI/Python-side changelog>.

Features highlighted on EW (keep ≤ a screenful):
- <feature 1>
- <feature 2>

Companion Python package: `uvx sketchup-mcp2`
PyPI: https://pypi.org/project/sketchup-mcp2/<X.Y.Z>/
Source: https://github.com/zinin/sketchup-mcp2
```

### Screenshots

EW requires ≥1 screenshot. Recommended 940×470 px, `.jpg`/`.png`, max 3 MB, up to 5 images.

For this backend-only extension (no own viewport), useful captures — all takeable inside SketchUp in <1 min each, no video recording needed:

1. **Settings dialog** — `Plugins → MCP Server → Settings...` shows the only HTML UI surface (3 fields). Take with Snipping Tool / Cmd+Shift+4.
2. **`Plugins → MCP Server` menu expanded** — shows Start / Stop / Settings menu items. Proves SketchUp integration.
3. **Ruby Console after Start** — `Window → Ruby Console` then `Plugins → MCP Server → Start`. Capture the `[INFO] server listening on 127.0.0.1:9876` line.

Optional 4th (marketing hero shot): Claude Code or Claude Desktop + SketchUp viewport in split-screen with a Claude-driven build visible. ~10–15 min to set up if Claude isn't already configured against the running server.

### Submit and what happens next

Click **Submit for Review**. EW reviews in 2–3 business days.

- EW renames your uploaded file on its side (typically to `<extension_id>_<version>.rbz`) — the upload filename doesn't surface to end users.
- EW signs and encrypts the bundle using EW's key; the GitHub Releases copy stays signed by the Trimble Signing Portal under your key. Both are functionally equivalent for end users — they choose which channel to install from.

### Common rejection: "Invalid extension is encrypted"

Cause: uploaded the **signed/encrypted** `.rbz` (the one from Trimble Signing Portal) instead of the plain `-ew-source.rbz`.

Fix: re-upload `su_mcp_v<X.Y.Z>-ew-source.rbz` (plain, built by `ruby package.rb`). Keep Encryption Type = `Encrypt` — that flag controls what EW will do server-side, not what's in your upload.

## Notes

- `LICENSE` and `NOTICE` ship inside the wheel via `license-files` in `pyproject.toml` — no manual copying needed.
- After the first publish, swap the account-wide PyPI tokens in `~/.pypirc` for **project-scoped** ones (PyPI → Settings → API tokens → Scope: `Project: sketchup-mcp2`). Compromise of a scoped token only affects that project.
