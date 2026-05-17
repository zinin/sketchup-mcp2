#!/usr/bin/env python3
"""Multi-client live smoke for SketchupMCP.

Spawns N concurrent worker subprocesses; each opens its own
SketchUpConnection against the running SketchUp instance and executes
a short scripted workload. Asserts all workers complete without error.

Pre-conditions:
  1. SketchUp is running with the multi-client Ruby plugin installed
     and started via Plugins → MCP Server → Start.
  2. NO other client is attached (`sketchup` MCP must be detached from
     Claude Code, or the Ruby plugin restarted) — the server still
     enforces queueing per connection, but we want a clean baseline.
  3. Optional: SKETCHUP_MCP_HOST / SKETCHUP_MCP_PORT env vars.

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
# The worker script is fed as -c source text; %(...)r interpolation
# emits repr() of each value, which is round-trip-safe for str/list/dict
# of JSON-friendly primitives. The %% in printf-style format strings
# would conflict with any literal `%` inside the body, so the worker
# body contains no literal `%`.
WORKER_SCRIPT = '''
import asyncio, json, os, sys, time

sys.path.insert(0, %(src_dir)r)

from sketchup_mcp.connection import SketchUpConnection
from sketchup_mcp import config

WORKLOAD = %(workload)r
LABEL    = %(label)r


def _text_of(result):
    """Unwrap MCP-shape {content: [{text: ...}]} to raw text."""
    if isinstance(result, dict) and isinstance(result.get("content"), list):
        first = result["content"][0]
        if isinstance(first, dict):
            return first.get("text", "")
    return json.dumps(result)


def _resolve(value, captured):
    """Replace {"$ref": "slot_name"} markers with captured ids."""
    if isinstance(value, dict) and "$ref" in value:
        return captured[value["$ref"]]
    return value


async def main():
    conn = SketchUpConnection(
        host=config.HOST, port=config.PORT, timeout=config.TIMEOUT)
    await conn.connect()
    captured = {}
    try:
        for step in WORKLOAD:
            tool = step["tool"]
            args = {k: _resolve(v, captured) for k, v in step["args"].items()}
            t0 = time.monotonic()
            result = await conn.send_command(tool, args)
            dt = time.monotonic() - t0
            # Capture id from response if the step requests it
            capture_slot = step.get("capture")
            if capture_slot:
                payload = json.loads(_text_of(result))
                captured[capture_slot] = payload["id"]
            print(f"[{LABEL}] {tool:30s} ok dt={dt:.3f}s")
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

# Heavy / mutating sequence — exercises start_operation / commit_operation
# paths while staying self-contained.
#
# NB: this workload intentionally avoids `boolean_operation` because that
# tool takes entity-id strings (`target_id` / `tool_id`), which would
# force the worker to resolve ids via `find_components` first. The goal
# here is to exercise the multi-client server, not to test boolean ops;
# the work is "heavy" because `create_component` on a 1 m cube is a
# slower handler than `get_model_info`.
#
# `create_component` returns `{id, name, type, bbox_mm}`; we capture the
# id into a named slot and reference it by `{"$ref": "<slot>"}` in the
# matching `delete_component` step. The Ruby `create_component` handler
# does NOT accept a `name` parameter — entity names are auto-assigned by
# SketchUp — so the `name` parameter from earlier drafts has been
# removed.
HEAVY_WORKLOAD = [
    {"tool": "create_component",
     "args": {"type": "cube",
              "position": [0, 0, 0],
              "dimensions": [1000, 1000, 1000]},
     "capture": "box_a_id"},
    {"tool": "create_component",
     "args": {"type": "cube",
              "position": [400, 400, 400],
              "dimensions": [800, 800, 800]},
     "capture": "box_b_id"},
    {"tool": "get_model_info", "args": {}},
    {"tool": "delete_component", "args": {"id": {"$ref": "box_a_id"}}},
    {"tool": "delete_component", "args": {"id": {"$ref": "box_b_id"}}},
]


def spawn_worker(label: str, workload: list[dict]) -> subprocess.Popen:
    script = WORKER_SCRIPT % {
        "src_dir": str(PROJECT_ROOT / "src"),
        "workload": workload,
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

    workers = []
    for i in range(args.n):
        # Worker 0 is light/read-only; the rest run the heavier sequence
        # so we get a real mix of contention on Ruby's per-connection
        # serialization queue.
        wl = LIGHT_WORKLOAD if i == 0 else HEAVY_WORKLOAD
        workers.append((f"w{i}", spawn_worker(f"w{i}", wl), wl))

    t_start = time.monotonic()
    failures = []
    for label, proc, wl in workers:
        global_budget = WORKER_PER_OPERATION_BUDGET * len(wl)
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
