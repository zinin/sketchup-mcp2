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

## 1. Choose the scope, then bump

Releases share one version line. Each release takes the next number — patch for fixes, minor for features and contract breaks — whether it ships the Python package, the plugin, or both. The side a release does not ship keeps its version literals, so every `vX.Y.Z` tag stays unique.

Bump only the side you ship:

- **Python** — `pyproject.toml` (`version = "X.Y.Z"`) and `src/sketchup_mcp/__init__.py` (`__version__ = "X.Y.Z"`). Then run `uv lock` to refresh `uv.lock` with the new project version; otherwise the next `uv` call updates it post-release and you end up with a stray `chore: sync uv.lock` commit.
- **Plugin** — `mcp_for_sketchup/package.rb` (`VERSION = 'X.Y.Z'`), `mcp_for_sketchup/mcp_for_sketchup.rb` (`ext.version = 'X.Y.Z'`) and `mcp_for_sketchup/mcp_for_sketchup/core/compat.rb` (`SERVER_VERSION = "X.Y.Z"`).

**Compatibility floors.** Each side declares only the oldest counterpart it works with: `MIN_RUBY` in `src/sketchup_mcp/compat.py`, `MIN_PYTHON` in `core/compat.rb`. There is no upper bound — the newer side of a pair knows what changed, so the newer side rejects the older one. Decide per release:

- A hotfix, or a feature with no new requirement, leaves both floors alone.
- When one side starts to need a newer counterpart — say, a new Python tool calls a new Ruby handler — raise that side's floor to the first counterpart version that has what it needs.
- A contract break (an existing message changes meaning or shape) ships both sides, and both floors rise to this release's version. Forget a floor here and an incompatible pair passes the handshake: the older side cannot stop it.

`tests/test_compat.py::test_in_repo_pair_is_compatible` checks that the client and the plugin in the same commit accept each other.

**Contract break of v0.3.0 (2026-07-02; batches 1+2, branch `fix/deep-review-p2`):** `transform_component.position` switched from a relative offset to an absolute bbox-min target (`feat!`, commit `6b7d133`), so an old/new client–server mix would pass the handshake but silently misplace geometry. Batch 2 widened the break with new tool parameters, stricter validation and changed response shapes. v0.3.0 raised both floors to `0.3.0`.

