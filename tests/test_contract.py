"""M-09: tools.py, dispatch.rb and the retry whitelist must agree on wire names.

Three hand-kept copies of one vocabulary, tied together by nothing at run
time. A wire name deleted from ``Dispatch.call_handler`` used to pass every
test, and a mutating tool added to ``_RETRY_SAFE_TOOLS`` would be applied
twice after a stale socket. These tests read the sources, the way test_compat.py
reads compat.rb. test/test_dispatch_routing.rb is the Ruby half: every routed
wire name reaches its handler.
"""
import re
from pathlib import Path

from sketchup_mcp import connection
from sketchup_mcp.annotations import WIRE_NAMES
from sketchup_mcp.app import mcp

_ROOT = Path(__file__).resolve().parent.parent
_TOOLS_PY = _ROOT / "src" / "sketchup_mcp" / "tools.py"
_DISPATCH_RB = (
    _ROOT / "mcp_for_sketchup" / "mcp_for_sketchup" / "handlers" / "dispatch.rb"
)


def _dispatched_wire_names() -> set[str]:
    """Every wire name literal in call_handler, between ``case tool`` and ``else``."""
    source = _DISPATCH_RB.read_text(encoding="utf-8")
    m = re.search(
        r"def self\.call_handler\b.*?\bcase tool\b(.*?)^\s*else\b", source, re.S | re.M
    )
    assert m, f"call_handler's `case tool` table not found in {_DISPATCH_RB}"
    return set(re.findall(r'"([a-z_]+)"', m.group(1)))


def _sent_wire_names() -> list[str]:
    """Wire names tools.py passes to ``_call`` / ``_raw_call``, in source order."""
    source = _TOOLS_PY.read_text(encoding="utf-8")
    return re.findall(r'_(?:raw_)?call\(\s*ctx,\s*"([a-z_]+)"', source)


def _ruby_read_only_tools() -> set[str]:
    """The names in dispatch.rb's ``READ_ONLY_TOOLS = %w[...]``."""
    source = _DISPATCH_RB.read_text(encoding="utf-8")
    m = re.search(r"^\s*READ_ONLY_TOOLS\s*=\s*%w\[([^\]]*)\]", source, re.M)
    assert m, f"READ_ONLY_TOOLS not found in {_DISPATCH_RB}"
    return set(m.group(1).split())


def test_every_wire_name_python_sends_is_dispatched_by_ruby():
    sent, dispatched = set(_sent_wire_names()), _dispatched_wire_names()
    assert sent <= dispatched, (
        f"tools.py sends {sorted(sent - dispatched)}, which call_handler does not route"
    )


def test_ruby_only_wire_names_are_pinned():
    # export_scene is the Ruby-side alias of "export": the MCP tool carries
    # that name and examples/smoke_check.py sends it, but tools.py sends
    # "export". A new Ruby route without a Python tool must be added here
    # on purpose.
    assert _dispatched_wire_names() - set(_sent_wire_names()) == {"export_scene"}


async def test_each_mcp_tool_sends_exactly_one_wire_name():
    sent = _sent_wire_names()
    tools = await mcp.list_tools()   # 20 today
    assert len(sent) == len(set(sent)) == len(tools), (
        f"{len(tools)} MCP tools, {len(sent)} wire names sent "
        f"({len(set(sent))} distinct): {sorted(sent)}"
    )


def test_retry_safe_tools_are_read_only_in_ruby():
    read_only = _ruby_read_only_tools()
    assert connection._RETRY_SAFE_TOOLS <= read_only, (
        f"_RETRY_SAFE_TOOLS re-sends {sorted(connection._RETRY_SAFE_TOOLS - read_only)}, "
        "which dispatch.rb's READ_ONLY_TOOLS does not list"
    )


def test_read_only_tools_are_dispatched():
    read_only, dispatched = _ruby_read_only_tools(), _dispatched_wire_names()
    assert read_only <= dispatched, (
        f"READ_ONLY_TOOLS lists {sorted(read_only - dispatched)}, "
        "which call_handler does not route"
    )


def _ruby_allowed_args() -> dict[str, set[str]]:
    """dispatch.rb's ``ALLOWED_ARGS = { "wire" => %w[...], ... }.freeze``."""
    source = _DISPATCH_RB.read_text(encoding="utf-8")
    m = re.search(r"^\s*ALLOWED_ARGS\s*=\s*\{(.*?)^\s*\}\.freeze", source, re.S | re.M)
    assert m, f"ALLOWED_ARGS not found in {_DISPATCH_RB}"
    return {name: set(words.split())
            for name, words in re.findall(r'"([a-z_]+)"\s*=>\s*%w\[([^\]]*)\]', m.group(1))}


# MCP parameters a wrapper sends under another argument name.
_ARG_RENAMES = {"chamfer_edge": {"id": "entity_id"}, "fillet_edge": {"id": "entity_id"}}

# Arguments a Ruby handler reads that no MCP tool sends; a direct TCP client
# may. A new one must be added here on purpose.
_RUBY_ONLY_ARGS = {
    "create_component": {"segments"},
    "chamfer_edges": {"edge_indices"},
    "fillet_edges": {"edge_indices"},
    "export": {"width", "height"},
}


async def test_ruby_allows_every_argument_a_tool_sends():
    # M-29: Ruby refuses an argument outside its table with -32602, so a
    # parameter added to a tool here without the table there would fail every
    # call that sets it.
    allowed = _ruby_allowed_args()
    for tool in await mcp.list_tools():
        wire = WIRE_NAMES.get(tool.name, tool.name)
        renames = _ARG_RENAMES.get(tool.name, {})
        sent = {renames.get(name, name) for name in tool.inputSchema.get("properties", {})}
        assert wire in allowed, f"{tool.name}: dispatch.rb's ALLOWED_ARGS has no {wire!r}"
        assert sent <= allowed[wire], f"{tool.name}: Ruby refuses {sorted(sent - allowed[wire])}"
        assert allowed[wire] - sent == _RUBY_ONLY_ARGS.get(wire, set()), (
            f"{wire}: Ruby-only arguments {sorted(allowed[wire] - sent)}; pin them in _RUBY_ONLY_ARGS"
        )
    assert allowed["export_scene"] == allowed["export"]
