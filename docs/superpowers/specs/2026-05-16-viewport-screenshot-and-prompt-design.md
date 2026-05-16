# Design: Viewport screenshot tool + sketchup_modeling_strategy prompt

- **Date**: 2026-05-16
- **Status**: Draft — awaiting user review
- **Branch**: `feature/viewport-screenshot-and-prompt`
- **Author**: Alexander V. Zinin (with Claude Code)

## 1. Context

Our `sketchup-mcp` (v0.0.3) was originally forked from
[mhyrr/sketchup-mcp](https://github.com/mhyrr/sketchup-mcp), which was
itself inspired by [ahujasid/blender-mcp](https://github.com/ahujasid/blender-mcp).
`blender-mcp` has remained active (v1.5.5, 21.7k stars, last commit
2026-01-23) and has evolved in a notably different direction:

- It is now an **eval-first** server: scene mutations happen through
  `execute_blender_code`. Typed creation/modification tools were removed.
- It added integrations with external asset libraries (Poly Haven,
  Sketchfab) and AI generators (Hyper3D Rodin, Hunyuan3D).
- It exposes one MCP `prompt` (`asset_creation_strategy`) that teaches
  Claude the preferred workflow.
- It has a `get_viewport_screenshot` tool returning an MCP `Image`,
  letting Claude visually verify the scene between steps.

Our project went the opposite way (typed tools first, `eval_ruby` as an
escape hatch) and we want to keep that. But two features from blender-mcp
fit our model cleanly and add measurable value **now**:

1. `get_viewport_screenshot` — visual verification.
2. `@mcp.prompt sketchup_modeling_strategy` — explicit usage guidance
   for Claude.

This document is the design for porting exactly these two features.
Anything else from blender-mcp is explicitly out of scope (see §10).

## 2. Goals

- Add a single new typed tool `get_viewport_screenshot` that captures
  the current SketchUp viewport and returns the PNG as an MCP `Image`,
  with optional camera/style/zoom controls and **non-destructive
  semantics by default**.
- Add a single MCP `prompt` named `sketchup_modeling_strategy`
  explaining to Claude how to use our tools effectively (pre-flight
  checks, typed-tools-vs-`eval_ruby`, units, post-mutation verification,
  error recovery, known traps).
- Keep changes additive: existing 22 tools, wire protocol, Ruby
  modules, and release process are untouched.
- Maintain test coverage at parity with current state
  (120 runs / 279 assertions Ruby, 56 tests Python — new tests add to
  these counts, none are removed).

## 3. Non-goals

- We do **not** migrate to an eval-first design.
- We do **not** add Sketchfab, Poly Haven, Hyper3D, Hunyuan3D, or any
  other external asset integration in this iteration.
- We do **not** add telemetry, server feature toggles, or a settings UI
  for prompts.
- We do **not** modify `export_scene` or its PNG/JPEG branch — the
  screenshot tool is a separate code path.

## 4. High-level structure of changes

```
src/sketchup_mcp/
  tools.py              +1 wrapper: get_viewport_screenshot()
  prompts.py            NEW — defines sketchup_modeling_strategy prompt
  app.py                +1 side-effect import sketchup_mcp.prompts
                        (next to existing `import sketchup_mcp.tools` at app.py:51)

su_mcp/su_mcp/
  main.rb                 +1 entry "handlers/view" in LOAD_ORDER
  handlers/dispatch.rb    +1 branch "get_viewport_screenshot" -> Handlers::View
  handlers/view.rb        NEW — viewport_screenshot handler

test/
  test_view.rb          NEW — Ruby unit tests
tests/
  test_prompts.py       NEW — Python tests for prompt registration
  test_screenshot.py    NEW — Python tests for tool wrapper

examples/
  smoke_check.py        +1 step exercising get_viewport_screenshot

docs/
  sketchup-ruby-cookbook.md  + section "Viewport snapshot via View#write_image"
CLAUDE.md             updated tool table + prompts note
```

### Wire-level contract (Python ↔ Ruby)

The new tool reuses the existing JSON-RPC framing (4-byte big-endian
length prefix, 64 MiB cap). Payload sizes for an 800-px PNG fall in the
300 KiB – 1 MiB range, well within the limit.

Ruby returns:

```json
{
  "png_base64": "<base64 PNG bytes>",
  "width": 800,
  "height": 450,
  "preset_used": "iso",
  "style_used": "default"
}
```

Python decodes `png_base64` and wraps it in
`mcp.server.fastmcp.Image(data=bytes, format="png")` for the MCP client.

## 5. Tool: `get_viewport_screenshot`

### 5.1 Python signature

```python
@mcp.tool()
async def get_viewport_screenshot(
    *,
    max_size: int = 800,
    view_preset: Literal[
        "current", "front", "back", "left", "right",
        "top", "bottom", "iso"
    ] = "current",
    zoom_extents: bool = False,
    style: Literal[
        "default", "shaded", "hidden_line", "wireframe"
    ] = "default",
    restore_view: bool = True,
    ctx: Context | None = None,
) -> Image:
    ...
```

Validation:

- `max_size` is clamped to `[64, 4096]`; values outside raise
  `ValidationError`.
- `view_preset` and `style` are constrained by `Literal` (Pydantic).

### 5.2 Parameter semantics

| Parameter | Effect |
|---|---|
| `max_size` | Largest side of the returned PNG. Aspect ratio is taken from `view.vpwidth / view.vpheight`; the smaller side is scaled proportionally and rounded. |
| `view_preset="current"` | Camera is not modified. |
| `view_preset=<other>` | `Sketchup.send_action("view#{Preset.capitalize}:")` switches to the named SketchUp standard view. These actions are synchronous and locale-independent. |
| `zoom_extents=true` | `view.zoom_extents` is called after the (optional) preset change and style change. |
| `style="default"` | Rendering options are not modified. |
| `style=<other>` | A small set of `model.rendering_options` keys is modified directly. We do **not** switch `model.styles.selected_style` (that is locale-dependent and pollutes the undo stack). |
| `restore_view=true` | Camera and the touched rendering-options keys are snapshotted before mutations and restored after `write_image`. |
| `restore_view=false` | No snapshot; the model retains the new view/style after the call. |

### 5.3 Style → rendering_options mapping (initial)

| `style` | Keys set |
|---|---|
| `shaded` | `DisplayShaded=true`, `DisplayShadedUsingAllSameObject=false`, `DrawEdges=true` |
| `hidden_line` | `DisplayShaded=false`, `DrawEdges=true`, `DrawHidden=true`, `DrawProfilesOnly=false` |
| `wireframe` | `DrawEdges=true`, `DrawFaces=false` |

The exact key set will be confirmed empirically against SketchUp 2026
during TDD; up to 2-3 minor adjustments are expected.

### 5.4 Ruby handler flow

```
1. (if restore_view) snapshot view.camera
   (if restore_view AND style != "default")
     snapshot rendering_options keys we are about to touch
2. (if view_preset != "current") Sketchup.send_action("view#{P}:")
3. (if style != "default")        apply rendering_options keys
4. (if zoom_extents)               view.zoom_extents
5. tmp = "#{Dir.tmpdir}/sumcp_vp_#{ts}.png"
   ok  = view.write_image(filename: tmp, width: w, height: h,
                          antialias: true, compression: 0.9,
                          transparent: false)
   raise Core::StructuredError.new(-32000, "...") if !ok
6. data = File.binread(tmp)  # in `ensure`: File.delete(tmp) if File.exist?
7. (if restore_view) view.camera = snapshot_cam;
                     snapshot_ro.each { |k,v| ro[k] = v }
8. return {png_base64: Base64.strict_encode64(data),
           width: w, height: h,
           preset_used: view_preset, style_used: style}
```

`w` / `h` computation:

```ruby
vw = view.vpwidth.to_f
vh = view.vpheight.to_f
scale = max_size.to_f / [vw, vh].max
w = (vw * scale).round
h = (vh * scale).round
```

### 5.5 Transactions and undo

`view.write_image`, `view.camera=`, and `rendering_options[...] = v` are
**UI-state** operations and do not enter the SketchUp undo stack. The
handler therefore does NOT wrap its work in
`model.start_operation` / `commit_operation`. The user's Undo menu is
not polluted by screenshots.

### 5.6 Edge cases

- **Empty model**: `view.zoom_extents` produces SketchUp's default
  frame. The screenshot is a blue background — acceptable.
- **`write_image` returns false**: handler raises
  `Core::StructuredError.new(-32000, "viewport write_image failed")`.
  Python propagates as `SketchUpError`.
- **Extreme aspect ratios** (e.g. 5000×100): scaled down so both sides
  fit the max_size budget. No special handling.
- **Open SketchUp modal dialog**: `write_image` may fail; we surface
  the error to the user rather than silently producing garbage.

### 5.7 Security

- `view_preset` / `style`: Python `Literal`-validated; an unknown value
  cannot reach Ruby.
- `max_size`: clamped Python-side, re-validated Ruby-side (defence in
  depth).
- Tempfile path: `Dir.tmpdir` + timestamped name; deleted in `ensure`
  block regardless of outcome.

## 6. MCP prompt: `sketchup_modeling_strategy`

### 6.1 Registration

`src/sketchup_mcp/prompts.py` (new file):

```python
from sketchup_mcp.app import mcp

_STRATEGY_TEXT = """..."""  # full text below

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
```

`src/sketchup_mcp/app.py` gains one extra side-effect import next to the
existing `import sketchup_mcp.tools` (currently at `app.py:51`):

```python
import sketchup_mcp.prompts  # noqa: E402, F401  — register prompts
```

No Ruby-side changes for the prompt itself. The dead `prompts/list`
branch in `su_mcp/su_mcp/handlers/dispatch.rb` is left as-is for now;
FastMCP serves prompts from the Python side and never forwards
`prompts/*` to Ruby.

### 6.2 Prompt content (draft, English)

```
You are working with a SketchUp model through the sketchup-mcp server.
Follow this strategy to be effective and avoid common pitfalls.

# 1. Pre-flight — ALWAYS start with
- get_model_info() — units, model bbox, layer list, total entity count.
- If the user references existing geometry: list_components or
  find_components(name=...) to locate IDs.
- For visual context after major changes:
  get_viewport_screenshot(view_preset="iso", zoom_extents=true).

# 2. Tool priority
1. Typed tools first — create_component, transform_component,
   set_material, boolean_operation, chamfer_edge, fillet_edge,
   create_mortise_tenon, create_dovetail, create_finger_joint,
   create_layer, delete_component. They handle units, transactions,
   and edge cases.
2. eval_ruby ONLY when typed tools cannot express the operation
   (custom curves, Follow Me, complex transformations,
   ComponentDefinition manipulation, layer attributes).
3. Never use eval_ruby for things a typed tool already does — you
   lose validation, mm-conversion, and atomic undo.

# 3. Conventions
- ALL linear dimensions are millimeters at the MCP boundary.
  SketchUp's Ruby API uses inches internally; the server converts.
- ALL angles are degrees.
- Entity IDs are integers but accept strings (server casts via .to_i).
- New geometry lives inside SketchUp Groups so it can be moved/deleted
  as a unit.

# 4. After every mutation — verify
- Tools that create or modify entities return {id, name, type, bbox_mm}.
  Read bbox_mm to confirm the result matches the intent before the
  next step.
- For visual confirmation across multiple parts:
  get_viewport_screenshot(view_preset="iso", zoom_extents=true).

# 5. Error recovery
- If a mutation produced wrong geometry — call undo immediately, then
  retry with corrected parameters. Do not pile up bad geometry hoping
  to fix it later.
- boolean_operation, chamfer_edge, fillet_edge are unreliable on
  non-manifold meshes. If they fail, try with simpler input or use
  eval_ruby for a manual workaround.

# 6. Known traps
- Group#subtract is REVERSED: A.subtract(B) returns B - A. Inside
  eval_ruby, to get "target minus tool", call tool.subtract(target).
- Sketchup::Model#undo does not exist. The undo MCP tool uses
  Sketchup.send_action("editUndo:") internally — just call it.
- Layers in SketchUp are visibility flags, not folders. Adding an
  entity to a layer doesn't move it in the hierarchy.

# 7. Joinery defaults
For mortise/tenon/dovetail/finger joints, when the user doesn't
specify:
- joint dimensions ≈ 0.3-0.5 × board thickness;
- number of fingers/tails: 3-5 for typical drawer-width boards
  (200-400 mm);
- if uncertain, ASK before generating — joints are hard to fix after
  the fact without scrapping the boards.
```

Approximate size: ~1.5 KB, ~50 lines.

### 6.3 How users see it

In Claude Desktop / Code MCP-aware clients, the prompt appears in the
slash menu or resource picker under the name
`sketchup_modeling_strategy`. The user inserts it explicitly at the
start of a chat. The server never injects it automatically.

## 7. Testing

### 7.1 Python (pytest) — two new files

`tests/test_screenshot.py`:

| Test | Asserts |
|---|---|
| `test_screenshot_minimal_payload` | Default call sends JSON-RPC `tools/call name="get_viewport_screenshot"` with full default param map. |
| `test_screenshot_max_size_clamps` | `max_size=10` and `max_size=99999` raise `ValidationError`. |
| `test_screenshot_view_preset_invalid` | `view_preset="diagonal"` raises `ValidationError`. |
| `test_screenshot_style_invalid` | `style="cartoon"` raises `ValidationError`. |
| `test_screenshot_returns_image` | Ruby returns valid base64 PNG → wrapper returns `Image` with `format="png"` and decoded bytes. |
| `test_screenshot_base64_decode_failure` | Invalid base64 surfaces as a clear error, not silent corruption. |
| `test_screenshot_propagates_ruby_error` | JSON-RPC error → `SketchUpError`. |

`tests/test_prompts.py`:

| Test | Asserts |
|---|---|
| `test_prompt_registered` | After importing `sketchup_mcp.prompts`, `sketchup_modeling_strategy` is in the FastMCP prompt registry. |
| `test_prompt_returns_non_empty_text` | Body > 200 chars. |
| `test_prompt_anchor_phrases` | Contains `get_model_info`, `millimeters`, `undo`, `eval_ruby`, `boolean_operation`, `bbox_mm`. |
| `test_prompt_description_present` | `description` non-empty and mentions "SketchUp". |

### 7.2 Ruby (minitest) — `test/test_view.rb`

| Test | Asserts |
|---|---|
| `test_dispatch_routes_to_view_handler` | JSON-RPC dispatches to `Handlers::View.viewport_screenshot`. |
| `test_invalid_view_preset_raises` | `view_preset="weird"` → `Core::StructuredError`. |
| `test_invalid_style_raises` | `style="cartoon"` → `Core::StructuredError`. |
| `test_invalid_max_size_raises` | `max_size=10` or `99999` → `Core::StructuredError`. |
| `test_camera_restored_when_flag_true` | After `restore_view=true, view_preset="top"`, final `view.camera` equals the snapshot. |
| `test_camera_not_restored_when_flag_false` | After `restore_view=false`, final camera differs from snapshot. |
| `test_rendering_options_restored` | With `style="wireframe", restore_view=true`, RO keys return to snapshot. |
| `test_send_action_called_for_preset` | Spying on `Sketchup.send_action`, `view_preset="iso"` triggers exactly one `"viewIso:"`. |
| `test_zoom_extents_called_when_flag` | `view.zoom_extents` is called only when `zoom_extents=true`. |
| `test_write_image_failure_raises` | Stubbed `view.write_image -> false` → `Core::StructuredError`. |
| `test_tempfile_deleted_on_success` | After a successful call, the tmp file does not exist. |
| `test_tempfile_deleted_on_failure` | When `write_image` raises, the tmp file is still cleaned up (ensure block). |
| `test_response_structure` | Success response shape: `{png_base64, width, height, preset_used, style_used}`. |
| `test_aspect_ratio_preserved` | vpwidth=1920, vpheight=1080, max_size=800 → width=800, height=450. |

### 7.3 Live integration — `examples/smoke_check.py`

Append a final step:

```python
# 21. Screenshot
result = await session.call_tool(
    "get_viewport_screenshot",
    {"view_preset": "iso", "zoom_extents": True, "max_size": 640},
)
img = result.content[0]
assert img.type == "image"
assert img.mimeType == "image/png"
assert len(img.data) > 1000, "PNG suspiciously small"
print(f"screenshot: {len(img.data)} bytes base64")
```

### 7.4 Manual verification — for the prompt

The MCP-prompt slash menu cannot be exercised in CI. Manual checklist
post-release:

1. Run `python -m sketchup_mcp` with the local Claude Desktop config.
2. Confirm `/sketchup_modeling_strategy` appears in the slash menu.
3. Insert the prompt into a new chat. Verify Claude calls
   `get_model_info` first when asked to modify the model.

### 7.5 TDD order

1. Write failing Python tests for `prompts` and `screenshot` (red).
2. Write failing Ruby tests for `view.viewport_screenshot` (red).
3. Implement Python prompt → `test_prompts.py` green.
4. Implement Python tool wrapper (mocked connection) →
   `test_screenshot.py` green.
5. Implement Ruby handler → `test_view.rb` green.
6. Run live smoke against SketchUp.

## 8. Documentation updates

- `CLAUDE.md`: new "View" row in the tool category table; short
  paragraph documenting that the server now exposes one MCP prompt;
  note that the leftover Ruby `prompts/list` dispatch is dormant (kept
  for safety).
- `docs/sketchup-ruby-cookbook.md`: new section "Viewport snapshot via
  View#write_image" with the save → mutate → restore pattern.
- `README.md` (if shipped to PyPI users): one-line mention of
  `get_viewport_screenshot` in the tool list and a note about the
  modeling-strategy prompt.

## 9. Release plan

1. Implement on this feature branch
   (`feature/viewport-screenshot-and-prompt`) using the TDD order in
   §7.5.
2. Green test runs: `uv run pytest tests/ -q` and
   `ruby test/run_all.rb`.
3. Live smoke check (`python examples/smoke_check.py`) with SketchUp
   running and the plugin loaded.
4. Per the global CLAUDE.md rule: `git rm` the design and plan docs
   from `docs/superpowers/` and commit before opening the PR. The
   documents remain in branch git history.
5. Open PR to `master`.
6. After merge: bump version (proposed `0.1.0` — first user-facing
   feature addition after the `0.0.x` bugfix series), `uv lock`,
   follow `docs/release.md`: build → twine check → TestPyPI verify →
   PyPI → `git tag v0.1.0` → GitHub release.
7. Rebuild `.rbz` (`cd su_mcp && ruby package.rb`) if distributing an
   updated SketchUp extension package.

## 10. Out of scope (rationale, for future batches)

| Blender-MCP feature | Why deferred / declined |
|---|---|
| Sketchfab integration | Useful for archviz decor, but adds external API-key handling, import-failure handling, scale-normalization logic. Worth a separate spec if/when users ask for it. |
| Poly Haven textures | Textures are relevant (SketchUp materials accept images) but HDRI/lighting is not — SketchUp has no PBR renderer. Partial port only; defer. |
| Hyper3D Rodin / Hunyuan3D AI generation | AI mesh topology is unsuitable for joinery and precision CAD. Plausibly useful only for archviz decor; defer until concrete user demand. |
| Feature toggles in Settings UI (per-tool kill switch) | A toggle for `eval_ruby` (security opt-in) was considered but deferred — current loopback-only default already mitigates the obvious risk; this can be added cheaply later as a separate spec. |
| Telemetry (Supabase) | Out of scope on purpose. Privacy- and dependency-cost-wise undesirable. |
| Migration to eval-first | Explicitly rejected. Typed tools are our strength. |

## 11. Open decisions (small, to be confirmed during implementation)

| Decision | Default | Alternative |
|---|---|---|
| Version after release | `0.1.0` | `0.0.4` |
| Python prompts file name | `prompts.py` | `prompt_strategy.py` |
| Ruby handler file name | `handlers/view.rb` | `handlers/screenshot.rb` |
| Include `monochrome` style | No (YAGNI) | Yes if needed during live test |
| Final `rendering_options` key set per style | per §5.3 table | Adjusted empirically during TDD |

## 12. Risks

- **Style mapping fragility**: SketchUp `rendering_options` keys may
  behave differently than expected across versions. Mitigation: TDD
  loop with the live model; the worst case is that one style produces
  a slightly off-looking PNG, which is not a correctness defect.
- **Camera restoration on locked/orbiting view**: if the user is mid-
  drag when the screenshot is requested, the snapshot may capture a
  weird intermediate state. Mitigation: documented as a known
  limitation; we won't try to suspend user input.
- **PNG size at high `max_size`**: 4096-px PNGs can reach 5-10 MB
  base64 over JSON-RPC. Mitigation: existing 64 MiB cap covers it;
  default `800` keeps responses small.
- **Prompt drift**: future edits could accidentally remove an anchor
  phrase (e.g. "millimeters"), changing Claude's behavior. Mitigation:
  `test_prompt_anchor_phrases` test in §7.1.

## 13. Acceptance criteria

The work is complete when:

- [ ] `get_viewport_screenshot` is registered as an MCP tool and
      callable through Claude Desktop, returning an MCP `Image`.
- [ ] `sketchup_modeling_strategy` is registered as an MCP prompt,
      visible in the slash menu of a compliant client.
- [ ] All Python tests pass (`uv run pytest tests/ -q`).
- [ ] All Ruby tests pass (`ruby test/run_all.rb`).
- [ ] `examples/smoke_check.py` end-to-end run is green against a live
      SketchUp instance.
- [ ] `CLAUDE.md`, `docs/sketchup-ruby-cookbook.md`, and (if relevant)
      `README.md` are updated.
- [ ] Design and plan docs are removed from `docs/superpowers/` before
      the PR is opened.
