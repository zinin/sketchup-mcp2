# Block A (world coordinates and responses) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every `bbox_mm` and every `transform_component.position` is in world coordinates, edits inside a component placed more than once are refused, and the MCP surface reports errors and annotations properly, on branch `fix/p2-world-coordinates`.

**Architecture:** A new `Helpers::Frames` holds pure 4×4 matrix math on plain arrays and one walk up an entity's parents. The walk gives the matrix from the frame of `entity.bounds` to the world, the depth, and whether the entity is shared. Handlers report bounds through that matrix, conjugate world moves into the parent frame, and refuse shared targets. A new `Helpers::Operation.run` replaces the hand-written `start_operation` … `safe_abort` blocks in every mutating handler. On the Python side one annotation table drives both the tool annotations and the retry set, and errors come back as `isError` results.

**Tech Stack:** Ruby (SketchUp 2024–2027: Ruby 3.2 and 3.4) with minitest; Python ≥ 3.10, FastMCP (`mcp>=1.30,<2`), pytest.

**Spec:** `docs/superpowers/specs/2026-11-20-release-0.5.0-design.md`. The relevant sections are:
- §1 (the principle: refuse rather than build the wrong thing);
- §3 (live facts);
- §6 and §6.6a (block A);
- §9 (decisions);
- §10 (left to the builder).

## Global Constraints

- MCP tools take and return mm; the Ruby API works in inches. Convert at the boundary with `Helpers::Units` (`MM = 25.4`). The pure functions of `Frames` are unit-agnostic and are called with inches.
- `Group#subtract` is reversed: `a.subtract(b)` returns `b − a`.
- Never run an auto-formatter over handlers or tests. A literal source pin changes only in the task that changes the pinned code.
- No gem in the plugin; the Python floor stays 3.10; no version bump and no floor change on this branch (the release PR raises both).
- Unsuitable input → `Core::StructuredError.new(-32602, msg)`; a failed operation or post-check → `-32603`. Messages say what is wrong and what to do, with lengths in mm.
- Comments follow their surroundings (this codebase mixes Russian and English); docs and docstrings are English; commits are Conventional Commits in English.
- Every commit keeps `python -m sketchup_mcp` importable: this session's MCP server runs from the checkout.
- Commit only the files a task names. Never commit `docs/superpowers/plans/*-prompt.md`, `full-review/` or `.venv.broken-task8/`.
- After every task: `ruby test/run_all.rb` and `uv run --locked pytest tests/ -q` are green.
- **Matrices** are 16 Floats in column-major order, exactly as `Geom::Transformation#to_a` gives them: the translation is in elements 12–14. These values were checked live on SketchUp 2027:
  - a 90° rotation about Z through the origin is `[0,1,0,0, -1,0,0,0, 0,0,1,0, 0,0,0,1]`;
  - `scaling([1,2,3], 1,2,3)` is `[1,0,0,0, 0,2,0,0, 0,0,3,0, 0,-2,-6,1]`;
  - uniform scaling sits on the diagonal with `w = 1`.

  `Frames.normalize` still divides by a `w` other than 1. Only `Frames.transformation` builds a `Geom::Transformation`, and tests stub it.
- **Shared** (spec §6.2): the walk from `entity.parent` meets a definition with more than one instance. For a group or component instance the walk starts at its parent, so its own definition does not count.
  - The number of copies is the **holding** definition's `count_used_instances`. The holding definition is `entity.parent`, the one whose contents the edit would change.
  - Live on SketchUp 2027, `count_used_instances` counts placements through the hierarchy and leaves out definitions that are not placed. Example: a leg placed twice at the top level and twice inside a group that is copied twice gives 6, while `instances.length` gives 4.
- Handler modules alias the new helpers like the existing ones: `O = MCPforSketchUp::Helpers::Operation`, `F = MCPforSketchUp::Helpers::Frames`. A test file that loads a handler requires `helpers/operation` and `helpers/frames` first, or stubs the modules the way it already stubs the other helpers.
- **Test fakes.** Under `ruby test/run_all.rb` every test file loads into one process, so SketchUp stubs are shared between files and are guarded with `unless defined?`. Parent chains for the walk come from `test/support/frame_fakes.rb` (Task 2). Module functions are stubbed with `SingletonStubs`, never by reopening a class. When a task's change makes another test file's fakes need `parent`, `definition` or `to_a`, update that file too, commit it with the task and name it in the report.
- Tests compare computed Floats within a tolerance: `1e-9` for matrices and inches, `1e-6` for mm. Rotations carry rounding noise, and 25.4 is not exact in binary.
- **Rulings made in this plan.** The user can overrule any of them.
  1. `create_mortise_tenon` places the joint along world axes in every state (spec §6.6a asks for one frame). The boards' total rotation in the model must be a multiple of 90°, so a closed parent rotated by 30°, which block B accepted, is now refused.
  2. `eval_ruby` gets `openWorldHint: true`, because it can reach the file system, the network and the shell. Every other tool gets `false`.
  3. `boolean_operation` checks both operands for sharing.
  4. `get_model_info.editing` names an unnamed component instance by its definition, as the Outliner does.
  5. The walk stops with `-32603` beyond 64 levels, the old `LOOKUP_MAX_DEPTH`.

## Review Focus

1. **A group open for editing, moved and rotated, with a nested group inside.** `get_component_info`, `list_components` and `transform_component` report and reach the same world box whether the group is open or closed (spec §3). Tests: Task 3 `test_component_info_agrees_open_and_closed`, Task 5 `test_open_and_closed_parent_reach_the_same_world_target`, Task 11 live.
2. **Four chairs: one component placed several times, and copied groups.** Moving, painting or deleting one chair at the top level stays allowed. Anything inside a chair is refused, and the refusal gives the number of copies. Tests: Task 2 `test_the_entitys_own_definition_does_not_count`, Task 4 `test_top_level_copy_can_be_painted_and_deleted` and `test_face_inside_a_copied_group_is_refused`.
3. **A parent with non-uniform scale.** Boxes, transform targets and joint volumes come out right in world mm. Tests: Task 2 `test_world_box_through_a_scaled_parent`, Task 5 `test_position_inside_a_scaled_parent_reaches_the_world_target`, Task 7 `test_scaled_parent_divides_the_expected_volumes`.
4. **Warehouse or imported components (unnamed instances).** `find_components(name=…)` finds them by definition name, and the rows show `definition`. Tests: Task 3 `test_find_components_matches_a_definition_name` and `test_group_definition_names_are_not_matched`.
5. **An error seen through an MCP client.** `isError: true` with the text unchanged: `[code] message`, the eval-gate message verbatim, and the "SketchUp not running" line. `get_version` is never an error. Tests: Task 8 `test_ruby_error_is_an_error_result_with_the_same_text`, `test_eval_gate_message_is_an_error_result_verbatim`, `test_connection_down_is_an_error_result`, `test_get_version_is_never_an_error_result`.

---

### Task 1: One operation wrapper (M-16)

**Files:**
- Create: `mcp_for_sketchup/mcp_for_sketchup/helpers/operation.rb`
- Modify: `mcp_for_sketchup/mcp_for_sketchup/main.rb`. Add `helpers/operation` to `LOAD_ORDER` after `helpers/geometry`.
- Modify these handlers so that every mutating handler runs its body through `O.run`:
  - `handlers/geometry.rb`: `create_component`, `delete_component` and `transform_component`; also delete `safe_abort`;
  - `handlers/materials.rb`: `set_material`;
  - `handlers/operations.rb`: `boolean_operation` and `run_edge_op`;
  - `handlers/joints.rb`: `create_mortise_tenon`;
  - `handlers/model.rb`: `create_layer`.
- Create: `test/test_operation.rb`
- Modify: `test/test_operation_names.rb`, `test/test_handler_atomicity.rb`

