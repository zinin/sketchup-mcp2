# Block B (joinery) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Withdraw `create_dovetail` and `create_finger_joint`, and make `create_mortise_tenon` build a joint that fits on boards that touch face to face, or refuse, on branch `fix/p3-joinery`.

**Architecture:** Pure functions in `Handlers::Joints` turn the two boards' bounding boxes (common parent frame, inches) into a contact area and a joint box. The handler then builds the joint with two SketchUp solid operations — a cutter subtracted from the mortise board, a tenon piece united with the tenon board — inside one operation that aborts unless volume and solidity checks pass. A small identity helper in `Helpers::Entities` puts each board's name, tag and material back on its result; block A reuses it.

**Tech Stack:** Ruby (SketchUp 2024–2027: Ruby 3.2 and 3.4) with minitest; Python ≥ 3.10, FastMCP (`mcp>=1.30`), pytest.

**Spec:** `docs/superpowers/specs/2026-11-20-release-0.5.0-design.md` — §1 (principle), §3 (live facts), §5 (block B), §9 (decisions).

## Global Constraints

- MCP tools take and return mm; the Ruby API works in inches. Convert at the boundary with `Helpers::Units` (`MM = 25.4`). The pure functions below are unit-agnostic and are called with inches.
- `Group#subtract` is reversed: `a.subtract(b)` returns `b − a`. The mortise is cut with `cutter.subtract(board)`.
- Never run an auto-formatter over handlers or tests. Literal source pins change only in the task that changes the pinned code.
- No gem in the plugin; Python floor stays 3.10. No version bump and no floor change on this branch.
- Mutating handlers: `model.start_operation(label, true)` … `commit_operation`, and `Handlers::Geometry.safe_abort(model)` plus re-raise on any `StandardError`. Build the response before `commit_operation`.
- Unsuitable input → `Core::StructuredError.new(-32602, msg)`; a failed solid operation or post-check → `-32603`. Messages say what is wrong and what to do, with lengths in mm.
- Comments follow their surroundings (this codebase mixes Russian and English); docs and docstrings are English; commits are Conventional Commits in English.
- Every commit keeps `python -m sketchup_mcp` importable (this session's MCP server runs from the checkout).
- Commit only the files a task names. Never commit `docs/superpowers/plans/*-prompt.md`, `full-review/`, `.venv.broken-task8/`.
- After every task: `ruby test/run_all.rb` and `uv run --locked pytest tests/ -q` are green.
- `examples/smoke_check.py` keeps calling `create_dovetail` at step 21 until Task 6 rewrites it; nothing runs the smoke before Task 8.

## Review Focus

1. **A second joint on a board that already has a pocket.** The new pocket may meet the earlier one, so the mortise board loses less than `width × height × depth`; that is accepted. Tests: Task 2 `test_volume_pocket_meeting_an_earlier_one_is_fine`, Task 4 `test_second_pocket_meeting_an_earlier_one_is_accepted`, Task 8 live (two rails into one leg).
2. **Component instances as boards.** Accepted, and the results — groups — keep the instance's name, tag and material. Test: Task 4 `test_component_instance_boards_are_accepted`.
3. **A through mortise** (`depth` beyond the mortise board's thickness). Allowed; the board loses only `width × height × thickness`. Tests: Task 2 `test_volume_through_mortise_is_fine`, Task 8 live.
4. **A joint rectangle reaching the edge of the contact area** (an open mortise, with coplanar faces in SketchUp's solid operations). The geometry accepts it; if SketchUp returns an empty result, the post-check refuses with `-32603` instead of committing it. Tests: Task 2 `test_joint_box_may_reach_the_contact_edge`, Task 4 `test_empty_cut_is_refused_by_the_volume_check`, Task 8 live.
5. **Boards inside a group the user has open for editing.** The joint lands the same as with nothing open (spec §3), and one undo restores both boards. Test: Task 8 live.

---

### Task 1: Withdraw `create_dovetail` and `create_finger_joint`

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/joints.rb` — delete `create_dovetail`, `create_finger_joint`, `add_parent_frame_prototype`, `carve_tails`, `carve_pins`, `carve_board1_fingers`, `carve_board2_slots`. `create_mortise_tenon` and its helpers stay until Task 4.
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/dispatch.rb` — delete the `create_dovetail` and `create_finger_joint` rows of `call_handler`.
- Modify: `src/sketchup_mcp/tools.py` — delete both tools.
- Modify: `src/sketchup_mcp/prompts.py` — Step 5.
- Delete: `test/test_joints_frame_compensation.rb` (every test in it targets the removed helpers).
- Modify: `test/test_dispatch_routing.rb`, `test/test_joints_validation.rb`, `test/test_param_bounds.rb`, `test/test_operation_names.rb`, `test/test_handler_atomicity.rb`, `tests/test_tools.py`, `tests/test_tool_descriptions.py`, `tests/test_contract.py`, `README.md`, `CLAUDE.md`.

**Interfaces:**
- Produces: a dispatch table without the two tools; calling either gets `-32601 unknown tool: <name>`.

- [ ] **Step 1: Write the failing tests**

`test/test_dispatch_routing.rb`:

```ruby
def test_withdrawn_joinery_tools_are_unknown
  %w[create_dovetail create_finger_joint].each do |name|
    err = assert_raises(MCPforSketchUp::Core::StructuredError) { Dispatch.call_handler(name, {}) }
    assert_equal(-32601, err.code)
  end
end
```

`tests/test_tools.py`:

```python
async def test_withdrawn_joinery_tools_are_not_offered():
    names = {t.name for t in await mcp.list_tools()}
    assert "create_dovetail" not in names
    assert "create_finger_joint" not in names
```

- [ ] **Step 2: Run them to verify they fail**

Run: `ruby test/test_dispatch_routing.rb -n test_withdrawn_joinery_tools_are_unknown` and `uv run --locked pytest tests/test_tools.py -q -k withdrawn`
Expected: both FAIL (the routes and tools still exist).

- [ ] **Step 3: Remove the code** listed under Files from `joints.rb`, `dispatch.rb` and `tools.py`.

- [ ] **Step 4: Remove the tests that only covered the withdrawn tools**
  - `test/test_joints_validation.rb`: the dovetail angle, `num_tails` and `num_fingers` tests (keep `test_string_offset_rejected_not_silently_zeroed`); the header comment names mortise-tenon offsets only.
  - `test/test_param_bounds.rb`: `test_dovetail_num_tails_default_to_3`, `test_finger_joint_num_fingers_default_to_5`, the `J` constant and the `joints` require; the header comment drops the dovetail/finger sentences.
  - `test/test_operation_names.rb`: `test_joints_labels_are_title_case` keeps only `"Mortise and Tenon"`; `test_joints_subtract_call_sites_keep_cutter_first` keeps only `/subtract_tracked\(cutter,\s*board\)/`.
  - `test/test_handler_atomicity.rb`: delete the dovetail and finger rows; the header says "nine" where it says "eleven" (twice).
  - `tests/test_tools.py`: the seven dovetail/finger schema tests and their two rows in the wire-argument table.
  - `tests/test_tool_descriptions.py`: drop the two tools from `test_dimension_tools_mention_units`.
  - `tests/test_contract.py`: the comment `# 22 today` becomes `# 20 today`.

- [ ] **Step 5: Update the prompt (`prompts.py`)**

§2, item 1 becomes:

```
1. Typed tools first — create_component, transform_component,
   set_material, boolean_operation, chamfer_edge, fillet_edge,
   create_mortise_tenon, create_layer, delete_component. They handle
   units, transactions, and edge cases.
```

§4, the joinery bullet becomes (Task 5 rewrites it again):

```
- create_mortise_tenon returns ONE OBJECT PER BOARD — {mortise, tenon},
  each {id, name, type, bbox_mm} — plus boolean_cuts {attempted, failed}:
  treat failed > 0 as a partial failure and verify via bbox_mm.
```

§7, the first sentence becomes (the bullets stay):

```
For mortise-and-tenon joints (create_mortise_tenon) and for joints
built with eval_ruby (dovetails, finger joints), when the user doesn't
specify:
```

- [ ] **Step 6: Update the docs.** `README.md` tool table and `CLAUDE.md` "Tool categories": the Joinery row lists only `create_mortise_tenon`. `CLAUDE.md` "Literal source-guard tests": drop `test/test_joints_frame_compensation.rb`.

- [ ] **Step 7: Run both suites**

Run: `ruby test/run_all.rb` and `uv run --locked pytest tests/ -q`
Expected: 0 failures, 0 errors.

- [ ] **Step 8: Commit**

```bash
git add -A mcp_for_sketchup src test tests README.md CLAUDE.md
git commit -m "feat!: withdraw create_dovetail and create_finger_joint"
```

---

### Task 2: Joint geometry as pure functions

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/joints.rb` — add the constants and module functions below; no SketchUp calls.
- Create: `test/test_joint_geometry.rb` — loads `core/errors`, `helpers/validation`, `helpers/units`, `helpers/entities` (or empty stubs, as `test_joint_cut_stats.rb` does) and then `handlers/joints`.

**Interfaces:**
- Produces (a box is `[[min_x, min_y, min_z], [max_x, max_y, max_z]]` in the boards' common parent frame):
  - `Joints::TOUCH_TOL = 0.001` (SketchUp's tolerance, inches); `Joints::VOLUME_RTOL = 1e-4`.
  - `Joints.contact_area(mortise_box, tenon_box, tol = TOUCH_TOL) -> Hash` with keys `:axis` (0, 1 or 2), `:side` (+1 when the tenon board lies on the + side of the mortise board along `:axis`, else −1), `:plane` (the touching faces' coordinate along `:axis`), `:cross` (`[u, v]`, the other two axes in ascending order), `:lo` and `:hi` (`[u, v]` extents of the contact area). Per axis, the boxes are *touching* when the gap `max(min_a, min_b) − min(max_a, max_b)` is within `tol` of 0, *overlapping* when it is below `−tol`, and *separated* above `tol`. A contact needs exactly one touching axis with the other two overlapping. Raises `-32602`: a separated axis → message contains `do not touch`; all three overlapping → `overlap`; two or three touching axes → `edge`.
  - `Joints.joint_box(contact, width, height, depth, offsets, tol = TOUCH_TOL) -> box`. `width` runs along `cross[0]`, `height` along `cross[1]`, centred on the contact area's centre plus `offsets[cross[0]]` and `offsets[cross[1]]` (`offsets` is `[ox, oy, oz]`; the component along `:axis` is ignored). Along `:axis` the box runs from `:plane` into the mortise board: `[plane − depth, plane]` for side +1, `[plane, plane + depth]` for −1. Raises `-32602` with `does not fit` (sizes in mm) when the rectangle leaves the contact area by more than `tol`; reaching the edge is allowed.
  - `Joints.axis_aligned?(axes, tol = 1e-9) -> true/false`. `axes` is three `[x, y, z]` arrays (a transformation's x, y and z axes, any length). True when each, normalised, has one component within `tol` of magnitude 1.
  - `Joints.joint_volume_problem(expected, mortise_before, mortise_after, tenon_before, tenon_after, rtol = VOLUME_RTOL) -> String or nil`. Nil when the mortise board lost more than `expected × rtol` and at most `expected × (1 + rtol)`, and the tenon board gained `expected` within `expected × rtol`. Otherwise a sentence saying which board is off ("mortise board" / "tenon board") and by how much, in mm³ (in³ × 16 387.064).

- [ ] **Step 1: Write the failing tests** (`test/test_joint_geometry.rb`; plain numbers, the functions are unit-agnostic)

```ruby
LEG = [[0, 0, 0], [50, 50, 300]]

def test_contact_along_x_tenon_on_plus_side            # the §3 centred probe
  c = J.contact_area(LEG, [[50, 15, 110], [250, 35, 190]])
  assert_equal({ axis: 0, side: 1, plane: 50, cross: [1, 2], lo: [15, 110], hi: [35, 190] }, c)
end

def test_contact_along_y_tenon_on_minus_side
  c = J.contact_area([[0, 0, 0], [100, 100, 20]], [[20, -50, 0], [80, 0, 20]])
  assert_equal({ axis: 1, side: -1, plane: 0, cross: [0, 2], lo: [20, 0], hi: [80, 20] }, c)
end

def test_contact_along_z_tenon_on_top
  c = J.contact_area([[0, 0, 0], [200, 200, 50]], [[75, 75, 50], [125, 125, 250]])
  assert_equal({ axis: 2, side: 1, plane: 50, cross: [0, 1], lo: [75, 75], hi: [125, 125] }, c)
end

def test_gap_within_tolerance_counts_as_touching
  assert_equal 0, J.contact_area(LEG, [[50.0005, 15, 110], [250, 35, 190]])[:axis]
end

def test_gap_beyond_tolerance_is_refused              # also: [[60, 15, 110], ...]
  assert_refused(/do not touch/) { J.contact_area(LEG, [[50.002, 15, 110], [250, 35, 190]]) }
end

def test_overlapping_boards_are_refused
  assert_refused(/overlap/) { J.contact_area(LEG, [[40, 15, 110], [250, 35, 190]]) }
end

def test_edge_contact_is_refused
  assert_refused(/edge/) { J.contact_area(LEG, [[50, 50, 110], [250, 70, 190]]) }
end

def test_joint_box_centred_on_the_contact_area        # the §3 centred probe
  c = J.contact_area(LEG, [[50, 15, 110], [250, 35, 190]])
  assert_box [[30, 20, 130], [50, 30, 170]], J.joint_box(c, 10, 40, 20, [0, 0, 0])
end

def test_joint_box_on_the_minus_side
  c = J.contact_area([[0, 0, 0], [100, 100, 20]], [[20, -50, 0], [80, 0, 20]])
  assert_box [[40, 0, 5], [60, 15, 15]], J.joint_box(c, 20, 10, 15, [0, 0, 0])
end

def test_joint_box_for_the_offset_rail                # the §3 offset probe
  c = J.contact_area(LEG, [[50, 0, 200], [250, 20, 280]])
  assert_box [[30, 5, 220], [50, 15, 260]], J.joint_box(c, 10, 40, 20, [0, 0, 0])
end

def test_joint_box_may_reach_the_contact_edge         # offset along x is ignored
  c = J.contact_area(LEG, [[50, 15, 110], [250, 35, 190]])
  assert_box [[30, 25, 150], [50, 35, 190]], J.joint_box(c, 10, 40, 20, [99, 5, 20])
end

def test_joint_box_past_the_edge_is_refused           # also: width 30 in a 20-wide area
  c = J.contact_area(LEG, [[50, 15, 110], [250, 35, 190]])
  assert_refused(/does not fit/) { J.joint_box(c, 10, 40, 20, [0, 0, 21]) }
end

def test_axis_aligned
  assert J.axis_aligned?([[1, 0, 0], [0, 1, 0], [0, 0, 1]])
  assert J.axis_aligned?([[0, 1, 0], [-1, 0, 0], [0, 0, 1]])        # 90° about Z
  assert J.axis_aligned?([[2, 0, 0], [0, 3, 0], [0, 0, 0.5]])       # scaled
  refute J.axis_aligned?([[0.7071, 0.7071, 0], [-0.7071, 0.7071, 0], [0, 0, 1]])
end

def test_volume_clean_joint
  assert_nil J.joint_volume_problem(8000, 750_000, 742_000, 320_000, 328_000)
end

def test_volume_through_mortise_is_fine               # lost w × h × thickness < expected
  assert_nil J.joint_volume_problem(8000, 750_000, 745_000, 320_000, 328_000)
end

def test_volume_pocket_meeting_an_earlier_one_is_fine
  assert_nil J.joint_volume_problem(8000, 742_000, 738_000, 320_000, 328_000)
end

def test_volume_problems
  assert_match(/mortise board/, J.joint_volume_problem(8000, 750_000, 750_000, 320_000, 328_000)) # empty cut
  assert_match(/mortise board/, J.joint_volume_problem(8000, 750_000, 741_000, 320_000, 328_000)) # too much
  assert_match(/tenon board/,   J.joint_volume_problem(8000, 750_000, 742_000, 320_000, 320_000)) # no tenon
  assert_match(/tenon board/,   J.joint_volume_problem(8000, 750_000, 742_000, 320_000, 327_990)) # short
end
```

`assert_refused(pattern)` asserts a `Core::StructuredError` with code `-32602` and a message matching `pattern`; `assert_box` compares every coordinate within `1e-9`.

- [ ] **Step 2: Run them to verify they fail**

Run: `ruby test/test_joint_geometry.rb`
Expected: FAIL / ERROR with `undefined method 'contact_area'`.

- [ ] **Step 3: Implement the four functions and two constants** in `joints.rb` with the signatures above.

- [ ] **Step 4: Run them to verify they pass**

Run: `ruby test/test_joint_geometry.rb`, then `ruby test/run_all.rb`
Expected: 0 failures, 0 errors.

- [ ] **Step 5: Commit**

```bash
git add mcp_for_sketchup/mcp_for_sketchup/handlers/joints.rb test/test_joint_geometry.rb
git commit -m "feat: compute a mortise-and-tenon joint from the boards' contact area"
```

---

### Task 3: Identity helpers in `Helpers::Entities`

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/helpers/entities.rb`
- Create: `test/test_entities_identity.rb`

**Interfaces:**
- Produces:
  - `Helpers::Entities.identity_of(entity) -> Hash` → `{ name: String, layer: <layer>, material: <material or nil> }`, read from a group or component instance before a solid operation consumes it.
  - `Helpers::Entities.restore_identity!(entity, identity) -> entity`: sets `name` and `layer`; sets `material` only when `identity[:material]` is not nil.

- [ ] **Step 1: Write the failing tests** — a duck-typed entity with `name`, `layer`, `material` and their writers:
  - `test_identity_round_trip`: `identity_of` of an entity named `"probe_rail"` with layer `L` and material `M`, restored onto a fresh entity → that entity's name, layer and material are `"probe_rail"`, `L`, `M`; the call returns the entity.
  - `test_nil_material_leaves_the_target_alone`: identity with `material: nil` restored onto an entity whose material is `X` → material stays `X`.

- [ ] **Step 2: Run them to verify they fail** — `ruby test/test_entities_identity.rb` → ERROR `undefined method 'identity_of'`.

- [ ] **Step 3: Implement both methods.**

- [ ] **Step 4: Run them, then the Ruby suite** — `ruby test/test_entities_identity.rb`, `ruby test/run_all.rb` → 0 failures.

- [ ] **Step 5: Commit**

```bash
git add mcp_for_sketchup/mcp_for_sketchup/helpers/entities.rb test/test_entities_identity.rb
git commit -m "feat: carry a group's name, tag and material across a solid operation"
```

---

### Task 4: Rewrite `create_mortise_tenon`

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/joints.rb` — rewrite `create_mortise_tenon`; delete `reset_joint_stats!`, `subtract_tracked`, `assert_some_cut!`, `joint_cut_stats`, `closest_face`, `face_origin`, `place_mortise`, `place_tenon`, `push_cutter_face`; add the helpers below.
- Create: `test/test_mortise_tenon.rb`
- Delete: `test/test_joint_cut_stats.rb`
- Modify: `test/test_operation_names.rb`, `test/test_handler_atomicity.rb`

**Interfaces:**
- Consumes: Task 2 (`contact_area`, `joint_box`, `axis_aligned?`, `joint_volume_problem`); Task 3 (`identity_of`, `restore_identity!`); `Helpers::Geometry.make_box(entities, x, y, z, w, d, h)` (inches, returns a group); `Helpers::Entities.entity_collection`; `Handlers::Geometry.describe_entity` and `.safe_abort`.
- Produces:
  - `create_mortise_tenon(params) -> {"mortise" => describe_entity(result), "tenon" => describe_entity(result)}` (no `boolean_cuts`).
  - `board_box(board) -> box` from `board.bounds`.
  - `require_joinable!(mortise, tenon)`: `-32602` unless the boards share a parent (`mortise.parent == tenon.parent`; message contains `same group`), both transformations are axis-aligned (`axis_aligned?([t.xaxis.to_a, t.yaxis.to_a, t.zaxis.to_a])`; message names the board and contains `multiple of 90`), and both are solids (`manifold?`; message names the board and contains `not a solid`).
  - `cut_mortise(board, box) -> result`: `cutter = make_box(board.parent.entities, …)`, then `result = cutter.subtract(board)`; `-32603` (message contains `could not`) when `result` is nil or not `valid?`.
  - `attach_tenon(board, box) -> result`: `piece = make_box(board.parent.entities, …)`, then `result = piece.union(board)`; `-32603` as above.
  - `single_shell?(group) -> true/false`: every face of `entity_collection(group)` is in the first face's `all_connected`.
  - `verify_joint!(mortise_result, tenon_result, expected, mortise_before, tenon_before)`: `-32603` (message contains `was not committed`) unless both results are `manifold?`, `joint_volume_problem` is nil, and `single_shell?(tenon_result)`.

Handler order: validate params as today → `start_operation("Mortise and Tenon", true)` → `E.find!` and the group guard for both boards → `require_joinable!` → `contact_area(board_box(mortise), board_box(tenon))` → `joint_box(contact, width, height, depth, [ox, oy, oz])` → record both volumes and both identities → `cut_mortise` → `attach_tenon` → `verify_joint!` with `expected = width * height * depth` → `restore_identity!` on both results → build the response → `commit_operation` → return it.

**Test fakes** (`test/test_mortise_tenon.rb`, with `SingletonStubs`): a recording model (`[:start, label]`, `:commit`, `:abort`; `find_entity_by_id`); a parent whose `entities` is a sentinel; boards subclassing the guarded `Sketchup::Group` (and one subclassing `Sketchup::ComponentInstance`) with `entityID`, `name`/`layer`/`material` and writers, `bounds` (`min`/`max` points in inches), `transformation` (`xaxis`/`yaxis`/`zaxis` returning objects with `to_a`), `parent`, `volume`, `manifold?`, `valid?`, `typename`, and faces answering `all_connected`. `Helpers::Geometry.make_box` is stubbed: it records its arguments and returns a cutter, then a tenon piece, whose `subtract`/`union` record their argument and return a configured result board (or nil). Helpers in the test: `mm(*v)` → inches, `mm3(v)` → in³.

- [ ] **Step 1: Write the failing tests**
  - `test_centred_boards_cut_and_join_and_commit_once` — leg `mm(0,0,0)`..`mm(50,50,300)` (volume `mm3(750_000)`, after `mm3(742_000)`), rail `mm(50,15,110)`..`mm(250,35,190)` (`mm3(320_000)` → `mm3(328_000)`), width 10, height 40, depth 20: log `[[:start, "Mortise and Tenon"], :commit]`; `make_box` called twice with `(parent.entities, *mm(30, 20, 130), *mm(20, 10, 40))` within 1e-9; the cutter's `subtract` got the leg and the piece's `union` got the rail; the response ids are the result boards' ids.
  - `test_offset_rail_joint_is_centred_on_the_contact_area` — rail `mm(50,0,200)`..`mm(250,20,280)`: `make_box` gets `(…, *mm(30, 5, 220), *mm(20, 10, 40))`.
  - `test_results_keep_the_boards_names_tags_and_materials`.
  - `test_component_instance_boards_are_accepted` — both boards are component instances; the results are groups carrying the instances' names.
  - Refusals — each `-32602` with its fragment, log `[[:start, label], :abort]`, `make_box` never called: `test_boards_with_different_parents_are_refused` (`same group`), `test_board_rotated_by_45_degrees_is_refused` (`multiple of 90`), `test_non_solid_board_is_refused` (`not a solid`), `test_separated_boards_are_refused` (`do not touch`), `test_joint_too_big_for_the_contact_area_is_refused` (`does not fit`).
  - `test_board_rotated_by_90_degrees_is_accepted` (axes `[0,1,0]`, `[-1,0,0]`, `[0,0,1]`).
  - `test_nil_from_subtract_rolls_back`, `test_nil_from_union_rolls_back` — `-32603`, log ends with `:abort`.
  - `test_empty_cut_is_refused_by_the_volume_check` (the leg's result keeps its volume) → `-32603`, `was not committed`.
  - `test_tenon_in_two_shells_is_refused` (the rail's result faces split into two connected sets) → `-32603`.
  - `test_non_solid_result_is_refused` → `-32603`.
  - `test_second_pocket_meeting_an_earlier_one_is_accepted` — the leg starts at `mm3(742_000)` and ends at `mm3(738_000)` → commits.

- [ ] **Step 2: Run them to verify they fail** — `ruby test/test_mortise_tenon.rb` → failures (the old handler builds a different geometry and returns `boolean_cuts`).

- [ ] **Step 3: Implement** the handler and helpers above; delete the old helpers and `test/test_joint_cut_stats.rb`.

- [ ] **Step 4: Update the pins and comments**
  - `test/test_operation_names.rb`: `test_joints_subtract_call_sites_keep_cutter_first` pins `/result = cutter\.subtract\(board\)/`; delete `test_subtract_tracked_body_receiver_is_cutter` (that pin now covers the receiver).
  - `test/test_handler_atomicity.rb`: the mortise-tenon row stays. The COMMITTING comment's last sentence becomes "create_mortise_tenon in test/test_mortise_tenon.rb." Replace the header's "ROWS holds all nine, so a handler that stops aborting fails here whatever its own tests cover. The last tests read the handler files and find every method that calls start_operation, so a new site without a row fails too, and pin that scan." with:

```
# ROWS holds all nine, so a handler that stops aborting fails here
# whatever its own tests cover. The last tests read the handler files and
# find the methods that call start_operation, within the limits listed
# above the scan, so a new site without a row fails too, and pin that scan.
```

  and replace "None of the silent patterns is in handlers/ today." with:

```
# None of the silent patterns was in handlers/ when this was written;
# check again when you add a handler.
```

- [ ] **Step 5: Run the Ruby suite** — `ruby test/test_mortise_tenon.rb`, then `ruby test/run_all.rb` → 0 failures, 0 errors.

- [ ] **Step 6: Commit**

```bash
git add -A mcp_for_sketchup/mcp_for_sketchup/handlers/joints.rb test
git commit -m "fix!: build a mortise-and-tenon joint on the contact area, or refuse"
```

---

### Task 5: The Python surface and the prompt for the new mortise-tenon

**Files:**
- Modify: `src/sketchup_mcp/tools.py` (the `create_mortise_tenon` docstring and the three offset descriptions)
- Modify: `src/sketchup_mcp/prompts.py` (§4 joinery bullet)
- Modify: `tests/test_tool_descriptions.py`

- [ ] **Step 1: Write the failing tests** — in `test_returns_lines_pin_top_response_shapes`, the `create_mortise_tenon` fragment becomes `"{mortise: {id, name, type, bbox_mm|null}, tenon: {...}}"`; add:

```python
async def test_mortise_tenon_description_states_the_contact_rules():
    tools = {t.name: t for t in await mcp.list_tools()}
    desc = " ".join((tools["create_mortise_tenon"].description or "").split())
    for fragment in ("touch face to face", "multiples of 90 degrees",
                     "new ids", "Nothing is half-built"):
        assert fragment in desc, fragment
    assert "boolean_cuts" not in desc
```

- [ ] **Step 2: Run them to verify they fail** — `uv run --locked pytest tests/test_tool_descriptions.py -q` → 2 failed.

- [ ] **Step 3: Replace the docstring** with:

```
Create a mortise-and-tenon joint between two boards that touch face to face.

All dimensions in millimeters. The boards must be solid groups or
component instances in the same parent, rotated only by multiples of 90
degrees, and touch along one face: no gap and no overlap. The joint is centred on
the area where they touch; offsets move it along the two axes across the
joint (the offset along the joint axis is ignored). width runs along the
first cross axis and height along the second: for a joint along X, width
is along Y and height along Z; along Y, width along X and height along Z;
along Z, width along X and height along Y. depth is how far the tenon
reaches into the mortise board; a depth beyond its thickness makes a
through mortise. The joint must fit inside the contact area and may reach
its edge. Defaults are sized for ~100 mm boards.

The mortise is cut into the mortise board and the tenon is joined to the
tenon board as one solid. Both boards come back as new groups with new
ids and keep their names, tags and materials. A joint that cannot be
built is refused: -32602 for boards that do not suit, -32603 when
SketchUp's solid operations fail. Nothing is half-built.

Returns: JSON {mortise: {id, name, type, bbox_mm|null}, tenon: {...}}.
```

The three offset descriptions become `"Joint offset from the center of the contact area along X, mm"` (Y, Z likewise).

- [ ] **Step 4: Replace the §4 joinery bullet in `prompts.py`** with:

```
- create_mortise_tenon returns {mortise, tenon}, each {id, name, type,
  bbox_mm}. Both boards come back with new ids and keep their names. The
  boards must touch face to face; a joint that cannot be built is
  refused, and nothing is half-built.
```

- [ ] **Step 5: Run the Python suite** — `uv run --locked pytest tests/ -q` → 0 failed.

- [ ] **Step 6: Commit**

```bash
git add src/sketchup_mcp/tools.py src/sketchup_mcp/prompts.py tests/test_tool_descriptions.py
git commit -m "docs: describe the contact rules of create_mortise_tenon"
```

---

### Task 6: The smoke check for the new joinery

**Files:**
- Modify: `examples/smoke_check.py` — steps 12–14 and 21, a module constant `_POCKET_RUBY`, the comment before step 24 and the cleanup list.

- [ ] **Step 1: Steps 12–14.** The boards no longer share the origin: create `smoke_mortise` (200×200×50 at the origin) and `smoke_tenon` (50×50×200 at `[75, 75, 50]`, on the top face), both with `name=`. After `create_mortise_tenon(width=20, height=30, depth=15)` rebind both ids and assert: both names are kept; the mortise bbox is still `[0,0,0]`–`[200,200,50]`; the tenon bbox runs from z 35 to 250 (within 0.5 mm).

- [ ] **Step 2: Step 21** becomes "mortise-tenon on a moved leg and an offset rail":
  - create `smoke_leg` (50×50×300) and move it to `[800, 0, 0]` twice, keeping the T-04 idempotency asserts of the old step;
  - create `smoke_rail` (200×20×80 at `[850, 0, 200]`: flush with the leg's front face and 200 mm up);
  - call `create_mortise_tenon(mortise_id=leg, tenon_id=rail, width=10, height=40, depth=20)`, rebind both ids and assert:
    - both names are kept;
    - the leg bbox x is still 800–850;
    - the rail bbox starts at x = 830;
  - through `_maybe_skip_eval`, run `_POCKET_RUBY` on the leg and assert the result is `[5.0, 15.0, 220.0, 260.0]`.

```python
# Ruby for step 21: the y and z extent (mm) of the leg's face at x = 830 mm that
# looks along +X — the bottom of the pocket.
_POCKET_RUBY = """
leg = Sketchup.active_model.find_entity_by_id(__ID__)
t = leg.transformation
face = leg.entities.grep(Sketchup::Face).find do |f|
  f.normal.transform(t).x > 0.99 &&
    f.vertices.all? { |v| ((t * v.position).x * 25.4 - 830.0).abs < 0.01 }
end
pts = face.vertices.map { |v| t * v.position }
[pts.map(&:y).min, pts.map(&:y).max, pts.map(&:z).min, pts.map(&:z).max].map { |v| (v * 25.4).round(1) }.to_json
"""
```

- [ ] **Step 3: Cleanup.** The comment before step 24 says "the step-21 mortise-tenon" instead of "the step-21 dovetail"; the cleanup list deletes the leg and the rail instead of `b_tail`, `b_pin`.

- [ ] **Step 4: Check it compiles and the helper tests pass** — `uv run --locked python -m py_compile examples/smoke_check.py` and `uv run --locked pytest tests/test_smoke_helpers.py -q` → no output / 0 failed. The live run is Task 8.

- [ ] **Step 5: Commit**

```bash
git add examples/smoke_check.py
git commit -m "test(smoke): mortise-tenon on touching and offset boards"
```

---

### Task 7: CI on Ruby 3.4, and the numbers in `CLAUDE.md`

**Files:**
- Modify: `.github/workflows/test.yml` — the `ruby` and `contract` jobs.
- Modify: `CLAUDE.md` — test counts and the smoke line.

- [ ] **Step 1: CI matrix.** Both jobs get `strategy: { fail-fast: false, matrix: { ruby-version: ['3.2', '3.4'] } }` and `ruby-version: ${{ matrix.ruby-version }}`. The comment says SketchUp 2024–2026 carry Ruby 3.2 and SketchUp 2027 carries 3.4.

- [ ] **Step 2: Counts.** Run `ruby test/run_all.rb` and `uv run --locked pytest tests/ -q`, and put the new runs, assertions and test counts into `CLAUDE.md` (Development Commands). The smoke line names the tools `examples/smoke_check.py` reaches out of 20 (recount the wire names it sends).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/test.yml CLAUDE.md
git commit -m "ci: run the Ruby suites on Ruby 3.2 and 3.4"
```

Ruby 3.4 is checked by CI once the branch is pushed for the PR (only 3.3 is installed locally); a 3.4 failure is fixed on this branch before merging.

---

### Task 8 (controller, live): verify in SketchUp

Not for a subagent: it drives the user's SketchUp. Start from the empty template with plugin 0.4.0 installed.

- [ ] **Step 1: Hot reload.** Make the local, gitignored `.superpowers/sdd/hot_reload.py` send `mcp_for_sketchup/mcp_for_sketchup/helpers/entities.rb` before the handlers (its list holds handler files only). Run `uv run --directory /opt/github/zinin/sketchup-mcp2 --locked python .superpowers/sdd/hot_reload.py HEAD` and record the SHA-256 lines. Check that `MCPforSketchUp::Handlers::Joints.method(:create_mortise_tenon).source_location` is `"(eval)"`. Ask the user for `/mcp` reconnect (the Python tools changed).
- [ ] **Step 2: Scenarios.** Name probes `probe_*` and erase them. For each joint that succeeds, measure the pocket's bottom face and the tenon's world bounds as in spec §3, and check that both results are solids and keep their names.

  | Scenario | Expected |
  |---|---|
  | centred boards | joint built |
  | offset boards | joint built |
  | separated boards | refused, `-32602` |
  | edge contact | refused, `-32602` |
  | overlapping boards | refused, `-32602` |
  | board rotated by 45° | refused, `-32602` |
  | joint larger than the contact area | refused, `-32602` |
  | board rotated by 90° | joint built |
  | through mortise (depth 60 into the 50 mm leg) | joint built |
  | joint reaching the contact edge | an open mortise, or `-32603` — never a wrong joint |
  | a second rail on the leg's adjacent face, pockets meeting inside | joint built |
  | both boards inside a group opened with `model.active_path` | the same result as with nothing open |
  | component-instance boards | joint built, names kept |
  | one `undo` after a joint | both boards restored |
- [ ] **Step 3: Smoke.** Through `build-forge:build-runner`: `SKETCHUP_MCP_HOST=192.168.20.20 uv run --locked python examples/smoke_check.py` → `ALL STEPS PASSED`, 26/26, no eval steps skipped. Then remove what it leaves behind: the layer "MCP Test", the material "red", the group its undo restores, the PNG and the `%TEMP%\sketchup_exports` folder.
- [ ] **Step 4: Baseline.** Check the model is back to 0 entities, 0 definitions, layers `[Layer0]`, no materials, and no exports folder. Tell the user the running SketchUp keeps the branch's handlers until it restarts.

---

After Task 8: the final whole-branch review, then `git rm` of `docs/superpowers/` before the PR (user's workflow).
