"""M-12, M-18 (spec §6.6): the MCP surface.

One table (``sketchup_mcp.annotations``) gives every tool its annotations and
derives the retry set from the read-only ones, so a tool cannot be retried
after a stale socket unless it is annotated read-only. No tool returns
structured content beside its text (FastMCP wraps a ``str`` return in
``{"result": ...}`` unless told not to). The server reports its own package
version, not the ``mcp`` library's.
"""
import sketchup_mcp
from sketchup_mcp import connection
from sketchup_mcp.annotations import TOOL_ANNOTATIONS, WIRE_NAMES, read_only_wire_names
from sketchup_mcp.app import mcp

# The decisions, one row per tool: (readOnly, destructive, idempotent,
# openWorld). Read-only means it changes neither the model nor any file;
# destructive, that it may change or remove what exists (not only add);
# idempotent, that repeating it changes nothing more; open world, that it can
# reach beyond SketchUp (eval_ruby runs arbitrary Ruby: files, network,
# shell).
EXPECTED = {
    "get_model_info": (True, False, True, False),
    "list_components": (True, False, True, False),
    "get_component_info": (True, False, True, False),
    "find_components": (True, False, True, False),
    "list_layers": (True, False, True, False),
    "get_selection": (True, False, True, False),
    "get_viewport_screenshot": (True, False, True, False),
    "get_version": (True, False, True, False),
    "create_component": (False, False, False, False),
    "export_scene": (False, False, False, False),
    "create_layer": (False, False, True, False),
    "delete_component": (False, True, True, False),
    "set_material": (False, True, True, False),
    "transform_component": (False, True, False, False),
    "boolean_operation": (False, True, False, False),
    "chamfer_edge": (False, True, False, False),
    "fillet_edge": (False, True, False, False),
    "create_mortise_tenon": (False, True, False, False),
    "undo": (False, True, False, False),
    "eval_ruby": (False, True, False, True),
}


def _hints(annotations):
    return (annotations.readOnlyHint, annotations.destructiveHint,
            annotations.idempotentHint, annotations.openWorldHint)


async def test_every_tool_carries_its_annotations():
    tools = {t.name: t.annotations for t in await mcp.list_tools()}
    assert tools == TOOL_ANNOTATIONS


def test_the_annotations_are_the_decided_ones():
    assert {name: _hints(a) for name, a in TOOL_ANNOTATIONS.items()} == EXPECTED


def test_retry_safe_tools_are_the_read_only_ones():
    assert connection._RETRY_SAFE_TOOLS == read_only_wire_names() == {
        "get_model_info", "list_components", "get_component_info", "find_components",
        "list_layers", "get_selection", "get_viewport_screenshot", "get_version"}


def test_wire_names_cover_the_renamed_tools_only():
    assert WIRE_NAMES == {"chamfer_edge": "chamfer_edges", "fillet_edge": "fillet_edges",
                          "export_scene": "export"}


async def test_tools_return_no_structured_content():
    assert all(t.outputSchema is None for t in await mcp.list_tools())


def test_server_info_reports_the_package_version():
    assert mcp._mcp_server.create_initialization_options().server_version == sketchup_mcp.__version__
