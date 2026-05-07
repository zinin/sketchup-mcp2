# Changelog

## Unreleased

### Fixed

- `list_components(recursive: true)` and `find_components` now make the
  ComponentDefinition cycle-guard **path-local**: distinct instances of the
  same definition (e.g. four chairs around a table) each have their nested
  groups/components enumerated, instead of only the first one. True cycles
  (a definition that contains itself) are still bounded.
  Reported by Codex review on PR #1.

## 2.0.0

### Wire protocol — BREAKING

- Wire format changed from `\n`-delimited to **4-byte big-endian length-prefix**.
  Incompatible with Python <2.0.0 and Ruby plugin <2.0.0; both must be upgraded together.
- 64 MiB cap on incoming and outgoing message size; explicit error on overflow.
- Zero-length frames rejected on both encode and decode (symmetric).
- Persistent TCP socket — one connection serves multiple requests.
- Python: `asyncio.Lock` serializes tool-calls on the shared socket.
- Ruby: non-blocking state-machine reader inside `UI.start_timer` callback,
  bounded to 50 read-iterations per tick (~3.2MB) to keep SketchUp UI responsive
  on large payloads. Idle deadline (30s) and `IO.select` write timeout (1s)
  prevent slow-loris and hung-write scenarios.

### Ruby plugin — major refactor

- Monolithic `main.rb` (1859 lines) split into modules under
  `su_mcp/su_mcp/{core,handlers,helpers}/`.
- `core/{application,server,framing,config,logger,errors}.rb`.
- `handlers/{dispatch,geometry,operations,joints,materials,export,model,eval}.rb`.
- `helpers/{units,validation,entities,geometry}.rb`.
- New thin `main.rb` (~50 lines): loads modules + registers menu.

### Configuration via ENV

- `SKETCHUP_MCP_PORT` (default 9876)
- `SKETCHUP_MCP_HOST` (default 127.0.0.1)
- `SKETCHUP_MCP_TIMEOUT` (Python only; default 60s)
- `SKETCHUP_MCP_LOG_LEVEL` (DEBUG / INFO / WARN / ERROR; default INFO)

### Structured errors

- Ruby emits JSON-RPC errors with `data.{tool, params, timestamp, backtrace}`.
- `params` truncated to 512 UTF-8 bytes (multibyte-safe).
- Python `format_error` formats them into a single-line tool-response.

### New introspection tools

- `get_model_info` — path, title, units, bounding box, entity count, layers.
- `list_components` — top-level groups/components (with optional `recursive`).
- `get_component_info` — detailed info on one entity.
- `find_components` — filter by name substring, layer, type.
- `list_layers` — all layers with visibility, color, ID.
- `create_layer` — create a named layer.
- `undo` — atomic single-step undo (depends on every mutating handler being
  wrapped in `model.start_operation`/`commit_operation`).

### Menu & UI rewrite

- Status line via `Sketchup.status_text`: `MCP Server: running on :9876` / `stopped`.
- `validation_proc` greys out Start/Stop based on running state.
- New menu items: Restart, Show Log, Show Status.
- Removed three forced `SKETCHUP_CONSOLE.show` calls during plugin load —
  console only opens on user request.
- `UI.messagebox` shown only on `start` failure.

### Validation

- Per-handler explicit checks via `Helpers::Validation` primitives.
- Pydantic `Field(gt=0)`, `Literal[...]`, `min_length=3` on Python side.
- Defense-in-depth: Pydantic catches type errors, Ruby catches business rules.

### Geometry quality

- `segments` parameter on `create_component` for cylinder/cone/sphere
  (defaults preserved: 24 / 24 / 16).
- `chamfer_edges` and `fillet_edges` rewritten via SketchUp `follow_me`.
  Old implementation created parallel groups without modifying the original;
  new implementation properly subtracts the swept volume.
- Removed dead `gsub('"', '')` workaround everywhere — JSON-RPC never sends
  quoted IDs.

### Joints — BREAKING

- `create_mortise_tenon`, `create_dovetail`, `create_finger_joint` now expect
  dimension parameters (`width`, `height`, `depth`, `offset_*`) **in millimeters**
  instead of being passed as raw inches. Old code that worked by accident with
  small numbers (~1.0) will need to multiply by 25.4 to keep the same physical size.
