# Full-review fixes, part 1 — model integrity and safety net: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the tools that damage the model or misreport the result (chamfer/fillet on curved bodies, `set_material` on faces, `.skp` export of an untitled model, unbounded work), add the tests that should have caught them, make CI test the dependencies users get, and correct the security and release docs.

**Architecture:** Ruby handler fixes stay wire-compatible (response shapes change only additively). Edge ops gain a feature-edge selection step, a destroyed-body guard and a 30 s budget. Tests use local duck-typed fakes — no live SketchUp. A new CI job runs every MCP tool against the real Ruby server with echo handlers.

**Tech Stack:** Ruby 3.2 (SketchUp Ruby API, minitest), Python ≥ 3.10 (FastMCP from `mcp` 1.x, pydantic 2, pytest + pytest-asyncio), uv, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-19-p1-model-integrity-design.md` (read it first; `M-xx` IDs refer to `full-review/full-review-merged.md`, untracked).

## Global Constraints

- Ruby API works in inches, MCP tools in mm (`MM = 25.4`); convert at the handler boundary.
- `Group#subtract` is reversed (`A.subtract(B)` returns `B − A`). Keep the line `result = cutter.subtract(entity)` in `run_edge_op` verbatim — `test/test_operation_names.rb` pins it.
- Never run an auto-formatter over handlers or tests. Literal source pins live in `test/test_operation_names.rb`, `test/test_transform_absolute.rb`, `test/test_joints_frame_compensation.rb`; update a pin only deliberately.
- Plugin: no gems; Ruby 3.2 (SketchUp 2024–2026).
- Python floor stays `>=3.10`; dependencies `mcp>=1.30,<2`, `pydantic>=2.11`.
- No wire-contract change; response shapes change only additively.
- The session's MCP server runs from this checkout (`.mcp.json`: `uv run --directory /opt/github/zinin/sketchup-mcp2 python -m sketchup_mcp`). Every commit must keep `uv run --locked python -c "import sketchup_mcp.app, sketchup_mcp.tools"` working.
- After every task: `ruby test/run_all.rb` and `uv run --locked pytest tests/ -q` green (before Task 1 lands, plain `uv run pytest`). Every new Ruby test file is also green standalone: `ruby -Itest test/<file>.rb`.
- New Ruby fakes are local duck-typed objects. Subclass a guarded `Sketchup::*` stub (`class Edge; end unless defined?(Edge)`) only where a handler checks `is_a?`/`grep`; never reopen a shared stub class unguarded.
- Commit messages: Conventional Commits in English (`fix:`, `feat:`, `test:`, `docs:`, `build:`, `ci:`). Code comments match the surrounding comments.
- Error codes: invalid input or a refused request → `-32602`; failure inside an operation → `-32603`.
- Recording fake models log `[:start, <operation label>]`, `:commit` and `:abort`. "Rolls back" in a test means the log ends `[[:start, <label>], :abort]` with no `:commit`.

## Review Focus

1. **A body that mixes straight edges, curved rims and seams** (a box with a cylindrical hole): chamfer cuts the box edges and the hole's rims; fillet cuts only the box edges and counts the rims in `skipped_curved`. → Task 2 (`test_mixed_body_keeps_straight_edges_and_flags_hole_rims`).
2. **A straight edge split into collinear pieces** is not a curved rim; fillet cuts both pieces. → Task 2 (`test_collinear_split_edge_is_not_curved`).
3. **Edge ops on a ComponentInstance target** select edges from the definition's entities, exactly as for a group. → Task 3 (`test_component_instance_target_uses_definition_entities`).
4. **`edge_indices` from a direct TCP client that selects only seams** fails with `-32602` and rolls back; no crash. → Task 3 (`test_edge_indices_selecting_only_seams_refuses`).
5. **`set_material` on an entity that is not a group, component instance, face or edge** (e.g. a ComponentDefinition id) fails with `-32602`; no material is created and nothing commits. → Task 6 (`test_non_paintable_entity_is_rejected`).

---

### Task 1: Dependencies and lock enforcement in CI (M-11)

**Files:**
- Modify: `pyproject.toml` (`[project] dependencies` and the comment above it)
- Modify: `uv.lock` (regenerated)
- Modify: `.github/workflows/test.yml:41-44`
- Create: `.github/workflows/deps-latest.yml`
- Create: `.github/dependabot.yml`

**Interfaces:**
- Produces: CI commands `uv sync --locked --extra dev` and `uv run --locked pytest tests/ -q`; every later task runs Python tests with `--locked`.

- [ ] **Step 1: Change the dependencies**

`dependencies = ["mcp>=1.30,<2", "pydantic>=2.11"]`. Rewrite the comment: floor 1.30 is the newest 1.x and the first CI tests against; `<2` because mcp 2.x breaks the import surface (migration is a separate ticket); the `[cli]` extra is dropped because nothing imports `typer`/`rich`; `pydantic` is imported directly by `tools.py`, and 2.11 is mcp 1.30's own floor below Python 3.14.

- [ ] **Step 2: Regenerate the lock**

Run: `uv lock --upgrade`
Expected: `uv.lock` resolves `mcp` 1.30.x; `grep -c '^name = "typer"' uv.lock` prints `0`.

- [ ] **Step 3: Run the suite on the new lock**

