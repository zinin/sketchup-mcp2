# Design: Full-review fixes, part 1 — model integrity and safety net

- **Date**: 2026-10-19
- **Status**: Draft — awaiting user review
- **Branch**: `fix/p1-model-integrity` (from `master` at `caf3d0b`)
- **Target**: merge to `master` without a release; ships with 0.4.0 (part 5)
- **Source**: `full-review/full-review-merged.md` (untracked). `M-xx` IDs below refer to it.
- **Author**: Alexander V. Zinin (with Claude Code)

## 1. Context

Three full-review runs (Opus 5.5, DeepSeek v4.1 flash, GLM 5.3 flash) were merged into one list
and checked against the code and a live SketchUp 2026.1. The user chose to fix every valid finding
in parts, most critical first:

1. **This part** — defects that damage the model or lie about the result, plus the tests that
   should have caught them. No wire-contract change.
2. World coordinates for nested entities (M-03) — contract change.
3. Joinery redesign (M-02) — needs the user's joint semantics.
4. Socket authentication (M-06) — needs the user's token UX.
5. Release 0.4.0: Trusted Publishing (M-10), both floors raised.

Later sessions take the P2 and P3 lists.

## 2. Goals, non-goals, anti-goals

**Goals**

- `chamfer_edge` and `fillet_edge` work on the primitives `create_component` builds, or refuse
  cleanly; they never abort with `reference to deleted Group` (M-01).
- `set_material` on a face or edge succeeds and reports honestly; `delete_component` and
  `transform_component` reject anything but groups and component instances (M-04).
- Exporting `.skp` never re-points the user's untitled document to a temp file (M-05).
- Edge ops and joinery cannot run unbounded on the UI thread; a client timeout tells the agent the
  change may still land (M-07).
- Tests cover the destructive handlers, rollback on failure and the eval gate (M-08), and the
  Python↔Ruby wire contract (M-09).
- CI tests the dependency set users actually get (M-11).
- The docs stop misleading on security, entity IDs and the TestPyPI rehearsal (M-06 docs part,
  M-23 `.to_i`, M-10 §4).

**Non-goals**

- Any wire-contract change: coordinate frames (part 2), joinery semantics (part 3), authentication
  (part 4). Response shapes change only additively.
- Version bump, floors, CHANGELOG, release (part 5).
- P2 items, including the MCP surface (`isError`, annotations), migrating the existing Ruby test
  fakes (M-22) and reworking `examples/smoke_check.py`.
- Smooth chamfer or fillet along curved rims (§9).

**Anti-goals** — the change fails even if tests pass when it:

- silently removes behaviour the user relies on without saying so in a docstring or error;
- reformats pinned handler or test source (`CLAUDE.md`: no auto-formatter; update literal pins
  deliberately);
- adds a gem dependency to the plugin or raises the Python floor above 3.10.

## 3. Facts established live

SketchUp 26.1.256, Ruby 3.2.2, json 2.6.3, Windows; plugin and client 0.3.1. Probes ran inside
`start_operation` … `abort_operation` or were erased afterwards; the user's template is empty again.

| Probe | Result |
|---|---|
| Default cylinder (Ø100×100, 24 segments) | edges 0–47 are the two rims (90° between face normals); edges 48–71 are vertical seams (15°) |
| `chamfer_edge(distance=2)` on it | 48 cuts succeed; the cut on edge 48 (first seam) returns `nil` **and invalidates both the cutter and the body**; the next iteration raises `TypeError`; the operation rolls back; client gets `-32603 reference to deleted Group` |
| Same loop with seams (< 25°) skipped | cylinder 48/48 in 0.37 s, cone 24/24 in 0.18 s; result is manifold; ~10 % less material than an ideal smooth chamfer and 48 edges shorter than 0.2 mm at the segment joints |
| Default sphere (Ø100, 16 segments) | all 496 edges are seams, 2.2°–22.4° |
| Default cone | 24 seams at 13.4°, 24 rim edges at 116.4° |
| Per-segment fillet on the cylinder rims, seams skipped | 2 of 48 cut, then no live edge matches; with a larger match tolerance a cut returns `nil` and destroys the body |
| Profile swept along the whole closed rim with Follow Me | the cutter is not manifold (a profile-shaped hole at the seam); starting at an edge midpoint and capping with `find_faces` did not fix it |
| `set_material` on a face id | face painted, then `[-32603] undefined method 'name' for Sketchup::Face` |