- Default values bumped to mm-meaningful sizes: mortise/finger `width=50, height=25,
  depth=10`; dovetail `width=50, height=50, depth=15`. Old `1.0` defaults would
  produce 1mm features (invisible) under the new units.

### Geometry — UNIFIED MM CONTRACT (BREAKING)

- `create_component.dimensions/position`, `transform_component.position/scale`,
  `chamfer_edges.distance`, `fillet_edges.radius` now accepted in **millimeters**
  (previously raw values, treated as inches by SketchUp). Convert old
  `dimensions=[1,1,1]` to `dimensions=[25.4, 25.4, 25.4]` for equivalent size,
  or (recommended) `dimensions=[100, 100, 100]` for visually meaningful results.
- `transform_component.rotation` stays in degrees (not a size).
- All returned `bbox_mm` (entity bounding boxes) in mm + WORLD coordinates
  (transformation chain accumulated for nested groups).

### API improvements

- All entity-returning handlers (`create_component`, `transform_component`,
  `set_material`, joints, `boolean_operation`, etc.) return
  `{id, name, type, bbox_mm}` so Claude can re-locate entities by bounding box
  if their IDs become stale after destructive solid-tool operations.
- `list_components` and `find_components` accept `max_depth` (default 3) and
  use a seen-definitions set to prevent infinite recursion on cyclic
  ComponentInstance references.
- Entity-not-found errors return `-32602` (invalid params) instead of `-32603`
  (internal error) — Claude can recover by retrying with a different ID.
- `dispatch.rb` validates JSON-RPC envelope shape (jsonrpc=2.0, method is
  non-empty string, params is object); malformed requests return `-32600`
  (invalid request) instead of crashing with `-32603`.
- JSON-RPC notifications (requests without `id`) no longer receive a response
  per spec.
- Solid-tool operations use Group-level methods (`Group#subtract`,
  `Group#union`, `Group#intersect`) — the old `Entities#subtract` etc. were
  hallucinations that never existed in the SketchUp API.
- `Group#subtract` direction inverted at all 5 call sites (chamfer, fillet,
  boolean_operation:difference, plus 4 in joints). SketchUp's
  `A.subtract(B)` returns `B - A`, not `A - B` — verified empirically against
  SketchUp 2026.
- `chamfer_edges`/`fillet_edges` use sequential per-edge subtract with
  re-collection of live edges between iterations (combined-cutter approach
  is non-manifold at corners where 3 prisms meet, and the original-edge
  snapshot becomes stale after the first subtract trims adjacent edges).
  Cutter path offset along edge_dir + laterally by -(perp1+perp2)/2 *
  CUTTER_OFFSET so the swept prism shares no faces with the target's
  adjacent face planes (subtract returns empty group on coplanar operands).
- `chamfer_edges`/`fillet_edges` response includes a `stats` field —
  `{attempted, skipped_no_match, subtract_failed, succeeded}` — for
  iteration-level diagnostics.
- `undo` dispatches `Sketchup.send_action("editUndo:")` rather than calling
  the nonexistent `Sketchup::Model#undo`.

### Python tools

- `tools.py` adds 7 FastMCP wrappers for new Ruby introspection handlers:
  `get_model_info`, `list_components`, `get_component_info`, `find_components`,
  `list_layers`, `create_layer`, `undo`. Without these wrappers Claude could
  invoke them only via `eval_ruby`.

### resources/list — BREAKING

- `resources/list` and `prompts/list` now return `{"resources":[], "prompts":[]}`
  for symmetry with Python v2. The old monolith returned a real entity list;
  use `list_components` for entity introspection instead.

### Tests

- New Ruby `test/` directory: `test_errors.rb`, `test_config.rb`,
  `test_units.rb`, `test_validation.rb`, `test_framing.rb`, `test_state_machine.rb`.
- Pure stdlib `minitest` — no gem dependencies. Run via `ruby test/run_all.rb`.
- Python tests unchanged (52 tests in `tests/`).

### Smoke-check

- New `examples/smoke_check.py` — 20-step Python↔Ruby integration test.
  Covers ALL Ruby handlers including the riskiest rewrites: chamfer/fillet
  (live-validates new geometry math), boolean_operation, materials, export.
  Run after upgrading both sides together — required gate before merge.