**Interfaces:**
- Produces:
  - `Helpers::Operation.run(model, label) { … } -> the block's value`. It calls `model.start_operation(label, true)`, runs the block, calls `commit_operation` and returns the block's value. The block builds the response, so the response always exists before the commit. When the block does not complete — any exception, `StandardError` or not, or a `throw` — and also when `commit_operation` raises, it calls `safe_abort(model)` from an `ensure` and lets the exception through.
  - `Helpers::Operation.safe_abort(model) -> nil`, moved verbatim from `Handlers::Geometry`. Its log line names `Operation.safe_abort`.
  - `Operations.run_edge_op(entity_id, edge_indices, op_name, match_tolerance_in, done_key, skip_curved: false) { |cutter_entities, spec| … } -> Hash`. It returns the whole response: `describe_entity(fresh).merge(done_key => edges_done, "stats" => stats)`. `chamfer_edges` passes `"edges_chamfered"` and `fillet_edges` passes `"edges_filleted"`. `last_edges_done`, `last_stats`, `@_last_edges_done` and `@_last_stats` are deleted; the counts live in locals.

- [ ] **Step 1: Write the failing tests** — `test/test_operation.rb`. Its recording model logs `[:start, name, disable_ui]`, `:commit` and `:abort`, and the block can append its own marks. `safe_abort` logs through `Core::Logger.log`: stub it with `SingletonStubs`, so the file needs neither the logger nor the config.

```ruby
def test_run_commits_after_the_block_and_returns_its_value
  value = Op.run(@model, "Label") { @model.log << :built; 42 }
  assert_equal 42, value
  assert_equal [[:start, "Label", true], :built, :commit], @model.log
end

def test_run_aborts_on_a_standard_error_and_reraises
  err = assert_raises(RuntimeError) { Op.run(@model, "L") { raise "boom" } }
  assert_equal "boom", err.message
  assert_equal [[:start, "L", true], :abort], @model.log
end

def test_run_aborts_on_an_exception_outside_standard_error
  boom = Class.new(Exception)
  assert_raises(boom) { Op.run(@model, "L") { raise boom } }
  assert_equal [[:start, "L", true], :abort], @model.log
end

def test_run_aborts_when_the_block_throws
  catch(:out) { Op.run(@model, "L") { throw :out } }
  assert_equal [[:start, "L", true], :abort], @model.log
end

def test_run_aborts_when_commit_raises
  @model.define_singleton_method(:commit_operation) { log << :commit; raise "commit failed" }
  assert_raises(RuntimeError) { Op.run(@model, "L") { 1 } }
  assert_equal [[:start, "L", true], :commit, :abort], @model.log
end

def test_a_failing_abort_does_not_hide_the_original_error
  @model.define_singleton_method(:abort_operation) { raise "abort failed" }
  err = assert_raises(RuntimeError) { Op.run(@model, "L") { raise "original" } }
  assert_equal "original", err.message
end
```

- [ ] **Step 2: Run to verify they fail**
Run: `ruby test/test_operation.rb`
Expected: errors, because `Helpers::Operation` is not defined.

- [ ] **Step 3: Implement `helpers/operation.rb`**, then move every mutating handler onto it:
  - Each handler's `start_operation` … `commit_operation` … `rescue StandardError; safe_abort; raise` becomes `O.run(model, "<same label>") do … end`, with the response as the block's last expression.
  - Validation that runs before `start_operation` today stays before `O.run`.
  - `create_layer` passes its model variable `m`.
  - After this step no handler file mentions `start_operation`, `commit_operation`, `abort_operation` or `safe_abort` outside a comment.

- [ ] **Step 4: Update the pins deliberately**
  - `test/test_operation_names.rb`:
    - every `start_operation\("…"` pattern becomes `O\.run\(model, "…"`. The create_layer pattern uses `m`: `O\.run\(m, "Create Layer \(#\{name\}\)"`.
    - The run_edge_op guard region is `def self\.run_edge_op.*?O\.run\(`, and its message says "before the operation starts".
    - The catch-all scan reads `/\bO\.run\(\w+, "([^"]+)"/`.
    - Add `test_handlers_open_operations_only_through_the_wrapper`. It strips comment lines from each handler file and refutes `/\b(?:start|commit|abort)_operation\b|\bsafe_abort\b/`.
  - `test/test_handler_atomicity.rb`:
    - `operation_handlers` selects methods whose code matches `/\b(?:O|Operation)\.run[\s(]/`.
    - The synthetic sources in `test_the_scan_handles_bare_calls_plain_defs_helpers_and_comments` use `O.run(model, "Plain") do`, the bare `O.run model, "Bare" do` and so on, so that each case keeps what it tests.
    - The header says the handlers run through `Helpers::Operation.run`, which aborts on any exception.
    - The ROWS and their expected logs do not change.

- [ ] **Step 5: Run the suites**
Run: `ruby test/run_all.rb` and `uv run --locked pytest tests/ -q`
Expected: all green. The edge-op tests read `res["stats"]` and `res["edges_*"]` and need no change.

- [ ] **Step 6: Commit**

```bash
git add mcp_for_sketchup/mcp_for_sketchup/helpers/operation.rb mcp_for_sketchup/mcp_for_sketchup/main.rb \
  mcp_for_sketchup/mcp_for_sketchup/handlers/{geometry,materials,operations,joints,model}.rb \
  test/test_operation.rb test/test_operation_names.rb test/test_handler_atomicity.rb
git commit -m "refactor: run every mutating handler through one operation wrapper"
```

---

### Task 2: `Helpers::Frames` — matrices, the walk up the parents, shared entities

**Files:**
- Create: `mcp_for_sketchup/mcp_for_sketchup/helpers/frames.rb`
- Modify: `mcp_for_sketchup/mcp_for_sketchup/main.rb`. `helpers/frames` goes after `helpers/operation`.
- Modify: `mcp_for_sketchup/mcp_for_sketchup/helpers/entities.rb`. Extract `display_name`; `identity_of` uses it.
- Create: `test/support/frame_fakes.rb`, `test/test_frames.rb`

**Interfaces:**
- Produces in `Helpers::Frames`:
  - **Pure functions** (arrays of Floats, no SketchUp):
    - `IDENTITY` (frozen) and `MAX_DEPTH = 64`;
    - `multiply(a, b) -> m`: `a·b`, so `b` applies first;
    - `apply(m, [x,y,z]) -> [x,y,z]`;
    - `determinant(m) -> Float`, of the 3×3 part;
    - `inverse(m) -> m`: affine; raises `-32603` "…cannot be inverted (a scale of 0)…" when `|det| ≤ 1e-12`;
    - `identity?(m, tol = 1e-12) -> Boolean`;
    - `normalize(values) -> m`: Floats, divided by element 15 when that is not 1;
    - `translation(dx, dy, dz)`;
    - `rotation(center, axis, degrees)`: `axis` 0/1/2 is world X/Y/Z, right-handed, like `Geom::Transformation.rotation`;
    - `scaling(center, sx, sy, sz)`;
    - `conjugate(world, parent) -> m`: `inverse(parent)·world·parent`, the transformation that, applied in the parent frame, does `world` in the world;
    - `world_box(bounds, m) -> [[min x,y,z], [max x,y,z]]`: the box of the eight corners of `bounds` (anything with `min`/`max` points that answer `x`/`y`/`z`), mapped through `m`, as Floats;
    - `center(box) -> [x,y,z]`.
  - **SketchUp-facing functions:**
    - `matrix_of(transformation) -> m`, which is `normalize(transformation.to_a)`;
    - `transformation(m) -> Geom::Transformation`, which is `Geom::Transformation.new(m)`;
    - `Placement = Struct.new(:matrix, :depth, :shared)`, where `shared` is `nil` or `{label:, copies:}`;
    - `placement(entity) -> Placement`: the walk;
    - `label_of(definition) -> String`;
    - `shared?(definition) -> Boolean`, which is `definition.instances.length > 1`;
    - `copies_text(count) -> String`;
    - `require_unshared!(entity, what) -> Placement`;
    - `bbox_mm(bounds, m) -> {"min" => [mm, mm, mm], "max" => […]} | nil`;
    - `world_bbox_mm(entity) -> Hash | nil`;
    - `editing(model) -> [{"id", "name", "shared"}]`;
    - `require_open_path_unshared!(model) -> nil`.
  - `Helpers::Entities.display_name(entity) -> String`: the entity's name or, for an unnamed component instance, its definition's name.
  - In `test/support/frame_fakes.rb`:
    - a guarded `Sketchup::ComponentDefinition`;
    - `FrameFakes::Transform` (a Struct of `values` with `to_a`);
    - `FrameFakes.bounds(min, max)`, whose points answer `x`/`y`/`z`;
    - `FrameFakes::Definition.new(name, group: false, used: nil)`, a subclass of `Sketchup::ComponentDefinition`, with `instances` (starting empty), `group?`, `count_used_instances` (`used || instances.length`) and `bounds`;
    - `FrameFakes::Placed`, an instance with `entityID`, `name`, `parent`, `transformation` and `definition`;
    - `FrameFakes.place(definition, id:, parent:, matrix: IDENTITY, name: "")`, which builds a `Placed` and appends it to `definition.instances`;
    - `FrameFakes::Leaf.new(id, parent:, bounds:)`, a face-like entity.

