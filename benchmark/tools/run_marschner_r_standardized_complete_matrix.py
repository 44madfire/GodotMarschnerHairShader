#!/usr/bin/env python3
"""Run the Fresnel-weighted standardized-R validator over a designed matrix.

This replaces the R-specific albedo-only cases with parameters that actually
change R: longitudinal roughness, cuticle tilt and IOR. The script intentionally
uses the Windows Godot executable from WSL by default, matching the repository's
existing benchmark tooling.
"""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path
from typing import Any

DEFAULT_GODOT = "/mnt/c/Tools/Godot/godot.exe"
VALIDATOR = "res://benchmark/tools/validate_marschner_r_standardized_complete_energy.gd"

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


def parse_report(stdout: str) -> dict[str, Any]:
    start = stdout.find("{")
    marker = stdout.rfind("\nFAST_MARSCHNER_R_STANDARDIZED_COMPLETE_ENERGY_OK")
    if start < 0:
        raise RuntimeError("validator output did not contain JSON")
    if marker < 0:
        marker = stdout.rfind("}") + 1
    text = stdout[start:marker].strip()
    return json.loads(text)


def run_case(godot: str, project: Path, grid: int, phi_grid: int, case: dict[str, Any]) -> dict[str, Any]:
    command = [
        godot,
        "--headless",
        "--path",
        str(project),
        "--script",
        VALIDATOR,
        "--",
        f"--grid={grid}",
        f"--phi-grid={phi_grid}",
        f"--beta-m={case['beta_m']}",
        f"--cuticle={case['cuticle']}",
        f"--eta={case['eta']}",
        "--contract=report",
    ]
    completed = subprocess.run(command, text=True, capture_output=True, check=False)
    if completed.returncode != 0:
        raise RuntimeError(
            f"{case['name']} failed with code {completed.returncode}\n"
            f"STDOUT:\n{completed.stdout}\nSTDERR:\n{completed.stderr}"
        )
    report = parse_report(completed.stdout)
    return {"name": case["name"], "parameters": case, "report": report}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", default=DEFAULT_GODOT)
    parser.add_argument("--project", type=Path, default=Path.cwd())
    parser.add_argument("--grid", type=int, default=512)
    parser.add_argument("--phi-grid", type=int, default=128)
    parser.add_argument("--out", type=Path, default=Path("benchmark/results/marschner_r_standardized_complete_matrix_512x128.json"))
    args = parser.parse_args()

    records: list[dict[str, Any]] = []
    for case in CASES:
        print(f"[standardized-R] {case['name']}", flush=True)
        records.append(run_case(args.godot, args.project, args.grid, args.phi_grid, case))

    worst_linear = {"value": -1.0, "case": ""}
    worst_log = {"value": -1.0, "case": ""}
    worst_direct_share = {"value": -1.0, "case": ""}
    for record in records:
        report = record["report"]
        linear_error = float(report["complete_r"]["linear_relative_error"])
        log_error = float(report["complete_r"]["log_relative_error"])
        direct_share = float(report["branch_statistics"]["expensive_direct_sample_share"])
        if linear_error > worst_linear["value"]:
            worst_linear = {"value": linear_error, "case": record["name"]}
        if log_error > worst_log["value"]:
            worst_log = {"value": log_error, "case": record["name"]}
        if direct_share > worst_direct_share["value"]:
            worst_direct_share = {"value": direct_share, "case": record["name"]}

    payload = {
        "schema": "standardized_r_complete_matrix_v2",
        "grid": args.grid,
        "phi_grid": args.phi_grid,
        "case_count": len(records),
        "cases": records,
        "summary": {
            "worst_linear_complete_r_relative_error": worst_linear,
            "worst_log_complete_r_relative_error": worst_log,
            "worst_expensive_direct_sample_share": worst_direct_share,
        },
        "acceptance_targets": {
            "complete_r_aggregate_ratio": [0.98, 1.02],
            "per_theta_ratio": [0.95, 1.05],
            "expensive_direct_sample_share_max": 0.05,
        },
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {args.out}")
    print(json.dumps(payload["summary"], indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
