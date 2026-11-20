"""MCP tool annotations: one table, read by ``tools.py`` and ``connection.py``.

Every tool gets its hints from ``TOOL_ANNOTATIONS`` (spec §6.6, M-18): a tool
is read-only when it changes neither the model nor any file; destructive when
it may change or remove what exists rather than only add; idempotent when
repeating it with the same arguments changes nothing more; open-world when it
can reach beyond SketchUp. Only ``eval_ruby`` is open-world: it runs arbitrary
Ruby, with the file system, the network and the shell in reach.

The stale-socket retry set (``connection._RETRY_SAFE_TOOLS``) is derived from
the read-only hints, so a tool cannot be re-sent after a dropped connection
unless it is annotated read-only. The retry set holds wire names: three tools
are called by another name on the wire (``WIRE_NAMES``).

This module imports nothing from the package, so ``connection.py`` can read it
without importing ``tools.py`` (which imports ``connection.py``).
"""
from mcp.types import ToolAnnotations


def _hints(read_only: bool, destructive: bool = False, idempotent: bool = False,
           open_world: bool = False) -> ToolAnnotations:
    return ToolAnnotations(readOnlyHint=read_only, destructiveHint=destructive,
                           idempotentHint=idempotent, openWorldHint=open_world)


_READ = _hints(True, idempotent=True)

# MCP tool name -> hints.
TOOL_ANNOTATIONS: dict[str, ToolAnnotations] = {
    "get_model_info": _READ,
    "list_components": _READ,
    "get_component_info": _READ,
    "find_components": _READ,
    "list_layers": _READ,
    "get_selection": _READ,
    # Read-only for the model and the files: it writes neither. With
    # restore_view (the default) the camera and the style are put back after
    # the snapshot; restore_view=false leaves the view where the call put it,
    # which is what that argument asks for. A repeat with the same arguments
    # gives the same view, so the retry set may hold it, and Ruby's
    # READ_ONLY_TOOLS (dispatch.rb) lists it too.
    "get_viewport_screenshot": _READ,
    "get_version": _READ,
    "create_component": _hints(False),
    # Writes a new file on the SketchUp host each time.
    "export_scene": _hints(False),
    # Adding a layer that exists returns it.
    "create_layer": _hints(False, idempotent=True),
    "delete_component": _hints(False, destructive=True, idempotent=True),
    "set_material": _hints(False, destructive=True, idempotent=True),
    "transform_component": _hints(False, destructive=True),
    "boolean_operation": _hints(False, destructive=True),
    "chamfer_edge": _hints(False, destructive=True),
    "fillet_edge": _hints(False, destructive=True),
    "create_mortise_tenon": _hints(False, destructive=True),
    "undo": _hints(False, destructive=True),
    "eval_ruby": _hints(False, destructive=True, open_world=True),
}

# MCP tool name -> wire name, where they differ.
WIRE_NAMES: dict[str, str] = {
    "chamfer_edge": "chamfer_edges",
    "fillet_edge": "fillet_edges",
    "export_scene": "export",
}


def read_only_wire_names() -> frozenset[str]:
    """The wire names of the tools annotated read-only."""
    return frozenset(WIRE_NAMES.get(name, name)
                     for name, hints in TOOL_ANNOTATIONS.items() if hints.readOnlyHint)