**The walk.** `placement(entity)` starts with `IDENTITY`, depth 0, nothing shared, and `parent = entity.parent`. While `parent.is_a?(Sketchup::ComponentDefinition)`:
1. When the definition has no instances, stop: it is not placed in the model.
2. When the definition is `shared?` and nothing shared has been found yet, record `{label: label_of(parent), copies: entity.parent.count_used_instances}`.
3. Set `matrix = multiply(matrix_of(instances.first.transformation), matrix)`, add 1 to depth, and set `parent = instances.first.parent`.
4. Past `MAX_DEPTH`, raise `-32603`.

**Wording.** These strings are pinned by tests.
- `label_of`:
  - a component definition gives `component '<definition name>'`;
  - a group definition gives `group '<first instance's name>'`, or `an unnamed group` when that name is empty.
- `copies_text(n)`: `placed #{n} times in the model` when `n > 1`; otherwise `shared with a copy that is not placed in the model`.
- `require_unshared!(entity, what)` raises `-32602` with:
  `"#{what} is inside #{label}, which is #{copies_text(copies)}, so changing it would change every copy. To change all copies, edit the definition through eval_ruby; to change one copy, make it unique first (Make Unique in SketchUp, or make_unique through eval_ruby), then use the new ids of the entities inside it (list_components with recursive=true)"`
- `require_open_path_unshared!(model)`:
  - Take the innermost instance on `model.active_path` whose definition is `shared?`; call it `inst`.
  - Raise `-32602` with: `"#{label_of(inst.definition)} is open for editing and is #{copies_text(inst.definition.count_used_instances)}, so a new object would appear in every copy. Close it, or make the open copy unique first (Make Unique in SketchUp, or make_unique through eval_ruby), then retry"`
  - A nil or empty path, or a path with no shared instance, passes.
- `editing(model)`: `(model.active_path || []).map { |i| {"id" => i.entityID, "name" => Entities.display_name(i), "shared" => shared?(i.definition)} }`.
- `bbox_mm(bounds, m)` returns nil when `Helpers::Geometry.empty_bbox?(bounds)` is true; otherwise `world_box` converted to mm. `world_bbox_mm(entity)` is `bbox_mm(entity.bounds, placement(entity).matrix)`.

- [ ] **Step 1: Write the failing tests** — `test/test_frames.rb`. Compare matrices and points within `1e-9`. The tests:

```ruby
def test_rotation_has_sketchups_layout
  assert_matrix [0,1,0,0, -1,0,0,0, 0,0,1,0, 0,0,0,1], F.rotation([0, 0, 0], 2, 90)
end
def test_scaling_has_sketchups_layout
  assert_matrix [1,0,0,0, 0,2,0,0, 0,0,3,0, 0,-2,-6,1], F.scaling([1, 2, 3], 1, 2, 3)
end
def test_multiply_applies_the_right_matrix_first
  assert_point [1, 1, 0], F.apply(F.multiply(F.translation(1, 0, 0), F.rotation([0, 0, 0], 2, 90)), [1, 0, 0])
end
def test_rotation_turns_about_its_center
  assert_point [0, 1, 0], F.apply(F.rotation([1, 1, 0], 2, 180), [2, 1, 0])
end
def test_inverse_undoes_an_affine_matrix
  m = F.multiply(F.translation(5, -2, 7), F.multiply(F.rotation([1, 2, 3], 0, 30), F.scaling([0, 0, 0], 2, 1, 0.5)))
  assert_matrix F::IDENTITY, F.multiply(F.inverse(m), m)
end
def test_inverse_refuses_a_singular_matrix          # scaling(…, 1, 0, 1) → -32603
def test_normalize_divides_by_w
  assert_equal [1.0,0,0,0, 0,1.0,0,0, 0,0,1.0,0, 1.0,2.0,3.0,1.0], F.normalize([2,0,0,0, 0,2,0,0, 0,0,2,0, 2,4,6,2])
end
def test_conjugate_performs_the_world_move_in_the_parent_frame
  parent = F.multiply(F.translation(100, 0, 0), F.rotation([0, 0, 0], 2, 90))
  local  = F.conjugate(F.translation(10, 0, 0), parent)
  assert_point F.apply(parent, [3, 4, 5]).zip([10, 0, 0]).map(&:sum), F.apply(parent, F.apply(local, [3, 4, 5]))
end
def test_world_box_of_a_rotated_box                 # bounds (0,0,0)-(2,1,1), Z 90° → [[-1,0,0],[0,2,1]]
def test_world_box_through_a_scaled_parent          # bounds (0,0,0)-(1,1,1) through translation(10,0,0)·scaling(origin, 2,1,1) → [[10,0,0],[12,1,1]]
def test_top_level_entity_has_identity_and_no_sharing   # parent = Object.new → IDENTITY, depth 0, shared nil
def test_nested_entity_multiplies_its_parents_outermost_first
  # outer at translation(100,0,0)·rotation Z 90 in the model; inner at translation(0,0,20) in outer's definition;
  # a Leaf in inner's definition → matrix == multiply(outer_m, inner_m), depth 2, shared nil
def test_a_definition_placed_twice_makes_its_contents_shared
  # component "Leg" with placements at translation(10,0,0) and translation(20,0,0); a Leaf in it →
  # shared == {label: "component 'Leg'", copies: 2}; matrix from the FIRST placement
def test_the_entitys_own_definition_does_not_count  # a top-level group whose definition has 2 instances → shared nil
def test_copies_come_from_the_holding_definition
  # Leaf in "Seat" (1 placement, used: 4) inside "Chair" (2 placements) → {label: "component 'Chair'", copies: 4}
def test_copied_group_is_labelled_by_its_instance_name  # group definition, first instance "Top" → "group 'Top'"; unnamed → "an unnamed group"
def test_an_unplaced_definition_ends_the_walk       # Leaf in a definition without instances → IDENTITY, depth 0, shared nil
def test_a_walk_past_max_depth_is_refused           # a definition placed inside itself → -32603
def test_require_unshared_refuses_with_the_copy_count
  # assert_equal the full message for what = "entity 7", component 'Leg', copies 2
def test_require_unshared_names_a_copy_outside_the_model   # used: 1 → "…which is shared with a copy that is not placed in the model, …"
def test_require_unshared_returns_the_placement
def test_bbox_mm_maps_bounds_through_the_matrix
  assert_bbox_mm({ "min" => [25.4, 0.0, 0.0], "max" => [50.8, 50.8, 101.6] },
                 F.bbox_mm(FrameFakes.bounds([0, 0, 0], [1, 2, 4]), F.translation(1, 0, 0)))  # within 1e-6
end
def test_bbox_mm_is_nil_for_empty_bounds            # min > max
def test_editing_lists_the_open_path
  # active_path [outer group "Outer" (1 instance), unnamed instance of "Leg" (2 instances)] →
  # [{"id"=>1, "name"=>"Outer", "shared"=>false}, {"id"=>2, "name"=>"Leg", "shared"=>true}]
def test_editing_is_empty_when_nothing_is_open      # active_path nil → []
def test_require_open_path_unshared_refuses_inside_a_shared_component   # full message, "component 'Leg' is open for editing and is placed 2 times …"
def test_require_open_path_unshared_passes_a_unique_path
```

