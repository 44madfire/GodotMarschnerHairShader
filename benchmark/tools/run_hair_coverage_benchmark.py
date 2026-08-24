#!/usr/bin/env python3
"""Run fresh-process hair-card coverage GPU benchmarks."""

from __future__ import annotations

import argparse
import csv
import json
import statistics
import subprocess
import sys
from pathlib import Path
from typing import Any

SCRIPT = "res://benchmark/tools/benchmark_hair_coverage_modes.gd"
MARKER = "HAIR_COVERAGE_BENCHMARK_JSON:"

CASES = [
    {"name": "legacy_bayer_no_taa", "mode": "legacy_time_bayer", "taa": 0, "msaa": 0},
    {"name": "legacy_bayer_taa", "mode": "legacy_time_bayer", "taa": 1, "msaa": 0},
    {"name": "static_bayer_no_taa", "mode": "static_bayer", "taa": 0, "msaa": 0},
    {"name": "static_bayer_taa", "mode": "static_bayer", "taa": 1, "msaa": 0},
    {"name": "taa_bayer", "mode": "taa_bayer", "taa": 1, "msaa": 0},
    {"name": "alpha_hash_no_taa", "mode": "alpha_hash", "taa": 0, "msaa": 0},
    {"name": "alpha_hash_taa", "mode": "alpha_hash", "taa": 1, "msaa": 0},
    {"name": "a2c_2x", "mode": "a2c", "taa": 0, "msaa": 2},
    {"name": "a2c_4x", "mode": "a2c", "taa": 0, "msaa": 4},
    {"name": "a2c_2x_taa", "mode": "a2c", "taa": 1, "msaa": 2},
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--project", default=".")
    parser.add_argument("--gpu-index", type=int)
    parser.add_argument("--resolution", default="1920x1080")
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--prewarm", type=int, default=120)
    parser.add_argument("--settle", type=int, default=30)
    parser.add_argument("--sample", type=int, default=300)
    parser.add_argument(
        "--cases",
        default="all",
        help="Comma-separated case names, or all",
    )
    parser.add_argument(
        "--output",
        default="benchmark/results/hair_coverage_benchmark/latest",
    )
    return parser.parse_args()


def selected_cases(text: str) -> list[dict[str, Any]]:
    if text == "all":
        return list(CASES)
    names = {part.strip() for part in text.split(",") if part.strip()}
    known = {case["name"] for case in CASES}
    missing = sorted(names - known)
    if missing:
        raise SystemExit(f"Unknown cases: {', '.join(missing)}")
    return [case for case in CASES if case["name"] in names]


def command_for(args: argparse.Namespace, case: dict[str, Any]) -> list[str]:
    command = [args.godot, "--path", str(Path(args.project)), "--disable-vsync"]
    if args.gpu_index is not None:
        command.extend(["--gpu-index", str(args.gpu_index)])
    command.extend(
        [
            "--script",
            SCRIPT,
            "--",
            f"--mode={case['mode']}",
            f"--taa={case['taa']}",
            f"--msaa={case['msaa']}",
            f"--resolution={args.resolution}",
            f"--prewarm={args.prewarm}",
            f"--settle={args.settle}",
            f"--sample={args.sample}",
        ]
    )
    return command


def run_case(args: argparse.Namespace, case: dict[str, Any]) -> dict[str, Any]:
    command = command_for(args, case)
    print("+", " ".join(command), flush=True)
    completed = subprocess.run(command, text=True, capture_output=True)
    if completed.stdout:
        print(completed.stdout, end="")
    if completed.stderr:
        print(completed.stderr, end="", file=sys.stderr)
    if completed.returncode != 0:
        raise RuntimeError(f"Coverage benchmark failed for {case['name']}")
    for line in reversed(completed.stdout.splitlines()):
        if line.startswith(MARKER):
            payload = json.loads(line[len(MARKER) :])
            payload["case"] = case["name"]
            payload["command"] = " ".join(command)
            return payload
    raise RuntimeError(f"Missing benchmark marker for {case['name']}")


def result_named(payload: dict[str, Any], name: str) -> dict[str, Any]:
    for result in payload["results"]:
        if result.get("name") == name:
            return result
    raise KeyError(name)


def median(values: list[float]) -> float:
    return float(statistics.median(values))


def mad(values: list[float]) -> float:
    center = statistics.median(values)
    return float(statistics.median(abs(value - center) for value in values))


def aggregate(rows: list[dict[str, Any]]) -> dict[str, Any]:
    groups: dict[str, Any] = {}
    for case in CASES:
        selected = [row for row in rows if row["case"] == case["name"]]
        if not selected:
            continue
        coverage = [float(result_named(row, "COVERAGE")["gpu_median_ms"]) for row in selected]
        cards = [float(result_named(row, "CARDS_PIPELINE_CONTROL")["gpu_median_ms"]) for row in selected]
        no_hair = [float(result_named(row, "NO_HAIR")["gpu_median_ms"]) for row in selected]
        delta_cards = [c - b for c, b in zip(coverage, cards)]
        delta_no_hair = [c - b for c, b in zip(coverage, no_hair)]
        groups[case["name"]] = {
            "mode": case["mode"],
            "taa": bool(case["taa"]),
            "msaa": case["msaa"],
            "samples": len(selected),
            "coverage_gpu_median_ms": median(coverage),
            "coverage_gpu_mad_ms": mad(coverage),
            "cards_gpu_median_ms": median(cards),
            "no_hair_gpu_median_ms": median(no_hair),
            "incremental_vs_cards_median_ms": median(delta_cards),
            "incremental_vs_cards_mad_ms": mad(delta_cards),
            "incremental_vs_no_hair_median_ms": median(delta_no_hair),
            "phase_policy": selected[0].get("taa_phase_policy", ""),
            "gpu": selected[0].get("gpu", {}),
        }
    return {
        "schema": "hair_coverage_process_matrix_v1",
        "groups": groups,
        "notes": {
            "taa_bayer": "Phase advances once per rendered frame and cycles over 16 phases, matching Godot 4.7 TAA cadence/period. It does not read Godot's private jitter sample index.",
            "filesystem": "Each case/repeat runs in a fresh Godot process.",
            "visual": "GPU timing does not rank visual quality; inspect the benchmark scene interactively for flicker, card-pattern visibility, and motion behavior.",
        },
    }


def write_outputs(output: Path, rows: list[dict[str, Any]], summary: dict[str, Any]) -> None:
    output.mkdir(parents=True, exist_ok=True)
    (output / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    (output / "runs.json").write_text(json.dumps(rows, indent=2, sort_keys=True) + "\n")

    fields = [
        "case",
        "repeat",
        "mode",
        "taa",
        "msaa",
        "coverage_gpu_median_ms",
        "cards_gpu_median_ms",
        "no_hair_gpu_median_ms",
        "incremental_vs_cards_ms",
        "incremental_vs_no_hair_ms",
        "gpu_name",
        "gpu_vendor",
    ]
    with (output / "aggregate_rows.csv").open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            coverage = result_named(row, "COVERAGE")
            cards = result_named(row, "CARDS_PIPELINE_CONTROL")
            no_hair = result_named(row, "NO_HAIR")
            writer.writerow(
                {
                    "case": row["case"],
                    "repeat": row["repeat"],
                    "mode": row["mode"],
                    "taa": row["taa_requested"],
                    "msaa": row["msaa_requested_samples"],
                    "coverage_gpu_median_ms": coverage["gpu_median_ms"],
                    "cards_gpu_median_ms": cards["gpu_median_ms"],
                    "no_hair_gpu_median_ms": no_hair["gpu_median_ms"],
                    "incremental_vs_cards_ms": coverage["incremental_vs_cards_ms"],
                    "incremental_vs_no_hair_ms": coverage["incremental_vs_no_hair_ms"],
                    "gpu_name": row.get("gpu", {}).get("name", ""),
                    "gpu_vendor": row.get("gpu", {}).get("vendor", ""),
                }
            )


def main() -> int:
    args = parse_args()
    if args.repeats < 1:
        raise SystemExit("--repeats must be at least 1")
    cases = selected_cases(args.cases)
    rows: list[dict[str, Any]] = []

    for repeat in range(args.repeats):
        shift = repeat % len(cases)
        order = cases[shift:] + cases[:shift]
        if repeat % 2:
            order = list(reversed(order))
        for case in order:
            payload = run_case(args, case)
            payload["repeat"] = repeat
            rows.append(payload)

    summary = aggregate(rows)
    output = Path(args.output)
    write_outputs(output, rows, summary)
    print(json.dumps(summary["groups"], indent=2, sort_keys=True))
    print(f"HAIR_COVERAGE_BENCHMARK_OUTPUT {output}")
    print("HAIR_COVERAGE_PROCESS_MATRIX_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
