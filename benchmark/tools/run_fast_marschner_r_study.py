#!/usr/bin/env python3
"""Run the Unity HDRP R-lobe attribution study through Windows Godot.

The validator emits human-readable lines followed by one JSON payload. This
runner executes all five report-only R-study modes, extracts their payloads,
and emits a compact machine-readable comparison report. It intentionally never
invokes a shipping shader path or the regression contract for diagnostic modes.
"""

import argparse
import json
import math
import os
import subprocess
import sys
from typing import NoReturn

GODOT_DEFAULT = "/mnt/c/Tools/Godot/godot.exe"
PROJECT_DEFAULT = "//wsl.localhost/Ubuntu/home/jeffreymwang/godot-hair-shader"
VALIDATOR = "res://benchmark/tools/validate_fast_marschner_energy.gd"
R_STUDY_MODES = ["current", "unity_fresnel", "unity_nf", "baseline_m_unity_nf", "unity_exact"]
DECOMPOSITIONS = ["full", "m", "n", "a"]
CASE_TIMEOUT_SECONDS = 3600.0


def _die(message: str) -> NoReturn:
    sys.stderr.write("run_fast_marschner_r_study: error: %s\n" % message)
    raise SystemExit(1)


def _parse_constant(token: str):
    if token == "Infinity":
        return float("inf")
    if token == "-Infinity":
        return float("-inf")
    return float("nan")


def _find_payload(stdout: str):
    decoder = json.JSONDecoder(parse_constant=_parse_constant)
    index = 0
    candidates = []
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
        if isinstance(obj, dict) and "aggregate" in obj and "ratio_audit" in obj:
            candidates.append(obj)
        index = end
    return candidates[-1] if candidates else None


def _tail(text: str, lines: int = 30) -> str:
    nonempty = [line for line in text.splitlines() if line.strip()]
    return "\n".join(nonempty[-lines:]) or "(no output)"


