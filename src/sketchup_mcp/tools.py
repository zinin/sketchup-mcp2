"""FastMCP tool handlers for SketchUp.

Most tools are thin wrappers that delegate to :func:`_call`, which centralises
connection acquisition, error handling, and response unwrapping; a few
(`eval_ruby`, `get_viewport_screenshot`) use :func:`_raw_call` directly.
"""
import base64
import json
import logging
from typing import Annotated, Literal, Optional

from mcp.server.fastmcp import Context, Image
from pydantic import Field

from sketchup_mcp import compat, config
from sketchup_mcp.app import mcp
from sketchup_mcp.connection import get_connection
from sketchup_mcp.errors import IncompatibleVersionError, SketchUpError, format_error

logger = logging.getLogger("sketchup_mcp.tools")

# T-06: хендлеры возвращают id как JSON-число (entity.entityID), а схемы
# требовали строго str — модель, отдающая {"id": 12345} обратно как int,
# получала ValidationError (клиентская коэрция это часто маскирует, но
# прямой call_tool — нет). Принимаем оба типа; на провод уходит str(id),
# wire-формат неизменен (Ruby require_id парсит строку).
# P-05: int-ветка СТРОГАЯ — bool является подклассом int, и без strict
# True тихо коэрсился бы в id "1" (валидная операция над чужой сущностью
# из мусорного вызова). Строка "3" при этом спокойно проходит str-веткой.
EntityId = Annotated[int, Field(strict=True)] | Annotated[str, Field(min_length=1)]


async def _raw_call(ctx: Context, tool_name: str, /, **kwargs) -> dict:
    """Acquire the connection and execute one tools/call.

    Returns the raw MCP-shaped result dict
    (``{"content": [...], "isError": False}``).

    ``tool_name`` is positional-only (PEP 570) so wrappers can forward
    user kwargs containing a ``name`` key via ``**args`` without
    colliding with this parameter — see ``find_components`` /
    ``create_layer`` callers below for the pattern.

    Does **not** translate :class:`ConnectionError` to anything — that
    is each caller's responsibility, since callers have divergent
    strategies for unavailable-server (string-returning tools surface a
    graceful string, Image-returning tools raise). Centralising the
    conversion here would introduce brittle string-based detection in
    callers and lose the canonical error text shared by the 22 existing
    text-returning tools.

    See the design's §5.8 for the rationale on error-handling asymmetry
    between text-returning and Image-returning tools.
    """
    sketchup = await get_connection()
    # ConnectionError при недоступном SketchUp поднимает send_command
    # (ленивый connect под conn._lock, T-08), не get_connection — callers
    # ловят её как раньше.
    return await sketchup.send_command(tool_name, kwargs)  # raises SketchUpError


def _extract_text(result: object) -> str:
    """Unwrap a Ruby handler's MCP content envelope to its text payload.

    Both :func:`_call` and the ``eval_ruby`` tool share the same response
    shape — ``{"content": [{"text": ...}], ...}``. Falls back to a JSON
    dump for any result that isn't a well-formed text-content envelope.
    """
    content = result.get("content") if isinstance(result, dict) else None
    if (
        isinstance(content, list)
        and content
        and isinstance(content[0], dict)
        and "text" in content[0]
    ):
        return content[0]["text"]
    return json.dumps(result)


async def _call(ctx: Context, tool_name: str, /, **kwargs) -> str:
    """Dispatch a tool call to SketchUp and shape the response for Claude.

    Same external contract as before — kept for compatibility with the 22
    existing string-returning tools. Now delegates to :func:`_raw_call`
    for connection acquisition and converts the result to a string.
    Connection failures surface as the canonical legacy string so the LLM
    sees a stable, actionable hint.
    """
    try:
        result = await _raw_call(ctx, tool_name, **kwargs)
    except ConnectionError as e:
        return f"SketchUp not running or extension not started: {e}"
    except SketchUpError as e:
        # Locally-raised transport errors (timeout, stale socket, oversize)
        # carry no `tool` in data → format_error would render `tool=?`.
        # Backfill it from the tool name; setdefault never overrides a
        # Ruby-origin error that already carries its own `tool`.
        e.data.setdefault("tool", tool_name)
        return format_error(e, debug=config.LOG_LEVEL == "DEBUG")
    return _extract_text(result)


