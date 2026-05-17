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

## Notes

- `LICENSE` and `NOTICE` ship inside the wheel via `license-files` in `pyproject.toml` — no manual copying needed.
- After the first publish, swap the account-wide PyPI tokens in `~/.pypirc` for **project-scoped** ones (PyPI → Settings → API tokens → Scope: `Project: sketchup-mcp2`). Compromise of a scoped token only affects that project.