## 4. Changes

Ruby paths are relative to `mcp_for_sketchup/mcp_for_sketchup/`.

### 4.1 Edge ops: feature edges only, no crash on a destroyed body (M-01)

`handlers/operations.rb`, `run_edge_op` and helpers.

1. **Seams are not edges to cut.** New constant `SEAM_MAX_DIHEDRAL_DEG = 25.0`. An edge with two
   faces whose normals differ by less than this angle is a seam of a tessellated surface. Seams are
   removed from the edge set before the specs are snapshotted and counted in a new stats key
   `skipped_seam`. The threshold separates every default primitive cleanly (§3) and keeps the
   vertical edges of prisms up to 12 sides (30°) as feature edges.
2. **Fillet skips curved rims.** A *curved-rim edge* is a non-seam edge that shares a vertex and a
   face with another non-seam edge whose direction turns by less than `SEAM_MAX_DIHEDRAL_DEG`
   but is not collinear with it (consecutive segments of a polygonized curve, e.g. a cylinder
   rim). Collinear pieces of a split straight edge are not curved. `fillet_edges` skips curved-rim
   edges and counts them in `skipped_curved`; the per-segment fillet cannot cut them (§3).
   `chamfer_edges` keeps cutting them segment by segment (§3: manifold result).
3. **Nothing left to cut → `-32602`**, raised inside the operation so it rolls back:
   "no feature edges to chamfer on target_id=N (all M edges are surface seams)" for chamfer;
   "no straight feature edges to fillet on target_id=N (all M edges are surface seams or curved
   rims)" for fillet. A sphere hits this immediately instead of running 496 cuts.
4. **Destroyed body.** When `cutter.subtract(entity)` returns `nil` and `entity.valid?` is false,
   raise `StructuredError(-32603, "<Op name>: SketchUp's subtract failed on edge k of N and
   destroyed the body; the operation was rolled back, the model is unchanged")`. The existing
   `rescue` → `safe_abort` keeps it atomic. A `nil` that leaves the body valid keeps today's
   behaviour (count `subtract_failed`, erase the cutter, continue). Check `entity.valid?` at the
   top of each iteration as well.
5. **`edge_indices`** (direct TCP clients only) keeps its meaning — positions in
   `entities.grep(Sketchup::Edge)` — and the seam and curved-rim rules apply to the chosen edges.
6. **Stats** gain `skipped_seam` and `skipped_curved` (additive). `attempted` counts the edges
   actually snapshotted.
7. **Docstrings** (`tools.py`): replace "By default ALL edges" with what the tool now does —
   every feature edge; seams of curved surfaces are skipped; fillet also skips curved rims and
   refuses a body that has no straight feature edges; read the new stats keys.

### 4.2 `set_material` on raw entities, type guards (M-04)

1. `Handlers::Geometry.describe_entity` describes any `Drawingelement`:
   - `"type"`: `"group"` for `Group`, `"component"` for `ComponentInstance`, otherwise
     `entity.typename.downcase` (`"face"`, `"edge"`). Today a face would be called `"component"`.
   - `"name"`: `entity.name` for groups and component instances, `nil` (JSON `null`) otherwise.
   - `"bbox_mm"`: unchanged.
2. `set_material` builds the description **before** `commit_operation`, so a describe failure
   rolls the paint back.
