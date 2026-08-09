#!/usr/bin/env python3
"""Run the Cinematic Marschner complete-energy validator over a material matrix.

The matrix is deliberately split into two responsibilities:

* geometry: beta_m x cuticle x IOR, with nominal azimuthal roughness;
* azimuthal weighting: beta_m x beta_n at nominal cuticle/IOR.

This covers the parameters that can change which part of the generic longitudinal
LUT is sampled and the azimuthal weighting applied to its error without paying
for a redundant four-dimensional Cartesian product. ``--preset full`` is
available when a full 3x3x3x3 sweep is desired.

All child validator runs use ``--contract=report``. This runner applies the
production acceptance gates across the gated matrix as a whole:

    worst aggregate lobe relative error <= 2%
    worst per-incoming-angle total relative error <= 5%

A small set of UI-edge stress cases is also reported by the promotion preset,
but those do not fail the promotion gate. They exist to expose LUT-domain
clamping or extreme-parameter behavior separately from the intended human-hair
validation domain.
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
DEFAULT_PROJECT = "//wsl.localhost/Ubuntu/home/jeffreymwang/godot-hair-shader"
VALIDATOR = "res://benchmark/tools/validate_marschner_cinematic_energy.gd"
DEFAULT_OUT = Path("benchmark/results/marschner_cinematic_material_matrix.json")
CASE_TIMEOUT_SECONDS = 3600.0

LOBE_ERROR_GATE = 0.02
PER_ANGLE_ERROR_GATE = 0.05

# Effective beta values are the values consumed by the Marschner equations
# after the production roughness reparameterization. They deliberately straddle
# the low-beta transition and cover a substantially rougher-than-nominal case.
BETA_M_VALUES = (0.08, 0.30, 1.20)
BETA_N_VALUES = (0.08, 0.80, 1.80)
CUTICLE_VALUES = (0.0, 0.087, 0.20)
ETA_VALUES = (1.30, 1.55, 1.80)

NOMINAL_BETA_M = 0.30
NOMINAL_BETA_N = 0.80
NOMINAL_CUTICLE = 0.087
NOMINAL_ETA = 1.55


def die(message: str) -> NoReturn:
    print(f"run_marschner_cinematic_material_matrix: error: {message}", file=sys.stderr)
    raise SystemExit(1)


def fmt(value: float) -> str:
    return "%.10g" % float(value)


def tail(text: str, lines: int = 40) -> str:
    if not text:
        return "(no output)"
    rows = [line for line in text.splitlines() if line.strip()]
    return "\n".join(rows[-lines:])


def extract_json(stdout: str, schema: str) -> dict[str, Any] | None:
    decoder = json.JSONDecoder()
    index = 0
    found: dict[str, Any] | None = None
    while True:
        try:
            index = stdout.index("{", index)
        except ValueError:
            break
        try:
            value, end = decoder.raw_decode(stdout, index)
        except json.JSONDecodeError:
            index += 1
            continue
        if isinstance(value, dict) and value.get("schema") == schema:
            found = value
        index = end
    return found


def case_name(prefix: str, beta_m: float, beta_n: float, cuticle: float, eta: float) -> str:
    def token(value: float) -> str:
        return fmt(value).replace("-", "m").replace(".", "p")

    return (
        f"{prefix}_bm{token(beta_m)}_bn{token(beta_n)}_"
        f"c{token(cuticle)}_eta{token(eta)}"
    )


def make_case(
    category: str,
    prefix: str,
    beta_m: float,
    beta_n: float,
    cuticle: float,
    eta: float,
    *,
    gated: bool,
) -> dict[str, Any]:
    return {
        "name": case_name(prefix, beta_m, beta_n, cuticle, eta),
        "category": category,
        "gated": gated,
        "parameters": {
            "beta_m_effective": beta_m,
            "beta_n_effective": beta_n,
            "cuticle": cuticle,
            "eta": eta,
        },
    }


def dedupe(cases: list[dict[str, Any]]) -> list[dict[str, Any]]:
    seen: set[tuple[float, float, float, float, bool]] = set()
    result: list[dict[str, Any]] = []
    for case in cases:
        p = case["parameters"]
        key = (
            float(p["beta_m_effective"]),
            float(p["beta_n_effective"]),
            float(p["cuticle"]),
            float(p["eta"]),
            bool(case["gated"]),
        )
        if key in seen:
            continue
        seen.add(key)
        result.append(case)
    return result


def build_cases(preset: str) -> list[dict[str, Any]]:
    cases: list[dict[str, Any]] = []

    if preset == "smoke":
        cases.append(make_case(
            "nominal", "nominal", NOMINAL_BETA_M, NOMINAL_BETA_N,
            NOMINAL_CUTICLE, NOMINAL_ETA, gated=True,
        ))
        for beta_m in (BETA_M_VALUES[0], BETA_M_VALUES[-1]):
            cases.append(make_case(
                "axis", "beta_m", beta_m, NOMINAL_BETA_N,
                NOMINAL_CUTICLE, NOMINAL_ETA, gated=True,
            ))
        for beta_n in (BETA_N_VALUES[0], BETA_N_VALUES[-1]):
            cases.append(make_case(
                "axis", "beta_n", NOMINAL_BETA_M, beta_n,
                NOMINAL_CUTICLE, NOMINAL_ETA, gated=True,
            ))
        for cuticle in (CUTICLE_VALUES[0], CUTICLE_VALUES[-1]):
            cases.append(make_case(
                "axis", "cuticle", NOMINAL_BETA_M, NOMINAL_BETA_N,
                cuticle, NOMINAL_ETA, gated=True,
            ))
        for eta in (ETA_VALUES[0], ETA_VALUES[-1]):
            cases.append(make_case(
                "axis", "eta", NOMINAL_BETA_M, NOMINAL_BETA_N,
                NOMINAL_CUTICLE, eta, gated=True,
            ))
        return dedupe(cases)

    if preset == "full":
        for beta_m in BETA_M_VALUES:
            for beta_n in BETA_N_VALUES:
                for cuticle in CUTICLE_VALUES:
                    for eta in ETA_VALUES:
                        cases.append(make_case(
                            "full_cartesian", "full", beta_m, beta_n,
                            cuticle, eta, gated=True,
                        ))
        return dedupe(cases)

    # Promotion default: 27-case geometry Cartesian product plus a 9-case
    # beta_m x beta_n weighting plane. The nominal overlap is deduplicated.
    for beta_m in BETA_M_VALUES:
        for cuticle in CUTICLE_VALUES:
            for eta in ETA_VALUES:
                cases.append(make_case(
                    "geometry", "geometry", beta_m, NOMINAL_BETA_N,
                    cuticle, eta, gated=True,
                ))

    for beta_m in BETA_M_VALUES:
        for beta_n in BETA_N_VALUES:
            cases.append(make_case(
                "azimuthal_weighting", "weighting", beta_m, beta_n,
                NOMINAL_CUTICLE, NOMINAL_ETA, gated=True,
            ))

    # UI-edge stress characterization. These intentionally do not define the
    # human-hair promotion domain, but they make out-of-LUT behavior visible.
    stress = (
        (5.238, NOMINAL_BETA_N, NOMINAL_CUTICLE, NOMINAL_ETA, "roughness_m_ui_max"),
        (NOMINAL_BETA_M, 6.831, NOMINAL_CUTICLE, NOMINAL_ETA, "roughness_n_ui_max"),
        (NOMINAL_BETA_M, NOMINAL_BETA_N, 0.50, NOMINAL_ETA, "cuticle_ui_max"),
        (NOMINAL_BETA_M, NOMINAL_BETA_N, NOMINAL_CUTICLE, 1.05, "eta_low_edge"),
        (NOMINAL_BETA_M, NOMINAL_BETA_N, NOMINAL_CUTICLE, 2.00, "eta_ui_max"),
    )
    for beta_m, beta_n, cuticle, eta, label in stress:
        cases.append(make_case(
            "stress", label, beta_m, beta_n, cuticle, eta, gated=False,
        ))

    return dedupe(cases)


def run_case(args: argparse.Namespace, case: dict[str, Any], index: int, total: int) -> dict[str, Any]:
    p = case["parameters"]
    print(
        f"[{index}/{total}] {case['name']} "
        f"bm={p['beta_m_effective']} bn={p['beta_n_effective']} "
        f"cuticle={p['cuticle']} eta={p['eta']}",
        file=sys.stderr,
        flush=True,
    )
    user_args = [
        f"--grid={args.grid}",
        f"--phi-grid={args.phi_grid}",
        f"--beta-m={fmt(p['beta_m_effective'])}",
        f"--beta-n={fmt(p['beta_n_effective'])}",
        f"--cuticle={fmt(p['cuticle'])}",
        f"--eta={fmt(p['eta'])}",
        "--contract=report",
    ]
    command = [
        args.godot,
        "--headless",
        "--path",
        args.project,
        "--script",
        VALIDATOR,
        "--",
        *user_args,
    ]
    try:
        completed = subprocess.run(
            command,
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            check=False,
            timeout=CASE_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        die(f"case {case['name']} exceeded {CASE_TIMEOUT_SECONDS:g} seconds")
    except OSError as exc:
        die(f"case {case['name']} could not execute {args.godot!r}: {exc}")

    if completed.returncode != 0:
        die(
            f"case {case['name']} failed with exit code {completed.returncode}\n"
            f"--- stdout tail ---\n{tail(completed.stdout)}\n"
            f"--- stderr tail ---\n{tail(completed.stderr)}"
        )

    payload = extract_json(completed.stdout, "marschner_cinematic_complete_energy_v1")
    if payload is None:
        die(
            f"case {case['name']} did not emit the expected JSON payload\n"
            f"--- stdout tail ---\n{tail(completed.stdout)}"
        )
    return payload


def lobe_map(payload: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {str(row["name"]): row for row in payload.get("lobes", [])}


def build_record(case: dict[str, Any], payload: dict[str, Any]) -> dict[str, Any]:
    lobes = lobe_map(payload)
    per_theta = payload.get("per_theta_i", [])
    worst_theta = max(
        per_theta,
        key=lambda row: float(row.get("relative_error", -1.0)),
        default=None,
    )
    summary = payload.get("summary", {})
    return {
        **case,
        "summary": {
            "gate_passed": bool(summary.get("gate_passed", False)),
            "worst_lobe_relative_error": float(summary.get("worst_lobe_relative_error", math.inf)),
            "worst_per_theta_relative_error": float(summary.get("worst_per_theta_relative_error", math.inf)),
            "worst_theta_i_deg": None if worst_theta is None else float(worst_theta["theta_i_deg"]),
        },
        "lobe_relative_error": {
            name: float(lobes.get(name, {}).get("relative_error", math.inf))
            for name in ("R", "TT", "TRT")
        },
        "branch_statistics": payload.get("branch_statistics", {}),
        "per_theta_i": per_theta,
    }


def worst_case(records: list[dict[str, Any]], field: str) -> dict[str, Any] | None:
    if not records:
        return None
    row = max(records, key=lambda item: float(item["summary"][field]))
    return {
        "case": row["name"],
        "parameters": row["parameters"],
        "value": row["summary"][field],
        "worst_theta_i_deg": row["summary"].get("worst_theta_i_deg") if field == "worst_per_theta_relative_error" else None,
    }


def summarize(records: list[dict[str, Any]]) -> dict[str, Any]:
    gated = [row for row in records if row["gated"]]
    stress = [row for row in records if not row["gated"]]
    failures = [row for row in gated if not row["summary"]["gate_passed"]]

    per_lobe: dict[str, Any] = {}
    for name in ("R", "TT", "TRT"):
        if gated:
            row = max(gated, key=lambda item: float(item["lobe_relative_error"][name]))
            per_lobe[name] = {
                "case": row["name"],
                "parameters": row["parameters"],
                "relative_error": row["lobe_relative_error"][name],
            }

    def branch_peak(key: str) -> dict[str, Any] | None:
        if not records:
            return None
        row = max(records, key=lambda item: float(item["branch_statistics"].get(key, 0.0)))
        return {
            "case": row["name"],
            "parameters": row["parameters"],
            "value": float(row["branch_statistics"].get(key, 0.0)),
            "gated": row["gated"],
        }

    return {
        "gate_passed": not failures,
        "gated_case_count": len(gated),
        "stress_case_count": len(stress),
        "failed_gated_case_count": len(failures),
        "failed_gated_cases": [row["name"] for row in failures],
        "worst_gated_lobe": worst_case(gated, "worst_lobe_relative_error"),
        "worst_gated_per_theta": worst_case(gated, "worst_per_theta_relative_error"),
        "worst_gated_per_lobe": per_lobe,
        "highest_low_beta_sample_share": branch_peak("low_beta_sample_share"),
        "highest_beta_above_lut_sample_share": branch_peak("beta_above_lut_sample_share"),
        "worst_stress_lobe": worst_case(stress, "worst_lobe_relative_error"),
        "worst_stress_per_theta": worst_case(stress, "worst_per_theta_relative_error"),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", default=DEFAULT_GODOT)
    parser.add_argument("--project", default=DEFAULT_PROJECT)
    parser.add_argument("--grid", type=int, default=128)
    parser.add_argument("--phi-grid", type=int, default=96)
    parser.add_argument("--preset", choices=("smoke", "promotion", "full"), default="promotion")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument(
        "--report-only",
        action="store_true",
        help="write the matrix report but exit zero even when a gated case fails",
    )
    args = parser.parse_args()

    if not os.path.exists(args.godot):
        die(f"Godot executable not found: {args.godot}")
    if not os.path.basename(args.godot).lower().endswith(".exe"):
        die("this runner expects the Windows Godot executable")
    if args.grid < 8 or args.phi_grid < 8:
        die("--grid and --phi-grid must both be >= 8")

    cases = build_cases(args.preset)
    records: list[dict[str, Any]] = []
    for index, case in enumerate(cases, start=1):
        payload = run_case(args, case, index, len(cases))
        records.append(build_record(case, payload))

    matrix_summary = summarize(records)
    report = {
        "schema": "marschner_cinematic_material_matrix_v1",
        "configuration": {
            "preset": args.preset,
            "grid": args.grid,
            "phi_grid": args.phi_grid,
            "theta_i_deg": [-60.0, -30.0, 0.0, 30.0, 60.0],
            "acceptance": {
                "worst_aggregate_lobe_relative_error_max": LOBE_ERROR_GATE,
                "worst_per_incoming_angle_relative_error_max": PER_ANGLE_ERROR_GATE,
            },
            "gated_domain": {
                "beta_m_effective": list(BETA_M_VALUES),
                "beta_n_effective": list(BETA_N_VALUES),
                "cuticle": list(CUTICLE_VALUES),
                "eta": list(ETA_VALUES),
            },
            "matrix_design": (
                "full 3x3x3x3 Cartesian product" if args.preset == "full" else
                "nominal plus axis extremes" if args.preset == "smoke" else
                "3x3x3 beta_m/cuticle/eta geometry product plus 3x3 beta_m/beta_n weighting plane; UI-edge stress cases report-only"
            ),
            "validator": VALIDATOR,
        },
        "summary": matrix_summary,
        "cases": records,
    }

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    print(json.dumps(matrix_summary, indent=2, allow_nan=False))
    print(f"wrote {args.out}", file=sys.stderr)

    if not matrix_summary["gate_passed"] and not args.report_only:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
