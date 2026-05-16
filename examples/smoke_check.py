# examples/smoke_check.py
"""Live integration smoke-check Python ↔ Ruby.

Pre-conditions:
  1. SketchUp 2024+ is running with an empty model.
  2. Ruby SketchUp plugin is installed and started via Plugins → MCP Server →
     Start. The plugin version must satisfy the handshake range declared in
     src/sketchup_mcp/compat.py (MIN_RUBY..MAX_RUBY); step 22 verifies this.
  3. Run with the same Python venv used by the MCP server.
  4. Optional: SKETCHUP_MCP_HOST / SKETCHUP_MCP_PORT to override 127.0.0.1:9876.

Usage:
    python examples/smoke_check.py

Sequence covers ALL Ruby handlers + new introspection tools, with focus on
the riskiest rewrites (chamfer/fillet/boolean). Fails fast on first error.

All dimensions are in millimeters per the v0.0.1 unified mm contract.
"""
import asyncio
import base64
import json
import os
import sys
from pathlib import Path

# Force UTF-8 on stdout/stderr so the script's unicode glyphs (→, ←, ✓)
# don't crash on Windows consoles defaulting to cp1251/cp1252.
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="replace")

# Allow running from repo root: src/sketchup_mcp on the path.
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from sketchup_mcp.connection import SketchUpConnection  # noqa: E402
from sketchup_mcp.errors import SketchUpError  # noqa: E402
from sketchup_mcp import config  # noqa: E402


async def call(conn: SketchUpConnection, tool: str, **args) -> dict:
    print(f"  → {tool}({args})")
    result = await conn.send_command(tool, args)
    # 800 chars — enough to see full bbox + edges_chamfered/edges_filleted on
    # chamfer/fillet results. Truncate at 200 was hiding diagnostic fields.
    print(f"    ← {json.dumps(result)[:800]}")
    return result


def text_of(result: dict) -> str:
    """Unwrap MCP-shape `{content: [{text: ...}]}` to raw text."""
    if isinstance(result, dict) and isinstance(result.get("content"), list):
        first = result["content"][0]
        if isinstance(first, dict):
            return first.get("text", "")
    return json.dumps(result)


def parse(result: dict) -> dict:
    return json.loads(text_of(result))