3. Material resolution, in this order:
   1. an existing material with exactly this name is used as is;
   2. a named color, case-insensitive, maps to the lower-case canonical name (`"Red"` → `"red"`),
      found or created;
   3. `#rrggbb`, case-insensitive, maps to the lower-case hex, found or created;
   4. anything else → `-32602`, as today.

   The `set_material` docstring documents step 1, which is why "anything else fails" was false.
4. `delete_component` and `transform_component` call `E.require_group_or_component!` after
   `E.find!`: a face, an edge or any other entity → `-32602`, nothing erased or moved. Docstrings
   say "groups and component instances only".

### 4.3 `.skp` export of an untitled model is refused (M-05)

`handlers/export.rb`. `format == "skp"` with an empty `model.path` raises
`StructuredError(-32602, "cannot export .skp: the model has never been saved, and saving it to a
temp file would re-point the open document there. Ask the user to save the model in SketchUp
first (File → Save), or export another format.")` before `build_export_path`, so no temp file or
directory appears. `save_skp` keeps only the `save_copy` path. The T-27 `warning` field goes away.
This reverses decision T-27 (§7). The `export_scene` docstring states the refusal.

### 4.4 Bounded work and the timeout message (M-07)

1. **Time budget for edge ops.** `EDGE_OP_BUDGET_S = 30.0`, monotonic clock from the start of the
   cut loop, checked before each cut. Past it: `StructuredError(-32603, "<Op name>: stopped after
   k of N edges — exceeded the 30 s budget; the operation was rolled back, the model is
   unchanged")`. 30 s stays under the client's default 60 s timeout, so the client never times
   out on an edge op that later commits.
2. **Upper bounds**, the same on both sides:

   | Parameter | Python (`Field`) | Ruby (`V.optional_int_range`) |
   |---|---|---|
   | `fillet_edge.segments` | `ge=1, le=32` | `1..32`, default 8 |
   | `create_finger_joint.num_fingers` | `gt=0, le=50` | `1..50`, default 5 |
   | `create_dovetail.num_tails` | `gt=0, le=25` | `1..25`, default 3 |
   | `create_component` `segments` (Ruby-only parameter) | — | `3..128`, default per type |

3. **Timeout advisory** (`src/sketchup_mcp/connection.py`). For a tool outside
   `_RETRY_SAFE_TOOLS`, the timeout error reads `timeout after Ns — SketchUp may still finish and
   commit '<tool>'; check the model (get_component_info / list_components) before retrying`. The
   read-only tools keep the bare message.
4. `edge_indices` stays out of the MCP tools (§7).
5. README, Configuration: an `SKETCHUP_MCP_TIMEOUT` below 30 s lets the client give up before an
   edge op stops itself.

### 4.5 Tests for destructive handlers and the eval gate (M-08)

1. **Rollback table.** A recording fake model logs `start_operation`, `commit_operation` and
   `abort_operation`. For every mutating handler — `create_component`, `delete_component`,
   `transform_component`, `set_material`, `boolean_operation`, `chamfer_edges`, `fillet_edges`,
   `create_layer`, `create_mortise_tenon`, `create_dovetail`, `create_finger_joint`:
   - success → one commit, no abort;
   - a failure injected after `start_operation` → one abort, no commit, the error propagates.

   Where a handler's full fake is too costly, inject the failure into one inner call. The
   requirement is the abort-on-failure invariant for every mutating handler.
2. **Eval gate.** With the gate closed, `eval_ruby` returns `-32010` and the code does not run (the
   code would set a global; assert it stays unset). The real `confirm_eval_enable` body runs with
   a stubbed `UI.messagebox`: `IDYES` → true, `IDNO` → false.
3. **Undo.** `Handlers::Model.undo` calls `Sketchup.send_action("editUndo:")`.
4. **RED first** for §4.1–§4.4: a fake whose `subtract` returns `nil` and invalidates the operand;
   faces with preset normals for the seam and curved-rim rules; an all-seam body; a budget breach
   driven by a stubbed clock; a face without `name` for `set_material`; delete and transform of a
   face; untitled and nil-path `.skp` export; the material resolution order.
