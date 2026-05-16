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
                        (also: small refactor to extract _raw_call, see §5.8)
  prompts.py            NEW — defines sketchup_modeling_strategy prompt
  app.py                +1 side-effect import sketchup_mcp.prompts
                        (next to existing `import sketchup_mcp.tools` at app.py:51)
  connection.py         +1 entry "get_viewport_screenshot" in _RETRY_SAFE_TOOLS

su_mcp/su_mcp/
  main.rb                 +1 entry "handlers/view" in LOAD_ORDER
  handlers/dispatch.rb    +1 branch "get_viewport_screenshot" -> Handlers::View
  handlers/view.rb        NEW — viewport_screenshot handler

test/
  test_view.rb          NEW — Ruby unit tests
tests/
  test_prompts.py       NEW — Python tests for prompt registration
  test_screenshot.py    NEW — Python tests for tool wrapper
  test_connection.py    +1 test — get_viewport_screenshot ∈ _RETRY_SAFE_TOOLS

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

**Double-encoding overhead.** Effective wire size ≈ 2× raw PNG (base64
adds ~33%, JSON string wrapping inside the MCP `content` envelope adds
another ~33%). An 800-px PNG stays well under 2 MiB on the wire; a
4096-px PNG can reach 20+ MiB. To prevent the framing cap from being
hit on rich textured scenes, the Ruby handler enforces a hard size
limit (see §5.4 step 6) before base64 encoding.

**Retry-safety.** `get_viewport_screenshot` is added to
`_RETRY_SAFE_TOOLS` in `src/sketchup_mcp/connection.py`. The handler is
idempotent: when `restore_view=true` the model is untouched after the
call, and when `restore_view=false` the only state change is to the
viewport — never to the document — so a repeated retry is harmless.

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

### 5.3 Style → rendering_options mapping (initial — to be verified)

The keys below are **proposed**; SketchUp's `Sketchup::RenderingOptions`
documentation is incomplete and some keys behave differently between
versions (in SketchUp 2024+ unknown keys raise `ArgumentError`).
Verifying each key against SketchUp 2026 is a blocking acceptance
gate — see §13.

| `style` | Keys set (proposed) |
|---|---|
| `shaded` | `DisplayShaded=true`, `DisplayShadedUsingAllSameObject=false`, `DrawEdges=true` |
| `hidden_line` | `DisplayShaded=false`, `DrawEdges=true`, `DrawHidden=true`, `DrawProfilesOnly=false` |
| `wireframe` | `DisplayShaded=false`, `DrawEdges=true`, `DrawFaces=false` (the `DisplayShaded=false` is essential — without it, faces may still render even with `DrawFaces=false`) |

The Ruby production handler raises `Core::StructuredError` if any key
in the requested style's set is rejected by SketchUp; the test stub
raises on unknown keys to mirror that behavior.

**RO snapshot scope.** When `restore_view=true` and `style != "default"`,
only the keys listed for the requested style are snapshotted and
restored — not the full ~30-key `rendering_options` dictionary. This is
sufficient because `Sketchup.send_action("view{Preset}:")` (preset
application) is empirically verified during acceptance (§13) to leave
`rendering_options` untouched, so no out-of-style keys change as a
side effect. If acceptance discovers otherwise, we switch to a
full-dictionary snapshot.

### 5.4 Ruby handler flow

**Operation order**: snapshot → preset → style → zoom_extents →
write_image → restore (outer `ensure` always runs the restore step
when `restore_view=true`, even on exceptions).

**Active-model/active-view guards** come first: use the existing
`SU_MCP::Helpers::Entities.active_model!` for the model, and raise a
`Core::StructuredError(-32000, "no active view")` if `model.active_view`
is `nil`. Never dereference into `nil`.