async def main() -> int:
    conn = SketchUpConnection(host=config.HOST, port=config.PORT, timeout=30.0)
    await conn.connect()
    step = 0
    try:
        step = 1; print(f"[{step}] get_model_info")
        info = parse(await call(conn, "get_model_info"))
        assert "path" in info, f"unexpected model_info: {info}"
        assert info.get("units") == "mm"

        step = 2; print(f"[{step}] list_layers — baseline")
        layers_before = parse(await call(conn, "list_layers"))["layers"]
        had_test_layer = any(l["name"] == "MCP Test" for l in layers_before)

        step = 3; print(f"[{step}] create_layer 'MCP Test'")
        layer = parse(await call(conn, "create_layer", name="MCP Test"))
        assert isinstance(layer["id"], int)

        step = 4; print(f"[{step}] list_layers — 'MCP Test' present")
        layers_after = parse(await call(conn, "list_layers"))["layers"]
        # Robust to pre-existing state (re-running the test on a non-clean
        # model): assert the layer NAME is present rather than that count grew.
        # If the model already had the layer, count won't change but creation
        # is still considered idempotent-success.
        assert any(l["name"] == "MCP Test" for l in layers_after), \
            f"'MCP Test' layer missing after create: {[l['name'] for l in layers_after]}"

        step = 5; print(f"[{step}] create_component cube id1 — 100×100×100mm")
        c1 = parse(await call(conn, "create_component",
                              type="cube", dimensions=[100, 100, 100]))
        id1 = c1["id"]
        assert isinstance(id1, int)
        # bbox in mm — verify it's roughly 100×100×100
        bb = c1["bbox_mm"]
        assert abs((bb["max"][0] - bb["min"][0]) - 100) < 1.0, f"width: {bb}"

        step = 6; print(f"[{step}] transform_component — move id1 to (200,0,0)")
        await call(conn, "transform_component", id=id1, position=[200, 0, 0])

        step = 7; print(f"[{step}] create_component cube id2 — 100×100×100mm at origin")
        c2 = parse(await call(conn, "create_component",
                              type="cube", dimensions=[100, 100, 100]))
        id2 = c2["id"]

        step = 8; print(f"[{step}] set_material(id1, 'red')")
        await call(conn, "set_material", id=id1, material="red")

        step = 9; print(f"[{step}] chamfer_edges(id1, distance=10mm) — LIVE-VALIDATES NEW MATH")
        # smoke_check uses raw send_command (bypasses FastMCP wrapper),
        # so we must call Ruby's plural tool name with entity_id parameter.
        # Group#subtract returns a NEW group; rebind id1 to the post-chamfer id.
        chamfer_result = parse(await call(conn, "chamfer_edges", entity_id=id1, distance=10))
        id1 = chamfer_result["id"]

        step = 10; print(f"[{step}] fillet_edges(id2, radius=5mm, segments=8)")
        fillet_result = parse(await call(conn, "fillet_edges", entity_id=id2, radius=5, segments=8))
        id2 = fillet_result["id"]

        step = 11; print(f"[{step}] boolean_operation union(id1, id2)")
        # Use the post-chamfer/fillet IDs directly — robust to a non-empty
        # model (e.g. session opened with a saved file). list_components is
        # exercised in step 16/17 where filter behavior matters.
        bool_result = parse(await call(conn, "boolean_operation",
                                       target_id=id1, tool_id=id2,
                                       operation="union"))
        id_bool = bool_result["id"]

        step = 12; print(f"[{step}] create_component for joint board — 200×200×50mm")
        b_mortise = parse(await call(conn, "create_component",
                                     type="cube", dimensions=[200, 200, 50]))["id"]

        step = 13; print(f"[{step}] create_component for joint board — 50×50×200mm")
        b_tenon = parse(await call(conn, "create_component",
                                   type="cube", dimensions=[50, 50, 200]))["id"]

        step = 14; print(f"[{step}] create_mortise_tenon — width=20mm, height=30mm, depth=15mm")
        # Group#subtract erases the original mortise board and returns a NEW
        # group; the handler reports the new ID via "mortise"/"tenon" keys.
        # Re-bind b_mortise/b_tenon so subsequent assertions and cleanup target
        # the post-subtract entities.
        mt = parse(await call(conn, "create_mortise_tenon",
                              mortise_id=b_mortise, tenon_id=b_tenon,
                              width=20, height=30, depth=15))
        b_mortise = mt["mortise"]["id"]
        b_tenon   = mt["tenon"]["id"]

        step = 15; print(f"[{step}] eval_ruby — count entities")
        ev = parse(await call(conn, "eval_ruby",
                              code="Sketchup.active_model.entities.length"))
        # eval_ruby returns raw integer-string; Python sees it as JSON int.
        assert isinstance(ev, int) and ev > 0, f"unexpected eval result: {ev}"

        step = 16; print(f"[{step}] list_components(max_depth=2)")
        lc = parse(await call(conn, "list_components", max_depth=2))
        ids = [c["id"] for c in lc["components"]]
        assert id_bool in ids, f"boolean result {id_bool} not in {ids}"
        assert b_mortise in ids and b_tenon in ids

        step = 17; print(f"[{step}] find_components(type='group')")
        fc = parse(await call(conn, "find_components", type="group"))
        assert len(fc["components"]) >= 4

        step = 18; print(f"[{step}] export_scene format=png")
        ex = parse(await call(conn, "export_scene", format="png"))
        path = ex["path"]
        assert os.path.exists(path), f"export file missing: {path}"

        step = 19; print(f"[{step}] get_viewport_screenshot — exercise the new tool")
        result = await call(
            conn, "get_viewport_screenshot",
            view_preset="iso", zoom_extents=True, max_size=640,
            style="default", restore_view=True,
        )
        payload = json.loads(text_of(result))
        # Structural assertions — response shape.
        for key in ("png_base64", "width", "height", "preset_used", "style_used"):
            assert key in payload, f"missing {key!r} in {payload!r}"
        # Echo-back sanity: handler must report the preset/style it actually used.
        assert payload["preset_used"] == "iso", f"unexpected preset_used: {payload['preset_used']!r}"
        assert payload["style_used"] == "default", f"unexpected style_used: {payload['style_used']!r}"
        # Dimension sanity — width/height are positive integers, both ≤ max_size=640.
        w, h = payload["width"], payload["height"]
        assert isinstance(w, int) and isinstance(h, int), f"non-int dimensions: {w!r}×{h!r}"
        assert 0 < w <= 640 and 0 < h <= 640, f"dimensions out of bounds: {w}×{h}"
        # Content sanity — must be a non-trivial PNG (a valid 1×1 PNG is ~70 bytes;
        # require > 1024 bytes to rule out blank/empty captures).
        png = base64.b64decode(payload["png_base64"])
        assert png.startswith(b"\x89PNG\r\n\x1a\n"), \
            f"missing PNG magic header: got {png[0:8]!r}"
        assert len(png) > 1024, f"PNG suspiciously small: {len(png)} bytes"
        print(f"    PNG ok: {len(png)} bytes, {w}×{h}, preset={payload['preset_used']}")

        # NB: cleanup must precede undo. `undo` rolls back the last undoable
        # operation, which here is mortise_tenon (export bypasses the undo
        # stack). Running undo first would invalidate b_mortise/b_tenon (the
        # post-subtract IDs captured in step 14) and the cleanup loop would
        # silently no-op on stale IDs while leaving the restored mortise board
        # behind in the model.
        step = 20; print(f"[{step}] cleanup: delete created components")
        for cid in [id_bool, b_mortise, b_tenon]:
            try:
                await call(conn, "delete_component", id=cid)
            except Exception as e:
                print(f"    (cleanup non-fatal: {e})")

        step = 21; print(f"[{step}] undo — verify the tool runs without error")
        await call(conn, "undo")

        step = 22; print(f"[{step}] version handshake — matched pair must report compatible=true")
        payload = parse(await call(conn, "get_version"))
        print(f"    python={payload['python_version']} ruby={payload['ruby_version']}")
        print(f"    compatible={payload['compatible']} error={payload['error']}")
        assert payload["compatible"] is True, f"version mismatch: {payload}"
        # Two-way verdict sanity: Ruby payload must have populated all fields.
        # `compatible=True` with any of these None would mean the verdict was
        # reached on partial data (Python silently accepting missing Ruby side).
        assert payload["ruby_version"] is not None, f"ruby_version missing: {payload}"
        assert payload["ruby_min_compatible_python"] is not None, \
            f"two-way field ruby_min_compatible_python missing: {payload}"
        assert payload["ruby_max_compatible_python"] is not None, \
            f"two-way field ruby_max_compatible_python missing: {payload}"
        assert payload["error"] is None, f"error reported despite compatible=true: {payload}"

        print("\nALL STEPS PASSED ✓")
        return 0
    except Exception as e:
        print(f"\nFAILED at step {step}: {e}", file=sys.stderr)
        # DEBUG: surface Ruby-side backtrace + tool/params from JSON-RPC error.data.
        # The Ruby plugin always sends data.backtrace (first 3 frames) regardless of
        # log level; smoke_check default printing only shows the message.
        # Remove this block once chamfer/fillet debugging is complete.
        if isinstance(e, SketchUpError):
            print(f"  code={e.code}", file=sys.stderr)
            print(f"  tool={e.data.get('tool')}", file=sys.stderr)
            print(f"  params={e.data.get('params')}", file=sys.stderr)
            print(f"  timestamp={e.data.get('timestamp')}", file=sys.stderr)
            for line in e.data.get("backtrace") or []:
                print(f"  bt: {line}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        return 1
    finally:
        await conn.disconnect()


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