- [ ] **Step 2: Run to verify they fail**
Run: `ruby test/test_frames.rb`
Expected: errors, because `Helpers::Frames` is not defined.

- [ ] **Step 3: Implement `helpers/frames.rb`, `FrameFakes` and `Entities.display_name`.** `world_box` reads each bounds point with `.x.to_f` and its siblings: SketchUp's `Length` compares within tolerance, and the math wants Floats.

- [ ] **Step 4: Run the suites**
Run: `ruby test/test_frames.rb`, `ruby test/run_all.rb`
Expected: green, `test_entities_identity.rb` included.

- [ ] **Step 5: Commit**

```bash
git add mcp_for_sketchup/mcp_for_sketchup/helpers/frames.rb mcp_for_sketchup/mcp_for_sketchup/helpers/entities.rb \
  mcp_for_sketchup/mcp_for_sketchup/main.rb test/support/frame_fakes.rb test/test_frames.rb
git commit -m "feat: add world-frame matrices and the walk up an entity's parents"
```

---

### Task 3: Read-only tools in world coordinates, with `shared`, `definition` and `editing` (§6.1, §6.2, §6.5)

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/model.rb`
- Create: `test/test_model_world.rb`
- Modify: `test/test_collect_components.rb`, `test/test_model_empty_bbox.rb`, `test/test_model_pagination.rb`. Their `Geom::Transformation` fakes gain a `to_a` that returns the identity array. Their group and instance fakes gain a `definition` that answers `instances` and, for components, `name`. Direct calls to `describe_component` pass `Frames::IDENTITY` where they passed a `Geom::Transformation`.

**Interfaces:**
- Consumes: `F.placement`, `F.multiply`, `F.matrix_of`, `F.shared?`, `F.bbox_mm`, `F.editing`, and `F::IDENTITY` from Task 2.
- Produces:
  - `Model.describe_component(entity, parent_matrix = F::IDENTITY, depth: 0, shared: false) -> Hash`. The row is `{"id", "name", "type", "layer", "depth", "shared", "bbox_mm"}`. A component instance also carries `"definition" => entity.definition.name`; a group carries no `definition` key. `bbox_mm` is `F.bbox_mm(entity.bounds, parent_matrix)` and is nil for empty bounds.
  - `Model.collect_components(entities, parent_matrix, recursive:, depth:, max_depth:, seen:, shared: false)`. A child's matrix is `F.multiply(parent_matrix, F.matrix_of(entity.transformation))`. A child is shared when `shared || F.shared?(entity.definition)`. The traversal and the cycle guard stay as they are.
  - `Model.describe_placed(entity) -> Hash`. It runs `p = F.placement(entity)` and returns `describe_component(entity, p.matrix, depth: p.depth, shared: !p.shared.nil?)`. `get_component_info` and the group/instance rows of `get_selection` use it. `find_component_by_id` and `LOOKUP_MAX_DEPTH` are deleted.
  - `find_components(name=…)` matches a lower-cased substring of `name` or of `definition`.
  - `paginate` keeps `id name type layer depth shared definition` in concise rows.
  - `get_model_info` gains `"editing" => F.editing(m)`.

- [ ] **Step 1: Write the failing tests** — `test/test_model_world.rb`. Scenes come from `FrameFakes`, and targets are guarded `Sketchup::Group`/`ComponentInstance` subclasses with `parent`, `bounds`, `transformation`, `definition`, `layer` and `name`. `Entities.active_model!` is stubbed.
  - `test_get_component_info_reports_world_bbox_through_parents`: an inner group with bounds (0,0,0)–(1,1,1) inches inside an outer group placed at `translation(10,0,0)·rotation Z 90°`. Expect `bbox_mm` `{"min"=>[228.6, 0.0, 0.0], "max"=>[254.0, 25.4, 25.4]}`, `depth` 1, `shared` false.
  - `test_component_info_agrees_open_and_closed`: the same inner group with the outer group open. Model that the way SketchUp reports it (spec §3): the outer placement has the identity matrix, and the inner group's bounds are its world box. Expect the same `bbox_mm` as the closed scene.
  - `test_shared_child_reports_the_first_placement`: a child of a component placed at x = 10 and x = 20 inches. Expect `shared` true and the box of the x = 10 placement.
  - `test_list_rows_carry_shared_and_definition`: recursive listing of a component "Leg" placed twice, with a child group. The two "Leg" rows have `"definition"=>"Leg"` and `shared` false. The two child rows have `shared` true and no `definition` key.
  - `test_find_components_matches_a_definition_name`: an unnamed instance of "Oak Chair" is found by `name: "chair"`.
  - `test_group_definition_names_are_not_matched`: a group whose definition is "Group#3" is not found by `name: "group#"`.
  - `test_concise_rows_keep_shared_and_definition`.
  - `test_get_selection_reports_world_bbox_and_shared`: a nested group in the selection has the same row as `get_component_info`; a face in the selection stays `{id, type}`.
  - `test_get_model_info_reports_the_open_path`: `editing` equals `F.editing(model)` for a two-level path, and is `[]` with nothing open.

- [ ] **Step 2: Run to verify they fail**
Run: `ruby test/test_model_world.rb`
Expected: FAIL: parent-frame boxes, and no `shared`, `definition` or `editing`.

- [ ] **Step 3: Implement the interfaces above in `model.rb`.** Rewrite the comments above `get_component_info` and `list_components` to describe the walk and the `shared` flag.

- [ ] **Step 4: Run the suites**
Run: `ruby test/run_all.rb`, `uv run --locked pytest tests/ -q`
Expected: green.

- [ ] **Step 5: Commit**

```bash
git add mcp_for_sketchup/mcp_for_sketchup/handlers/model.rb test/test_model_world.rb \
  test/test_collect_components.rb test/test_model_empty_bbox.rb test/test_model_pagination.rb