```
0. model = Helpers::Entities.active_model!
   view  = model.active_view; raise StructuredError if view.nil?

1. (if restore_view)
     # Deep snapshot — construct a fresh Camera so mutating the live
     # view does not affect the snapshot. See CONCERN-1 in review iter 1.
     c = view.camera
     snap_camera = Sketchup::Camera.new(c.eye, c.target, c.up)
     snap_camera.perspective = c.perspective?
     if c.perspective?
       snap_camera.fov = c.fov
     else
       snap_camera.height = c.height
     end
   (if restore_view AND style != "default")
     snapshot rendering_options keys we are about to touch

   begin   # outer begin/ensure guarantees restore on every path

2.   (if view_preset != "current") Sketchup.send_action("view#{P}:")
3.   (if style != "default")        apply rendering_options keys
4.   (if zoom_extents)
        begin
          view.zoom_extents
        rescue StandardError => e
          # Some SketchUp versions surface a "no geometry" dialog on
          # empty models. Swallow it: a default-frame screenshot is OK.
          Logger.warn("zoom_extents failed: #{e}")
        end

5.   # Tempfile.create gives a guaranteed-unique path and auto-cleanup.
     Tempfile.create(["sumcp_vp_", ".png"]) do |tmp|
       tmp.close
       ok = view.write_image(filename: tmp.path, width: w, height: h,
                             antialias: true, compression: 1.0,
                             transparent: false)
       raise Core::StructuredError.new(-32000,
                                      "viewport write_image failed") unless ok

6.     # Hard size cap to keep wire payload under the 64 MiB framing
       # limit even after base64 + JSON-string wrapping (~2× overhead).
       size = File.size(tmp.path)
       if size > 32 * 1024 * 1024  # 32 MiB raw → ~64 MiB on wire
         raise Core::StructuredError.new(-32000,
           "screenshot too large: #{size} bytes — reduce max_size")
       end
       data = File.binread(tmp.path)
     end                            # Tempfile auto-deleted here

   ensure
7.   if restore_view
       view.camera = snap_camera if snap_camera
       snap_ro&.each { |k, v| model.rendering_options[k] = v }
     end
   end

8. return {png_base64: Base64.strict_encode64(data),
           width: w, height: h,
           preset_used: view_preset, style_used: style}
```

`w` / `h` computation:

```ruby
vw = view.vpwidth.to_f
vh = view.vpheight.to_f
raise StructuredError if vw <= 0 || vh <= 0
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

- **No active model / no active view**: `Helpers::Entities.active_model!`
  raises if `Sketchup.active_model` is nil/false. The handler additionally
  raises `Core::StructuredError(-32000, "no active view")` if
  `model.active_view` is nil. Both are wrapped in MCP error responses.
- **Empty model**: `view.zoom_extents` produces SketchUp's default frame
  — typically a sky/ground gradient with horizon line. The screenshot is
  visually neutral but valid. If `zoom_extents` itself raises (some
  SketchUp versions trigger a "no geometry" dialog on empty models), the
  exception is caught and logged; the screenshot proceeds with the
  current (unscoped) view.
- **`write_image` returns false**: handler raises
  `Core::StructuredError.new(-32000, "viewport write_image failed")`.
  Python propagates as `SketchUpError`.
- **Extreme aspect ratios** (e.g. 5000×100): scaled down so both sides
  fit the `max_size` budget. No special handling.
- **Open SketchUp modal dialog**: `write_image` may fail; we surface
  the error to the user rather than silently producing garbage.
- **Hidden geometry / hidden tags / current style**: the screenshot
  captures **what the user currently sees** — hidden objects stay
  hidden, hidden tags stay hidden, the active style applies (unless
  overridden by the `style` parameter). The handler does not
  temporarily unhide anything.
- **Active Section Plane**: respected — the screenshot reflects the
  current section cut. No special handling.
- **Active SketchUp Page (Scene)**: the saved page camera is not
  modified by this tool. With `restore_view=true` the handler restores
  the live `view.camera`, which is not necessarily identical to the
  current page's saved camera — calling the tool while the user has
  modified the live camera away from a saved page does not "re-snap"
  to that page. Documented as known behavior.
- **Mid-drag / mid-orbit input**: if the user is actively dragging or
  orbiting when the MCP request arrives, `write_image` captures the
  intermediate state. Documented limitation; we do not suspend user
  input. See §12.
- **Oversize result**: when raw PNG > 32 MiB the handler raises
  `Core::StructuredError` with a hint to reduce `max_size`. See §5.4
  step 6.

### 5.7 Security

- `view_preset` / `style`: Python `Literal`-validated; an unknown value
  cannot reach Ruby.
- `max_size`: clamped Python-side, re-validated Ruby-side (defence in
  depth).
- Tempfile path: created via `Tempfile.create(["sumcp_vp_", ".png"])`
  (stdlib idiom — guaranteed-unique path, auto-cleanup on block exit).

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

### 7.1 Python (pytest) — three new tests files

`tests/test_screenshot.py`:

| Test | Asserts |
|---|---|
| `test_screenshot_minimal_payload` | Default call sends JSON-RPC `tools/call name="get_viewport_screenshot"` with full default param map. |
| `test_screenshot_max_size_clamps` | Through `mcp.call_tool(...)` — `max_size=10` and `max_size=99999` raise validation error (not via `.fn`, which doesn't exist; via FastMCP's full dispatch path). |
| `test_screenshot_view_preset_invalid` | Through `mcp.call_tool(...)` — `view_preset="diagonal"` raises validation error. |
| `test_screenshot_style_invalid` | Through `mcp.call_tool(...)` — `style="cartoon"` raises validation error. |
| `test_screenshot_returns_image` | Ruby returns valid base64 PNG → wrapper returns `Image` with `data == png_bytes`; check `img.format == "png"` (public attr from constructor) rather than `img._mime_type`. |
| `test_screenshot_via_mcp_dispatch` | End-to-end through `await mcp.call_tool("get_viewport_screenshot", {...})` — mocked SketchUp connection — verifies FastMCP serializes `Image` to `ImageContent` with `mimeType="image/png"`. |
| `test_screenshot_base64_decode_failure` | Invalid base64 surfaces as a clear error, not silent corruption. |
| `test_screenshot_propagates_ruby_error` | JSON-RPC error → `SketchUpError`. |

`tests/test_prompts.py`:

| Test | Asserts |
|---|---|
| `test_prompt_registered` | After importing `sketchup_mcp.prompts` (module-level — no autouse fixture needed), `sketchup_modeling_strategy` is in the FastMCP prompt registry. |
| `test_prompt_returns_non_empty_text` | Body > 200 chars. |
| `test_prompt_anchor_phrases` | Contains `get_model_info`, `millimeters`, `undo`, `eval_ruby`, `boolean_operation`, `bbox_mm`. |
| `test_prompt_required_sections` | All seven section headers from §6.2 are present: `# 1. Pre-flight`, `# 2. Tool priority`, `# 3. Conventions`, `# 4. After every mutation`, `# 5. Error recovery`, `# 6. Known traps`, `# 7. Joinery defaults`. Guards prompt structure, not just words. |
| `test_prompt_description_present` | `description` non-empty and mentions "SketchUp". |