@mcp.tool()
async def create_component(
    ctx: Context,
    type: Literal["cube", "cylinder", "cone", "sphere"] = "cube",
    position: Annotated[list[float], Field(min_length=3, max_length=3)] = [0, 0, 0],
    dimensions: Annotated[
        list[Annotated[float, Field(gt=0)]],
        Field(min_length=3, max_length=3),
    ] = [1, 1, 1],
) -> str:
    """Create a new component in Sketchup."""
    return await _call(
        ctx,
        "create_component",
        type=type,
        position=position,
        dimensions=dimensions,
    )


@mcp.tool()
async def delete_component(
    ctx: Context,
    id: EntityId,
) -> str:
    """Delete a component by entity ID."""
    return await _call(ctx, "delete_component", id=str(id))


@mcp.tool()
async def transform_component(
    ctx: Context,
    id: EntityId,
    position: Optional[Annotated[list[float], Field(min_length=3, max_length=3)]] = None,
    rotation: Optional[Annotated[list[float], Field(min_length=3, max_length=3)]] = None,
    scale: Optional[Annotated[list[float], Field(min_length=3, max_length=3)]] = None,
) -> str:
    """Move, rotate and/or scale a group or component (mm / degrees).

    - position: ABSOLUTE target for the entity's bounding-box MIN corner,
      in mm — the same anchor create_component uses. Applied LAST (after
      rotation/scale), so the final bbox-min lands exactly at [x, y, z]
      even in combined calls. It is NOT a relative offset: repeating the
      same position is idempotent.
    - rotation: RELATIVE rotation in degrees around the bbox center,
      applied sequentially about world X, then Y, then Z.
    - scale: RELATIVE scale factors about the bbox center.

    Returns {id, name, type, bbox_mm} — read bbox_mm to verify the result.
    """
    args: dict = {"id": str(id)}
    if position is not None:
        args["position"] = position
    if rotation is not None:
        args["rotation"] = rotation
    if scale is not None:
        args["scale"] = scale
    return await _call(ctx, "transform_component", **args)


@mcp.tool()
async def get_selection(ctx: Context) -> str:
    """Get currently selected components."""
    return await _call(ctx, "get_selection")


@mcp.tool()
async def set_material(
    ctx: Context,
    id: EntityId,
    material: Annotated[str, Field(min_length=1)],
) -> str:
    """Set material for a component (named color or hex)."""
    return await _call(ctx, "set_material", id=str(id), material=material)


@mcp.tool()
async def export_scene(
    ctx: Context,
    format: Literal["skp", "obj", "dae", "stl", "png", "jpg"] = "skp",
) -> str:
    """Export the current scene. Note: Ruby tool name is 'export'."""
    return await _call(ctx, "export", format=format)


@mcp.tool()
async def create_mortise_tenon(
    ctx: Context,
    mortise_id: EntityId,
    tenon_id: EntityId,
    width: Annotated[float, Field(gt=0)] = 50.0,
    height: Annotated[float, Field(gt=0)] = 25.0,
    depth: Annotated[float, Field(gt=0)] = 10.0,
    offset_x: float = 0.0,
    offset_y: float = 0.0,
    offset_z: float = 0.0,
) -> str:
    """Create a mortise and tenon joint between two components.

    All dimensions in millimeters. Defaults sized for visibility on a typical
    100mm-board: 50mm wide, 25mm tall, 10mm deep. Pydantic always sends these
    on the wire, so they override Ruby's V.optional_positive defaults — keep
    the two sides in sync (see mcp_for_sketchup/mcp_for_sketchup/handlers/joints.rb).
    """
    return await _call(
        ctx,
        "create_mortise_tenon",
        mortise_id=str(mortise_id),
        tenon_id=str(tenon_id),
        width=width,
        height=height,
        depth=depth,
        offset_x=offset_x,
        offset_y=offset_y,
        offset_z=offset_z,
    )


@mcp.tool()
async def create_dovetail(
    ctx: Context,
    tail_id: EntityId,
    pin_id: EntityId,
    width: Annotated[float, Field(gt=0)] = 50.0,
    height: Annotated[float, Field(gt=0)] = 50.0,
    depth: Annotated[float, Field(gt=0)] = 15.0,
    angle: Annotated[float, Field(gt=0)] = 15.0,
    num_tails: Annotated[int, Field(gt=0)] = 3,
    offset_x: float = 0.0,
    offset_y: float = 0.0,
    offset_z: float = 0.0,
) -> str:
    """Create a dovetail joint between two components. Dimensions in mm."""
    return await _call(
        ctx,
        "create_dovetail",
        tail_id=str(tail_id),
        pin_id=str(pin_id),
        width=width,
        height=height,
        depth=depth,
        angle=angle,
        num_tails=num_tails,
        offset_x=offset_x,
        offset_y=offset_y,
        offset_z=offset_z,
    )