git commit -m "feat: report world boxes, shared flags and definition names from the read-only tools"
```

---

### Task 4: World boxes in mutating responses; refuse shared targets (§6.1, §6.2)

**Files:**
- Modify:
  - `mcp_for_sketchup/mcp_for_sketchup/handlers/geometry.rb`. `describe_entity` computes `bbox_mm` with `F.world_bbox_mm(entity)`. `create_component` calls `F.require_open_path_unshared!(model)` before `O.run`. `delete_component` and `transform_component` call `F.require_unshared!(entity, "entity #{id}")` right after the group guard.
  - `handlers/materials.rb`: `set_material` checks its target the same way after `require_paintable!`.
  - `handlers/operations.rb`: `boolean_operation` checks the target (`"target (entity #{target_id})"`) and the tool (`"tool (entity #{tool_id})"`); `run_edge_op` checks its target (`"entity #{entity_id}"`).
- Create: `test/test_shared_refusals.rb`
- Modify the fakes that reach `describe_entity` or the checks. They gain `parent`: the fake model, or a `FrameFakes::Definition` in nested cases.
  - `test/test_handler_atomicity.rb`. Its `RecordingModel` also gains `active_path`, which returns nil.
  - `test/test_transform_absolute.rb`
  - `test/test_materials.rb`
  - `test/test_boolean_direction.rb`
  - `test/support/edge_fakes.rb` and `test/test_edge_ops.rb`
  - `test/test_geometry_builders.rb`
  - `test/test_geometry_guards.rb`

**Interfaces:**
- Consumes: `F.world_bbox_mm`, `F.require_unshared!` and `F.require_open_path_unshared!` from Task 2; `O.run` from Task 1.
- Produces:
  - `describe_entity` keeps its shape `{id, name, type, bbox_mm}`, and `bbox_mm` is world.
  - A refusal of a target found inside the operation logs `[[:start, label], :abort]`.
  - The `create_component` refusal comes before any operation, so its log is empty.
  - `create_mortise_tenon` is covered in Task 7.

- [ ] **Step 1: Write the failing tests** — `test/test_shared_refusals.rb`. The scene is a recording model as in `test_handler_atomicity.rb`, and component "Chair" with two top-level placements. A seat group (entity 7, a `Sketchup::Group` subclass) and a face (entity 8) live in Chair's definition. Each test asserts the exact `F.require_unshared!` message and the log:
  - `test_delete_refuses_an_entity_inside_a_shared_component`: `"entity 7 is inside component 'Chair', which is placed 2 times in the model, so changing it would change every copy. …"`, and the log `[[:start, "Delete Component"], :abort]`.
  - `test_transform_refuses_an_entity_inside_a_shared_component`
  - `test_face_inside_a_copied_group_is_refused`: `set_material` on a face inside a group definition with two instances, the first named "Top". The message names `group 'Top'`.
  - `test_boolean_refuses_a_shared_target` and `test_boolean_refuses_a_shared_tool`
  - `test_chamfer_refuses_a_shared_target`
  - `test_top_level_copy_can_be_painted_and_deleted`: a top-level group whose own definition has two instances. `set_material` and `delete_component` both commit.
  - `test_create_component_refuses_inside_an_open_shared_component`: `active_path` is `[a Chair placement]`. Assert the exact message and `@model.log == []`.
  - `test_create_component_passes_an_open_unique_group`: `active_path` is a unique group, and `active_entities.add_group` raises a sentinel error. The sentinel propagates with the log `[[:start, "Create Component (Cube)"], :abort]`.
  - `test_mutating_responses_report_world_bbox`: `set_material` on a face with bounds (0,0,0)–(1,1,0) inches inside a unique group placed at `translation(10,0,0)`. Expect `bbox_mm` `{"min"=>[254.0, 0.0, 0.0], "max"=>[279.4, 25.4, 0.0]}`.

- [ ] **Step 2: Run to verify they fail**
Run: `ruby test/test_shared_refusals.rb`
Expected: FAIL. Nothing refuses, and boxes are in the parent frame.

- [ ] **Step 3: Implement the changes listed under Files**, then add `parent` and `active_path` to the existing fakes until the whole suite is green. Change fakes, not assertions. If an existing assertion has to change, say why in the report.

- [ ] **Step 4: Run the suites**
Run: `ruby test/run_all.rb`, `uv run --locked pytest tests/ -q`
Expected: green.

- [ ] **Step 5: Commit**

```bash
git add mcp_for_sketchup/mcp_for_sketchup/handlers/{geometry,materials,operations}.rb test/test_shared_refusals.rb \
  test/test_handler_atomicity.rb test/test_transform_absolute.rb test/test_materials.rb test/test_boolean_direction.rb \
  test/support/edge_fakes.rb test/test_edge_ops.rb test/test_geometry_builders.rb test/test_geometry_guards.rb
git commit -m "feat: refuse edits inside shared components and report world boxes after edits"
```

---

### Task 5: `transform_component` with a world target and world axes (§6.1)

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/geometry.rb`: `transform_component`, `apply_rotation` and `position_delta`.
- Modify: `test/test_transform_absolute.rb`. Update its pins deliberately, and the behavioural class too.

**Interfaces:**
- Consumes: `F.require_unshared!`, which returns the placement (Task 2/4); `F.world_box`, `F.center`, `F.rotation`, `F.scaling`, `F.translation`, `F.conjugate`, `F.transformation`.
- Produces:
  - `position_delta(world_min, target) -> [dx, dy, dz]`, both arrays in inches.
  - `apply_rotation(entity, rot_degrees, parent)`. It computes the world centre once and turns about world X, then Y, then Z, skipping zero angles.
  - `parent = F.require_unshared!(entity, "entity #{id}").matrix`. Every change goes through `entity.transform!(F.transformation(F.conjugate(<world matrix>, parent)))`.
  - The order stays rotation → scale → position. Scale uses the world centre after the rotation, and position uses the world box after both.

The position block is pinned, so write it exactly like this:

```ruby
          if position
            world_min = F.world_box(entity.bounds, parent)[0]
            delta = position_delta(world_min, position)
            entity.transform!(F.transformation(F.conjugate(F.translation(*delta), parent)))
          end
```

- [ ] **Step 1: Write the failing tests** in `test/test_transform_absolute.rb`:
  - The pure tests call `position_delta` with arrays.
  - The source guard asserts `/world_min = F\.world_box\(entity\.bounds, parent\)\[0\]/`, `/delta = position_delta\(world_min, position\)/` and `/F\.conjugate\(F\.translation\(\*delta\), parent\)/`. It refutes `/F\.translation\(\*position\)/` and `/Geom::Transformation\.translation/`.
  - The behavioural class stubs `F.transformation` with `SingletonStubs` so that it returns a marker carrying the matrix. `FakeEntity#transform!` records the markers.
  - `test_position_moves_world_bbox_min_to_target_at_top_level`: bounds (10,0,0)–(14,4,4) inches, position `[381.0, 0, 0]` mm. Expect one transform whose matrix is `translation(5,0,0)`.
  - `test_position_inside_a_rotated_parent_is_conjugated`: parent `P = translation(100,0,0)·rotation Z 90°`, bounds (0,0,0)–(2,1,1), whose world box is [[99,0,0],[100,2,1]]. The target is `[0,0,0]` mm. Expect `F.multiply(P, recorded) ≈ F.multiply(F.translation(-99, 0, 0), P)`.
  - `test_position_inside_a_scaled_parent_reaches_the_world_target`: `P = scaling(origin, 2,1,1)`, bounds (1,0,0)–(2,1,1), and a target of 254 mm (10 in) on x. Expect `F.apply(P, F.apply(recorded, [1, 0, 0])) ≈ [10, 0, 0]`.
  - `test_rotation_turns_about_world_axes_through_the_world_center`: the same `P` as the rotated case and rotation `[0, 0, 90]`. Expect one transform, and `P·recorded ≈ F.rotation(world_center, 2, 90)·P`.
  - `test_scale_is_along_world_axes_about_the_world_center`: the same check with `F.scaling(world_center, 2, 1, 1)`.
  - `test_open_and_closed_parent_reach_the_same_world_target`:
    - Closed: the parent `P` and local bounds.
    - Open, as spec §3 describes it: the parent placement is the identity, and the bounds are the world box.
    - The same target gives the same world move in both, `P·L_closed·P⁻¹ ≈ L_open`.
  - `test_transform_component_commits_on_success`: kept.

- [ ] **Step 2: Run to verify they fail**
Run: `ruby test/test_transform_absolute.rb`
Expected: FAIL. The pins are missing, and the delta is in the parent frame.

- [ ] **Step 3: Implement the changes**, and rewrite the comment above `transform_component` for world semantics.

- [ ] **Step 4: Run the suites**
Run: `ruby test/run_all.rb`
Expected: green.

- [ ] **Step 5: Commit**

```bash
git add mcp_for_sketchup/mcp_for_sketchup/handlers/geometry.rb test/test_transform_absolute.rb
git commit -m "feat: move, rotate and scale nested entities in world coordinates"
```

---

### Task 6: Names after solid operations (§6.3)

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/operations.rb`
- Modify: `test/test_boolean_direction.rb`, `test/test_edge_ops.rb`, `test/support/edge_fakes.rb`

**Interfaces:**
- Consumes: `E.identity_of` and `E.restore_identity!` (block B).
- Produces:
  - `run_edge_op` takes `identity = E.identity_of(entity)` after its checks and before the first cut, and calls `E.restore_identity!(fresh, identity)` before `describe_entity(fresh)`.
  - `boolean_operation` takes `identity = E.identity_of(target)` before the solid operation when `delete_originals` is true, and calls `E.restore_identity!(result, identity)` after it. With `delete_originals` false nothing is restored, and the result keeps SketchUp's name.

- [ ] **Step 1: Write the failing tests**
  - `test/test_boolean_direction.rb`:
    - `test_delete_originals_gives_the_result_the_targets_identity`: the result gets the target's name, layer and material.
    - `test_kept_originals_leave_the_result_name_alone`: the result's name stays whatever the fake set, "Union".
  - `test/test_edge_ops.rb`:
    - `test_chamfered_body_keeps_its_name_tag_and_material`;
    - `test_unnamed_instance_result_takes_the_definition_name`.
- [ ] **Step 2: Run to verify they fail**
Run: `ruby test/test_boolean_direction.rb`, `ruby test/test_edge_ops.rb`
Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the suites**
Run: `ruby test/run_all.rb`
Expected: green.
- [ ] **Step 5: Commit**

```bash
git add mcp_for_sketchup/mcp_for_sketchup/handlers/operations.rb test/test_boolean_direction.rb test/test_edge_ops.rb test/support/edge_fakes.rb
git commit -m "feat: keep the target's name, tag and material on edge and boolean results"
```

---

### Task 7: Mortise and tenon in world axes (§6.6a)

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/joints.rb`
- Modify: `test/test_mortise_tenon.rb`, `test/test_joint_geometry.rb`