`tests/test_connection.py` — add one test:

| Test | Asserts |
|---|---|
| `test_get_viewport_screenshot_is_retry_safe` | `"get_viewport_screenshot" in _RETRY_SAFE_TOOLS`. Guards against accidental removal. |

### 7.2 Ruby (minitest) — `test/test_view.rb`

| Test | Asserts |
|---|---|
| `test_dispatch_routes_to_view_handler` | JSON-RPC dispatches to `Handlers::View.viewport_screenshot`. |
| `test_invalid_view_preset_raises` | `view_preset="weird"` → `Core::StructuredError`. |
| `test_invalid_style_raises` | `style="cartoon"` → `Core::StructuredError`. |
| `test_invalid_max_size_raises` | `max_size=10` or `99999` → `Core::StructuredError`. |
| `test_camera_restored_when_flag_true` | **Strengthened**: stub `send_action` actually mutates `view.camera` (or test directly mutates the camera between snapshot and restore) AND a spy records every `view.camera=` assignment. Asserts a restore-assignment occurred AND the final camera equals the original. |
| `test_camera_not_restored_when_flag_false` | After `restore_view=false`, the `view.camera=` spy records no restore-assignment. |
| `test_camera_restored_after_zoom_extents_failure` | Restore runs even when `zoom_extents` raises (outer `ensure`). |
| `test_rendering_options_restored` | Pre-mutate one RO key, call handler with `style="wireframe", restore_view=true`, assert key returns to its pre-call value. |
| `test_rendering_options_restored_after_write_image_failure` | Restore runs even when `write_image` returns false (outer `ensure`). |
| `test_rendering_options_not_restored_when_restore_view_false` | Negative case: with `style="wireframe", restore_view=false`, RO keys stay mutated. |
| `test_no_ro_touched_when_style_default` | Spy on `model.rendering_options[]=`; with `style="default", restore_view=true`, no RO key is written. |
| `test_send_action_called_for_preset` | Spying on `Sketchup.send_action`, `view_preset="iso"` triggers exactly one `"viewIso:"`. |
| `test_zoom_extents_called_when_flag` | `view.zoom_extents` is called only when `zoom_extents=true`. |
| `test_zoom_extents_failure_does_not_propagate` | Stub `zoom_extents` to raise; handler still returns a valid response (logs the failure). |
| `test_write_image_failure_raises` | Stubbed `view.write_image -> false` → `Core::StructuredError`. |
| `test_oversize_png_raises` | Stub returns >32 MiB file → `Core::StructuredError` with hint to reduce `max_size`. |
| `test_no_active_view_raises` | `model.active_view = nil` → `Core::StructuredError` from the early guard. |
| `test_tempfile_cleaned_up_on_success` | Glob assertion `Dir.glob(File.join(Dir.tmpdir, "sumcp_vp_*.png")).empty?` after success. (Racy `Dir.entries.count` check removed.) |
| `test_tempfile_cleaned_up_on_failure` | Same glob assertion when `write_image` raises. |
| `test_response_structure` | Success response shape: `{png_base64, width, height, preset_used, style_used}`. `png_base64` decodes to bytes starting with PNG magic header `\x89PNG\r\n\x1a\n` (the stub writes a real-looking minimal PNG, not the placeholder `"FAKE_PNG_BYTES"`). |
| `test_aspect_ratio_preserved` | vpwidth=1920, vpheight=1080, max_size=800 → width=800, height=450. |
| `test_aspect_ratio_preserved_portrait` | vpwidth=1080, vpheight=1920, max_size=800 → width=450, height=800. |

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
6. After merge: bump version to `0.1.0` — chosen over `0.0.4` because
   this is the first user-facing **feature** addition after the
   `0.0.x` bugfix series, signalling a capability addition rather
   than a maintenance patch. Pre-1.0 SemVer treats both as valid;
   we lean on the minor-bump convention to make the changelog
   semantically informative. `uv lock`, follow `docs/release.md`:
   build → twine check → TestPyPI verify → PyPI → `git tag v0.1.0`
   → GitHub release.
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
| Python prompts file name | `prompts.py` | `prompt_strategy.py` |
| Ruby handler file name | `handlers/view.rb` | `handlers/screenshot.rb` |
| Include `monochrome` style | No (YAGNI) | Yes if needed during live test |
| Final `rendering_options` key set per style | per §5.3 table — to be empirically confirmed against SketchUp 2026 during TDD before writing the production handler (see §13 acceptance criteria) | Adjustments expected; major divergence escalates to a follow-up review iteration |

