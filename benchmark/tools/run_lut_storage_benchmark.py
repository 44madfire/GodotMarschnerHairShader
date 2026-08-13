#!/usr/bin/env python3
"""Compare raw-data LUT resources with directly serialized ImageTexture3D files."""

from __future__ import annotations

import argparse
import csv
import json
import statistics
import subprocess
import sys
from pathlib import Path
from typing import Any

PREP_SCRIPT = "res://benchmark/tools/prepare_lut_storage_benchmark.gd"
CASE_SCRIPT = "res://benchmark/tests/benchmark_lut_storage_case.gd"
FAST_GENERATOR = "res://benchmark/tools/generate_unity_hair_azimuthal_lut.gd"
CINEMATIC_GENERATOR = "res://benchmark/tools/generate_marschner_cinematic_longitudinal_lut.gd"
FAST_RAW_REL = Path("benchmark/resources/luts/unity_azimuthal_64.res")
CINEMATIC_RAW_REL = Path("benchmark/resources/luts/cinematic_longitudinal_kernel_128x128x64.res")
PREP_MARKER = "LUT_STORAGE_PREP_RESULT "
CASE_MARKER = "LUT_STORAGE_BENCHMARK_RESULT "


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Benchmark production Fast/Cinematic LUT storage as either the current "
            "validated raw-data Resource or a directly serialized ImageTexture3D."
        )
    )
    parser.add_argument("--godot", default="godot", help="Godot executable path")
    parser.add_argument("--project", default=".", help="Godot project root")
    parser.add_argument("--repeats", type=int, default=12, help="Fresh-process samples per kind/mode")
    parser.add_argument(
        "--output",
        default="benchmark/results/lut_storage_benchmark/latest",
        help="Directory for samples.csv, summary.json, and commands.txt",
    )
    parser.add_argument(
        "--generate",
        action="store_true",
        help="Generate missing production Fast/Cinematic raw LUT resources before benchmarking",
    )
    parser.add_argument(
        "--headless",
        action="store_true",
        help="Use Godot's headless mode for all benchmark processes",
    )
    parser.add_argument(
        "--keep-direct-resources",
        action="store_true",
        help="Leave the temporary direct ImageTexture3D resources in user:// after the run",
    )
    return parser.parse_args()


def run_command(command: list[str]) -> subprocess.CompletedProcess[str]:
    print("+", " ".join(command), flush=True)
    completed = subprocess.run(command, text=True, capture_output=True)
    if completed.stdout:
        print(completed.stdout, end="")
    if completed.stderr:
        print(completed.stderr, end="", file=sys.stderr)
    return completed


def godot_command(args: argparse.Namespace, script: str, user_args: list[str] | None = None) -> list[str]:
    command = [args.godot]
    if args.headless:
        command.append("--headless")
    command.extend(["--path", str(Path(args.project)), "--script", script])
    if user_args:
        command.append("--")
        command.extend(user_args)
    return command


def ensure_raw_luts(args: argparse.Namespace) -> None:
    project = Path(args.project)
    required = [
        (project / FAST_RAW_REL, FAST_GENERATOR),
        (project / CINEMATIC_RAW_REL, CINEMATIC_GENERATOR),
    ]
    missing = [(path, generator) for path, generator in required if not path.exists()]
    if not missing:
        return
    if not args.generate:
        lines = ["Required production LUT resources are missing:"]
        for path, generator in missing:
            lines.append(f"  - {path}")
            lines.append(
                "    generate with: "
                + " ".join(godot_command(args, generator))
            )
        raise RuntimeError("\n".join(lines))

    for _, generator in missing:
        completed = run_command(godot_command(args, generator))
        if completed.returncode != 0:
            raise RuntimeError(f"LUT generation failed for {generator}")


def parse_marker(stdout: str, marker: str) -> dict[str, Any]:
    for line in reversed(stdout.splitlines()):
        if line.startswith(marker):
            return json.loads(line[len(marker) :])
    raise RuntimeError(f"Expected marker {marker!r} not found in Godot output")


def prepare(args: argparse.Namespace) -> dict[str, Any]:
    completed = run_command(godot_command(args, PREP_SCRIPT))
    if completed.returncode != 0:
        raise RuntimeError("Direct ImageTexture3D preparation failed")
    result = parse_marker(completed.stdout, PREP_MARKER)
    if not result.get("fast", {}).get("ok") or not result.get("cinematic", {}).get("ok"):
        raise RuntimeError(f"Preparation reported invalid result: {result}")
    return result


def cleanup(args: argparse.Namespace) -> None:
    completed = run_command(godot_command(args, PREP_SCRIPT, ["--cleanup"]))
    if completed.returncode != 0:
        raise RuntimeError("Failed to clean temporary direct ImageTexture3D resources")