**Interfaces:**
- Consumes: Frames (Task 2), `O.run` (Task 1), and the world-box `describe_entity` (Task 4).
- Produces:
  - `require_joinable!(model, mortise, tenon) -> parent_matrix`. It checks, in this order:
    1. a board open for editing — unchanged;
    2. the same parent — unchanged;
    3. `F.require_unshared!(mortise, "the mortise board")` and `F.require_unshared!(tenon, "the tenon board")`;
    4. world alignment: for each board, `W = F.multiply(P, F.matrix_of(board.transformation))` must pass `world_aligned?(W)`, else `ROTATION_MESSAGE` for that label;
    5. `manifold?` — unchanged.

    The check of an open group rotated off-axis is deleted. Its case now gets `ROTATION_MESSAGE` in both states.
  - `world_aligned?(m)` is `axis_aligned?([m[0..2], m[4..6], m[8..10]])`. `aligned_transformation?` is deleted.
  - `board_box(board, parent)` is `F.world_box(board.definition.bounds, F.multiply(parent, F.matrix_of(board.transformation)))`. It uses the definition's bounds, so the box is the same whether or not the boards' parent is open.
  - `cut_mortise(board, box, parent)` and `attach_tenon(board, box, parent)` build the piece with `make_box(board.parent.entities, *make_box_args(box))`, with the box in world inches. Then `piece.transform!(F.transformation(F.inverse(parent))) unless F.identity?(parent)`. The pinned line `result = cutter.subtract(board)` stays.
  - The expected volumes are in the parent frame: `cut` and `joint` are divided by `F.determinant(parent).abs`.
  - `joint_volume_problem(…) -> nil | [sentence, kind]`. The sentences do not change. The kinds are:
    - `:shortfall` when `cut*rtol < lost < cut - cut*rtol`;
    - `:cut` for any other wrong mortise loss: nothing removed, too much, or a gain;
    - `:join` when the tenon board is off.
  - `verify_joint!` maps `:shortfall` → `SHORTFALL_ADVICE`, `:cut` → `CUT_ADVICE` and `:join` → `JOIN_ADVICE`. The general sentence before the advice does not change.

The two new messages are pinned:

```ruby
      ROTATION_MESSAGE = "is rotated in the model by an angle that is not a multiple of 90°, and the joint " \
        "is placed along the model's axes from bounding boxes; rotate the board, or the group or component " \
        "that holds it, to a multiple of 90°, or build this joint with eval_ruby"
      # raised as "the #{label} #{ROTATION_MESSAGE}"

      SHORTFALL_ADVICE =
        "Make the joint shallower, or move it with the offsets, so that its pocket stays clear of the " \
        "earlier one"
```

- [ ] **Step 1: Write the failing tests**
  - `test/test_joint_geometry.rb`: the volume tests expect `[sentence, kind]`, and they add a kind case for each of:
    - lost 0.5·cut → `:shortfall`;
    - lost 0 → `:cut`;
    - lost 1.5·cut → `:cut`;
    - a mortise gain → `:cut`;
    - a tenon shortfall → `:join`.
  - `test/test_mortise_tenon.rb`. Fakes: boards gain `definition.bounds` and `transformation.to_a`; the parent stays a non-definition sentinel unless a test puts the boards in a `FrameFakes::Definition`. The tests:
    - `test_parent_rotated_90_builds_in_world_axes`: the boards' parent is placed at `rotation Z 90°`. `make_box` receives the world box, and the piece gets `transform!` with `F.inverse(P)`.
    - `test_open_and_closed_parent_give_the_same_joint`:
      - Closed: the parent `P` and local board matrices.
      - Open: the parent placement is the identity and each board's matrix is `P·local`.
      - `make_box` receives the same arguments in both.
    - `test_parent_rotated_30_is_refused_with_the_model_axes_message`: closed. The message is `"the mortise board #{ROTATION_MESSAGE}"`.
    - `test_open_parent_rotated_30_gets_the_same_message`: the parent placement is the identity, the boards' matrices include the 30°, and `active_path` is `[the parent]`.
    - `test_boards_beside_an_open_group_get_the_same_message`: `active_path` is `[P, Q]` and the boards are in `P`, rotated 30°.
    - `test_shared_board_is_refused`: the boards' parent definition has two placements. Expect the `F.require_unshared!` message for "the mortise board".
    - `test_scaled_parent_divides_the_expected_volumes`: the parent is `scaling(origin, 2,2,2)`. Result volumes 1/8 of the world volumes pass, and the world volumes themselves fail.
    - `test_volume_shortfall_gets_its_own_advice`: the message ends with `SHORTFALL_ADVICE` and does not contain `CUT_ADVICE`.

    Delete the block B tests of the open-rotated-group refusal, which `test_open_parent_rotated_30_gets_the_same_message` replaces.
- [ ] **Step 2: Run to verify they fail**
Run: `ruby test/test_joint_geometry.rb`, `ruby test/test_mortise_tenon.rb`
Expected: FAIL.
- [ ] **Step 3: Implement.** Rewrite the module and `require_joinable!` comments: boxes are world, in inches; joints follow world axes in every edit state.
- [ ] **Step 4: Run the suites**
Run: `ruby test/run_all.rb`
Expected: green. `test_operation_names.rb` still finds `result = cutter.subtract(board)`.
- [ ] **Step 5: Commit**

```bash
git add mcp_for_sketchup/mcp_for_sketchup/handlers/joints.rb test/test_mortise_tenon.rb test/test_joint_geometry.rb
git commit -m "feat: place mortise-and-tenon joints along world axes in every edit state"
```

---

### Task 8: MCP surface — errors, structured output, annotations, retry set, version, screenshot size (§6.6)

**Files:**
- Create: `src/sketchup_mcp/annotations.py`, `tests/test_annotations.py`
- Modify: `src/sketchup_mcp/tools.py`, `src/sketchup_mcp/connection.py`, `src/sketchup_mcp/app.py`, `src/sketchup_mcp/prompts.py` (§8, one sentence)
- Modify: `tests/test_tools.py`, `tests/test_screenshot.py`, `tests/test_version_handshake.py`, `tests/test_app.py`

**Interfaces:**
- Produces:
  - `annotations.TOOL_ANNOTATIONS: dict[str, ToolAnnotations]`, keyed by MCP tool name. Each value comes from `_hints(read_only, destructive=False, idempotent=False, open_world=False)`.
  - `annotations.WIRE_NAMES = {"chamfer_edge": "chamfer_edges", "fillet_edge": "fillet_edges", "export_scene": "export"}`.
  - `annotations.read_only_wire_names() -> frozenset[str]`.
  - `connection._RETRY_SAFE_TOOLS = read_only_wire_names()`.
  - In `tools.py`, the decorator `_tool(fn)` is `mcp.tool(annotations=TOOL_ANNOTATIONS[fn.__name__], structured_output=False)(fn)` and replaces `@mcp.tool()` everywhere.
  - `_error(text) -> CallToolResult` is `CallToolResult(content=[TextContent(type="text", text=text)], isError=True)`.
  - `_call` returns `str | CallToolResult`.

The annotation table:

| Tool | readOnly | destructive | idempotent | openWorld |
|---|---|---|---|---|
| `get_model_info`, `list_components`, `get_component_info`, `find_components`, `list_layers`, `get_selection`, `get_viewport_screenshot`, `get_version` | true | false | true | false |
| `create_component`, `export_scene` | false | false | false | false |
| `create_layer` | false | false | true | false |
| `delete_component`, `set_material` | false | true | true | false |
| `transform_component`, `boolean_operation`, `chamfer_edge`, `fillet_edge`, `create_mortise_tenon`, `undo` | false | true | false | false |
| `eval_ruby` | false | true | false | **true** |

Error shapes. The texts are the strings these paths return today, now returned as `_error(...)`:
- a `ConnectionError` → `f"SketchUp not running or extension not started: {e}"`;
- a `SketchUpError` → `format_error(e, debug=…)`, with the tool-name backfill kept;
- `eval_ruby` with `-32010` → `e.message` verbatim;
- `get_viewport_screenshot`:
  - a connection failure → the "SketchUp not running …" line;
  - any `SketchUpError`, from Ruby or a local decode check → `format_error`, with the tool name backfilled.

  It no longer raises.
- `get_version` is unchanged: it always returns a payload, never an error.

In `app.py`, right after `FastMCP(...)`, set `mcp._mcp_server.version = __version__`, with a comment saying why: FastMCP 1.30 takes no version argument, and without this `serverInfo.version` is the `mcp` package's version. `get_viewport_screenshot.max_size` becomes `Field(ge=64, le=2000, …)`, and its docstring says 64..2000. The `eval_ruby` docstring says the gate message comes back as an error result, verbatim. `prompts.py` §8 says the call "returns an error whose text starts with "eval_ruby is disabled."".

- [ ] **Step 1: Write the failing tests**
  - `tests/test_annotations.py`:

```python
async def test_every_tool_carries_its_annotations():
    tools = {t.name: t.annotations for t in await mcp.list_tools()}
    assert tools == TOOL_ANNOTATIONS

def test_retry_safe_tools_are_the_read_only_ones():
    assert connection._RETRY_SAFE_TOOLS == read_only_wire_names() == {
        "get_model_info", "list_components", "get_component_info", "find_components",
        "list_layers", "get_selection", "get_viewport_screenshot", "get_version"}

async def test_tools_return_no_structured_content():
    assert all(t.outputSchema is None for t in await mcp.list_tools())

def test_server_info_reports_the_package_version():
    assert mcp._mcp_server.create_initialization_options().server_version == sketchup_mcp.__version__
```

  - `tests/test_tools.py`:
    - `test_ruby_error_is_an_error_result_with_the_same_text`: `isError` is True and `content[0].text` equals the old `format_error` string.
    - `test_connection_down_is_an_error_result`
    - `test_eval_gate_message_is_an_error_result_verbatim`
    - `test_get_version_is_never_an_error_result`
    - `test_success_is_a_list_without_structured_content`: `await mcp.call_tool("list_layers", {})` with a mocked `send_command` returns a `list`, not a tuple.

    Rewrite the existing error-path tests (`test_call_handles_connection_error_gracefully`, `test_call_formats_sketchup_error`, `test_call_fills_tool_name_when_error_lacks_it` and the eval ones) to read `.isError` and `.content[0].text`.
  - `tests/test_screenshot.py`: the raising tests become error-result tests. `test_screenshot_max_size_rejects_out_of_range` uses 2001, and a schema test asserts `maximum == 2000`.
  - `tests/test_version_handshake.py` keeps its membership check.
- [ ] **Step 2: Run to verify they fail**
Run: `uv run --locked pytest tests/test_annotations.py tests/test_tools.py tests/test_screenshot.py -q`
Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the suites**
Run: `uv run --locked pytest tests/ -q`, `SKETCHUP_MCP_CONTRACT=1 uv run --locked pytest tests/test_contract_wire.py -q`, `ruby test/run_all.rb`
Expected: green. `tests/test_contract.py` still checks `_RETRY_SAFE_TOOLS ⊆` Ruby's `READ_ONLY_TOOLS`.
- [ ] **Step 5: Commit**

```bash
git add src/sketchup_mcp/annotations.py src/sketchup_mcp/tools.py src/sketchup_mcp/connection.py src/sketchup_mcp/app.py \
  src/sketchup_mcp/prompts.py tests/test_annotations.py tests/test_tools.py tests/test_screenshot.py \
  tests/test_version_handshake.py tests/test_app.py
git commit -m "feat: report tool errors as error results and annotate every tool"
```

---

### Task 9: Smoke steps for world coordinates and shared components

**Files:**
- Modify: `examples/smoke_check.py`, plus the step count in `README.md`, `CLAUDE.md` and `docs/release.md`

**Interfaces:**
- Consumes: the wire behaviour of Tasks 3–5. The smoke talks to Ruby directly, not through FastMCP.
- Produces: two new steps before cleanup. Cleanup becomes 26, undo 27 and version 28, and the closing line says `Smoke complete: 28 steps total`. Each new step skips through `_maybe_skip_eval` when the eval gate is closed, and deletes what it made in a `finally`.

- [ ] **Step 1: Add step 24, "nested group in a moved, rotated group: world box and a world move".**
  - `_NESTED_RUBY` builds:
    - a group `smoke_outer` with a 100 mm cube, rotated 90° about Z at the origin and then moved +1000 mm along X;
    - inside it, a group `smoke_inner`: a 50 mm cube at local (0, 0, 200) mm.

    It returns `{outer, inner}` ids as JSON.
  - Assert `get_component_info(inner).bbox_mm` ≈ `{min: [950, 0, 200], max: [1000, 50, 250]}`, within 0.01 mm.
  - Call `transform_component(inner, position=[1200, 0, 0])`. Assert that its `bbox_mm.min` ≈ `[1200, 0, 0]` and that `get_component_info(inner)` reports the same box at depth 1.
  - Delete `outer`.
- [ ] **Step 2: Add step 25, "a component placed twice: its child is shared and refused".**
  - `_SHARED_RUBY` builds a definition `smoke_shared_def` with a 40 mm group `smoke_shared_part`, placed twice at x = 1500 and x = 1700 mm. It returns `{a, b, part}`.
  - Assert:
    - `find_components(name="smoke_shared_part")` has `total == 2`, and every row has `shared` true;
    - `find_components(name="smoke_shared_def")` has `total == 2`, and every row has `definition == "smoke_shared_def"`;
    - `set_material(part, "red")` raises `SketchUpError` with code `-32602` and `"placed 2 times"` in the message.
  - Delete `a` and `b`; top-level instances are not shared.
- [ ] **Step 3: Renumber and update the counts.** Steps 24–26 become 26–28. "26-step" becomes "28-step" on the smoke lines of `README.md` and `CLAUDE.md`, and `docs/release.md` reads "All 28 steps must pass, and step 28 must show…".
- [ ] **Step 4: Run the structure tests**
Run: `uv run --locked pytest tests/test_smoke_helpers.py -q`
Expected: green. Steps 1..28 are consecutive and the documents agree. The live run is Task 11.
- [ ] **Step 5: Commit**

```bash
git add examples/smoke_check.py README.md CLAUDE.md docs/release.md
git commit -m "test: smoke-check world coordinates and shared components"
```

---

### Task 10: Docstrings, prompt, server instructions, README, CLAUDE.md (M-24, §6.6a)

**Files:**
- Modify: `src/sketchup_mcp/tools.py` (docstrings only), `src/sketchup_mcp/prompts.py`, `src/sketchup_mcp/app.py` (instructions), `README.md`, `CLAUDE.md`
- Modify: `tests/test_tool_descriptions.py`, `tests/test_prompts.py`, `tests/test_app.py`

**Interfaces:**
- Consumes: the behaviour of Tasks 1–8.
- Produces: the texts below. The wording is the builder's within these facts; the quoted fragments are pinned by tests.