@mcp.tool()
async def create_finger_joint(
    ctx: Context,
    board1_id: EntityId,
    board2_id: EntityId,
    width: Annotated[float, Field(gt=0)] = 50.0,
    height: Annotated[float, Field(gt=0)] = 25.0,
    depth: Annotated[float, Field(gt=0)] = 10.0,
    num_fingers: Annotated[int, Field(gt=0)] = 5,
    offset_x: float = 0.0,
    offset_y: float = 0.0,
    offset_z: float = 0.0,
) -> str:
    """Create a finger joint (box joint) between two components. Dimensions in mm."""
    return await _call(
        ctx,
        "create_finger_joint",
        board1_id=str(board1_id),
        board2_id=str(board2_id),
        width=width,
        height=height,
        depth=depth,
        num_fingers=num_fingers,
        offset_x=offset_x,
        offset_y=offset_y,
        offset_z=offset_z,
    )


@mcp.tool()
async def eval_ruby(
    ctx: Context,
    code: Annotated[str, Field(min_length=1)],
) -> str:
    """Evaluate arbitrary Ruby code in SketchUp.

    Disabled by default in the Extension Warehouse build. If disabled, the
    SketchUp side returns JSON-RPC code -32010 with a user-facing message
    explaining how to enable it. This wrapper surfaces that message as a
    plain string so the LLM can repeat it to the user verbatim — without
    the `[code]` prefix that format_error would otherwise add.
    """
    try:
        result = await _raw_call(ctx, "eval_ruby", code=code)
    except ConnectionError as e:
        return f"SketchUp not running or extension not started: {e}"
    except SketchUpError as e:
        if e.code == compat.EVAL_DISABLED_CODE:
            return e.message
        # Same tool-name backfill as _call, placed AFTER the -32010 verbatim
        # path so the eval-disabled message stays untouched.
        e.data.setdefault("tool", "eval_ruby")
        return format_error(e, debug=config.LOG_LEVEL == "DEBUG")

    return _extract_text(result)


@mcp.tool()
async def boolean_operation(
    ctx: Context,
    target_id: EntityId,
    tool_id: EntityId,
    operation: Literal["union", "difference", "intersection"] = "union",
    delete_originals: bool = False,
) -> str:
    """Perform a boolean operation (union/difference/intersection) on two solids."""
    return await _call(
        ctx,
        "boolean_operation",
        target_id=str(target_id),
        tool_id=str(tool_id),
        operation=operation,
        delete_originals=delete_originals,
    )


@mcp.tool()
async def chamfer_edge(
    ctx: Context,
    id: EntityId,
    distance: Annotated[float, Field(gt=0)] = 5.0,
) -> str:
    """Chamfer all edges of a group/component by ``distance`` (mm).

    Default 5mm — visible on the documented 100mm-cube use case. Ruby tool name
    is ``chamfer_edges`` (plural); Python parameter ``id`` maps to Ruby ``entity_id``.
    """
    return await _call(ctx, "chamfer_edges", entity_id=str(id), distance=distance)


@mcp.tool()
async def fillet_edge(
    ctx: Context,
    id: EntityId,
    radius: Annotated[float, Field(gt=0)] = 5.0,
    segments: Annotated[int, Field(gt=0)] = 8,
) -> str:
    """Fillet (round) all edges of a group/component. Default radius 5mm.

    Note: Ruby tool name is ``fillet_edges`` (plural); Python parameter ``id``
    maps to Ruby parameter ``entity_id``.
    """
    return await _call(
        ctx, "fillet_edges", entity_id=str(id), radius=radius, segments=segments
    )


