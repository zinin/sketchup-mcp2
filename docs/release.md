# Releasing a New Version

Step-by-step for the next PyPI/GitHub release. PyPI tokens live in `~/.pypirc` (chmod 600); `twine` reads them automatically.

## 1. Bump version in 5 places (must match)

- `pyproject.toml` — `version = "X.Y.Z"`
- `src/sketchup_mcp/__init__.py` — `__version__ = "X.Y.Z"`
- `su_mcp/extension.json` — `"version": "X.Y.Z"`
- `su_mcp/package.rb` — `VERSION = 'X.Y.Z'`
- `su_mcp/su_mcp.rb` — `ext.version = 'X.Y.Z'`

Commit (`chore: bump to vX.Y.Z`) and push.

## 2. Pre-flight tests

```bash
uv run pytest tests/ -q          # Python — must be green
ruby test/run_all.rb             # Ruby — must be green
```

## 3. Build artifacts

```bash
rm -rf dist/ su_mcp/*.rbz
uv build                                     # → dist/*.whl + dist/*.tar.gz
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
    sketchup-mcp2==X.Y.Z && \
  .venv/bin/python -c "import sketchup_mcp; print(sketchup_mcp.__version__)"
rm -rf /tmp/verify
```

`--extra-index-url` is required — TestPyPI doesn't host the `mcp` dependency.

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
