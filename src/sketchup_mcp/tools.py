"""FastMCP tool handlers for SketchUp.

Each tool is a thin wrapper that delegates to :func:`_call`, which centralises
connection acquisition, error handling, and response unwrapping.
"""
import json
import logging
from typing import Annotated, Literal, Optional

from mcp.server.fastmcp import Context
from pydantic import Field

from sketchup_mcp import config
from sketchup_mcp.app import mcp
from sketchup_mcp.connection import get_connection
from sketchup_mcp.errors import SketchUpError, format_error

logger = logging.getLogger("sketchup_mcp.tools")


async def _call(ctx: Context, name: str, **kwargs) -> str:
    """Dispatch a tool call to SketchUp and shape the response for Claude.

    - Connection errors → human-readable string, server keeps running.
    - SketchUpError → ``format_error`` string.
    - Successful MCP-shaped result ({content: [{text: "..."}]}) → just the text.
    - Any other dict result → ``json.dumps``.
    """
    try:
        sketchup = await get_connection()
    except ConnectionError as e:
        return f"SketchUp not running or extension not started: {e}"
    try:
        result = await sketchup.send_command(name, kwargs)
    except ConnectionError as e:
        # Cached connection was stale and reconnect inside send_command failed:
        # `_connect_or_raise` re-raises OSError as ConnectionError before the
        # send/recv try-block, so it escapes past the SketchUpError handler.
        return f"SketchUp not running or extension not started: {e}"
    except SketchUpError as e:
        return format_error(e, debug=config.LOG_LEVEL == "DEBUG")
    content = result.get("content") if isinstance(result, dict) else None
    if (
        isinstance(content, list)
        and content
        and isinstance(content[0], dict)
        and "text" in content[0]
    ):
        return content[0]["text"]
    return json.dumps(result)


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
    id: Annotated[str, Field(min_length=1)],
) -> str:
    """Delete a component by entity ID."""
    return await _call(ctx, "delete_component", id=id)


@mcp.tool()
async def transform_component(
    ctx: Context,
    id: Annotated[str, Field(min_length=1)],
    position: Optional[Annotated[list[float], Field(min_length=3, max_length=3)]] = None,
    rotation: Optional[Annotated[list[float], Field(min_length=3, max_length=3)]] = None,
    scale: Optional[Annotated[list[float], Field(min_length=3, max_length=3)]] = None,
) -> str:
    """Transform a component's position, rotation, or scale."""
    args: dict = {"id": id}
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
    id: Annotated[str, Field(min_length=1)],
    material: Annotated[str, Field(min_length=1)],
) -> str:
    """Set material for a component (named color or hex)."""
    return await _call(ctx, "set_material", id=id, material=material)


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
    mortise_id: Annotated[str, Field(min_length=1)],
    tenon_id: Annotated[str, Field(min_length=1)],
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
    the two sides in sync (see su_mcp/su_mcp/handlers/joints.rb).
    """
    return await _call(
        ctx,
        "create_mortise_tenon",
        mortise_id=mortise_id,
        tenon_id=tenon_id,
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
    tail_id: Annotated[str, Field(min_length=1)],
    pin_id: Annotated[str, Field(min_length=1)],
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
        tail_id=tail_id,
        pin_id=pin_id,
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
    board1_id: Annotated[str, Field(min_length=1)],
    board2_id: Annotated[str, Field(min_length=1)],
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
        board1_id=board1_id,
        board2_id=board2_id,
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
    """Evaluate arbitrary Ruby code in Sketchup."""
    return await _call(ctx, "eval_ruby", code=code)


@mcp.tool()
async def boolean_operation(
    ctx: Context,
    target_id: Annotated[str, Field(min_length=1)],
    tool_id: Annotated[str, Field(min_length=1)],
    operation: Literal["union", "difference", "intersection"] = "union",
    delete_originals: bool = False,
) -> str:
    """Perform a boolean operation (union/difference/intersection) on two solids."""
    return await _call(
        ctx,
        "boolean_operation",
        target_id=target_id,
        tool_id=tool_id,
        operation=operation,
        delete_originals=delete_originals,
    )


@mcp.tool()
async def chamfer_edge(
    ctx: Context,
    id: Annotated[str, Field(min_length=1)],
    distance: Annotated[float, Field(gt=0)] = 5.0,
) -> str:
    """Chamfer all edges of a group/component by ``distance`` (mm).

    Default 5mm — visible on the documented 100mm-cube use case. Ruby tool name
    is ``chamfer_edges`` (plural); Python parameter ``id`` maps to Ruby ``entity_id``.
    """
    return await _call(ctx, "chamfer_edges", entity_id=id, distance=distance)


@mcp.tool()
async def fillet_edge(
    ctx: Context,
    id: Annotated[str, Field(min_length=1)],
    radius: Annotated[float, Field(gt=0)] = 5.0,
    segments: Annotated[int, Field(gt=0)] = 8,
) -> str:
    """Fillet (round) all edges of a group/component. Default radius 5mm.

    Note: Ruby tool name is ``fillet_edges`` (plural); Python parameter ``id``
    maps to Ruby parameter ``entity_id``.
    """
    return await _call(
        ctx, "fillet_edges", entity_id=id, radius=radius, segments=segments
    )


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
    id: Annotated[str, Field(min_length=1)],
) -> str:
    """Detailed info for a single Group or ComponentInstance by entity ID."""
    return await _call(ctx, "get_component_info", id=id)


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