@mcp.tool()
async def get_viewport_screenshot(
    ctx: Context,
    max_size: Annotated[int, Field(ge=64, le=4096)] = 800,
    view_preset: Literal[
        "current", "front", "back", "left", "right",
        "top", "bottom", "iso",
    ] = "current",
    zoom_extents: bool = False,
    style: Literal["default", "shaded", "hidden_line", "wireframe"] = "default",
    restore_view: bool = True,
) -> Image:
    """Capture the current SketchUp viewport as a PNG and return it as an MCP Image.

    Useful for letting Claude visually verify the scene between steps.

    Parameters
    - max_size: largest side of the returned PNG (64..4096). Aspect ratio is
      taken from the current viewport; the smaller side is scaled proportionally.
    - view_preset: switch the camera to a standard view before snapping.
      ``current`` leaves the camera alone.
    - zoom_extents: call view.zoom_extents before snapping.
    - style: temporarily flip a small set of rendering_options keys.
      ``default`` leaves them alone.
    - restore_view: when true (default), camera and rendering_options are
      snapshotted before mutation and restored after the snapshot, so the
      user's viewport is unchanged.

    Note on operation order (Ruby handler): snapshot → preset → style →
    zoom_extents → write_image → restore. Restore runs in an outer ``ensure``
    block, so an exception anywhere between snapshot and write_image still
    leaves the viewport in its original state.
    """
    # Delegate connection + send_command to _raw_call so we don't duplicate
    # the transport logic of _call. _raw_call does NOT translate
    # ConnectionError (text-tools and Image-tools have divergent strategies),
    # so we convert here: there is no Image sentinel for "not connected",
    # so raise SketchUpError. See design §5.8 for the error-handling
    # asymmetry rationale.
    try:
        raw = await _raw_call(
            ctx,
            "get_viewport_screenshot",
            max_size=max_size,
            view_preset=view_preset,
            zoom_extents=zoom_extents,
            style=style,
            restore_view=restore_view,
        )
    except ConnectionError as e:
        raise SketchUpError(-32000, f"SketchUp not running: {e}") from e

    # Ruby returns MCP-shaped {content: [{type: "text", text: JSON-blob}], ...}.
    # Extract the JSON blob and decode the base64 PNG into raw bytes.
    text: Optional[str] = None
    if isinstance(raw, dict):
        content = raw.get("content")
        if (
            isinstance(content, list)
            and content
            and isinstance(content[0], dict)
        ):
            text = content[0].get("text")
    if not isinstance(text, str):
        raise SketchUpError(
            -32603, f"unexpected screenshot response shape: {raw!r}"
        )
    try:
        payload = json.loads(text)
    except json.JSONDecodeError as e:
        raise SketchUpError(-32603, f"screenshot response not JSON: {e}") from e
    # Guard before .get(): a JSON scalar/array decodes fine but has no .get,
    # which would leak an AttributeError to the MCP client instead of a clean
    # SketchUpError (mirrors the isinstance(text, str) guard above).
    if not isinstance(payload, dict):
        raise SketchUpError(
            -32603,
            f"screenshot payload is not a JSON object: {type(payload).__name__}",
        )
    b64 = payload.get("png_base64")
    if not isinstance(b64, str):
        raise SketchUpError(-32603, "screenshot response missing png_base64")
    try:
        png_bytes = base64.b64decode(b64, validate=True)
    except (ValueError, base64.binascii.Error) as e:
        raise SketchUpError(-32603, f"png_base64 decode failed: {e}") from e
    return Image(data=png_bytes, format="png")


@mcp.tool()
async def get_model_info(ctx: Context) -> str:
    """Get current SketchUp model info: file path, title, units, bounding box, entity count, layer list."""
    return await _call(ctx, "get_model_info")


@mcp.tool()
async def list_components(
    ctx: Context,
    recursive: bool = False,
    max_depth: Annotated[int, Field(ge=1, le=10)] = 3,
) -> str:
    """List groups and component instances in the model.

    Returns each as {id, name, type, layer, depth, bbox_mm}. Bounds are in
    world coordinates. Set recursive=true to descend into nested components
    (bounded by max_depth, default 3).
    """
    return await _call(ctx, "list_components", recursive=recursive, max_depth=max_depth)


@mcp.tool()
async def get_component_info(
    ctx: Context,
    id: EntityId,
) -> str:
    """Detailed info for a single Group or ComponentInstance by entity ID."""
    return await _call(ctx, "get_component_info", id=str(id))