5. Every new Ruby test file passes standalone (`ruby -Itest test/test_<name>.rb`) and under
   `ruby test/run_all.rb`. New fakes subclass the guarded `Sketchup::*` stubs, as
   `test/test_boolean_direction.rb` does, and add no unguarded reopening of a shared stub class.

### 4.6 Cross-language contract (M-09)

1. **`Handlers::Dispatch::READ_ONLY_TOOLS`** — a frozen list of the wire names that never mutate
   the model: the eight in `_RETRY_SAFE_TOOLS` today.
2. **Python, source level** (`tests/test_contract.py`, same technique as
   `tests/test_compat.py::_ruby_const`):
   - every wire name `tools.py` sends (`_call(ctx, "<name>"` and `_raw_call(ctx, "<name>"`) is
     routed by `call_handler` in `dispatch.rb`;
   - the names `dispatch.rb` routes minus the names `tools.py` sends equal a pinned allowlist
     (today `{"export_scene"}`), so a Ruby handler without a Python tool is noticed;
   - `_RETRY_SAFE_TOOLS` ⊆ `READ_ONLY_TOOLS`.
3. **Ruby, behavioural.** Every `when` branch of `call_handler` reaches its handler method: stub the
   handler modules, dispatch each wire name, assert the expected method was called.
4. **Wire level, new CI job `contract`.**
   - A Ruby harness (`test/contract/echo_server.rb`) loads the real `core/` and
     `handlers/dispatch.rb`, replaces `UI.start_timer` with a loop it drives itself, replaces the
     handler modules with echo modules that return `{"wire": name, "params": params}`, binds
     `127.0.0.1:0` and prints the port.
   - A pytest (`tests/test_contract_wire.py`, marker `contract`, skipped when `ruby` is missing)
     starts the harness and calls every MCP tool function in `tools.py` through the real
     `SketchUpConnection`, including the real `hello` handshake. Each call must reach the expected
     wire name with the expected argument names.
   - The CI job runs on Ubuntu with Ruby 3.2 and one Python version, `timeout-minutes: 10`.

   The Opus review's prototype of the same idea ran 20 tools in 0.43 s.

### 4.7 Dependencies and CI (M-11)

1. `pyproject.toml`: `mcp>=1.30,<2` without the `[cli]` extra; declare `pydantic>=2.11`
   directly. That is the floor mcp 1.30 requires below Python 3.14; on 3.14 mcp itself demands
   2.12, and the resolver handles it. mcp 1.30 still supports Python 3.10. Keep the `<2` cap and
   its comment: mcp 2.x exists and breaks the import surface.
2. Regenerate `uv.lock`; both suites stay green on mcp 1.30. Watch the bare `list` annotation of
   `get_viewport_screenshot` and the `structuredContent` behaviour.
3. `.github/workflows/test.yml`: `uv sync --locked --extra dev` and `uv run --locked pytest tests/
   -q`; fix the comment that claims `--frozen` turns lock drift red.
4. New `.github/workflows/deps-latest.yml`: weekly `schedule` plus `workflow_dispatch`;
   `uv sync --upgrade --extra dev` (the lock change stays in the runner), `uv pip list` to the
   log, then the Python suite. GitHub's failure email is the alert.
5. New `.github/dependabot.yml`: ecosystems `uv` and `github-actions`, weekly. Ignore major
   updates of `mcp`, so Dependabot does not propose the 2.x migration as a routine bump.

### 4.8 Documentation

