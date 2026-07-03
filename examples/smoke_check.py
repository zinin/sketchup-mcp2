# examples/smoke_check.py
"""Live integration smoke-check Python ↔ Ruby.

Pre-conditions:
  1. SketchUp 2026+ is running with an empty model (step 19 uses the
     viewport-screenshot tool, verified on SketchUp 2026 only).
  2. Ruby SketchUp plugin is installed and started via Plugins → MCP Server →
     Start. The plugin version must satisfy the handshake range declared in
     src/sketchup_mcp/compat.py (MIN_RUBY..MAX_RUBY); step 25 verifies this.
  3. Run with the same Python venv used by the MCP server.
  4. Optional: SKETCHUP_MCP_HOST / SKETCHUP_MCP_PORT to override 127.0.0.1:9876.
     When SketchUp runs remotely, step 18 (export_scene) degrades to asserting
     Ruby returned a non-empty path — the file lives on the SketchUp host.

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
import time
from pathlib import Path

# Force UTF-8 on stdout/stderr so the script's unicode glyphs (→, ←, ✓)
# don't crash on Windows consoles defaulting to cp1251/cp1252.
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="replace")

# Allow running from repo root: src/sketchup_mcp on the path.
# Guarded by __main__ so loading this module from tests (via
# importlib.util.spec_from_file_location in tests/test_smoke_helpers.py)
# does NOT mutate sys.path globally. iter-2 CONCERN-5.
if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from sketchup_mcp.connection import SketchUpConnection  # noqa: E402
from sketchup_mcp.errors import SketchUpError  # noqa: E402
from sketchup_mcp import compat, config  # noqa: E402
from sketchup_mcp.compat import EVAL_DISABLED_CODE  # noqa: E402  iter-1 SUGGESTION-1: shared constant


async def _maybe_skip_eval(label, coro):
    """Run an eval_ruby-dependent step; if Ruby returns -32010, skip and tally.

    smoke_check uses raw SketchUpConnection.send_command (see `call()` in
    examples/smoke_check.py), which raises SketchUpError on a JSON-RPC error
    envelope. We MUST catch that exception and inspect `e.code`, not look
    for text in a string result — the textual route only fires for the
    FastMCP-wrapped client (iter-1 CRITICAL-4).
    """
    try:
        return await coro
    except SketchUpError as e:
        if e.code == EVAL_DISABLED_CODE:
            print(f"  ⚠ {label}: skipped (eval_ruby disabled in extension settings)")
            return None
        raise


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
    eval_skipped = [0]   # mutable container — see iter-2 CONCERN-12 note
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

        step = 6; print(f"[{step}] transform_component — move id1 to (200,0,0) [ABSOLUTE bbox-min]")
        t1 = parse(await call(conn, "transform_component", id=id1, position=[200, 0, 0]))
        assert abs(t1["bbox_mm"]["min"][0] - 200) < 0.5, \
            f"absolute position semantics broken (T-04): {t1['bbox_mm']}"

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
        ev_raw = await _maybe_skip_eval(
            "eval_ruby step 15 (count entities)",
            call(conn, "eval_ruby", code="Sketchup.active_model.entities.length"),
        )
        if ev_raw is None:
            eval_skipped[0] += 1
        else:
            ev = parse(ev_raw)
            # eval_ruby returns raw integer-string; Python sees it as JSON int.
            assert isinstance(ev, int) and ev > 0, f"unexpected eval result: {ev}"

        step = 16; print(f"[{step}] list_components(max_depth=2)")
        lc = parse(await call(conn, "list_components", max_depth=2))
        ids = [c["id"] for c in lc["components"]]
        # T-07: пагинационный конверт — total/truncated обязаны присутствовать;
        # смоук-модель (< 50 entities) не должна усекаться дефолтным limit.
        assert isinstance(lc["total"], int) and lc["total"] >= len(lc["components"])
        assert lc["truncated"] is False, f"unexpected truncation: {lc}"
        assert id_bool in ids, f"boolean result {id_bool} not in {ids}"
        assert b_mortise in ids and b_tenon in ids

        step = 17; print(f"[{step}] find_components(type='group')")
        fc = parse(await call(conn, "find_components", type="group"))
        assert len(fc["components"]) >= 4

        step = 18; print(f"[{step}] export_scene format=png")
        ex = parse(await call(conn, "export_scene", format="png"))
        path = ex["path"]
        # Split-host: when SketchUp runs remotely the export file isn't visible here.
        if config.HOST in {"127.0.0.1", "localhost", "::1"}:
            assert os.path.exists(path), f"export file missing: {path}"
        else:
            assert path, "export_scene returned empty path"

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

        step = 20; print(f"[{step}] sphere d=100 — manifold poles + boolean union (T-02)")
        sph = parse(await call(conn, "create_component",
                               type="sphere", position=[400, 0, 0],
                               dimensions=[100, 100, 100]))
        id_sph = sph["id"]
        zspan = sph["bbox_mm"]["max"][2] - sph["bbox_mm"]["min"][2]
        assert abs(zspan - 100) < 0.5, (
            f"sphere z-span {zspan}mm — poles cut off => non-manifold generator (T-02)")
        cub = parse(await call(conn, "create_component",
                               type="cube", position=[450, 50, 0],
                               dimensions=[100, 100, 100]))
        id_cub = cub["id"]
        # До фикса T-02 этот union падал с -32603 "likely non-manifold".
        uni = parse(await call(conn, "boolean_operation",
                               target_id=id_sph, tool_id=id_cub, operation="union"))
        id_sph_union = uni["id"]  # операнды копируются; originals живы

        step = 21; print(f"[{step}] dovetail on a TRANSLATED board (T-03)")
        b_tail = parse(await call(conn, "create_component",
                                  type="cube", dimensions=[120, 100, 20]))["id"]
        moved = parse(await call(conn, "transform_component",
                                 id=b_tail, position=[800, 0, 0]))
        assert abs(moved["bbox_mm"]["min"][0] - 800) < 0.5, f"move failed: {moved}"
        # Идемпотентность absolute-семантики (T-04): повтор того же position
        # не смещает доску (старый relative-баг дал бы суммарно 1600).
        again = parse(await call(conn, "transform_component",
                                 id=b_tail, position=[800, 0, 0]))
        assert abs(again["bbox_mm"]["min"][0] - 800) < 0.5, \
            f"absolute position must be idempotent (T-04): {again['bbox_mm']}"
        b_pin = parse(await call(conn, "create_component",
                                 type="cube", position=[800, 120, 0],
                                 dimensions=[120, 100, 20]))["id"]
        dv = parse(await call(conn, "create_dovetail",
                              tail_id=b_tail, pin_id=b_pin,
                              width=50, height=50, depth=15))
        assert dv["boolean_cuts"]["failed"] == 0, f"dovetail cuts failed: {dv['boolean_cuts']}"
        # До фикса T-03 хвосты улетали на величину сдвига (живьём: x до 1704
        # при доске 800..920) — bbox обеих досок обязан остаться в объёме
        # доски ± глубина соединения.
        # DoD намеренно bbox-containment (ловит класс бага «улёт на |T|»);
        # механический контакт досок (зазор 20 мм по Y) не ассертится.
        for key in ("tail", "pin"):
            bb = dv[key]["bbox_mm"]
            assert bb["min"][0] >= 800 - 15 - 1 and bb["max"][0] <= 920 + 15 + 1, (
                f"{key} board bbox {bb} escaped the board volume — "
                f"frame-compensation regression (T-03)")
        b_tail, b_pin = dv["tail"]["id"], dv["pin"]["id"]

        step = 22; print(f"[{step}] eval_ruby syntax error — fast diagnostic, not a 60s hang (T-01)")
        t0 = time.monotonic()
        try:
            raw = await _maybe_skip_eval(
                "eval_ruby step 22 (syntax error)",
                call(conn, "eval_ruby", code="def broken("),
            )
            if raw is None:
                eval_skipped[0] += 1
            else:
                raise AssertionError(f"syntax error must raise an error, got: {raw}")
        except SketchUpError as e:
            elapsed = time.monotonic() - t0
            assert e.code == -32603, f"expected -32603, got [{e.code}] {e.message}"
            assert "SyntaxError" in e.message, f"no parser diagnostic in: {e.message}"
            assert elapsed < 10, f"took {elapsed:.1f}s — looks like the old 60s hang (T-01)"
            print(f"    ✓ SyntaxError surfaced in {elapsed:.2f}s")

        # NB: cleanup must precede undo, and the undo step is NOT a rollback
        # of the modeling steps: `delete_component` is itself an undoable
        # operation, so after the loop below step 24's undo rolls back the
        # LAST delete — resurrecting the most recently deleted ID — not the
        # last modeling op (the step-21 dovetail). One resurrected group is expected to remain
        # in the model after the run. Running undo before cleanup would
        # instead revert the last modeling operation and stale-ify IDs held
        # by the cleanup loop.
        # id1/id2 (post-chamfer/post-fillet) are live here: boolean_operation
        # copies its operands (delete_originals=false), so the step-11 union
        # consumed copies, not the originals. Same for id_sph/id_cub in step 20.
        step = 23; print(f"[{step}] cleanup: delete created components")
        for cid in [id1, id2, id_bool, b_mortise, b_tenon,
                    id_sph, id_cub, id_sph_union, b_tail, b_pin]:
            try:
                await call(conn, "delete_component", id=cid)
            except Exception as e:
                print(f"    (cleanup non-fatal: {e})")

        step = 24; print(f"[{step}] undo — verify the tool runs without error")
        await call(conn, "undo")

        step = 25; print(f"[{step}] version handshake — matched pair must report compatible=true")
        # smoke_check.py talks to Ruby directly (no FastMCP), so this returns
        # the raw handlers/system.rb output. Replicate the two-way verdict
        # that src/sketchup_mcp/tools.py::get_version computes.
        ruby_payload = parse(await call(conn, "get_version"))
        ruby_version = ruby_payload["ruby_version"]
        ruby_min_py = ruby_payload["min_compatible_python"]
        ruby_max_py = ruby_payload["max_compatible_python"]
        print(f"    python={compat.CLIENT_VERSION} ruby={ruby_version}")
        print(f"    ruby advertises python compat: {ruby_min_py}..{ruby_max_py}")
        compat.check_ruby_version(ruby_version)
        client = compat.parse(compat.CLIENT_VERSION)
        assert compat.parse(ruby_min_py) <= client <= compat.parse(ruby_max_py), (
            f"Ruby advertised range {ruby_min_py}..{ruby_max_py} rejects "
            f"client {compat.CLIENT_VERSION}"
        )
        print("    matched-pair: compatible=true")

        print("\nALL STEPS PASSED ✓")
        skips = (f", {eval_skipped[0]} skipped (eval gate closed)"
                 if eval_skipped[0] else "")
        print(f"Smoke complete: 25 steps total{skips}")
        return 0
    except Exception as e:
        print(f"\nFAILED at step {step}: {e}", file=sys.stderr)
        # DEBUG: surface Ruby-side backtrace + tool/params from JSON-RPC error.data.
        # The Ruby plugin always sends data.backtrace (first 3 frames) regardless of
        # log level; smoke_check default printing only shows the message.
        # Kept permanently: smoke failures need the Ruby-side backtrace for diagnosis.
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