Resolved during review iter 1:
- Version after release: **`0.1.0`** (see §9 step 6 for rationale).

## 12. Risks

- **Style mapping fragility**: SketchUp `rendering_options` keys may
  behave differently than expected across versions (in SketchUp 2024+
  invalid keys can raise `ArgumentError`). Mitigation: empirical
  verification of every key in §5.3 against SketchUp 2026 is a
  blocking pre-implementation step (§13 acceptance); test stub raises
  on unknown keys to mirror live behavior; production handler
  surfaces unknown-key errors as `Core::StructuredError`.
- **Camera restoration on locked/orbiting view**: if the user is
  actively dragging or orbiting when the MCP request arrives, the
  snapshot may capture an intermediate state, and `view.camera=`
  during restore may compete with the active tool's input. Mitigation:
  documented as a known limitation; we won't try to suspend user
  input. Users should not expect deterministic screenshots while
  interacting with the model.
- **PNG size at high `max_size`**: 4096-px PNGs of detailed textured
  scenes can exceed 10 MB raw → ~20 MB on the wire after base64+JSON
  wrapping. Mitigation: hard 32 MiB raw-file cap in the handler
  raises a `Core::StructuredError` with a "reduce max_size" hint
  before transport; default `800` keeps typical responses well under
  2 MiB.
- **`antialias: true` cost at large sizes**: SketchUp's antialiasing
  scales nonlinearly with output size; a 4096-px screenshot may take
  several seconds and briefly block the SketchUp UI thread.
  Mitigation: documented; user can request smaller `max_size` if
  responsiveness matters more than fidelity.
- **`view.camera` reference vs deep copy**: empirically `view.camera`
  returns a fresh object each call in SketchUp 2026, but the design
  does not assume this — the snapshot explicitly constructs a new
  `Sketchup::Camera(eye, target, up)` and copies `perspective?` plus
  `fov`/`height` to guard against future API changes.
- **`rendering_options` undo interaction**: the design assumes RO
  writes are pure UI-state and do not enter the undo stack. This is
  not officially documented and is verified via a live SketchUp 2026
  acceptance test in §13. If found false, the handler will be wrapped
  in `model.start_operation(name, true, false, true)` with the
  transparent flag so screenshots cannot pollute user-visible undo.
- **Prompt drift**: future edits could accidentally remove an anchor
  phrase (e.g. "millimeters") or a structural section, changing
  Claude's behavior. Mitigation: `test_prompt_anchor_phrases` (word-
  level) AND `test_prompt_required_sections` (section-level) tests
  in §7.1.

## 13. Acceptance criteria

The work is complete when:

- [ ] **Live SketchUp 2026 verification step BEFORE writing the
      production handler** — each of these assumptions verified via a
      tiny `eval_ruby` snippet against a running SketchUp 2026, results
      pasted into the PR description:
   1. Each `rendering_options` key listed in §5.3 is accepted (no
      `ArgumentError`) and produces the expected visual change.
   2. `view.camera` returns a fresh object on each call (or, if not,
      the snapshot mechanism in §5.4 step 1 is verified to capture
      eye/target/up/perspective/fov-or-height correctly).
   3. RO writes do **not** add entries to the Undo menu (verified by
      observing the menu before/after the snippet).
- [ ] `get_viewport_screenshot` is registered as an MCP tool and
      callable through Claude Desktop, returning an MCP `Image`.
- [ ] `get_viewport_screenshot` appears in `_RETRY_SAFE_TOOLS`
      (`src/sketchup_mcp/connection.py`); the regression test in
      `tests/test_connection.py` is green.
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
