#!/usr/bin/env python3
"""Multi-client live smoke for SketchupMCP.

Spawns N concurrent worker subprocesses; each opens its own
SketchUpConnection against the running SketchUp instance and executes
a short scripted workload. Asserts all workers complete without error.

Pre-conditions:
  1. SketchUp is running with the multi-client Ruby plugin installed
     and started via Plugins → MCP Server → Start.
  2. Optional: SKETCHUP_MCP_HOST / SKETCHUP_MCP_PORT env vars.

Other clients (e.g. an attached Claude Code MCP session) may coexist
with this smoke run — the new multi-client server multiplexes them on
the SketchUp UI thread; no detach/restart workaround is needed.

Usage:
    python examples/smoke_multi_client.py                 # 2 workers
    python examples/smoke_multi_client.py --n 3           # 3 workers
    SKETCHUP_MCP_HOST=192.168.20.20 python examples/smoke_multi_client.py

This is NOT part of CI — it's a manual sanity check the developer runs
before merging the multi-client server work. The script exits 0 on
success, 1 on any worker failure or timeout.
"""
import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "src"))

WORKER_PER_OPERATION_BUDGET = 10.0   # seconds — per workload step


# Each worker is a freshly-spawned Python subprocess so we exercise the
# real multi-connection path (NOT asyncio.gather over one socket).
# Worker scripts are fed as -c source text; %(...)r interpolation
# emits repr() of each value, which is round-trip-safe for str/list/dict
# of JSON-friendly primitives. Worker bodies therefore contain no
# literal `%`.
#
# LIGHT worker — read-only loop over a list of {tool, args} dicts
# interpolated verbatim.
LIGHT_WORKER_SCRIPT = '''
import asyncio, sys, time

sys.path.insert(0, %(src_dir)r)

from sketchup_mcp.connection import SketchUpConnection
from sketchup_mcp import config

WORKLOAD = %(workload)r
LABEL    = %(label)r


async def main():
    conn = SketchUpConnection(
        host=config.HOST, port=config.PORT, timeout=config.TIMEOUT)
    await conn.connect()
    try:
        for step in WORKLOAD:
            tool = step["tool"]
            args = step["args"]
            t0 = time.monotonic()
            await conn.send_command(tool, args)
            dt = time.monotonic() - t0
            print(f"[{LABEL}] {tool:30s} ok dt={dt:.3f}s")
    finally:
        await conn.disconnect()


asyncio.run(main())
'''


# HEAVY worker — imperative routine: create two boxes, get_model_info,
# delete the boxes by id. create_component returns `{id, name, type,
# bbox_mm}` (Ruby auto-assigns the name; no `name` parameter accepted)
# wrapped in MCP shape `{content: [{text: "<json>"}]}`; the worker
# decodes that and feeds `id` straight back to delete_component. The
# "heavy" label is about exercising start_operation/commit_operation,
# which create + delete already do.
HEAVY_WORKER_SCRIPT = '''
import asyncio, json, sys, time

sys.path.insert(0, %(src_dir)r)

from sketchup_mcp.connection import SketchUpConnection
from sketchup_mcp import config

LABEL = %(label)r


async def main():
    conn = SketchUpConnection(
        host=config.HOST, port=config.PORT, timeout=config.TIMEOUT)
    await conn.connect()
    try:
        ids = []
        creates = [
            {"type": "cube", "position": [0, 0, 0],
             "dimensions": [1000, 1000, 1000]},
            {"type": "cube", "position": [400, 400, 400],
             "dimensions": [800, 800, 800]},
        ]
        for args in creates:
            t0 = time.monotonic()
            result = await conn.send_command("create_component", args)
            dt = time.monotonic() - t0
            payload = json.loads(result["content"][0]["text"])
            ids.append(payload["id"])
            print(f"[{LABEL}] create_component               ok dt={dt:.3f}s")

        t0 = time.monotonic()
        await conn.send_command("get_model_info", {})
        dt = time.monotonic() - t0
        print(f"[{LABEL}] get_model_info                 ok dt={dt:.3f}s")

        for entity_id in ids:
            t0 = time.monotonic()
            await conn.send_command("delete_component", {"id": entity_id})
            dt = time.monotonic() - t0
            print(f"[{LABEL}] delete_component               ok dt={dt:.3f}s")
    finally:
        await conn.disconnect()


asyncio.run(main())
'''


# Read-only sequence — exercises the lightweight introspection path.
LIGHT_WORKLOAD = (
    [{"tool": "get_version",     "args": {}}] +
    [{"tool": "get_model_info",  "args": {}} for _ in range(8)] +
    [{"tool": "list_components", "args": {}} for _ in range(5)]
)

# HEAVY is fully encoded in HEAVY_WORKER_SCRIPT (no list); expose its
# step count so the global per-worker timeout stays proportional.
HEAVY_STEP_COUNT = 5   # 2 creates + 1 get_model_info + 2 deletes


def spawn_worker(label: str, heavy: bool) -> subprocess.Popen:
    if heavy:
        script = HEAVY_WORKER_SCRIPT % {
            "src_dir": str(PROJECT_ROOT / "src"),
            "label": label,
        }
    else:
        script = LIGHT_WORKER_SCRIPT % {
            "src_dir": str(PROJECT_ROOT / "src"),
            "workload": LIGHT_WORKLOAD,
            "label": label,
        }
    return subprocess.Popen(
        [sys.executable, "-c", script],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env={**os.environ},
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--n", type=int, default=2,
        help="number of concurrent workers (default: 2; max practical: 4)",
    )
    args = parser.parse_args()

    # Worker 0 is light/read-only; the rest run the heavier sequence so
    # we get a real mix of contention on Ruby's per-connection
    # serialization queue.
    workers = []
    for i in range(args.n):
        heavy = i != 0
        step_count = HEAVY_STEP_COUNT if heavy else len(LIGHT_WORKLOAD)
        workers.append((f"w{i}", spawn_worker(f"w{i}", heavy), step_count))

    t_start = time.monotonic()
    failures = []
    for label, proc, step_count in workers:
        global_budget = WORKER_PER_OPERATION_BUDGET * step_count
        try:
            out, _ = proc.communicate(timeout=global_budget * 2)
        except subprocess.TimeoutExpired:
            proc.kill()
            failures.append(
                f"[{label}] EXCEEDED timeout {global_budget * 2:.0f}s"
            )
            continue
        rc = proc.returncode
        if rc != 0:
            failures.append(f"[{label}] EXIT {rc}\n{out}")
        else:
            print(out, end="")
    elapsed = time.monotonic() - t_start
    print(f"\nelapsed: {elapsed:.1f}s")

    if failures:
        print("\nFAIL:")
        for f in failures:
            print(f)
        return 1
    print("\nOK — all workers completed successfully.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