def _run_validator(args, mode: str, decomposition: str):
    user_args = [
        "--contract=report",
        "--longitudinal=unity",
        "--r-longitudinal=standard",
        "--azimuthal=fixed_h",
        "--decomposition=%s" % decomposition,
        "--r-study=%s" % mode,
        "--grid=%d" % args.grid,
        "--coarse=%d" % args.coarse,
    ]
    command = [args.godot, "--headless", "--path", args.project, "--script", VALIDATOR, "--"] + user_args
    sys.stderr.write("run_fast_marschner_r_study: mode=%s decomposition=%s grid=%d coarse=%d\n" %
                     (mode, decomposition, args.grid, args.coarse))
    try:
        completed = subprocess.run(command, capture_output=True, text=True, encoding="utf-8",
                                   errors="replace", timeout=CASE_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        _die("validator timed out for mode=%s decomposition=%s" % (mode, decomposition))
    except OSError as exc:
        _die("failed to execute Windows Godot: %s" % exc)
    if completed.returncode != 0:
        _die("validator failed for mode=%s decomposition=%s (returncode=%d)\n%s\n%s" %
             (mode, decomposition, completed.returncode, _tail(completed.stdout), _tail(completed.stderr)))
    payload = _find_payload(completed.stdout)
    if payload is None:
        _die("no validator JSON payload for mode=%s decomposition=%s\n%s" %
             (mode, decomposition, _tail(completed.stdout)))
    if payload.get("contract_result") != "REPORT":
        _die("expected contract_result=REPORT for mode=%s decomposition=%s, got %r" %
             (mode, decomposition, payload.get("contract_result")))
    return payload


def _sum_rgb(values):
    return sum(float(value) for value in values)


def _mode_record(mode: str, decomposition: str, payload: dict) -> dict:
    aggregate = payload["aggregate"]
    audit = payload["ratio_audit"]
    return {
        "mode": mode,
        "decomposition": decomposition,
        "r_study": payload.get("r_study", {}),
        "aggregate": {
            "baseline_R": _sum_rgb(aggregate["lobes"]["R"]["baseline"]),
            "fast_R": _sum_rgb(aggregate["lobes"]["R"]["fast"]),
            "R_ratio": aggregate["lobes"]["R"]["ratio"],
            "baseline_total": aggregate["baseline_total"],
            "fast_total": aggregate["fast_total"],
            "total_ratio": aggregate["ratio_total"],
        },
        "per_theta_i": [
            {
                "theta_i_deg": entry["theta_i_deg"],
                "baseline_R": _sum_rgb(entry["baseline"]["R"]),
                "fast_R": _sum_rgb(entry["fast"]["R"]),
                "R_ratio": entry["ratio"]["R"],
                "baseline_total": entry["baseline_total"],
                "fast_total": entry["fast_total"],
                "total_ratio": entry["ratio_total"],
            }
            for entry in payload["per_theta_i"]
        ],
        "ratio_audit": {
            "valid_ratio_min": audit["valid_ratio_min"],
            "valid_ratio_max": audit["valid_ratio_max"],
            "baseline_energy_weighted_R_ratio": _safe_ratio(
                _sum_rgb(aggregate["lobes"]["R"]["fast"]),
                _sum_rgb(aggregate["lobes"]["R"]["baseline"])),
            "baseline_energy_weighted_total_ratio": audit["baseline_energy_weighted_ratio"],
            "rms_absolute_error_total": audit["rms_absolute_error_total"],
            "max_absolute_error_total": audit["max_absolute_error_total"],
        },
        "grid_convergence": payload["grid_convergence"],
        "contract_result": payload["contract_result"],
    }


def _safe_ratio(numerator, denominator):
    return numerator / denominator if denominator else float("inf")


def _attribution(records: dict) -> dict:
    full = {mode: records[mode]["aggregate"]["R_ratio"] for mode in R_STUDY_MODES}
    current = full["current"]
    def multiplier(mode):
        return _safe_ratio(full[mode], current)
    return {
        "R_ratio_by_mode": full,
        "fresnel_multiplier": multiplier("unity_fresnel"),
        "unity_n_multiplier": _safe_ratio(full["unity_nf"], full["unity_fresnel"]),
        "baseline_m_multiplier": _safe_ratio(full["baseline_m_unity_nf"], full["unity_nf"]),
        "unity_exact_vs_current": multiplier("unity_exact"),
    }


def _positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="Run the Unity HDRP R-lobe attribution study through Windows Godot.")
    parser.add_argument("--godot", default=GODOT_DEFAULT)
    parser.add_argument("--project", default=PROJECT_DEFAULT)
    parser.add_argument("--grid", type=_positive_int, default=128)
    parser.add_argument("--coarse", type=_positive_int, default=64)
    parser.add_argument("--include-decomposition", action="store_true",
                        help="also run m/n/a/full decomposition reports for current, unity_nf, baseline_m_unity_nf, unity_exact")
    parser.add_argument("--out", default=None)
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    if not os.path.basename(args.godot).lower().endswith(".exe"):
        _die("refusing non-Windows Godot binary %r" % args.godot)
    if not os.path.exists(args.godot):
        _die("Windows Godot executable not found: %r" % args.godot)
    if not args.project.startswith("//wsl.localhost/") and not os.path.isdir(args.project):
        _die("Godot project directory not found: %r" % args.project)

    full_records = {}
    for mode in R_STUDY_MODES:
        full_records[mode] = _mode_record(mode, "full", _run_validator(args, mode, "full"))

    decomposition_records = {}
    if args.include_decomposition:
        for mode in ("current", "unity_nf", "baseline_m_unity_nf", "unity_exact"):
            decomposition_records[mode] = {}
            for decomposition in DECOMPOSITIONS:
                decomposition_records[mode][decomposition] = _mode_record(
                    mode, decomposition, _run_validator(args, mode, decomposition))

    report = {
        "study": "unity_r_attribution_v1",
        "tool": "run_fast_marschner_r_study",
        "grid": args.grid,
        "coarse": args.coarse,
        "parameters": {
            "longitudinal": "unity",
            "r_longitudinal": "standard",
            "azimuthal": "fixed_h",
            "contract": "report",
            "decompositions": DECOMPOSITIONS if args.include_decomposition else ["full"],
        },
        "modes": full_records,
        "attribution": _attribution(full_records),
        "decompositions": decomposition_records,
        "limitations": [
            "CPU projected-solid-angle integration only; no shipping shader is modified.",
            "Unity N_R uses the direct 20-sample h integration and raw perceptual radial roughness.",
            "All non-current modes are report-only and strict parity fields remain diagnostic.",
            "The study attributes aggregate and per-angle R differences; it does not prove full Unity HDRP parity.",
        ],
    }
    text = json.dumps(report, indent=2, allow_nan=False)
    sys.stdout.write(text + "\n")
    if args.out:
        try:
            with open(args.out, "w", encoding="utf-8") as handle:
                handle.write(text + "\n")
        except OSError as exc:
            _die("failed to write report %r: %s" % (args.out, exc))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
