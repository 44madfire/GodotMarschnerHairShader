#!/usr/bin/env python3
"""Run and aggregate the production hair GPU benchmark matrix.

The runner intentionally launches separate Godot processes. Process-level
repeats reduce shader-order, cache, clock-state, and one-process warmup bias.
Do not add --headless: the runtime benchmark requires a real RenderingDevice.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import os
import statistics
import subprocess
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

MARKER = "HAIR_BENCHMARK_JSON:"
PRODUCTION_NAMES = {
    "APPROX_KAJIYA_KAY",
    "FAST_MARSCHNER",
    "CINEMATIC_MARSCHNER",
    "REFERENCE_MARSCHNER",
}

PRESETS = {
    "quick": {
        "resolutions": ["1920x1080"],
        "coverage_modes": ["cards"],
        "extra_lights": [3],
        "repeats": 3,
    },
    "standard": {
        "resolutions": ["1920x1080"],
        "coverage_modes": ["cards", "coverage"],
        "extra_lights": [0, 7],
        "repeats": 3,
    },
    "full": {
        "resolutions": ["1280x720", "1920x1080", "2560x1440"],
        "coverage_modes": ["cards", "coverage"],
        "extra_lights": [0, 3, 7],
        "repeats": 5,
    },
}


def comma_strings(value: str) -> list[str]:
    return [part.strip() for part in value.split(",") if part.strip()]


def comma_ints(value: str) -> list[int]:
    return [int(part.strip()) for part in value.split(",") if part.strip()]


def median_abs_deviation(values: list[float]) -> float:
    if not values:
        return 0.0
    center = statistics.median(values)
    return statistics.median(abs(v - center) for v in values)


def linear_slope(points: list[tuple[float, float]]) -> float | None:
    if len(points) < 2:
        return None
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    xbar = statistics.mean(xs)
    ybar = statistics.mean(ys)
    denom = sum((x - xbar) ** 2 for x in xs)
    if denom == 0.0:
        return None
    return sum((x - xbar) * (y - ybar) for x, y in points) / denom


def parse_runtime_payload(stdout: str) -> dict[str, Any]:
    payloads = []
    for line in stdout.splitlines():
        if line.startswith(MARKER):
            payloads.append(json.loads(line[len(MARKER):]))
    if len(payloads) != 1:
        raise RuntimeError(f"expected one {MARKER} payload, found {len(payloads)}")
    return payloads[0]


def result_rows(payloads: list[dict[str, Any]]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for payload in payloads:
        gpu = payload["gpu"]
        workload = payload["workload"]
        sampling = payload["sampling"]
        resolution = workload["actual_viewport_size"]
        for result in payload["results"]:
            if "gpu_median_ms" not in result:
                continue
            rows.append({
                "gpu_name": gpu.get("name", ""),
                "gpu_vendor": gpu.get("vendor", ""),
                "gpu_type": gpu.get("device_type_name", ""),
                "api_version": gpu.get("api_version", ""),
                "pipeline_cache_uuid": gpu.get("pipeline_cache_uuid", ""),
                "resolution": f"{resolution['x']}x{resolution['y']}",
                "pixels": int(resolution["pixels"]),
                "coverage_mode": workload["coverage_mode"],
                "total_lights": int(workload["total_directional_lights"]),
                "extra_lights": int(workload["extra_directional_lights"]),
                "repeat_index": int(sampling["repeat_index"]),
                "name": result["name"],
                "gpu_median_ms": float(result["gpu_median_ms"]),
                "gpu_p95_ms": float(result["gpu_p95_ms"]),
                "gpu_mad_ms": float(result.get("gpu_mad_ms", 0.0)),
                "cpu_median_ms": float(result["cpu_median_ms"]),
                "incremental_vs_no_hair_ms": result.get("incremental_vs_no_hair_ms"),
                "incremental_vs_card_control_ms": result.get("incremental_vs_card_control_ms"),
            })
    return rows


def aggregate_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[Any, ...], list[dict[str, Any]]] = defaultdict(list)
    key_fields = (
        "gpu_name", "gpu_vendor", "gpu_type", "api_version", "pipeline_cache_uuid",
        "resolution", "pixels", "coverage_mode", "total_lights", "extra_lights", "name",
    )
    for row in rows:
        grouped[tuple(row[field] for field in key_fields)].append(row)

    result: list[dict[str, Any]] = []
    for key, group in sorted(grouped.items(), key=lambda item: tuple(str(v) for v in item[0])):
        out = dict(zip(key_fields, key))
        medians = [float(row["gpu_median_ms"]) for row in group]
        p95s = [float(row["gpu_p95_ms"]) for row in group]
        out.update({
            "process_repeats": len(group),
            "gpu_median_of_medians_ms": statistics.median(medians),
            "gpu_repeat_mad_ms": median_abs_deviation(medians),
            "gpu_min_process_median_ms": min(medians),
            "gpu_max_process_median_ms": max(medians),
            "gpu_median_p95_ms": statistics.median(p95s),
            "cpu_median_of_medians_ms": statistics.median(float(row["cpu_median_ms"]) for row in group),
        })
        for field in ("incremental_vs_no_hair_ms", "incremental_vs_card_control_ms"):
            values = [float(row[field]) for row in group if row[field] is not None]
            if values:
                out[f"{field}_median"] = statistics.median(values)
                out[f"{field}_mad"] = median_abs_deviation(values)
        result.append(out)
    return result


def derive_scaling(aggregates: list[dict[str, Any]]) -> dict[str, Any]:
    light_groups: dict[tuple[Any, ...], list[tuple[float, float]]] = defaultdict(list)
    pixel_groups: dict[tuple[Any, ...], list[tuple[float, float]]] = defaultdict(list)

    for row in aggregates:
        if row["name"] not in PRODUCTION_NAMES:
            continue
        card_delta = row.get("incremental_vs_card_control_ms_median")
        if card_delta is None:
            continue
        light_key = (
            row["gpu_name"], row["gpu_type"], row["resolution"],
            row["coverage_mode"], row["name"],
        )
        light_groups[light_key].append((float(row["total_lights"]), float(card_delta)))

        pixel_key = (
            row["gpu_name"], row["gpu_type"], row["coverage_mode"],
            row["total_lights"], row["name"],
        )
        pixel_groups[pixel_key].append((float(row["pixels"]) / 1_000_000.0, float(card_delta)))

    light_scaling = []
    for key, points in sorted(light_groups.items(), key=lambda item: tuple(str(v) for v in item[0])):
        distinct = sorted(set(points))
        slope = linear_slope(distinct)
        if slope is not None:
            light_scaling.append({
                "gpu_name": key[0], "gpu_type": key[1], "resolution": key[2],
                "coverage_mode": key[3], "name": key[4],
                "bsdf_delta_ms_per_directional_light": slope,
                "points": [{"lights": x, "delta_ms": y} for x, y in distinct],
            })

    pixel_scaling = []
    for key, points in sorted(pixel_groups.items(), key=lambda item: tuple(str(v) for v in item[0])):
        distinct = sorted(set(points))
        slope = linear_slope(distinct)
        if slope is not None:
            pixel_scaling.append({
                "gpu_name": key[0], "gpu_type": key[1], "coverage_mode": key[2],
                "total_lights": key[3], "name": key[4],
                "bsdf_delta_ms_per_megapixel": slope,
                "points": [{"megapixels": x, "delta_ms": y} for x, y in distinct],
            })

    return {
        "per_light_scaling": light_scaling,
        "per_pixel_scaling": pixel_scaling,
        "note": "Slopes use production GPU median minus CARD_CONTROL GPU median. They isolate tier-dependent shaded-fragment/light work better than total viewport time, but remain empirical end-to-end measurements rather than shader instruction counts.",
    }


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    if not rows:
        return
    fields = sorted({field for row in rows for field in row})
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def run_source_inventory(project: Path, output_dir: Path) -> None:
    analyzer = project / "benchmark/tools/analyze_production_shader_costs.py"
    command = [sys.executable, str(analyzer), "--project", str(project), "--output", str(output_dir / "source_inventory.json"), "--pretty"]
    completed = subprocess.run(command, cwd=project, text=True, capture_output=True)
    (output_dir / "source_inventory.log").write_text(completed.stdout + completed.stderr, encoding="utf-8")
    if completed.returncode != 0:
        raise RuntimeError("source inventory failed; see source_inventory.log")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN", "godot"), help="Godot 4.7 executable")
    parser.add_argument("--project", type=Path, default=Path("."))
    parser.add_argument("--preset", choices=PRESETS, default="standard")
    parser.add_argument("--gpu-index", action="append", type=int, dest="gpu_indices", help="Repeatable; omit to use Godot's default GPU")
    parser.add_argument("--renderer", choices=("forward_plus", "mobile"), default="forward_plus")
    parser.add_argument("--resolutions", type=comma_strings)
    parser.add_argument("--coverage-modes", type=comma_strings)
    parser.add_argument("--extra-lights", type=comma_ints)
    parser.add_argument("--repeats", type=int)
    parser.add_argument("--prewarm", type=int, default=120)
    parser.add_argument("--settle", type=int, default=30)
    parser.add_argument("--sample", type=int, default=300)
    parser.add_argument("--no-probes", action="store_true")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--fail-fast", action="store_true")
    args = parser.parse_args()

    project = args.project.resolve()
    preset = PRESETS[args.preset]
    resolutions = args.resolutions or list(preset["resolutions"])
    coverage_modes = args.coverage_modes or list(preset["coverage_modes"])
    extra_lights = args.extra_lights or list(preset["extra_lights"])
    repeats = args.repeats if args.repeats is not None else int(preset["repeats"])
    gpu_indices: list[int | None] = args.gpu_indices or [None]

    invalid_modes = set(coverage_modes) - {"cards", "coverage"}
    if invalid_modes:
        parser.error(f"unsupported coverage modes: {sorted(invalid_modes)}")
    if repeats < 1:
        parser.error("--repeats must be >= 1")

    timestamp = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    output_dir = (args.output or project / "benchmark/results" / f"production_tiers_{timestamp}").resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    if not args.dry_run:
        run_source_inventory(project, output_dir)

    payloads: list[dict[str, Any]] = []
    command_log: list[str] = []
    run_number = 0
    failures = 0

    for gpu_index in gpu_indices:
        for resolution in resolutions:
            for coverage in coverage_modes:
                for lights in extra_lights:
                    for repeat_index in range(repeats):
                        run_number += 1
                        command = [
                            args.godot,
                            "--path", str(project),
                            "--rendering-method", args.renderer,
                            "--disable-vsync",
                        ]
                        if gpu_index is not None:
                            command += ["--gpu-index", str(gpu_index)]
                        command += [
                            "--script", "res://benchmark/tools/benchmark_production_hair_tiers.gd",
                            "--",
                            f"--resolution={resolution}",
                            f"--coverage={coverage}",
                            f"--extra-lights={lights}",
                            f"--prewarm={args.prewarm}",
                            f"--settle={args.settle}",
                            f"--sample={args.sample}",
                            f"--repeat-index={repeat_index}",
                        ]
                        if args.no_probes:
                            command.append("--no-probes")

                        rendered_command = " ".join(str(part) for part in command)
                        command_log.append(rendered_command)
                        print(f"[{run_number}] {rendered_command}", flush=True)
                        if args.dry_run:
                            continue

                        completed = subprocess.run(command, cwd=project, text=True, capture_output=True)
                        stem = f"run_{run_number:04d}_gpu_{gpu_index if gpu_index is not None else 'default'}_{resolution}_{coverage}_lights_{lights}_repeat_{repeat_index}"
                        (output_dir / f"{stem}.log").write_text(completed.stdout + completed.stderr, encoding="utf-8")
                        if completed.returncode != 0:
                            failures += 1
                            print(f"  FAILED ({completed.returncode}); see {stem}.log", file=sys.stderr)
                            if args.fail_fast:
                                (output_dir / "commands.txt").write_text("\n".join(command_log) + "\n", encoding="utf-8")
                                return completed.returncode or 1
                            continue
                        try:
                            payload = parse_runtime_payload(completed.stdout)
                        except Exception as exc:
                            failures += 1
                            print(f"  FAILED to parse result: {exc}; see {stem}.log", file=sys.stderr)
                            if args.fail_fast:
                                return 1
                            continue
                        payload["requested_gpu_index"] = gpu_index
                        payloads.append(payload)
                        (output_dir / f"{stem}.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
                        print(f"  {payload['gpu']['name']} / {payload['gpu']['device_type_name']} OK", flush=True)

    (output_dir / "commands.txt").write_text("\n".join(command_log) + "\n", encoding="utf-8")
    if args.dry_run:
        print(f"Dry run complete: {run_number} process invocations")
        return 0
    if not payloads:
        print("No successful benchmark payloads were collected.", file=sys.stderr)
        return 1

    rows = result_rows(payloads)
    aggregates = aggregate_rows(rows)
    derived = derive_scaling(aggregates)
    summary = {
        "schema": "production_hair_benchmark_aggregate_v1",
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "processes_requested": run_number,
        "processes_succeeded": len(payloads),
        "processes_failed": failures,
        "preset": args.preset,
        "renderer": args.renderer,
        "aggregates": aggregates,
        "derived_scaling": derived,
        "methodology": {
            "runtime": "RenderingServer viewport GPU/CPU render-time measurements with per-variant prewarm, settle, and sample windows.",
            "repeats": "Separate Godot processes; tier order rotates/reverses by repeat index.",
            "card_control": "Common hair-card preparation with trivial unshaded output.",
            "alu_probe": "Fixed synthetic 96-iteration arithmetic chain after common card prep; device sensitivity calibration only.",
            "lut_probe": "Fixed 16 dependent trilinear Texture3D samples after common card prep; device sensitivity calibration only.",
            "source_inventory": "Expanded-source structural counts; never post-compile ISA counts.",
        },
    }
    (output_dir / "aggregate.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    write_csv(output_dir / "aggregate.csv", aggregates)
    write_csv(output_dir / "process_rows.csv", rows)

    print(f"Wrote benchmark results to {output_dir}")
    if failures:
        print(f"WARNING: {failures} process run(s) failed; inspect logs before comparing tiers.", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