Run: `uv sync --locked --extra dev && uv run --locked pytest tests/ -q`
Expected: `182 passed`. If the SDK bump breaks a test (watch `get_viewport_screenshot`'s bare `list` return annotation and `structuredContent`), fix the code in this task and say what changed in the commit body.

- [ ] **Step 4: Check the server still imports**

Run: `uv run --locked python -c "import sketchup_mcp.app, sketchup_mcp.tools"`
Expected: exit 0, no output.

- [ ] **Step 5: Enforce the lock in CI**

In the `python` job: `uv sync --locked --extra dev`, then `uv run --locked pytest tests/ -q`. Replace the `--frozen` comment with: `--locked` fails when uv.lock is out of sync with pyproject.toml; `--frozen` would install the stale lock silently.

- [ ] **Step 6: Add the weekly latest-dependencies workflow**

```yaml
name: deps-latest

# Weekly run against the newest dependency versions a fresh `uvx sketchup-mcp2`
# resolves; uv.lock pins only what CI installs, not what users get.
on:
  schedule:
    - cron: '17 4 * * 1'
  workflow_dispatch:

permissions:
  contents: read

jobs:
  python-latest:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    strategy:
      fail-fast: false
      matrix:
        python-version: ['3.10', '3.14']
    steps:
      - uses: actions/checkout@v4
      - uses: astral-sh/setup-uv@v5
        with:
          python-version: ${{ matrix.python-version }}
      - run: uv sync --upgrade --extra dev
      - run: uv pip list
      - run: uv run --frozen pytest tests/ -q
```

- [ ] **Step 7: Add Dependabot**

```yaml
version: 2
updates:
  - package-ecosystem: uv
    directory: /
    schedule:
      interval: weekly
    ignore:
      # mcp 2.x breaks the import surface; the migration is a separate ticket.
      - dependency-name: mcp
        update-types: ["version-update:semver-major"]
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
```

- [ ] **Step 8: Verify the lock**

Run: `uv lock --check`
Expected: exit 0.

- [ ] **Step 9: Commit**

```bash
git add pyproject.toml uv.lock .github/workflows/test.yml .github/workflows/deps-latest.yml .github/dependabot.yml
git commit -m "build: require mcp 1.30, drop the cli extra, enforce uv.lock in CI"
```

---

### Task 2: Feature-edge selection helpers (M-01)

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/operations.rb` (constants at the top of the edge-op section; helpers next to `filter_edges`)
- Create: `test/support/edge_fakes.rb`
- Create: `test/test_edge_selection.rb`

**Interfaces:**
- Produces (in `MCPforSketchUp::Handlers::Operations`):
  - `SEAM_MAX_DIHEDRAL_DEG = 25.0`
  - `COLLINEAR_MAX_TURN_DEG = 0.5`
  - `seam_edge?(edge) -> Boolean` — true iff `edge.faces.length == 2` and the angle between the two face normals, in degrees, is below `SEAM_MAX_DIHEDRAL_DEG`.
  - `curved_rim_edges(edges) -> Array` — the edges `e` of `edges` for which some other `e2` of `edges` shares a vertex and at least one face with `e`, and the turn at the shared vertex is above `COLLINEAR_MAX_TURN_DEG` and below `SEAM_MAX_DIHEDRAL_DEG`. Turn at vertex `v`: the angle between `v − a` and `b − v`, where `a` and `b` are the other vertices of `e` and `e2`.
  - `select_feature_edges(edges, skip_curved:) -> { edges: Array, skipped_seam: Integer, skipped_curved: Integer }` — drops seams first; with `skip_curved: true` also drops `curved_rim_edges` of the remaining edges; keeps input order.
  - SketchUp API used: `Edge#faces`, `Edge#vertices`, `Edge#other_vertex`, `Vertex#position`, `Face#normal`, `Vector3d#angle_between` (radians), `Point3d#-`.
- Produces (`test/support/edge_fakes.rb`, used again by Task 3): `FakeVec(x, y, z)` with `angle_between`; `FakePt` whose `-` returns a `FakeVec`; `FakeVertex(position)`; `FakeFace(normal)`; `FakeEdge < Sketchup::Edge` with `faces`, `vertices`, `other_vertex`, `start`, `end`; `EdgeFakes.prism(n, z0: 0, z1: 100)` → the `3n` edges of a regular n-gon prism with real cap and side normals; `EdgeFakes.box` → `prism(4)`. Guarded `module Sketchup; class Edge; end unless defined?(Edge); class Face; end unless defined?(Face); end`.

- [ ] **Step 1: Write the failing tests** (`test/test_edge_selection.rb`)

```ruby
def test_cylinder_seams_are_skipped
  sel = OPS.select_feature_edges(EdgeFakes.prism(24), skip_curved: false)
  assert_equal 48, sel[:edges].size
  assert_equal 24, sel[:skipped_seam]
  assert_equal 0,  sel[:skipped_curved]
end

def test_fillet_skips_curved_rims_of_cylinder
  sel = OPS.select_feature_edges(EdgeFakes.prism(24), skip_curved: true)
  assert_empty sel[:edges]
  assert_equal [24, 48], [sel[:skipped_seam], sel[:skipped_curved]]
end

def test_box_keeps_all_twelve_edges_in_both_modes        # 90° everywhere
def test_twelve_sided_prism_keeps_all_edges               # 30° seams, 30° turns: 36 kept in both modes
def test_sphere_like_body_is_all_seams                    # faces meeting at 2°–22.4° → 0 kept
def test_mixed_body_keeps_straight_edges_and_flags_hole_rims
  edges = EdgeFakes.box + EdgeFakes.prism(24)            # box + hole (disjoint fakes suffice)
  # chamfer: 12 + 48 kept, 24 seams; fillet: 12 kept, 48 curved, 24 seams
end
def test_collinear_split_edge_is_not_curved               # two collinear pieces sharing a vertex and a 90° face pair → both kept, skip_curved: true
def test_boundary_edge_is_not_a_seam                      # one face → seam_edge? false
```

- [ ] **Step 2: Run them to see them fail**

Run: `ruby -Itest test/test_edge_selection.rb`
Expected: errors `NoMethodError: undefined method 'select_feature_edges'`.

- [ ] **Step 3: Implement the constants and the three helpers in `operations.rb`**

Pure functions over the edge objects; group edges by shared vertex (`(e1.vertices & e2.vertices)`) rather than walking `Vertex#edges`, so the fakes need no back-references.

- [ ] **Step 4: Run the tests**

Run: `ruby -Itest test/test_edge_selection.rb && ruby test/run_all.rb`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add mcp_for_sketchup/mcp_for_sketchup/handlers/operations.rb test/support/edge_fakes.rb test/test_edge_selection.rb
git commit -m "feat(edge-ops): classify surface seams and curved rims"
```

---

### Task 3: Edge ops use the selection, survive a destroyed body, stop at 30 s (M-01, M-07)

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/operations.rb` (`chamfer_edges`, `fillet_edges`, `run_edge_op`, `last_stats`)
- Modify: `src/sketchup_mcp/tools.py` (`chamfer_edge`, `fillet_edge` docstrings)
- Create: `test/test_edge_ops.rb`

**Interfaces:**
- Consumes: `select_feature_edges(edges, skip_curved:)` and `test/support/edge_fakes.rb` from Task 2.
- Produces:
  - `run_edge_op(entity_id, edge_indices, op_name, match_tolerance_in, skip_curved: false)`; `fillet_edges` passes `skip_curved: true`. The call sites keep the prefix `run_edge_op(entity_id, edge_indices, "Chamfer Edges"` / `"Fillet Edges"` that `test_operation_names.rb` matches.
  - `EDGE_OP_BUDGET_S = 30.0`; `Operations.monotonic_now -> Float` (`Process.clock_gettime(Process::CLOCK_MONOTONIC)`) — the stub point for budget tests.
  - Stats keys: `attempted`, `skipped_no_match`, `subtract_failed`, `succeeded`, `skipped_seam`, `skipped_curved` (also in the `last_stats` fallback). `attempted` = edges left after selection.

Behaviour, in `run_edge_op` order:
1. After `filter_edges` and the existing empty-set check, apply `select_feature_edges`; record the two skip counts.
2. Nothing left → `-32602`, raised inside the operation:
   - chamfer: `"no feature edges to chamfer on target_id=#{entity_id} (all #{n} edges are surface seams)"`
   - fillet: `"no straight feature edges to fillet on target_id=#{entity_id} (all #{n} edges are surface seams or curved rims)"`
   (`n` = edges before selection; the verb is `op_name.split.first.downcase`.)
3. `started_at = monotonic_now` before the loop; before each cut, past `EDGE_OP_BUDGET_S` → `-32603 "#{op_name}: stopped after #{done} of #{total} edges — exceeded the 30 s budget; the operation was rolled back, the model is unchanged"`.
4. `nil` from `cutter.subtract(entity)` with `entity.valid?` false → `-32603 "#{op_name}: SketchUp's subtract failed on edge #{i + 1} of #{total} and destroyed the body; the operation was rolled back, the model is unchanged"`. The same message (with "before edge") guards an invalid `entity` at the top of an iteration. A `nil` that leaves the body valid keeps today's branch.

- [ ] **Step 1: Write the failing tests** (`test/test_edge_ops.rb`)

Fakes: a recording model (`start_operation`/`commit_operation`/`abort_operation` append to a log; `find_entity_by_id` returns registered bodies); `FakeBody < Sketchup::Group` over `EdgeFakes` edges (`entities`, `transformation`, `parent.entities.add_group`, `valid?`, `make_unique`, `entityID`, `name`, `bounds`); a cutter whose `subtract` follows a script of `:ok` (new valid body over the same edges), `:nil_keep` and `:nil_destroy` (invalidates the target and itself). Stub `edge_spec`, `find_current_edge_spec`, `build_chamfer_profile`, `build_fillet_profile` and `reconstruct_edge` with `define_singleton_method`, saving and restoring the originals; leave `select_feature_edges` real.

```ruby
def test_chamfer_cylinder_cuts_rims_and_counts_seams
  res = OPS.chamfer_edges("entity_id" => body.entityID, "distance" => 2)
  assert_equal({ "attempted" => 48, "succeeded" => 48, "skipped_seam" => 24, "skipped_curved" => 0 },
               res["stats"].slice("attempted", "succeeded", "skipped_seam", "skipped_curved"))
  assert_equal [[:start, "Chamfer Edges"], :commit], model.log
end
def test_fillet_cylinder_refuses_without_cutting          # -32602 /no straight feature edges/, log [[:start, "Fillet Edges"], :abort], zero subtract calls
def test_chamfer_all_seam_body_refuses                    # -32602 /no feature edges to chamfer/, abort
def test_destroyed_body_aborts_with_clear_error           # script [:ok, :nil_destroy] → -32603 /destroyed the body/, log [[:start, "Chamfer Edges"], :abort]
def test_nil_subtract_that_keeps_body_continues           # [:ok, :nil_keep, :ok, …] → success, subtract_failed == 1
def test_budget_exceeded_rolls_back                       # monotonic_now jumps 31 s after the first cut → -32603 /exceeded the 30 s budget/, abort
def test_component_instance_target_uses_definition_entities  # FakeInstance < Sketchup::ComponentInstance over prism(24) → skipped_seam == 24
def test_edge_indices_selecting_only_seams_refuses        # "edge_indices" => (48..71).to_a → -32602, abort, no crash
```

- [ ] **Step 2: Run them to see them fail**

Run: `ruby -Itest test/test_edge_ops.rb`
Expected: failures — seams are cut today, and the destroyed-body case raises `TypeError`.

- [ ] **Step 3: Implement the behaviour above in `operations.rb`**

- [ ] **Step 4: Update the two docstrings in `tools.py`**

`chamfer_edge`:
```
Chamfer (bevel) every feature edge of a group/component by ``distance`` mm.

Seams of curved surfaces — edges whose two faces meet at less than 25°, such
as a cylinder's vertical facet edges or every edge of a sphere — are skipped;
the rims of curved surfaces are chamfered segment by segment. A body with no
feature edges fails with -32602. One call runs at most 30 s inside SketchUp;
past that it rolls back and changes nothing. Unreliable on non-manifold
geometry.

Returns: JSON {id, name, type, bbox_mm|null, edges_chamfered,
stats{attempted, succeeded, subtract_failed, skipped_no_match, skipped_seam,
skipped_curved}} — check stats.subtract_failed == 0 (failed cuts) and
stats.skipped_no_match == 0 (edges consumed by earlier cuts).
```
`fillet_edge`:
```
Round (fillet) every straight feature edge of a group/component by
``radius`` mm with ``segments`` arc segments.

Skips seams of curved surfaces (faces meeting at less than 25°) and the rims
of curved surfaces, such as a cylinder's top and bottom circles: fillet cannot
round a tessellated curve. A body with no straight feature edges (cylinder,
cone, sphere) fails with -32602. One call runs at most 30 s inside SketchUp;
past that it rolls back and changes nothing. Unreliable on non-manifold
geometry.

Returns: JSON {id, name, type, bbox_mm|null, edges_filleted,
stats{attempted, succeeded, subtract_failed, skipped_no_match, skipped_seam,
skipped_curved}} — check stats.subtract_failed == 0 (failed cuts) and
stats.skipped_no_match == 0 (edges consumed by earlier cuts).
```

- [ ] **Step 5: Run everything**

Run: `ruby -Itest test/test_edge_ops.rb && ruby test/run_all.rb && uv run --locked pytest tests/ -q`
Expected: all green (`test_operation_names.rb` included).

- [ ] **Step 6: Commit**

```bash
git add mcp_for_sketchup/mcp_for_sketchup/handlers/operations.rb src/sketchup_mcp/tools.py test/test_edge_ops.rb
git commit -m "fix(edge-ops): skip surface seams, refuse curved rims for fillet, abort cleanly on a destroyed body"
```

---

### Task 4: Upper bounds on both sides (M-07)

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/operations.rb` (`fillet_edges`)
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/joints.rb` (`create_dovetail`, `create_finger_joint`)
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/geometry.rb` (`create_component`)
- Modify: `src/sketchup_mcp/tools.py` (`fillet_edge`, `create_dovetail`, `create_finger_joint`)
- Create: `test/test_param_bounds.rb`
- Modify: `test/test_joints_validation.rb`, `tests/test_tools.py`

**Interfaces:**
- Consumes: `V.optional_int_range(params, key, min:, max:, default:)` (exists, `helpers/validation.rb:109`).
- Produces:

| Parameter | Python `Field` | Ruby |
|---|---|---|
| `fillet_edge.segments` | `ge=1, le=32` | `optional_int_range(…, "segments", min: 1, max: 32, default: 8)` |
| `create_finger_joint.num_fingers` | `gt=0, le=50` | `min: 1, max: 50, default: 5` |
| `create_dovetail.num_tails` | `gt=0, le=25` | `min: 1, max: 25, default: 3` |
| `create_component` `segments` (Ruby-only) | — | `min: 3, max: 128, default: default_segments_for(type)` |

Each Python description gains the bound, e.g. `"Arc segments per rounded edge, 1–32"`.

- [ ] **Step 1: Write the failing tests**

Ruby (validation runs before any model access; reuse the `test_joints_validation.rb` pattern: stub `Entities.active_model!` to raise `"validation passed"`):
```ruby
def test_dovetail_num_tails_above_25_rejected      # -32602, /num_tails/
def test_dovetail_num_tails_25_passes_validation   # RuntimeError "validation passed"
def test_finger_joint_num_fingers_above_50_rejected
def test_finger_joint_num_fingers_50_passes_validation
def test_fillet_segments_above_32_rejected          # test_param_bounds.rb
def test_fillet_segments_32_passes_validation
def test_create_component_segments_above_128_rejected
def test_create_component_segments_below_3_rejected
def test_create_component_segments_128_passes_validation
```
Python (real schemas through `mcp.call_tool`, `dispatch_conn` fixture):
```python
async def test_schema_rejects_fillet_segments_above_32(dispatch_conn)        # raises; send_command not called
async def test_schema_accepts_fillet_segments_32(dispatch_conn)              # forwards segments=32
async def test_schema_rejects_dovetail_num_tails_above_25(dispatch_conn)
async def test_schema_rejects_finger_joint_num_fingers_above_50(dispatch_conn)
```

- [ ] **Step 2: Run them to see them fail**

Run: `ruby -Itest test/test_param_bounds.rb; ruby -Itest test/test_joints_validation.rb; uv run --locked pytest tests/test_tools.py -q`
Expected: the "rejected" cases fail.

- [ ] **Step 3: Apply the bounds from the table**

- [ ] **Step 4: Run everything**

Run: `ruby test/run_all.rb && uv run --locked pytest tests/ -q`
Expected: green.

- [ ] **Step 5: Commit**

```bash
git add mcp_for_sketchup/mcp_for_sketchup/handlers src/sketchup_mcp/tools.py test/test_param_bounds.rb test/test_joints_validation.rb tests/test_tools.py
git commit -m "fix: bound fillet segments, joint counts and primitive segments on both sides"
```

---

### Task 5: The timeout error says a mutating call may still commit (M-07)

**Files:**
- Modify: `src/sketchup_mcp/connection.py` (`_send_once`, the `asyncio.TimeoutError` branch)
- Modify: `tests/test_connection.py`
- Modify: `README.md` (Configuration table, `SKETCHUP_MCP_TIMEOUT` row)

**Interfaces:**
- Produces: for a tool in `_RETRY_SAFE_TOOLS` the message stays exactly `f"timeout after {self.timeout}s"`; for any other tool it becomes `f"timeout after {self.timeout}s — SketchUp may still finish and commit '{name}'; check the model (get_component_info / list_components) before retrying"`. Code stays `-32000`.

- [ ] **Step 1: Write the failing tests**

```python
async def test_timeout_on_mutating_tool_warns_it_may_commit(make_connection):
    conn = make_connection(timeout=0.05)      # the reader never answers
    with pytest.raises(SketchUpError) as ei:
        await conn.send_command("chamfer_edges", {})
    assert ei.value.code == -32000
    assert "may still finish and commit 'chamfer_edges'" in ei.value.message

async def test_timeout_on_read_only_tool_keeps_bare_message(make_connection):
    # "get_model_info" → message == "timeout after 0.05s"
```

- [ ] **Step 2: Run them to see the first fail**

Run: `uv run --locked pytest tests/test_connection.py -q -k timeout`
Expected: `test_timeout_on_mutating_tool_warns_it_may_commit` fails.

- [ ] **Step 3: Implement the message in `_send_once`** (`name` is in scope there).

- [ ] **Step 4: README** — append to the `SKETCHUP_MCP_TIMEOUT` description: `; keep it at 30 or more — chamfer/fillet stop themselves after 30 s inside SketchUp`.

- [ ] **Step 5: Run the suite**

Run: `uv run --locked pytest tests/ -q`
Expected: green.

- [ ] **Step 6: Commit**

```bash
git add src/sketchup_mcp/connection.py tests/test_connection.py README.md
git commit -m "fix(connection): warn that a timed-out mutating call may still commit"
```

---

### Task 6: `set_material` on faces and edges; documented material resolution (M-04)

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/geometry.rb` (`describe_entity`)
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/materials.rb` (`set_material`, `ensure_material`, new `canonical_material_name`)
- Modify: `src/sketchup_mcp/tools.py` (`set_material` docstring)
- Create: `test/test_materials.rb`

**Interfaces:**
- Produces:
  - `Geometry.describe_entity(entity) -> Hash` — `"type"`: `"group"` for `Sketchup::Group`, `"component"` for `Sketchup::ComponentInstance`, else `entity.typename.downcase`; `"name"`: `entity.name` for groups and component instances, `nil` otherwise; `"id"` and `"bbox_mm"` unchanged.
  - `Materials.canonical_material_name(name) -> String | nil` — `name.downcase` when `NAMED_COLORS` has it, the lower-cased hex when `HEX_COLOR_RE` matches, else `nil`.
  - `Materials.ensure_material(model, name)` — (1) `model.materials[name]` exact; (2) canonical name: find or create with `pick_color`; (3) `-32602 "invalid color: #{name.inspect} (expected an existing material name, a named color or '#rrggbb')"`.
  - `Materials.set_material(params)` order: `E.find!` → paintable check → `ensure_material` → `apply_to_entity` → `describe_entity` → `commit_operation` → return the description. Paintable: `Sketchup::Group`, `Sketchup::ComponentInstance`, `Sketchup::Face`, `Sketchup::Edge` (checked at call time); otherwise `-32602 "set_material needs a group, component instance, face or edge; entity #{id} is a #{entity.typename}"`.

- [ ] **Step 1: Write the failing tests** (`test/test_materials.rb`; guarded `Sketchup::Face`/`Edge` stubs; a recording model with a fake `materials` collection that logs `add`)

```ruby
def test_canonical_material_name
  assert_equal "red",     M.canonical_material_name("Red")
  assert_equal "grey",    M.canonical_material_name("GREY")
  assert_equal "#a05030", M.canonical_material_name("#A05030")
  assert_nil M.canonical_material_name("oak")
  assert_nil M.canonical_material_name("#abc")
end
def test_set_material_on_face_reports_face_and_describes_before_commit
  # FakeFace < Sketchup::Face, no #name; its #bounds appends :bounds to the model log
  res = M.set_material("id" => face.entityID.to_s, "material" => "red")
  assert_equal ["face", nil], [res["type"], res["name"]]
  assert_operator model.log.index(:bounds), :<, model.log.index(:commit)
  assert_equal "red", face.material.name
end
def test_existing_exact_material_wins                       # materials has "Oak" → used, no add
def test_named_color_is_case_insensitive_and_reuses_one_material  # "Red" then "red" → one add("red")
def test_invalid_color_aborts                               # "garbage" → -32602, rolls back, no add
def test_non_paintable_entity_is_rejected                   # FakeDefinition → -32602 /needs a group, component instance, face or edge/, no add, rolls back
def test_describe_entity_keeps_group_and_component_shape    # "group"/"component" with their names
```

- [ ] **Step 2: Run them to see them fail**

Run: `ruby -Itest test/test_materials.rb`
Expected: the face case raises `NoMethodError: undefined method 'name'`; the resolution cases fail.

- [ ] **Step 3: Implement the interfaces above**

- [ ] **Step 4: Replace the `set_material` docstring**

```
Assign a material (color) to a group, component instance, face or edge.

material: the exact name of a material already in the model, a named color —
red, green, blue, yellow, cyan, turquoise, magenta, purple, white, black,
brown, wood, orange, gray, grey — or a 6-digit hex string like "#a05030".
Named colors and hex are case-insensitive and map to one lower-case material
("Red" and "red" are the same). Anything else fails with -32602. Painting a
group/component affects only this instance (it is made unique first);
painting a raw face/edge id (obtainable via get_selection) colors the shared
definition — all instances show it.

Returns: JSON {id, name, type, bbox_mm{min,max}|null}. For a face or edge,
type is "face" or "edge" and name is null.
```

- [ ] **Step 5: Run everything**

Run: `ruby test/run_all.rb && uv run --locked pytest tests/ -q`
Expected: green (`test_operation_names.rb` still finds the `set_material` label).

- [ ] **Step 6: Commit**

```bash
git add mcp_for_sketchup/mcp_for_sketchup/handlers/geometry.rb mcp_for_sketchup/mcp_for_sketchup/handlers/materials.rb src/sketchup_mcp/tools.py test/test_materials.rb
git commit -m "fix(materials): paint faces and edges without a post-commit error; resolve materials as documented"
```

---

### Task 7: `delete_component` and `transform_component` accept only groups and component instances (M-04)

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/geometry.rb` (`delete_component`, `transform_component`)
- Modify: `src/sketchup_mcp/tools.py` (both docstrings)
- Create: `test/test_geometry_guards.rb`

**Interfaces:**
- Consumes: `E.require_group_or_component!(entity, label = "entity")` (exists; raises `-32602 "#{label} must be a Group or ComponentInstance, got …"`).
- Produces: both handlers call it right after `E.find!(id)`, inside the operation. Docstrings: "Delete a group or component instance by entity ID. Raw faces, edges and other entities fail with -32602." and, in `transform_component`, "Groups and component instances only; other entities fail with -32602."

- [ ] **Step 1: Write the failing tests**

```ruby
def test_delete_rejects_a_face             # -32602, face not erased, rolls back
def test_delete_erases_a_group             # erased, log [[:start, "Delete Component"], :commit]
def test_transform_rejects_a_face          # -32602, no transform!, rolls back
```

- [ ] **Step 2: Run them to see them fail**

Run: `ruby -Itest test/test_geometry_guards.rb`
Expected: the two "rejects" tests fail (the face is erased / `transform!` is attempted).

- [ ] **Step 3: Add the two guard calls and the docstrings**

- [ ] **Step 4: Run everything**

Run: `ruby test/run_all.rb && uv run --locked pytest tests/ -q`
Expected: green; `test_transform_absolute.rb` (literal pin and fake handler test) included.

- [ ] **Step 5: Commit**

```bash
git add mcp_for_sketchup/mcp_for_sketchup/handlers/geometry.rb src/sketchup_mcp/tools.py test/test_geometry_guards.rb
git commit -m "fix(geometry): delete and transform only groups and component instances"
```

---

### Task 8: Refuse a `.skp` export of an untitled model (M-05)

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/export.rb` (`export`, `save_skp`, the T-27 comments)
- Modify: `test/test_export_skp.rb`
- Modify: `src/sketchup_mcp/tools.py` (`export_scene` docstring)

**Interfaces:**
- Produces: `Export.export(params)` raises `-32602 "cannot export .skp: the model has never been saved, and saving it to a temp file would re-point the open document there. Ask the user to save the model in SketchUp first (File → Save), or export another format."` when the format is `skp` and `model.path.to_s.empty?`, before `build_export_path`. `Export.save_skp(model, path)` calls only `model.save_copy(path)`. The `warning` key is gone. Docstring adds: "An untitled model cannot be exported to skp (-32602) — the user must save it first; other formats work."

- [ ] **Step 1: Rewrite the tests** (deliberate pin change — the file documents the old T-27 behaviour)

```ruby
def test_untitled_skp_export_is_refused       # FakeModel(""): -32602 /never been saved/, model.calls empty, build_export_path not called (stub records)
def test_nil_path_skp_export_is_refused       # FakeModel(nil): same
def test_titled_model_uses_save_copy          # keep: [[:save_copy, path]]
def test_untitled_obj_export_still_works      # FakeModel("") with #export → result["format"] == "obj"
```
Delete `test_untitled_model_uses_save_not_save_copy`, `test_nil_path_is_treated_as_untitled`, `test_untitled_skp_export_carries_warning`, `test_titled_skp_export_has_no_warning`.

- [ ] **Step 2: Run them to see them fail**

Run: `ruby -Itest test/test_export_skp.rb`
Expected: the refusal tests fail.

- [ ] **Step 3: Implement the refusal; make `save_skp` `save_copy`-only; update the comments and the docstring**

- [ ] **Step 4: Run everything**

Run: `ruby test/run_all.rb && uv run --locked pytest tests/ -q`
Expected: green.

- [ ] **Step 5: Commit**

```bash
git add mcp_for_sketchup/mcp_for_sketchup/handlers/export.rb test/test_export_skp.rb src/sketchup_mcp/tools.py
git commit -m "fix(export): refuse a .skp export of an untitled model instead of re-pointing it to temp"
```

---

### Task 9: Every mutating handler rolls back on failure (M-08)

**Files:**
- Create: `test/test_handler_atomicity.rb`

**Interfaces:**
- Consumes: the handlers as left by Tasks 3–8. If a row fails, fix the handler in this task and name the fix in the commit body.

The table — params, and how to fail after `start_operation`:

| Handler | Params | Injected failure |
|---|---|---|
| `Geometry.create_component` | `{"type"=>"cube","dimensions"=>[10,10,10]}` | `model.active_entities.add_group` raises |
| `Geometry.delete_component` | `{"id"=>"1"}` | `find_entity_by_id` raises |
| `Geometry.transform_component` | `{"id"=>"1","position"=>[0,0,0]}` | `find_entity_by_id` raises |
| `Materials.set_material` | `{"id"=>"1","material"=>"red"}` | `find_entity_by_id` raises |
| `Operations.boolean_operation` | `{"target_id"=>"1","tool_id"=>"2","operation"=>"union"}` | `find_entity_by_id` raises |
| `Operations.chamfer_edges` | `{"entity_id"=>"1","distance"=>2}` | `find_entity_by_id` raises |
| `Operations.fillet_edges` | `{"entity_id"=>"1","radius"=>2}` | `find_entity_by_id` raises |
| `Model.create_layer` | `{"name"=>"L"}` | `model.layers.add` raises |
| `Joints.create_mortise_tenon` | `{"mortise_id"=>"1","tenon_id"=>"2"}` | `find_entity_by_id` raises |
| `Joints.create_dovetail` | `{"tail_id"=>"1","pin_id"=>"2"}` | `find_entity_by_id` raises |
| `Joints.create_finger_joint` | `{"board1_id"=>"1","board2_id"=>"2"}` | `find_entity_by_id` raises |

- [ ] **Step 1: Write the table test**

One test per row, generated from the table: the injected `RuntimeError("injected")` propagates and the model log is exactly `[[:start, <label>], :abort]` — no `:commit`. Success rows for the cheap handlers: `delete_component` on a fake group, `create_layer`, and `set_material` on a fake group with faces each log `[[:start, <label>], :commit]`.

- [ ] **Step 2: Run it**

Run: `ruby -Itest test/test_handler_atomicity.rb`
Expected: all rows pass. A failing row is a real rollback defect: fix the handler, re-run.

- [ ] **Step 3: Run everything**

Run: `ruby test/run_all.rb`
Expected: green.

- [ ] **Step 4: Commit**

```bash
git add test/test_handler_atomicity.rb
git commit -m "test: every mutating handler rolls back when it fails mid-operation"
```

---

### Task 10: Pin the eval gate, the enable confirm and undo (M-08)

**Files:**
- Create: `test/test_eval_gate.rb`
- Create: `test/test_model_undo.rb`

**Interfaces:**
- Consumes: `Handlers::Eval.eval_ruby`, `Core::Config.eval_enabled=`, `UI::SettingsDialog.confirm_eval_enable`, `Handlers::Model.undo`.
- Produces: `test_confirm_eval_enable_*` capture the messagebox text; Task 13 adds an assertion on its new wording.

- [ ] **Step 1: Write the tests**

```ruby
def test_closed_gate_does_not_run_the_code
  Config.eval_enabled = false
  $mcp_eval_probe = nil
  err = assert_raises(StructuredError) { Eval.eval_ruby("code" => "$mcp_eval_probe = :ran") }
  assert_equal(-32010, err.code)
  assert_nil $mcp_eval_probe
end
def test_open_gate_runs_the_code                     # eval_enabled = true → $mcp_eval_probe == :ran
def test_confirm_eval_enable_is_true_only_on_yes    # stub ::UI.messagebox → ::IDYES → true, ::IDNO → false; text mentions "filesystem"
def test_undo_dispatches_edit_undo                  # stub Sketchup.send_action; Model.undo({}) == {"ok" => true}; calls == ["editUndo:"]
```
Define `::MB_YESNO`, `::IDYES`, `::IDNO` guarded; restore every stub and `Config.eval_enabled` in `teardown`.

- [ ] **Step 2: Run them**

Run: `ruby -Itest test/test_eval_gate.rb && ruby -Itest test/test_model_undo.rb && ruby test/run_all.rb`
Expected: green.

- [ ] **Step 3: Check that the gate test bites**

Temporarily move the gate check in `handlers/eval.rb` below the `eval` call, run `ruby -Itest test/test_eval_gate.rb`, expect `test_closed_gate_does_not_run_the_code` to fail, then restore the file (`git checkout -- mcp_for_sketchup/mcp_for_sketchup/handlers/eval.rb`).

- [ ] **Step 4: Commit**

```bash
git add test/test_eval_gate.rb test/test_model_undo.rb
git commit -m "test: pin the eval gate, the enable confirm and undo's send_action"
```

---

### Task 11: Source-level contract between `tools.py` and `dispatch.rb` (M-09)

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/dispatch.rb` (new constant above `call_handler`)
- Create: `tests/test_contract.py`
- Create: `test/test_dispatch_routing.rb`

**Interfaces:**
- Produces: `Handlers::Dispatch::READ_ONLY_TOOLS = %w[get_model_info list_components get_component_info find_components list_layers get_selection get_viewport_screenshot get_version].freeze`, with a comment: wire names that never mutate the model; `connection.py::_RETRY_SAFE_TOOLS` must stay a subset (`tests/test_contract.py`).
- Python helpers in `tests/test_contract.py` (same technique as `tests/test_compat.py::_ruby_const`):
  - `_dispatched_wire_names() -> set[str]` — every `"name"` literal in `call_handler` between `case tool` and `else`;
  - `_sent_wire_names() -> list[str]` — `re.findall(r'_(?:raw_)?call\(\s*ctx,\s*"([a-z_]+)"', tools_source)`;
  - `_ruby_read_only_tools() -> set[str]` — parsed from `READ_ONLY_TOOLS = %w[...]`.

- [ ] **Step 1: Write the tests**

```python
def test_every_wire_name_python_sends_is_dispatched_by_ruby():
    assert set(_sent_wire_names()) <= _dispatched_wire_names()

def test_ruby_only_wire_names_are_pinned():
    assert _dispatched_wire_names() - set(_sent_wire_names()) == {"export_scene"}

async def test_each_mcp_tool_sends_exactly_one_wire_name():
    sent = _sent_wire_names()
    assert len(sent) == len(set(sent)) == len(await mcp.list_tools())   # 22

def test_retry_safe_tools_are_read_only_in_ruby():
    assert connection._RETRY_SAFE_TOOLS <= _ruby_read_only_tools()

def test_read_only_tools_are_dispatched():
    assert _ruby_read_only_tools() <= _dispatched_wire_names()
```
Ruby (`test/test_dispatch_routing.rb`): parse each `when … then Handlers::(\w+)\.(\w+)\(params\)` line of `call_handler` into (wire names, module, method). Load every handler file (guarded stubs as needed). For every wire name: replace the target method with a recording stub (`define_singleton_method`, original saved and restored), call `Dispatch.call_handler(wire, {})`, assert the stub ran exactly once. Also assert `READ_ONLY_TOOLS` is a subset of the parsed wire names, and `Dispatch.call_handler("no_such_tool", {})` raises `-32601`.

- [ ] **Step 2: Run them to see the read-only tests fail**

Run: `uv run --locked pytest tests/test_contract.py -q; ruby -Itest test/test_dispatch_routing.rb`
Expected: the `READ_ONLY_TOOLS` tests fail (constant missing); the rest pass.

- [ ] **Step 3: Check that the contract test bites** (`dispatch.rb` is still unmodified here)

Temporarily delete `"export", ` from the `when "export", "export_scene"` line, run `uv run --locked pytest tests/test_contract.py -q`, expect `test_every_wire_name_python_sends_is_dispatched_by_ruby` to fail, then restore: `git checkout -- mcp_for_sketchup/mcp_for_sketchup/handlers/dispatch.rb`.

- [ ] **Step 4: Add `READ_ONLY_TOOLS` to `dispatch.rb`**

- [ ] **Step 5: Run everything**

Run: `ruby test/run_all.rb && uv run --locked pytest tests/ -q`
Expected: green.

- [ ] **Step 6: Commit**

```bash
git add mcp_for_sketchup/mcp_for_sketchup/handlers/dispatch.rb tests/test_contract.py test/test_dispatch_routing.rb
git commit -m "test: check the wire names and the retry whitelist against dispatch.rb"
```

---

### Task 12: Wire-level contract job (M-09)

**Files:**
- Create: `test/contract/echo_server.rb`
- Create: `tests/test_contract_wire.py`
- Modify: `.github/workflows/test.yml` (new job `contract`)

**Interfaces:**
- Produces:
  - `ruby test/contract/echo_server.rb` — loads the real `core/` (errors, compat, config, logger, framing, client_state, server) and `handlers/dispatch.rb`; replaces `::UI.start_timer`/`stop_timer` with a loop it drives itself; replaces each handler module that `call_handler` names with an echo module that prints one JSON line `{"handler": "<Module>.<method>", "params": {...}}` to stdout and returns `{"echo" => true}`; sets `Config.host = "127.0.0.1"`, `Config.port = 0`; prints `PORT <n>` as its first stdout line; exits when stdin closes.
  - `tests/test_contract_wire.py` — skipped unless `os.environ.get("SKETCHUP_MCP_CONTRACT") == "1"` and `shutil.which("ruby")`.

- [ ] **Step 1: Write the harness and the test**

```python
async def test_every_mcp_tool_reaches_ruby_with_the_arguments_it_sent(echo_server):
    # conn = SketchUpConnection("127.0.0.1", echo_server.port, timeout=5), patched into
    # sketchup_mcp.tools.get_connection; send_command wrapped to record (wire_name, args).
    for tool in await mcp.list_tools():
        args = _minimal_args(tool.inputSchema)      # required fields only: ids "1"/"2", strings "x", material "red"
        try:
            await mcp.call_tool(tool.name, args)
        except Exception:
            pass                                    # the screenshot/version wrappers can't parse an echo payload
        wire_name, sent_args = recorded.pop()
        logged = echo_server.next_line()
        assert logged["params"] == json.loads(json.dumps(sent_args))
    # The real hello handshake succeeded: the first call went through.
```

- [ ] **Step 2: Run it**

Run: `SKETCHUP_MCP_CONTRACT=1 uv run --locked pytest tests/test_contract_wire.py -q`
Expected: `1 passed` in a few seconds. Without the variable: `1 skipped`.

- [ ] **Step 3: Check that it bites**

Temporarily rename `"fillet_edges"` to `"fillet_edge"` in `dispatch.rb`, re-run step 2, expect a failure (Ruby answers `-32601`, no handler line), then restore: `git checkout -- mcp_for_sketchup/mcp_for_sketchup/handlers/dispatch.rb` (committed in Task 11).

- [ ] **Step 4: Add the CI job**

```yaml
  contract:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.2'
      - uses: astral-sh/setup-uv@v5
        with:
          python-version: '3.12'
          enable-cache: true
      - run: uv sync --locked --extra dev
      - run: uv run --locked pytest tests/test_contract_wire.py -q
        env:
          SKETCHUP_MCP_CONTRACT: '1'
```

- [ ] **Step 5: Run everything**

Run: `ruby test/run_all.rb && uv run --locked pytest tests/ -q`
Expected: green; `test_contract_wire.py` skipped (no variable).

- [ ] **Step 6: Commit**

```bash
git add test/contract/echo_server.rb tests/test_contract_wire.py .github/workflows/test.yml
git commit -m "ci: run every MCP tool against the real Ruby server with echo handlers"
```

---

### Task 13: Security docs and strict entity-id wording (M-06 docs, M-23)

**Files:**
- Modify: `README.md` (new `## Security model` section after the Ruby-side settings; the `0.0.0.0` warning near line 103; the "Typical layout" paragraph near line 218)
- Modify: `mcp_for_sketchup/mcp_for_sketchup/ui/settings.html:75`
- Modify: `mcp_for_sketchup/mcp_for_sketchup/ui/settings_dialog.rb` (`confirm_eval_enable` text)
- Modify: `CLAUDE.md` (the Entity IDs bullet, line 29; the eval-gate bullet, item (2))
- Modify: `test/test_eval_gate.rb` (new wording assertion)

**Interfaces:**
- Consumes: `test_confirm_eval_enable_is_true_only_on_yes` from Task 10.

- [ ] **Step 1: Assert the new confirm wording** — the captured messagebox text matches `/any local process/` and `/other machines/`. Run `ruby -Itest test/test_eval_gate.rb`: it fails.

- [ ] **Step 2: Replace the two UI strings**

`settings.html:75`:
```
Lets anything that can connect to the MCP server's port — any local process, and other machines if Host is not a loopback address — run arbitrary Ruby with full file/shell access. ON by default; uncheck it unless you trust everything that can reach the port.
```
`confirm_eval_enable`:
```
You are about to enable Ruby evaluation.

This lets anything that can connect to the MCP server's port — any local process, and other machines if Host is not a loopback address — run arbitrary Ruby code inside SketchUp with FULL access to your filesystem, network, and shell.

Only enable this on a machine and network you trust.

Continue?
```

- [ ] **Step 3: Add the README section**

```markdown
## Security model

The plugin's TCP socket has **no authentication**. Anything that can open a connection to its port can call every tool, including `eval_ruby` (arbitrary Ruby with full filesystem, network and shell access): any process on the SketchUp machine, and other machines too when **Host** is not a loopback address.

- **Approval in your MCP client covers only calls made through that client.** Claude Desktop and Claude Code show each call's arguments before it runs; a process that talks to the socket directly bypasses that review.
- **The defaults are safe on a single-user machine.** The plugin listens on `127.0.0.1`, so only local processes can connect, and they already run with your permissions.
- **An upgrade can open the eval gate without a dialog.** If you never saved the Settings, the shipped default applies after an upgrade (`eval_ruby` is on since 0.3.1) and no confirmation appears. Open Settings once and uncheck **Enable Ruby evaluation** if you do not want it.
- **Split host (MCP client on a Linux VM, SketchUp on Windows): tunnel instead of binding to the LAN.** Keep the plugin on `127.0.0.1` and run this on the Windows machine:

  ```bash
  ssh -N -R 9876:127.0.0.1:9876 user@linux-vm
  ```

  The MCP server on the Linux side then connects to `127.0.0.1:9876`, the default. You need the OpenSSH client on Windows (built into Windows 10/11) and `sshd` on the VM.
- **Binding Host to a LAN address or `0.0.0.0` exposes `eval_ruby` to every machine that can reach the port.** The Settings dialog warns only for `0.0.0.0`-style hosts, not for an explicit LAN IP.
```
Point the `0.0.0.0` warning at the section (`See [Security model](#security-model); for multi-machine setups use the SSH tunnel described there.`). Rewrite the "Typical layout" sentence: the Linux VM and the Windows VM are connected through the SSH tunnel from [Security model](#security-model).

- [ ] **Step 4: Update `CLAUDE.md`**

- Entity IDs: `SketchUp's find_entity_by_id requires Integer; incoming ids are parsed strictly with Integer(id.to_s, 10) — never .to_i, because "abc".to_i == 0 silently addresses entity 0.`
- Eval gate, item (2): add `It covers only calls made through that client; a direct TCP client bypasses it.`

- [ ] **Step 5: Run the tests**

Run: `ruby test/run_all.rb`
Expected: green.

- [ ] **Step 6: Commit**

```bash
git add README.md CLAUDE.md mcp_for_sketchup/mcp_for_sketchup/ui/settings.html mcp_for_sketchup/mcp_for_sketchup/ui/settings_dialog.rb test/test_eval_gate.rb
git commit -m "docs: security model, SSH tunnel for split-host, strict entity-id parsing"
```

---

### Task 14: TestPyPI check by hash; smoke check behind the tunnel (M-10 §4)

**Files:**
- Modify: `docs/release.md` (§4)
- Modify: `examples/smoke_check.py` (header item 4, step 18, new helper)
- Modify: `tests/test_smoke_helpers.py`
- Modify: `README.md` (the split-host line under "Live smoke", near line 167)
- Modify: `CLAUDE.md` (the split-host smoke paragraph, near line 124)

**Interfaces:**
- Produces: `_export_file_is_local(host: str, environ: Mapping[str, str]) -> bool` in `examples/smoke_check.py` — `False` when `environ.get("SKETCHUP_MCP_SMOKE_REMOTE") == "1"`, otherwise `host in {"127.0.0.1", "localhost", "::1"}`. Step 18 calls it with `config.HOST` and `os.environ`.

- [ ] **Step 1: Write the failing tests** (`tests/test_smoke_helpers.py`, via the existing `_smoke` module loader)

```python
def test_export_file_is_local_on_loopback():
    assert _smoke._export_file_is_local("127.0.0.1", {}) is True

def test_export_file_is_not_local_for_lan_host():
    assert _smoke._export_file_is_local("192.168.1.20", {}) is False

def test_export_file_is_not_local_behind_tunnel():
    assert _smoke._export_file_is_local("127.0.0.1", {"SKETCHUP_MCP_SMOKE_REMOTE": "1"}) is False
```

- [ ] **Step 2: Run them to see them fail**

Run: `uv run --locked pytest tests/test_smoke_helpers.py -q`
Expected: `AttributeError: … '_export_file_is_local'`.

- [ ] **Step 3: Add the helper, use it in step 18, document `SKETCHUP_MCP_SMOKE_REMOTE=1` in the script header**

- [ ] **Step 4: Rewrite `docs/release.md` §4**

Keep the upload command. Replace the verification block with: list `sha256sum dist/*` next to the digests from `https://test.pypi.org/pypi/sketchup-mcp2/X.Y.Z/json` (`urls[].digests.sha256`) — they must match; then install the **local** wheel into a fresh venv with dependencies from PyPI only (`uv pip install dist/sketchup_mcp2-X.Y.Z-py3-none-any.whl`) and import it. Replace the two paragraphs that justify `--extra-index-url` / `--index-strategy unsafe-best-match` with one saying why the command is gone: it resolves every dependency from both indexes, anyone can register a missing dependency name on TestPyPI, and the rehearsal runs on the machine that holds the PyPI token.

- [ ] **Step 5: README and CLAUDE.md split-host smoke text** — two setups: the LAN address (`SKETCHUP_MCP_HOST=<sketchup-host>`), or the SSH tunnel (host stays `127.0.0.1`; set `SKETCHUP_MCP_SMOKE_REMOTE=1` so step 18 does not look for the export file locally).

- [ ] **Step 6: Run the suite**

Run: `uv run --locked pytest tests/ -q`
Expected: green.

- [ ] **Step 7: Commit**

```bash
git add docs/release.md examples/smoke_check.py tests/test_smoke_helpers.py README.md CLAUDE.md
git commit -m "docs(release): verify TestPyPI by hash and install the local wheel; smoke: remote opt-out for tunnels"
```

---

### Task 15: Live verification and test counts (controller, main session)

Not for a subagent: it needs the user's SketchUp, the session's `sketchup` MCP tools and a `/mcp` reconnect only the user can run.

**Files:**
- Modify: `CLAUDE.md` (test counts in "Development Commands")

- [ ] **Step 1: Full suites** (through the build-runner agent)

Run: `ruby test/run_all.rb` and `uv run --locked pytest tests/ -q`
Expected: green; note the new counts (Ruby runs / assertions, Python tests).

- [ ] **Step 2: Load the branch's Python** — ask the user to run `/mcp` (reconnect). Then `get_version` returns `"compatible": true`, and `fillet_edge(id=1, segments=33)` is rejected by the schema before reaching SketchUp.

- [ ] **Step 3: Hot-reload the changed handlers into SketchUp**

Send each file's full source as one `eval_ruby` call, in this order: `handlers/geometry.rb`, `handlers/materials.rb`, `handlers/operations.rb`, `handlers/joints.rb`, `handlers/export.rb`, `handlers/dispatch.rb`. Expected: each call returns without an error (constant-redefinition warnings are fine).

- [ ] **Step 4: Run the live scenarios** on the user's empty template; erase every probe afterwards.

| Call | Expected |
|---|---|
| `chamfer_edge` on a default cylinder | success; `stats.succeeded == 48`, `skipped_seam == 24` |
| `chamfer_edge` on a default cone | success; 24 cut |
| `chamfer_edge` on a 100 mm cube | success; 12 cut |
| `chamfer_edge` on a default sphere | `-32602` "no feature edges to chamfer" |
| `fillet_edge` on a 100 mm cube | success; 12 cut |
| `fillet_edge` on a default cylinder | `-32602` "no straight feature edges to fillet" |
| `set_material` on a face id (from `eval_ruby`) | success; `"type": "face"`, `"name": null`; the face is painted |
| `delete_component` on a face id | `-32602`; the face still exists |
| `export_scene(format="skp")` on the untitled template | `-32602` "never been saved"; `Sketchup.active_model.path` is still `""` |

- [ ] **Step 5: Tell the user** that the running SketchUp keeps the branch's handlers until it restarts.

- [ ] **Step 6: Update the counts and commit**

```bash
git add CLAUDE.md
git commit -m "docs: update test counts"
```