**Releases up to 0.3.1 cap the counterpart at their own version.** An installed 0.3.0 plugin accepts only a 0.3.0 client, a 0.3.1 plugin accepts 0.3.0–0.3.1, and the 0.3.x clients mirror this. Every later release looks too new to them, so the first release after 0.3.1 must ship both sides and raise both floors to its own version. No 0.3.x counterpart can pair with it anyway, and the raised `MIN_PYTHON` makes the new plugin reject a 0.3.x client itself, with the `uvx sketchup-mcp2@latest` hint, instead of leaving the 0.3.x client to print its own `uv pip install --upgrade` advice, which does not refresh a `uvx` install. `tests/test_compat.py::test_first_release_past_0_3_1_raises_floors` fails until both floors move; together with `test_in_repo_pair_is_compatible` it also refuses a one-sided first release. See the release-notes checklist in [§6](#6-git-tag--github-release).

Commit (`chore: bump to vX.Y.Z`) and push.

## 2. Pre-flight tests

Run both suites for every release, one-sided ones included: the client and the plugin in this commit must stay a working pair.

```bash
uv run pytest tests/ -q          # Python — must be green
ruby test/run_all.rb             # Ruby — must be green
```

## 3. Build artifacts

Build only the side you ship:

```bash
# Python
rm -rf dist/
uv build                                              # → dist/*.whl + dist/*.tar.gz
uvx twine check dist/*                                # validate metadata / README rendering

# Plugin
rm -f mcp_for_sketchup/*.rbz
(cd mcp_for_sketchup && ruby package.rb)   # → mcp_for_sketchup_vX.Y.Z.rbz
```

`package.rb` needs the `rubyzip` gem: `gem install --user-install rubyzip`.

## 4. TestPyPI rehearsal

Python releases only.

```bash
uvx twine upload --repository testpypi dist/*
```

Check by hash that TestPyPI holds exactly the files you built. The step needs bash (for `<(...)`), `curl`, `jq` and GNU `sha256sum`. It stops at once if `dist/` lacks the wheel or the sdist: with an empty `dist/` and a failed lookup both lists would be empty and `diff` would call that a match. The command prints `TestPyPI matches dist/` when the two lists agree, and the differing lines when they do not:

```bash
ls dist/*.whl dist/*.tar.gz >/dev/null && \
  diff <(sha256sum dist/* | sort) \
       <(curl -fsS https://test.pypi.org/pypi/sketchup-mcp2/X.Y.Z/json \
           | jq -r '.urls[] | "\(.digests.sha256)  dist/\(.filename)"' | sort) \
  && echo "TestPyPI matches dist/"
```

A difference means TestPyPI serves something other than your build, or the lookup failed (`curl` prints the error and the right-hand list is empty). Do not continue to [§5](#5-production-pypi) until you know why.

Then install the **local** wheel into a fresh venv. Dependencies come from PyPI only, because the command names no other index:

```bash
VENV=$(mktemp -d) && uv venv -q "$VENV" && \
  uv pip install -q --python "$VENV/bin/python" dist/sketchup_mcp2-X.Y.Z-py3-none-any.whl && \
  "$VENV/bin/python" -c "import sketchup_mcp.app, sketchup_mcp.tools; print(sketchup_mcp.__version__)"
rm -rf "$VENV"
```

The import loads the server and its tools, so the dependencies PyPI resolved (`mcp`, `pydantic`) are exercised, not only the wheel's own `__version__`.

**Why there is no install from TestPyPI.** The rehearsal used to run `uv pip install --index-url https://test.pypi.org/simple/ --extra-index-url https://pypi.org/simple/ --index-strategy unsafe-best-match sketchup-mcp2==X.Y.Z`. That command resolves every dependency from **both** indexes, and anyone can register a dependency name that TestPyPI does not host, so a stranger's package could be installed and executed — a dependency confusion attack — on the machine that holds the PyPI token (`~/.pypirc`), a minute before the production `twine upload` of [§5](#5-production-pypi). Do not reinstate it.

## 5. Production PyPI

Python releases only.

```bash
uvx twine upload dist/*
```

**Warning:** PyPI versions are **immutable**. Once `X.Y.Z` is uploaded, it can never be re-uploaded — even after deletion. If something is broken post-upload, bump to `X.Y.(Z+1)`.

## 6. Git tag + GitHub Release

Every release carries the current artifacts of **both** sides, so the latest release page always offers the plugin and the client — the handshake error messages send users there. Attach what you built in [§3](#3-build-artifacts), and re-attach the unchanged side's files from the previous release (`vPREV`):

```bash
# Python-only release: the current signed plugin
rm -f mcp_for_sketchup/*.rbz && gh release download vPREV -p '*-signed.rbz' -D mcp_for_sketchup
# Plugin-only release: the current wheel + sdist
rm -rf dist/ && gh release download vPREV -p 'sketchup_mcp2-*' -D dist
```

The `.rbz` must already be self-signed via the [Trimble signing service](https://extensions.sketchup.com/developer/sign-extension) — an unsigned extension is flagged as unidentified, and SketchUp blocks it outright under the strictest loading policy (*Identified Extensions Only*).

**The service hands back a different file from the one you upload.** It appends a `-signed` suffix to the name and encrypts every `.rb` under the extension folder to `.rbe`, adding `mcp_for_sketchup.susig`; the root loader and `settings.html` stay in the clear, and `main.rb`'s `LOAD_ORDER` names paths without an extension precisely so `Sketchup.require` picks up the `.rbe`. Attach **that** file. The unsuffixed artifact §3 produced is the unsigned one and must not be published:

```bash
git tag vX.Y.Z -m "Release X.Y.Z" && git push origin vX.Y.Z
gh release create vX.Y.Z \
  --title "vX.Y.Z" \
  --notes "..." \
  dist/sketchup_mcp2-*-py3-none-any.whl \
  dist/sketchup_mcp2-*.tar.gz \
  mcp_for_sketchup/mcp_for_sketchup_v*-signed.rbz
```

Release notes must say which side the release ships and the oldest counterpart it works with: "works with plugin ≥ vMIN_RUBY" for the client, "works with sketchup-mcp2 ≥ vMIN_PYTHON" for the plugin.

**First release after 0.3.1 (one-time):** it ships both sides and raises both floors to its own version (see [§1](#1-choose-the-scope-then-bump)), and its notes must ask every user to upgrade both once — releases up to 0.3.1 accept only a counterpart of their own version. Give the client command explicitly: `uvx sketchup-mcp2@latest`, then restart the MCP client. The 0.3.x client's own hint, `uv pip install --upgrade sketchup-mcp2`, does not refresh a `uvx` install.

Release notes must also call out anything a user upgrading in place would otherwise
discover the hard way. For `0.3.1`:

- `eval_ruby` now ships **enabled by default**; close the gate by unchecking
  **Enable Ruby evaluation** in `Plugins → MCP Server → Settings...`.
- Upgrading over an installation where the user had explicitly disabled
  `eval_ruby` leaves it disabled — the stored preference outranks the new
  default. Intended behaviour; say so, or it reads as a bug.
- Upgrading over an installation where the user **never opened Settings** does
  the opposite: with no stored preference the new default applies, so the gate
  opens. This hits everyone running a `-warehouse` build — published as a
  release asset for both v0.2.0 and v0.3.0 — where an absent preference
  previously resolved to *closed* through the build profile. No dialog is
  shown: `confirm_eval_enable` fires only on an off→on transition inside the
  Settings dialog, and an upgrade never passes through it. Spell this out; it
  is the one case a user cannot discover by reading their own settings.
- The Python package and the `.rbz` must be upgraded **together**: an installed
  0.3.0 plugin rejects a 0.3.1 client at the handshake (`-32001`), and a 0.3.0
  client rejects a 0.3.1 plugin (see [§1](#1-choose-the-scope-then-bump)).

## Notes

- `LICENSE` and `NOTICE` ship inside the wheel via `license-files` in `pyproject.toml` — no manual copying needed.
- After the first publish, swap the account-wide PyPI tokens in `~/.pypirc` for **project-scoped** ones (PyPI → Settings → API tokens → Scope: `Project: sketchup-mcp2`). Compromise of a scoped token only affects that project.
- **The Extension Warehouse is not a distribution channel for this project.** Trimble denied the v0.2.0 submission in August 2026 on policy grounds, not on fixable defects: they publish no externally developed MCP servers, reserving the catalogue for tools they build and secure themselves. Do not spend another two-month review cycle on it. GitHub Releases is the only channel — the `.rbz` still goes through the [Trimble signing service](https://extensions.sketchup.com/developer/sign-extension), which is a separate, self-serve flow with no review.
