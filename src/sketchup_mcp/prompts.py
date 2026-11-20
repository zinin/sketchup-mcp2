"""MCP prompts for the MCP Server for SketchUp.

Imported for its side effect (FastMCP decorator registration). See
``app.py`` — the import sits next to ``import sketchup_mcp.tools``.
"""
from sketchup_mcp.app import mcp

_STRATEGY_TEXT = """\
You are working with a SketchUp model through the sketchup-mcp server.
Follow this strategy to be effective and avoid common pitfalls.

# 1. Pre-flight — ALWAYS start with
- get_model_info() — units, model bbox, layer list, the number of
  top-level entities, and the groups open for editing (editing).
- If the user references existing geometry: list_components or
  find_components(name=...) to locate IDs (paginated: check "truncated"
  and page with offset/limit).
- For visual context after major changes:
  get_viewport_screenshot(view_preset="iso", zoom_extents=true).

# 2. Tool priority
1. Typed tools first — create_component, transform_component,
   set_material, boolean_operation, chamfer_edge, fillet_edge,
   create_mortise_tenon, create_layer, delete_component. They handle
   units, transactions, and edge cases.
2. eval_ruby ONLY when typed tools cannot express the operation
   (custom curves, Follow Me, complex transformations,
   ComponentDefinition manipulation, layer attributes).
3. Never use eval_ruby for things a typed tool already does — you
   lose validation, mm-conversion, and atomic undo.

# 3. Conventions
- ALL linear dimensions are millimeters at the MCP boundary.
  SketchUp's Ruby API uses inches internally; the server converts.
- ALL angles are degrees.
- ALL coordinates — positions, bbox_mm, transform targets — are in
  world (model) coordinates, nested entities included, whether or not a
  group is open for editing.
- transform_component.position is an ABSOLUTE world target: the entity's
  bbox-min corner lands exactly there (same anchor as
  create_component.position), applied AFTER rotation/scale — the
  bbox-min promise holds for combined calls too. rotation/scale are
  relative, about the world axes through the world bbox center.
- When the user has a group or component open for editing in SketchUp,
  create_component puts the new object inside it, as SketchUp's own
  tools do; get_model_info.editing shows the open path.
- Entity IDs: pass them back exactly as returned — integer or string,
  both are accepted by every id parameter.
- New geometry lives inside SketchUp Groups so it can be moved/deleted
  as a unit.
- create_component minimum dimension: 0.1 mm for cube, 1.0 mm for
  curved types; defaults are a 100 mm cube.
- create_component accepts an optional name — set it so
  find_components can locate the part later.

# 4. After every mutation — verify
- Geometry, material, boolean, and edge tools return
  {id, name, type, bbox_mm} (edge tools add edges_*/stats). bbox_mm is null
  when the entity ended up with no geometry (e.g. a boolean difference
  consumed the whole body) — treat null as "inspect what happened", not as
  an error. When bbox_mm is present, read it to confirm the result matches
  the intent before the next step (and to relocate the entity if its id
  becomes stale after destructive operations).
- create_mortise_tenon returns {mortise, tenon}, each {id, name, type,
  bbox_mm}. Both boards come back with new ids and keep their names. The
  boards must touch face to face; a joint that cannot be built is
  refused, and nothing is half-built.
- Boolean, edge and joinery results come back as new groups with new
  ids. They keep the target's name when they replace it
  (boolean_operation only with delete_originals=true; otherwise the
  result is named Union, Difference or Intersection).
- Other tools — delete_component, create_layer, undo, list/find
  queries, get_model_info, get_selection — have their own response
  shapes; see the tool docs.
- For visual confirmation across multiple parts:
  get_viewport_screenshot(view_preset="iso", zoom_extents=true).

# 5. Error recovery
- If a mutation produced wrong geometry — call undo immediately, then
  retry with corrected parameters. Do not pile up bad geometry hoping
  to fix it later.
- boolean_operation, chamfer_edge, fillet_edge are unreliable on
  non-manifold meshes. If they fail, try with simpler input or use
  eval_ruby for a manual workaround.
- Edits inside a component or group placed more than once are refused
  (shared: true in list/find rows): changing one would change every
  copy. To change all copies, edit the definition through eval_ruby; to
  change one, make it unique first (instance.make_unique through
  eval_ruby) and use the new ids of the entities inside it.

# 6. Known traps
- Group#subtract is REVERSED: A.subtract(B) returns B - A. Inside
  eval_ruby, to get "target minus tool", call tool.subtract(target).
- Sketchup::Model#undo does not exist. The undo MCP tool uses
  Sketchup.send_action("editUndo:") internally. It undoes the last step
  of SketchUp's shared undo stack — possibly the user's own edit, not
  your last call — and answers before SketchUp has processed it: verify
  the model afterwards.
- eval_ruby works in inches, opens no undo operation of its own (wrap
  edits in model.start_operation / commit_operation), and its defs and
  constants become global in SketchUp's Ruby session.
- get_model_info.entity_count counts top-level entities only.
- Layers in SketchUp are visibility flags, not folders. Adding an
  entity to a layer doesn't move it in the hierarchy.

# 7. Joinery defaults
For mortise-and-tenon joints (create_mortise_tenon) and for joints
built with eval_ruby (dovetails, finger joints), when the user doesn't
specify:
- create_mortise_tenon needs boards aligned with the model's axes (a
  rotation of a multiple of 90° in total, theirs and their groups') and
  not open for editing; the joint follows the model's X, Y and Z;
- joint dimensions ≈ 0.3-0.5 × board thickness;
- number of fingers/tails: 3-5 for typical drawer-width boards
  (200-400 mm);
- if uncertain, ASK before generating — joints are hard to fix after
  the fact without scrapping the boards.

# 8. eval_ruby gate
eval_ruby ships enabled, but the user can close the gate in the
SketchUp extension's Settings. If a call to eval_ruby returns an error
whose text starts with "eval_ruby is disabled.", it is not a fault in
your code: it is the extension's actionable instruction for the user.
Surface the full message to the user verbatim — do not paraphrase, do
not retry the same code, do not silently fall back to typed tools
without telling the user that eval was unavailable. The user can enable Ruby evaluation in
Plugins → MCP Server → Settings... — the checkbox is «Enable Ruby
evaluation».
"""


@mcp.prompt(
    name="sketchup_modeling_strategy",
    description=(
        "How to use SketchUp MCP tools effectively: pre-flight checks, "
        "typed-tools-vs-eval_ruby priority, units/angles conventions, "
        "verification after mutations, error recovery, known traps."
    ),
)
def sketchup_modeling_strategy() -> str:
    return _STRATEGY_TEXT