1. **README, new section "Security model".**
   - The socket has no authentication. Anything that can open a TCP connection to the plugin's
     port can call every tool, `eval_ruby` included: any local process, and other machines when
     Host is not a loopback address.
   - Claude Desktop / Claude Code approval covers only calls made through that client.
   - The defaults (`127.0.0.1`) are safe on a single-user machine.
   - Split host (Linux VM with the MCP client, Windows with SketchUp): keep the plugin on
     `127.0.0.1` and open a reverse tunnel from Windows,
     `ssh -N -R 9876:127.0.0.1:9876 user@linux-vm`. The MCP server then connects to
     `127.0.0.1:9876` on the Linux side. Needs the OpenSSH client on Windows (built into 10/11)
     and `sshd` on the VM.
   - An upgrade can open the eval gate without a dialog when the Settings were never saved
     (pulled forward from M-23 because it belongs in this section).

   Point the `0.0.0.0` warning (`README.md:103`) at the section; rewrite the "Typical layout"
   paragraph (`README.md:218`) to use the tunnel.
2. **Settings dialog** (`ui/settings.html`, `ui/settings_dialog.rb`): text that implies only a
   trusted MCP client can connect says instead that anything reaching the port can — any local
   process, and other machines if Host is not loopback. Update any test that pins the text.
3. **`CLAUDE.md`.**
   - Entity IDs: they are parsed strictly with `Integer(id.to_s, 10)`; never `.to_i`, because
     `"abc".to_i == 0` silently addresses entity 0.
   - Eval gate: the per-call review layer does not apply to a direct TCP client.
   - Split-host smoke check: describe both setups — the LAN address in `SKETCHUP_MCP_HOST`, and the
     tunnel with `SKETCHUP_MCP_SMOKE_REMOTE=1` (item 5).
   - Test counts.
4. **`docs/release.md` §4.** Replace the install-from-TestPyPI check: compare the sha256 of each
   uploaded file with the digests in `https://test.pypi.org/pypi/sketchup-mcp2/X.Y.Z/json`, then
   install the **local** wheel from `dist/` into a fresh venv with dependencies from PyPI only and
   import it. Drop `--index-strategy unsafe-best-match` and TestPyPI as an install index; say why
   (dependency confusion on the machine that holds the PyPI token).
5. **Smoke check behind the tunnel** (`examples/smoke_check.py`). Step 18 decides that SketchUp is
   local when `SKETCHUP_MCP_HOST` is a loopback address, then asserts that the exported file
   exists on this machine. Behind the reverse tunnel the host is `127.0.0.1` but the file lands on
   Windows, so the step fails. New opt-out: `SKETCHUP_MCP_SMOKE_REMOTE=1` forces the remote branch
   (assert only that Ruby returned a non-empty path). The script's header lists it.

## 5. Literal pins and tests that change deliberately

- `test/test_export_skp.rb`: untitled and nil-path cases expect the refusal; the two `warning`
  tests become refusal tests.
- `test/test_operation_names.rb`: the `run_edge_op` region regex (`def self.run_edge_op.*?
  model.start_operation`) must still find the `edge_indices` guard; keep the guard before
  `start_operation`.
- Any test pinning `ensure_material`, the `set_material` messages, the Settings dialog text or the
  `fillet_edge` / joinery schemas (`tests/test_tools.py`, `tests/test_tool_descriptions.py`).
- `CLAUDE.md` test counts.

## 6. Verification

1. `ruby test/run_all.rb` and `uv run pytest tests/ -q` green; each new Ruby test file green
   standalone; `uv lock --check` clean. Build and test commands go through the `build-runner`
   agent.
2. **The session's MCP server runs from this checkout.** `.mcp.json` starts it with
   `uv run --directory /opt/github/zinin/sketchup-mcp2 python -m sketchup_mcp`. A reconnect
   (`/mcp`) or a new session therefore runs the branch's Python and syncs the venv to the branch's
   `uv.lock`. Every commit must keep `python -m sketchup_mcp` importable, or the `sketchup` tools
   stop loading and the live check below cannot run. After the dependency bump (§4.7), reconnect
   and make one tool call before going on. The Python changes can then be checked live too, for
   example `fillet_edge(segments=33)` rejected by the schema.