@mcp.tool()
async def find_components(
    ctx: Context,
    name: str | None = None,
    layer: str | None = None,
    type: Literal["group", "component"] | None = None,
    max_depth: Annotated[int, Field(ge=1, le=10)] = 3,
) -> str:
    """Find components matching name substring, layer, and/or type.

    Recursive (bounded by max_depth). At least one filter should be supplied.
    """
    args: dict = {"max_depth": max_depth}
    if name is not None:
        args["name"] = name
    if layer is not None:
        args["layer"] = layer
    if type is not None:
        args["type"] = type
    return await _call(ctx, "find_components", **args)


@mcp.tool()
async def list_layers(ctx: Context) -> str:
    """List all model layers as {name, visible, color, id}."""
    return await _call(ctx, "list_layers")


@mcp.tool()
async def create_layer(
    ctx: Context,
    name: Annotated[str, Field(min_length=1)],
) -> str:
    """Create a new layer with the given name. Returns {id, name, visible}."""
    return await _call(ctx, "create_layer", name=name)


@mcp.tool()
async def undo(ctx: Context) -> str:
    """Undo the last atomic operation in SketchUp. One MCP tool-call = one undo step."""
    return await _call(ctx, "undo")


@mcp.tool()
async def get_version(ctx: Context) -> str:
    """Return the server version and Python↔Ruby compatibility verdict.

    Useful as a runtime sanity probe — always returns a payload, even
    when the connection or other tools surface errors. The result is a
    JSON string with fields: python_version, ruby_version,
    min_compatible_ruby, max_compatible_ruby, ruby_min_compatible_python,
    ruby_max_compatible_python, compatible (bool), error (string | null).
    """
    def _payload(ruby_version, ruby_min, ruby_max, compatible, error_msg):
        return json.dumps({
            "python_version": compat.CLIENT_VERSION,
            "ruby_version": ruby_version,
            "min_compatible_ruby": compat.MIN_RUBY,
            "max_compatible_ruby": compat.MAX_RUBY,
            "ruby_min_compatible_python": ruby_min,
            "ruby_max_compatible_python": ruby_max,
            "compatible": compatible,
            "error": error_msg,
        })

    try:
        raw = await _raw_call(ctx, "get_version")
    except ConnectionError as e:
        return _payload(None, None, None, False,
                        f"SketchUp not running or extension not started: {e}")
    except SketchUpError as e:
        # Covers old Ruby returning -32601 "unknown tool: get_version"
        # and any other JSON-RPC error envelope. Version compatibility is
        # validated once at connect-time in ``_handshake``; once a
        # connection survives that, tool-level errors here come from the
        # Ruby handler itself (not from per-request version checks).
        return _payload(None, None, None, False, str(e))

    # Defensive parse: any unexpected shape (missing keys, non-list content,
    # non-string text, invalid JSON, non-dict payload) must STILL produce a
    # payload — the tool's contract is "always returns a payload even on
    # mismatch / error", so a KeyError/IndexError/TypeError/JSONDecodeError
    # escaping here would violate it.
    try:
        ruby_payload = json.loads(raw["content"][0]["text"])
        if not isinstance(ruby_payload, dict):
            raise TypeError(
                f"ruby payload is {type(ruby_payload).__name__}, expected dict"
            )
    except (KeyError, IndexError, TypeError, json.JSONDecodeError) as e:
        return _payload(None, None, None, False,
                        f"unexpected get_version response shape: {e}")
    ruby_version = ruby_payload.get("ruby_version")
    ruby_min = ruby_payload.get("min_compatible_python")
    ruby_max = ruby_payload.get("max_compatible_python")

    # Two-way compatibility: BOTH sides' tables must accept the counterpart.
    try:
        compat.check_ruby_version(ruby_version)
        python_accepts_ruby, py_error = True, None
    except IncompatibleVersionError as e:
        python_accepts_ruby, py_error = False, str(e)

    try:
        ruby_accepts_python = bool(
            ruby_min and ruby_max and
            compat.parse(ruby_min)
            <= compat.parse(compat.CLIENT_VERSION)
            <= compat.parse(ruby_max)
        )
    except ValueError:
        ruby_accepts_python = False

    compatible = python_accepts_ruby and ruby_accepts_python
    if py_error:
        error_msg = py_error
    elif not ruby_accepts_python:
        error_msg = (
            f"SketchUp plugin advertises Python compatibility "
            f"{ruby_min}..{ruby_max}, which excludes v{compat.CLIENT_VERSION}."
        )
    else:
        error_msg = None

    return _payload(ruby_version, ruby_min, ruby_max, compatible, error_msg)