Docstrings, by fact:
- **Shared refusal.** Applies to `delete_component`, `transform_component`, `set_material`, `boolean_operation`, `chamfer_edge`, `fillet_edge` and `create_mortise_tenon`. Each says that an entity inside a component or group **"placed more than once"** is refused with -32602.
  - `set_material` drops "colors the shared definition — all instances show it". A face or edge inside a shared definition is now refused.
- **World coordinates.** Each of these says **"world"**:
  - `create_component`: position. Also: when the user has a group or component open for editing, the new object goes inside it; when that group is placed more than once, the call is refused (see `get_model_info.editing`).
  - `transform_component`: position is an absolute world target; rotation is about world X, Y and Z through the world bbox centre; scale is along the world axes about that centre; nested entities behave the same.
  - `get_component_info`: the box is world through the parents; a shared entity reports its first placement with `shared: true`.
  - `list_components` and `find_components`: world rows that carry `shared` and, for components, `definition`. `find_components` matches the instance name or a component's definition name.
  - `get_selection`.
- **New ids.**
  - `boolean_operation`: the result is a new group with a new id. With `delete_originals=true` it takes the target's name, tag and material; otherwise it keeps SketchUp's name: Union, Difference or Intersection.
  - `chamfer_edge` and `fillet_edge`: a new id; name, tag and material are kept.
- **`create_mortise_tenon`.**
  - The boards' rotation in the model, including the group or component that holds them, must be a **"multiple of 90°"**. The joint follows the model's X, Y and Z axes, the same axes `bbox_mm` uses, whether or not a group is open.
  - A board **"open for editing"** is refused: close it first.
  - Boards inside a component or group placed more than once are refused.
  - A volume shortfall advises a shallower joint or the offsets.
- **`eval_ruby`.** Code works in **"inches"** and opens **"no undo operation"**: wrap edits in `model.start_operation`/`commit_operation` for one undo step. Its `def`s and constants become **"global"** in SketchUp's Ruby session.
- **`undo`.** It undoes the last step of SketchUp's **"shared undo stack"**, which may be the user's own edit. It answers before SketchUp has processed it, so check the model afterwards.
- **`get_model_info`.**
  - `entity_count` counts **"top-level entities only"**.
  - `editing` lists the groups and components open for editing, outermost first, as `[{id, name, shared}]`.
  - The Returns line becomes `{path, title, units: "mm", bounding_box_mm|null, entity_count, layers[], editing[]}`.

Prompt (`prompts.py`):
- §3 says all coordinates are **"world (model) coordinates"**, nested entities included; rotation and scale are about world axes; new objects go into an open group.
- §4 says boolean, edge and joinery results get new ids and keep their names (boolean only with `delete_originals=true`).
- A bullet in §5 or §6 says edits inside a component or group placed more than once are refused (`shared: true` in list/find rows); make one copy unique through `eval_ruby` first.
- §6 traps cover `undo` and the shared undo stack, `eval_ruby` (inches, no undo step, global defs), and `entity_count`.
- §7 adds the mortise-tenon alignment rule and the open-board rule.

Server instructions (`app.py`, the `instructions=` argument), verbatim:

```
SketchUp modeling over MCP. Lengths are millimeters and angles degrees; every
position, bbox_mm and transform target is in world (model) coordinates, nested
entities included. Prefer the typed tools; use eval_ruby (inches, no undo step
of its own) only when none fits. After each change read the returned bbox_mm.
Boolean, edge and joinery results get new ids and keep their names. Edits
inside a component or group placed more than once are refused; new objects go
into a group open for editing. A refused call says what to change. The
sketchup_modeling_strategy prompt has the full guide.
```

README and CLAUDE.md:
- README's tool catalogue:
  - the Geometry row says "absolute **world** bbox-min target";
  - a sentence after the table says that edits inside shared components are refused;
  - the dimensions paragraph says `bbox_mm` is world;
  - Capabilities → Atomic undo names `Helpers::Operation.run`.
- `CLAUDE.md`:
  - the helpers row adds `operation.rb` and `frames.rb`;
  - the bullet "Mutating handlers wrap edits in…" names `Helpers::Operation.run`;
  - a new bullet under Non-Obvious Constraints covers world coordinates and shared refusals: `Frames.placement`, `require_unshared!`, open contexts in world coordinates;
  - the sentence "All entity-returning handlers respond…" says world;
  - the Ruby and Python test counts come from this task's final run.

- [ ] **Step 1: Write the failing tests**
  - `tests/test_tool_descriptions.py`:
    - "placed more than once" in the seven mutating id tools;
    - "world" in `create_component`, `transform_component`, `get_component_info`, `list_components`, `find_components` and `get_selection`;
    - "inches", "no undo operation" and "global" in `eval_ruby`;
    - "shared undo stack" in `undo`;
    - "top-level entities only" and "editing" in `get_model_info`;
    - "open for editing" and "multiple of 90°" in `create_mortise_tenon`;
    - the Returns pin for `get_model_info` contains "editing[]".
  - `tests/test_prompts.py`: "world (model) coordinates", "placed more than once", "shared undo stack".
  - `tests/test_app.py`: the instructions equal the text above.
- [ ] **Step 2: Run to verify they fail**
Run: `uv run --locked pytest tests/test_tool_descriptions.py tests/test_prompts.py tests/test_app.py -q`
Expected: FAIL.
- [ ] **Step 3: Write the texts.**
- [ ] **Step 4: Run the suites**
Run: `uv run --locked pytest tests/ -q`, `ruby test/run_all.rb`. Then put the two counts into `CLAUDE.md`.
Expected: green.
- [ ] **Step 5: Commit**

```bash
git add src/sketchup_mcp/tools.py src/sketchup_mcp/prompts.py src/sketchup_mcp/app.py README.md CLAUDE.md \
  tests/test_tool_descriptions.py tests/test_prompts.py tests/test_app.py
git commit -m "docs: describe world coordinates, shared refusals and undo in the tool texts"
```

---

### Task 11: Live checks (controller, not a subagent)

**Files:** none committed. Locally, `.superpowers/sdd/hot_reload.py` gains these entries in `ORDER`:
- `helpers/operation.rb` and `helpers/frames.rb`, after `helpers/entities.rb`;
- `handlers/model.rb`, before `handlers/dispatch.rb`.

- [ ] **Step 1: Hot-reload the branch** into SketchUp 2027 (`hot_reload.py` with no revision argument). Every file prints OK.
- [ ] **Step 2: The §3 scene**: group `probe_outer` moved +1000 mm and rotated 30° about Z, with `probe_inner` inside at z = 200 mm. Check it with nothing open, with `probe_outer` open, and with `probe_outer` → a nested group open:
  - `get_component_info(inner)`, `list_components(recursive)`, `find_components` and `get_selection` all report the same world box in every state;
  - `transform_component(inner, position=…)` lands at the world target in every state;
  - so does a rotation of `[0, 0, 90]`.
- [ ] **Step 3: A component placed twice.**
  - Edits to its children are refused, and the message gives the count.
  - `find_components` flags the children `shared`.
  - With one placement open, `create_component` is refused, and `get_model_info.editing` marks the path shared.
  - After `make_unique` through `eval_ruby`, the copy's children can be edited.
- [ ] **Step 4: Search, names and joints.**
  - `find_components` finds an unnamed instance by its definition name.
  - A chamfer keeps the target's name; `boolean_operation` with `delete_originals=true` keeps the target's name, and without it keeps "Union".
  - Mortise-tenon:
    - inside a parent rotated 90°, closed and open, the joint comes out the same, in world axes;
    - a parent rotated 30° is refused with `ROTATION_MESSAGE` in both states;
    - pockets that meet get `SHORTFALL_ADVICE`.
  - One undo after each change restores the model.
- [ ] **Step 5: Smoke.** `uv run --locked python examples/smoke_check.py` reports 28/28. Clean up as `docs/release.md` describes.
- [ ] **Step 6: MCP surface.** Ask the user to reconnect `/mcp`. Then the session's tools show the annotations, and a refused call comes back as an error result with `[-32602] …` text.
- [ ] **Step 7: Leave the template empty.** Erase every `probe_*` entity.