3. **Live check** in the user's running SketchUp (installed plugin 0.3.1). Hot-reload the changed
   handler files through `eval_ruby` (send each file's source and evaluate it at top level), then
   run:
   - chamfer: default cylinder (48 cut, 24 `skipped_seam`), cone (24), cube (12), sphere
     (`-32602`);
   - fillet: cube (12), cylinder (`-32602`, no straight feature edges);
   - `set_material` on a face (success, `"type": "face"`, face painted);
   - `delete_component` on a face (`-32602`, face intact);
   - `.skp` export of the untitled template (`-32602`, `model.path` still empty).

   Erase the probes. Tell the user the running SketchUp keeps the branch's handlers until it
   restarts.

## 7. Decisions taken here (the user can override)

1. **Seam threshold 25°.** It separates every default primitive and keeps 12-sided prisms
   (30° seams) cuttable. A body with real feature edges below 25° loses them; none of the
   primitives has one.
2. **Fillet skips curved rims; smooth rims are deferred.** The per-segment fillet cannot cut a
   tessellated rim, and the Follow Me sweep did not work in a short experiment (§3). An honest
   `-32602` beats a fillet on 2 of 48 segments.
3. **A destroyed body aborts the whole call.** Cutting a copy for each edge would survive it but
   costs a copy per cut and turns the result into a component instance. With seams skipped, the
   case should be rare.
4. **A 30 s time budget, no edge-count cap.** The budget is what keeps an edge op under the client
   timeout; a count cap would refuse valid bodies.
5. **`edge_indices` stays out of the MCP tools.** The Opus and DeepSeek reviews proposed exposing
   it, but an agent cannot discover edge indices without `eval_ruby`. With seams skipped, the
   unbounded case it was meant to cap is gone.
6. **The bounds in §4.4.2.** Generous for real joinery and fillets, small enough to stay seconds.
7. **Faces and edges in `describe_entity`**: `type` from `typename`, `name` null.
8. **Material resolution** keeps the exact-name lookup and documents it; named colors and hex are
   canonicalized to lower case.
9. **`delete_component` and `transform_component` refuse raw geometry**, matching their
   docstrings. Raw faces and edges stay reachable through `eval_ruby`.
10. **Untitled `.skp` export is refused, reversing T-27.** T-27 saved and returned a `warning`;
    whether the user hears about it depends on the agent, and SketchUp's extension requirements
    say not to save the open model silently.
11. **Contract tests** as in §4.6; the wire-level job runs only where Ruby is installed.
12. **Live verification by hot reload** through `eval_ruby`, without rebuilding the `.rbz`.
13. **A smoke-check opt-out instead of a docs note** (§4.8.5): the README now recommends the
    tunnel, and the release smoke run would otherwise fail at step 18 with a confusing assertion.
14. **`pydantic>=2.11`** as the declared floor (§4.7.1).

## 8. Left to the builder

- Fake designs, exact error wording within the meaning given above, regexes for source parsing,
  the contract harness internals.
- Extracting small helpers (feature-edge selection, curved-rim detection, material resolution)
  where it makes them testable without SketchUp — encouraged.
- Commit granularity; one commit per item is a sensible default.

## 9. Follow-ups recorded for later parts

- **Smooth chamfer and fillet along curved rims**: sweep one profile along the whole chain. The
  experiment in §3 left a non-manifold cutter; it needs its own investigation.
- **Fillet profile assumes a 90° dihedral** (`build_fillet_profile`: quarter arc centred at
  `origin + perp1·r + perp2·r`). On straight edges at other angles (a hexagonal prism, 60°) the
  arc is not tangent. Found in code, not verified live.
- **Joinery after a failed cut** (orphan cutter, destroyed operand, M-16) — part 3 rewrites joinery.
- **An edge listing tool**, if exposing `edge_indices` is ever wanted.
