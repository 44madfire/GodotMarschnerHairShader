#!/usr/bin/env python3
"""Process-level repeated GPU benchmark for the Marschner tier split.

Runs the existing Windows Godot runtime benchmark
(res://benchmark/tools/benchmark_marschner_tier_split_runtime.gd) once per
independent process and aggregates the per-variant GPU/CPU timings across
process repeats.

Each child process prints a single "marschner_tier_split_runtime_v1" JSON
payload on stdout. This wrapper extracts that payload from every repeat, fails
nonzero if any child exits nonzero or omits the expected schema (preserving the
stdout/stderr tail in the failure), and writes one JSON report containing the
raw per-process payloads plus per-variant aggregate statistics across repeats.

This is measurement/reporting infrastructure only: no quality gates or
invented thresholds are applied.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
from pathlib import Path
from typing import Any, NoReturn

DEFAULT_GODOT = "/mnt/c/Tools/Godot/godot.exe"
DEFAULT_PROJECT = (
    "//wsl.localhost/Ubuntu/home/jeffreymwang/"
    "godot-hair-shader-worktrees/production-marschner-tier-split"
)
RUNTIME_BENCHMARK = "res://benchmark/tools/benchmark_marschner_tier_split_runtime.gd"
RUNTIME_SCHEMA = "marschner_tier_split_runtime_v1"
REPORT_SCHEMA = "marschner_tier_split_runtime_repeats_v1"
TIMEOUT = 7200.0
FAILURE_TAIL_LINES = 40
METRICS = ("gpu_median_ms", "gpu_p95_ms", "cpu_median_ms", "cpu_p95_ms")


def die(message: str) -> NoReturn:
    print(f"benchmark_marschner_tier_split_process_repeats: error: {message}", file=sys.stderr)
    raise SystemExit(1)


def _tail(text: str, lines: int = FAILURE_TAIL_LINES) -> str:
    if not text:
        return "(empty)"
    return "\n".join(text.splitlines()[-lines:])


def extract_json(stdout: str, schema: str) -> dict[str, Any] | None:
    """Return the last JSON object in stdout whose schema matches, if any."""
    decoder = json.JSONDecoder()
    index = 0
    found: dict[str, Any] | None = None
    while True:
        try:
            index = stdout.index("{", index)
        except ValueError:
            break
        try:
            obj, end = decoder.raw_decode(stdout, index)
        except json.JSONDecodeError:
            index += 1
            continue
        if isinstance(obj, dict) and obj.get("schema") == schema:
            found = obj
        index = end
    return found


def run_runtime_repeat(godot: str, project: str, script: str, repeat: int) -> dict[str, Any]:
    """Run one independent Godot process; return its runtime payload or die."""
    cmd = [godot, "--path", project, "--script", script]
    print(f"repeat {repeat}: + " + " ".join(cmd), file=sys.stderr, flush=True)
    try:
        completed = subprocess.run(
            cmd,
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            check=False,
            timeout=TIMEOUT,
        )
    except subprocess.TimeoutExpired as exc:
        die(
            f"repeat {repeat}: timed out after {TIMEOUT:.0f}s\n"
            f"stdout tail:\n{_tail(exc.stdout or '')}\n"
            f"stderr tail:\n{_tail(exc.stderr or '')}"
        )
    if completed.returncode != 0:
        die(
            f"repeat {repeat}: {script} exited with code {completed.returncode}\n"
            f"stdout tail:\n{_tail(completed.stdout)}\n"
            f"stderr tail:\n{_tail(completed.stderr)}"
        )
    payload = extract_json(completed.stdout, RUNTIME_SCHEMA)
    if payload is None:
        die(
            f"repeat {repeat}: stdout lacks schema '{RUNTIME_SCHEMA}'\n"
            f"stdout tail:\n{_tail(completed.stdout)}\n"
            f"stderr tail:\n{_tail(completed.stderr)}"
        )
    if not isinstance(payload.get("results"), list):
        die(
            f"repeat {repeat}: payload with schema '{RUNTIME_SCHEMA}' has no results list\n"
            f"stdout tail:\n{_tail(completed.stdout)}"
        )
    return payload


def _percentile(values: list[float], fraction: float) -> float:
    """Deterministic nearest-rank percentile mirroring the runtime script.

    Uses floor(x + 0.5) rounding (round half away from zero, as in GDScript)
    so aggregation behavior matches the child payload's own percentile
    definition. Values are sorted before indexing; ties are resolved by the
    stable sort, keeping results reproducible.
    """
    if not values:
        return 0.0
    ordered = sorted(values)
    index = int(math.floor(fraction * (len(ordered) - 1) + 0.5))
    index = max(0, min(index, len(ordered) - 1))
    return ordered[index]


def _aggregate_metric(values: list[float]) -> dict[str, Any]:
    """Aggregate one per-process metric across repeats (repeat order preserved)."""
    ordered = sorted(values)
    return {
        "values": [float(value) for value in values],
        "median": float(_percentile(ordered, 0.5)),
        "min": float(ordered[0]) if ordered else 0.0,
        "max": float(ordered[-1]) if ordered else 0.0,
        "p95": float(_percentile(ordered, 0.95)),
        "sample_count": len(ordered),
    }


def aggregate_variants(runs: list[dict[str, Any]]) -> dict[str, Any]:
    """Group per-process results by variant name and aggregate across repeats."""
    slots: dict[str, dict[str, Any]] = {}
    for repeat, payload in enumerate(runs, start=1):
        for entry in payload.get("results", []):
            if not isinstance(entry, dict):
                continue
            name = entry.get("name")
            if not isinstance(name, str) or not name:
                continue
            slot = slots.setdefault(
                name,
                {"metrics": {metric: [] for metric in METRICS}, "sample_counts": [], "errors": []},
            )
            if "error" in entry:
                slot["errors"].append({"repeat": repeat, "error": entry["error"]})
            for metric in METRICS:
                value = entry.get(metric)
                if isinstance(value, (int, float)) and not isinstance(value, bool):
                    slot["metrics"][metric].append(float(value))
            if isinstance(entry.get("sample_count"), int):
                slot["sample_counts"].append(entry["sample_count"])
    aggregates: dict[str, Any] = {}
    for name, slot in slots.items():
        variant: dict[str, Any] = {
            metric: _aggregate_metric(slot["metrics"][metric]) for metric in METRICS
        }
        variant["sample_count"] = sum(slot["sample_counts"])
        if slot["errors"]:
            variant["errors"] = slot["errors"]
        aggregates[name] = variant
    return aggregates


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--godot",
        default=DEFAULT_GODOT,
        help="Windows Godot executable (default: %(default)s)",
    )
    parser.add_argument(
        "--project",
        default=DEFAULT_PROJECT,
        help="project path as seen by the Windows Godot executable (default: %(default)s)",
    )
    parser.add_argument(
        "--repeats",
        type=int,
        default=5,
        help="number of independent process repeats (default: %(default)s)",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("benchmark/results/marschner_tier_split_runtime_repeats.json"),
        help="report output path (default: %(default)s)",
    )
    args = parser.parse_args()

    if not os.path.exists(args.godot):
        die(f"Godot executable not found: {args.godot}")
    if not os.path.basename(args.godot).lower().endswith(".exe"):
        die("this runner expects the Windows Godot executable")
    if args.repeats < 1:
        die(f"--repeats must be >= 1, got {args.repeats}")

    runs: list[dict[str, Any]] = []
    for repeat in range(1, args.repeats + 1):
        payload = run_runtime_repeat(args.godot, args.project, RUNTIME_BENCHMARK, repeat)
        variants = [
            entry.get("name")
            for entry in payload.get("results", [])
            if isinstance(entry, dict) and isinstance(entry.get("name"), str)
        ]
        print(
            f"repeat {repeat}/{args.repeats}: ok (variants: {', '.join(variants)})",
            file=sys.stderr,
            flush=True,
        )
        runs.append(payload)

    report = {
        "schema": REPORT_SCHEMA,
        "configuration": {
            "godot": args.godot,
            "project": args.project,
            "script": RUNTIME_BENCHMARK,
            "repeats_requested": args.repeats,
            "repeats_completed": len(runs),
            "timeout_seconds": TIMEOUT,
            "runtime_schema": RUNTIME_SCHEMA,
            "percentile": "nearest_rank_matching_runtime_script",
            "out": str(args.out),
        },
        "process_repeats": [
            {"repeat": index, "payload": payload} for index, payload in enumerate(runs, start=1)
        ],
        "aggregates": aggregate_variants(runs),
        "notes": [
            "Each process repeat is an independent Godot process running the runtime benchmark.",
            "Per-variant aggregates summarize per-process gpu/cpu median and p95 values across repeats.",
            "Measurement/reporting only: no quality gates or thresholds applied.",
        ],
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    print(f"wrote {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
