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

✅ Done — see commit(s): `3f4da01`

---

### Task 2: Feature-edge selection helpers (M-01)

✅ Done — see commit(s): `9180818`

---

### Task 3: Edge ops use the selection, survive a destroyed body, stop at 30 s (M-01, M-07)

✅ Done — see commit(s): `ca9001e`

---

### Task 4: Upper bounds on both sides (M-07)

✅ Done — see commit(s): `371094c`

---

### Task 5: The timeout error says a mutating call may still commit (M-07)

✅ Done — see commit(s): `aedf4f7`

---

### Task 6: `set_material` on faces and edges; documented material resolution (M-04)

✅ Done — see commit(s): `c53a5c4`

---

### Task 7: `delete_component` and `transform_component` accept only groups and component instances (M-04)

✅ Done — see commit(s): `79e16ac`

---

### Task 8: Refuse a `.skp` export of an untitled model (M-05)

✅ Done — see commit(s): `5b117c6`

---

### Task 9: Every mutating handler rolls back on failure (M-08)

✅ Done — see commit(s): `ecefd0e`

---

### Task 10: Pin the eval gate, the enable confirm and undo (M-08)

✅ Done — see commit(s): `6f5ad79`

---

### Task 11: Source-level contract between `tools.py` and `dispatch.rb` (M-09)

✅ Done — see commit(s): `3837eb7`

---

### Task 12: Wire-level contract job (M-09)

✅ Done — see commit(s): `e4c2f5d`

---

### Task 13: Security docs and strict entity-id wording (M-06 docs, M-23)

✅ Done — see commit(s): `f917f6d`

---

### Task 14: TestPyPI check by hash; smoke check behind the tunnel (M-10 §4)

✅ Done — see commit(s): `f1b8b5a`

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