def run_case(args: argparse.Namespace, kind: str, mode: str) -> dict[str, Any]:
    completed = run_command(
        godot_command(args, CASE_SCRIPT, [f"--kind={kind}", f"--mode={mode}"])
    )
    if completed.returncode != 0:
        raise RuntimeError(f"Benchmark case failed for {kind}/{mode}")
    result = parse_marker(completed.stdout, CASE_MARKER)
    if not result.get("ok"):
        raise RuntimeError(f"Benchmark case reported failure for {kind}/{mode}: {result}")
    return result


def median(values: list[float]) -> float:
    return float(statistics.median(values))


def mad(values: list[float]) -> float:
    center = statistics.median(values)
    return float(statistics.median(abs(value - center) for value in values))


def aggregate(rows: list[dict[str, Any]], prep: dict[str, Any], repeats: int) -> dict[str, Any]:
    metrics = ["resource_load_us", "validation_us", "texture_build_us", "ready_us"]
    groups: dict[str, Any] = {}
    for kind in ("fast", "cinematic"):
        groups[kind] = {}
        for mode in ("raw", "direct"):
            selected = [row for row in rows if row["kind"] == kind and row["mode"] == mode]
            group: dict[str, Any] = {"samples": len(selected)}
            for metric in metrics:
                values = [float(row[metric]) for row in selected]
                group[f"{metric}_median"] = median(values)
                group[f"{metric}_mad"] = mad(values)
            groups[kind][mode] = group

        raw_ready = groups[kind]["raw"]["ready_us_median"]
        direct_ready = groups[kind]["direct"]["ready_us_median"]
        raw_size = float(prep[kind]["raw_res_bytes"])
        direct_size = float(prep[kind]["direct_res_bytes"])
        groups[kind]["comparison"] = {
            "direct_ready_over_raw_ready": direct_ready / raw_ready if raw_ready else None,
            "direct_ready_delta_us": direct_ready - raw_ready,
            "direct_size_over_raw_size": direct_size / raw_size if raw_size else None,
            "direct_size_delta_bytes": int(direct_size - raw_size),
        }

    return {
        "schema": "marschner_lut_storage_benchmark_v1",
        "repeats_per_kind_mode": repeats,
        "timing_scope": (
            "CPU-side time inside Godot from ResourceLoader start to a structurally valid "
            "Texture3D with a valid RID; process startup is excluded"
        ),
        "filesystem_cache_note": (
            "Fresh processes avoid Godot ResourceLoader/adapter caches but do not flush the OS filesystem cache"
        ),
        "preparation": prep,
        "groups": groups,
    }


def write_outputs(output: Path, rows: list[dict[str, Any]], summary: dict[str, Any], commands: list[str]) -> None:
    output.mkdir(parents=True, exist_ok=True)
    with (output / "summary.json").open("w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2, sort_keys=True)
        handle.write("\n")

    fieldnames = [
        "repeat",
        "order_index",
        "kind",
        "mode",
        "resource_load_us",
        "validation_us",
        "texture_build_us",
        "ready_us",
        "size_x",
        "size_y",
        "size_z",
        "format",
        "contract",
        "godot_version",
        "os",
    ]
    with (output / "samples.csv").open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)

    with (output / "commands.txt").open("w", encoding="utf-8") as handle:
        handle.write("\n".join(commands))
        handle.write("\n")


def main() -> int:
    args = parse_args()
    if args.repeats < 3:
        raise SystemExit("--repeats must be at least 3")

    output = Path(args.output)
    commands: list[str] = []
    rows: list[dict[str, Any]] = []

    try:
        ensure_raw_luts(args)
        prep = prepare(args)

        base_cases = [
            ("fast", "raw"),
            ("fast", "direct"),
            ("cinematic", "raw"),
            ("cinematic", "direct"),
        ]

        for repeat in range(args.repeats):
            shift = repeat % len(base_cases)
            order = base_cases[shift:] + base_cases[:shift]
            if repeat % 2 == 1:
                order = list(reversed(order))
            for order_index, (kind, mode) in enumerate(order):
                command = godot_command(args, CASE_SCRIPT, [f"--kind={kind}", f"--mode={mode}"])
                commands.append(" ".join(command))
                result = run_case(args, kind, mode)
                result["repeat"] = repeat
                result["order_index"] = order_index
                rows.append(result)

        summary = aggregate(rows, prep, args.repeats)
        write_outputs(output, rows, summary, commands)
        print(json.dumps(summary["groups"], indent=2, sort_keys=True))
        print(f"LUT_STORAGE_BENCHMARK_OUTPUT {output}")
        print("LUT_STORAGE_BENCHMARK_OK")
        return 0
    finally:
        if not args.keep_direct_resources:
            try:
                cleanup(args)
            except Exception as exc:  # cleanup should not hide the benchmark result/error
                print(f"warning: cleanup failed: {exc}", file=sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
