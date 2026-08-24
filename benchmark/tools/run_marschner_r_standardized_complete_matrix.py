#!/usr/bin/env python3
"""Run the Fresnel-weighted standardized-R validator over a designed matrix."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any, NoReturn

DEFAULT_GODOT = "/mnt/c/Tools/Godot/godot.exe"
DEFAULT_PROJECT = "//wsl.localhost/Ubuntu/home/jeffreymwang/godot-hair-shader"
VALIDATOR = "res://benchmark/tools/validate_marschner_r_standardized_complete_energy.gd"
VALIDATOR_SCHEMA = "standardized_r_complete_energy_v3"
CASE_TIMEOUT_SECONDS = 3600.0

CASES = [
    {"name": "reference", "beta_m": 0.2, "cuticle": 0.087, "eta": 1.55},
    {"name": "beta_m_0_02", "beta_m": 0.02, "cuticle": 0.087, "eta": 1.55},
    {"name": "beta_m_0_05", "beta_m": 0.05, "cuticle": 0.087, "eta": 1.55},
    {"name": "beta_m_0_1", "beta_m": 0.1, "cuticle": 0.087, "eta": 1.55},
    {"name": "beta_m_0_4", "beta_m": 0.4, "cuticle": 0.087, "eta": 1.55},
    {"name": "beta_m_0_8", "beta_m": 0.8, "cuticle": 0.087, "eta": 1.55},
    {"name": "cuticle_0", "beta_m": 0.2, "cuticle": 0.0, "eta": 1.55},
    {"name": "cuticle_0_1", "beta_m": 0.2, "cuticle": 0.1, "eta": 1.55},
    {"name": "cuticle_0_15", "beta_m": 0.2, "cuticle": 0.15, "eta": 1.55},
    {"name": "eta_1_45", "beta_m": 0.2, "cuticle": 0.087, "eta": 1.45},
    {"name": "eta_1_65", "beta_m": 0.2, "cuticle": 0.087, "eta": 1.65},
    {"name": "low_beta_high_cuticle", "beta_m": 0.02, "cuticle": 0.15, "eta": 1.55},
]


def die(message: str) -> NoReturn:
    sys.stderr.write(f"run_marschner_r_standardized_complete_matrix: error: {message}\n")
    raise SystemExit(1)


def parse_report(stdout: str) -> dict[str, Any]:
    decoder = json.JSONDecoder()
    index = 0
    candidates: list[dict[str, Any]] = []
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
        if isinstance(obj, dict) and obj.get("schema") == VALIDATOR_SCHEMA:
            candidates.append(obj)
        index = end
    if not candidates:
        raise RuntimeError(f"validator output did not contain {VALIDATOR_SCHEMA} JSON")
    return candidates[-1]


def run_case(godot: str, project: str, grid: int, phi_grid: int, case: dict[str, Any]) -> dict[str, Any]:
    command = [
        godot, "--headless", "--path", project, "--script", VALIDATOR, "--",
        f"--grid={grid}", f"--phi-grid={phi_grid}",
        f"--beta-m={case['beta_m']}", f"--cuticle={case['cuticle']}", f"--eta={case['eta']}",
        "--contract=report",
    ]
    try:
        completed = subprocess.run(
            command, text=True, encoding="utf-8", errors="replace",
            capture_output=True, check=False, timeout=CASE_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"{case['name']} timed out") from exc
    if completed.returncode != 0:
        raise RuntimeError(
            f"{case['name']} failed with code {completed.returncode}\n"
            f"STDOUT:\n{completed.stdout}\nSTDERR:\n{completed.stderr}"
        )
    return {"name": case["name"], "parameters": case, "report": parse_report(completed.stdout)}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", default=DEFAULT_GODOT)
    parser.add_argument("--project", default=DEFAULT_PROJECT)
    parser.add_argument("--grid", type=int, default=512)
    parser.add_argument("--phi-grid", type=int, default=128)
    parser.add_argument("--out", type=Path, default=Path("benchmark/results/marschner_r_standardized_complete_matrix_512x128.json"))
    args = parser.parse_args()

    if not os.path.basename(args.godot).lower().endswith(".exe"):
        die(f"refusing non-Windows Godot binary {args.godot!r}")
    if not os.path.exists(args.godot):
        die(f"Windows Godot executable not found: {args.godot!r}")
    if not args.project.startswith("//wsl.localhost/") and not os.path.isdir(args.project):
        die(f"Godot project directory not found: {args.project!r}")
    if args.grid <= 0 or args.phi_grid <= 0:
        die("grid sizes must be positive")

    records: list[dict[str, Any]] = []
    for case in CASES:
        print(f"[standardized-R] {case['name']}", file=sys.stderr, flush=True)
        try:
            records.append(run_case(args.godot, args.project, args.grid, args.phi_grid, case))
        except RuntimeError as exc:
            die(str(exc))

    worst_linear = {"value": -1.0, "case": ""}
    worst_log = {"value": -1.0, "case": ""}
    worst_direct_share = {"value": -1.0, "case": ""}
    worst_direct_energy_share = {"value": -1.0, "case": ""}
    largest_boundary_share = {"value": -1.0, "case": ""}
    smallest_boundary_weight = {"value": 2.0, "case": ""}
    for record in records:
        report = record["report"]
        branches = report["branch_statistics"]
        linear_error = float(report["complete_r"]["linear_relative_error"])
        log_error = float(report["complete_r"]["log_relative_error"])
        direct_share = float(branches["expensive_direct_sample_share"])
        direct_energy_share = float(branches["expensive_direct_complete_r_energy_share"])
        boundary_share = float(branches["grazing_boundary_lut"]["sample_share"])
        boundary_min = float(branches["boundary_valid_weight"]["min"])
        if linear_error > worst_linear["value"]:
            worst_linear = {"value": linear_error, "case": record["name"]}
        if log_error > worst_log["value"]:
            worst_log = {"value": log_error, "case": record["name"]}
        if direct_share > worst_direct_share["value"]:
            worst_direct_share = {"value": direct_share, "case": record["name"]}
        if direct_energy_share > worst_direct_energy_share["value"]:
            worst_direct_energy_share = {"value": direct_energy_share, "case": record["name"]}
        if boundary_share > largest_boundary_share["value"]:
            largest_boundary_share = {"value": boundary_share, "case": record["name"]}
        if boundary_min > 0.0 and boundary_min < smallest_boundary_weight["value"]:
            smallest_boundary_weight = {"value": boundary_min, "case": record["name"]}

    payload = {
        "schema": "standardized_r_complete_matrix_v3",
        "grid": args.grid,
        "phi_grid": args.phi_grid,
        "case_count": len(records),
        "cases": records,
        "summary": {
            "worst_linear_complete_r_relative_error": worst_linear,
            "worst_log_complete_r_relative_error": worst_log,
            "worst_expensive_direct_sample_share": worst_direct_share,
            "worst_expensive_direct_complete_r_energy_share": worst_direct_energy_share,
            "largest_grazing_boundary_lut_sample_share": largest_boundary_share,
            "smallest_nonzero_boundary_valid_weight": smallest_boundary_weight,
        },
        "acceptance_targets": {
            "complete_r_aggregate_ratio": [0.98, 1.02],
            "per_theta_ratio": [0.95, 1.05],
            "expensive_direct_sample_share_max": 0.05,
        },
        "limitations": [
            "CPU projected-solid-angle integration only; GPU timing is a separate benchmark.",
            "The shader-relative azimuth cosine is clamped to [-0.9999,0.9999] before c_phi, matching the Fast analytic path.",
            "The committed 256x256x128 RGBAF LUT remains a diagnostic reference and is not a production memory target.",
            "This pass evaluates q-tail zeroing and manual physical-boundary trilinear renormalization; pole/high-beta direct fallback is still diagnostic.",
        ],
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    print(json.dumps(payload["summary"], indent=2, allow_nan=False))
    print(f"wrote {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
