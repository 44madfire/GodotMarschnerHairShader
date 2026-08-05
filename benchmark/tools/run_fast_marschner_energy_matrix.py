#!/usr/bin/env python3
"""Fast Marschner energy matrix runner (Windows Godot only).

Drives the Phase 4 integrated-energy validator
(benchmark/tools/validate_fast_marschner_energy.gd) over a designed 12-case
material matrix and emits one top-level JSON report.

Every case runs through the WINDOWS Godot binary (WSL interop, godot.exe)
with the fixed report contract selectors

    --contract=report --longitudinal=unity --r-longitudinal=standard
    --decomposition=full

plus per-case material overrides (--eta, --beta-m, --beta-n, --cuticle,
--albedo) and the matrix grid (--grid, --coarse).

The validator prints human-readable lines interleaved with a single JSON
payload; this runner locates that payload by scanning from every '{' with
json.JSONDecoder.raw_decode and keeping the last decoded object that contains
both 'aggregate' and 'ratio_audit'.

The exit status is nonzero, with a useful stderr message, when:
  - the Godot binary is not a Windows .exe or cannot be executed,
  - the process exits nonzero,
  - no JSON payload containing 'aggregate' and 'ratio_audit' is found,
  - contract_result != REPORT,
  - required report fields are missing.

stdout carries ONLY the final JSON report (indent=2); progress and errors go
to stderr. Use --out <path> to also write the report to a file.

Usage:
  python3 run_fast_marschner_energy_matrix.py \
      [--godot /mnt/c/Tools/Godot/godot.exe] \
      [--project //wsl.localhost/Ubuntu/home/jeffreymwang/godot-hair-shader] \
      [--grid 128] [--coarse 64] [--out report.json]
"""

import argparse
import json
import math
import os
import subprocess
import sys
from typing import NoReturn

# --- Defaults (Windows Godot only, never the Linux binary) -------------------
GODOT_DEFAULT = "/mnt/c/Tools/Godot/godot.exe"
PROJECT_DEFAULT = "//wsl.localhost/Ubuntu/home/jeffreymwang/godot-hair-shader"
VALIDATOR = "res://benchmark/tools/validate_fast_marschner_energy.gd"

# Shipping reference material (Blowout clone; matches the validator defaults).
REFERENCE_ALBEDO = (0.24774602, 0.12215338, 0.09630052)
REFERENCE_ETA = 1.55
REFERENCE_BETA_M = 0.2
REFERENCE_BETA_N = 0.75
REFERENCE_CUTICLE = 0.087

# Each case is a 512x512-equivalent integration at --grid resolution; be
# generous per case so a slow machine cannot kill a legitimately slow run.
CASE_TIMEOUT_SECONDS = 3600.0

# --- Designed 12-case subset -------------------------------------------------
# Reference dark brown, beta_m 0.1/0.8, beta_n 0.1/0.9, cuticle 0.0/0.1,
# blond/red/neutral-gray albedos, eta 1.45/1.65. Everything not listed for a
# case stays at the shipping reference value. Deliberately NOT a Cartesian
# sweep: see LIMITATIONS.
CASES = [
    {"name": "reference_dark_brown",
     "eta": REFERENCE_ETA, "beta_m": REFERENCE_BETA_M,
     "beta_n": REFERENCE_BETA_N, "cuticle": REFERENCE_CUTICLE,
     "albedo": REFERENCE_ALBEDO},
    {"name": "beta_m_0_1",
     "eta": REFERENCE_ETA, "beta_m": 0.1,
     "beta_n": REFERENCE_BETA_N, "cuticle": REFERENCE_CUTICLE,
     "albedo": REFERENCE_ALBEDO},
    {"name": "beta_m_0_8",
     "eta": REFERENCE_ETA, "beta_m": 0.8,
     "beta_n": REFERENCE_BETA_N, "cuticle": REFERENCE_CUTICLE,
     "albedo": REFERENCE_ALBEDO},
    {"name": "beta_n_0_1",
     "eta": REFERENCE_ETA, "beta_m": REFERENCE_BETA_M,
     "beta_n": 0.1, "cuticle": REFERENCE_CUTICLE,
     "albedo": REFERENCE_ALBEDO},
    {"name": "beta_n_0_9",
     "eta": REFERENCE_ETA, "beta_m": REFERENCE_BETA_M,
     "beta_n": 0.9, "cuticle": REFERENCE_CUTICLE,
     "albedo": REFERENCE_ALBEDO},
    {"name": "cuticle_0",
     "eta": REFERENCE_ETA, "beta_m": REFERENCE_BETA_M,
     "beta_n": REFERENCE_BETA_N, "cuticle": 0.0,
     "albedo": REFERENCE_ALBEDO},
    {"name": "cuticle_0_1",
     "eta": REFERENCE_ETA, "beta_m": REFERENCE_BETA_M,
     "beta_n": REFERENCE_BETA_N, "cuticle": 0.1,
     "albedo": REFERENCE_ALBEDO},
    {"name": "blond",
     "eta": REFERENCE_ETA, "beta_m": REFERENCE_BETA_M,
     "beta_n": REFERENCE_BETA_N, "cuticle": REFERENCE_CUTICLE,
     "albedo": (0.843, 0.635, 0.392)},
    {"name": "red",
     "eta": REFERENCE_ETA, "beta_m": REFERENCE_BETA_M,
     "beta_n": REFERENCE_BETA_N, "cuticle": REFERENCE_CUTICLE,
     "albedo": (0.557, 0.268, 0.075)},
    {"name": "neutral_gray",
     "eta": REFERENCE_ETA, "beta_m": REFERENCE_BETA_M,
     "beta_n": REFERENCE_BETA_N, "cuticle": REFERENCE_CUTICLE,
     "albedo": (0.5, 0.5, 0.5)},
    {"name": "eta_1_45",
     "eta": 1.45, "beta_m": REFERENCE_BETA_M,
     "beta_n": REFERENCE_BETA_N, "cuticle": REFERENCE_CUTICLE,
     "albedo": REFERENCE_ALBEDO},
    {"name": "eta_1_65",
     "eta": 1.65, "beta_m": REFERENCE_BETA_M,
     "beta_n": REFERENCE_BETA_N, "cuticle": REFERENCE_CUTICLE,
     "albedo": REFERENCE_ALBEDO},
]

LIMITATIONS = [
    "Designed 12-case subset covering the reference dark-brown material (eta 1.55, "
    "beta_m 0.2, beta_n 0.75, cuticle 0.087), beta_m 0.1/0.8, beta_n 0.1/0.9, "
    "cuticle 0.0/0.1, blond/red/neutral-gray albedos, and eta 1.45/1.65; this is NOT "
    "a full Cartesian sweep and NOT a material-domain proof.",
    "Each case is a five-angle aggregate: the validator integrates the incoming angles "
    "{-60, -30, 0, 30, 60} degrees and sums the per-lobe projected energies; per-angle "
    "detail stays inside the validator payload (per_theta_i) and is not broken out in "
    "this matrix.",
    "All cases run with --contract=report (plus --longitudinal=unity, "
    "--r-longitudinal=standard, --decomposition=full); parity fields are reported "
    "unweakened but no acceptance gate is applied, so contract_result=REPORT does not "
    "imply the strict parity bands passed.",
    "Windows Godot only by design (WSL interop godot.exe); the script refuses any "
    "non-.exe Godot binary, so the Linux editor can never be selected accidentally.",
    "Ratios sum the RGB channels of the projected solid-angle energies; errors are "
    "absolute in those energy units; grid drift is the validator's coarse-vs-fine "
    "relative probe (grid_convergence.max_relative_drift).",
]


def _fmt(value):
    """Short, exact-enough float formatting for validator CLI arguments."""
    return "%.10g" % float(value)


def _die(message) -> NoReturn:
    sys.stderr.write("run_fast_marschner_energy_matrix: error: %s\n" % message)
    sys.exit(1)


def _tail(text, lines=40):
    """Last non-empty lines of captured output, for diagnostics."""
    if not text:
        return "(no output)"
    trimmed = [line for line in text.splitlines() if line.strip()]
    return "\n".join(trimmed[-lines:])


def _parse_constant(token):
    """Godot's JSON.stringify emits Infinity/-Infinity/NaN; accept them."""
    if token == "Infinity":
        return float("inf")
    if token == "-Infinity":
        return float("-inf")
    return float("nan")


def _json_safe(value):
    """Non-finite floats become null so the emitted report stays valid JSON."""
    if isinstance(value, float) and not math.isfinite(value):
        return None
    return value


def _nested_get(doc, *path):
    current = doc
    for key in path:
        if not isinstance(current, dict) or key not in current:
            return None
        current = current[key]
    return current


def _is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _find_payload(stdout):
    """Locate the validator JSON payload in mixed stdout.

    Scans from every '{' with json.JSONDecoder.raw_decode and keeps the LAST
    decoded object that contains both 'aggregate' and 'ratio_audit' (the
    validator report). Human-readable lines and partial/embedded JSON garbage
    are skipped naturally because raw_decode only succeeds on complete objects
    and the key pair is specific to the report.
    """
    decoder = json.JSONDecoder(parse_constant=_parse_constant)
    candidates = []
    index = 0
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


# Numeric fields the matrix summary reads out of the payload. contract_result
# is handled separately below (it is a string).
REQUIRED_FIELDS = [
    ("aggregate", "ratio_total"),
    ("aggregate", "lobes", "R", "ratio"),
    ("aggregate", "lobes", "TT", "ratio"),
    ("aggregate", "lobes", "TRT", "ratio"),
    ("ratio_audit", "valid_ratio_min"),
    ("ratio_audit", "valid_ratio_max"),
    ("ratio_audit", "baseline_energy_weighted_ratio"),
    ("ratio_audit", "rms_absolute_error_total"),
    ("ratio_audit", "max_absolute_error_total"),
    ("grid_convergence", "max_relative_drift"),
    ("contract_result",),
]


def _missing_fields(payload):
    missing = []
    for path in REQUIRED_FIELDS:
        value = _nested_get(payload, *path)
        if path == ("contract_result",):
            if not isinstance(value, str) or not value:
                missing.append(".".join(path))
        elif value is None or not _is_number(value):
            missing.append(".".join(path))
    return missing


def _run_case(args, case, index):
    """Run one validator case through Windows Godot; die with a useful
    stderr message on any failure. Returns the parsed validator payload."""
    sys.stderr.write(
        "run_fast_marschner_energy_matrix: case %d/%d %s (grid=%d, coarse=%d)\n"
        % (index, len(CASES), case["name"], args.grid, args.coarse))
    user_args = [
        "--grid=%d" % args.grid,
        "--coarse=%d" % args.coarse,
        "--eta=%s" % _fmt(case["eta"]),
        "--beta-m=%s" % _fmt(case["beta_m"]),
        "--beta-n=%s" % _fmt(case["beta_n"]),
        "--cuticle=%s" % _fmt(case["cuticle"]),
        "--albedo=%s" % ",".join(_fmt(a) for a in case["albedo"]),
        "--contract=report",
        "--longitudinal=unity",
        "--r-longitudinal=standard",
        "--decomposition=full",
    ]
    # Godot reads user args only after the "--" separator
    # (OS.get_cmdline_user_args).
    command = [args.godot, "--headless", "--path", args.project,
               "--script", VALIDATOR, "--"] + user_args
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=CASE_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        _die("case %s: validator did not finish within %g seconds (grid=%d, coarse=%d)"
             % (case["name"], CASE_TIMEOUT_SECONDS, args.grid, args.coarse))
    except OSError as exc:
        _die("case %s: failed to execute Windows Godot %r: %s"
             % (case["name"], args.godot, exc))
    if completed.returncode != 0:
        _die("case %s: Windows Godot exited nonzero (returncode=%d)\n"
             "--- stdout tail ---\n%s\n--- stderr tail ---\n%s"
             % (case["name"], completed.returncode,
                _tail(completed.stdout), _tail(completed.stderr)))
    payload = _find_payload(completed.stdout)
    if payload is None:
        _die("case %s: no JSON payload containing 'aggregate' and 'ratio_audit' "
             "found in validator stdout\n--- stdout tail ---\n%s\n--- stderr tail ---\n%s"
             % (case["name"], _tail(completed.stdout), _tail(completed.stderr)))
    missing = _missing_fields(payload)
    if missing:
        _die("case %s: validator payload is missing required field(s): %s"
             % (case["name"], ", ".join(missing)))
    contract_result = payload["contract_result"]
    if contract_result != "REPORT":
        _die("case %s: expected contract_result=REPORT, got %r (reason: %s)"
             % (case["name"], contract_result,
                str(payload.get("contract_reason", "<none>"))))
    return payload


def _build_case_record(case, payload):
    aggregate = payload["aggregate"]
    audit = payload["ratio_audit"]
    parameters = {
        "eta": case["eta"],
        "beta_m": case["beta_m"],
        "beta_n": case["beta_n"],
        "cuticle": case["cuticle"],
        "albedo": [float(a) for a in case["albedo"]],
    }
    return {
        "name": case["name"],
        "parameters": parameters,
        "ratios": {
            "total": _json_safe(aggregate["ratio_total"]),
            "R": _json_safe(aggregate["lobes"]["R"]["ratio"]),
            "TT": _json_safe(aggregate["lobes"]["TT"]["ratio"]),
            "TRT": _json_safe(aggregate["lobes"]["TRT"]["ratio"]),
        },
        "ratio_audit": {
            "min": _json_safe(audit["valid_ratio_min"]),
            "max": _json_safe(audit["valid_ratio_max"]),
            "weighted_ratio": _json_safe(audit["baseline_energy_weighted_ratio"]),
        },
        "errors": {
            "rms_absolute": _json_safe(audit["rms_absolute_error_total"]),
            "max_absolute": _json_safe(audit["max_absolute_error_total"]),
        },
        "grid_drift": _json_safe(payload["grid_convergence"]["max_relative_drift"]),
        "contract_result": payload["contract_result"],
        "contract_reason": payload.get("contract_reason", ""),
    }


def _build_summary(records):
    summary = {}
    for key in ("total", "R", "TT", "TRT"):
        entries = [(r["name"], r["ratios"][key], r["parameters"]) for r in records]
        finite = [(name, value, params) for name, value, params in entries
                  if value is not None and math.isfinite(value)]
        if not finite:
            summary[key] = {"min": None, "max": None,
                            "worst_case": None, "worst_parameters": None}
            continue
        lo = min(finite, key=lambda item: item[1])
        hi = max(finite, key=lambda item: item[1])
        # Worst case = the ratio farthest from 1.0.
        worst = max(finite, key=lambda item: abs(item[1] - 1.0))
        summary[key] = {
            "min": lo[1],
            "max": hi[1],
            "worst_case": worst[0],
            "worst_parameters": worst[2],
        }

    def _worst_record(records, pick):
        best = records[0]
        best_key = pick(best)
        for record in records[1:]:
            key = pick(record)
            if key is not None and (best_key is None or key > best_key):
                best, best_key = record, key
        return best

    max_rms = _worst_record(records, lambda r: r["errors"]["rms_absolute"])
    max_abs = _worst_record(records, lambda r: r["errors"]["max_absolute"])
    summary["max_rms_absolute_error"] = {
        "value": max_rms["errors"]["rms_absolute"],
        "case": max_rms["name"],
        "case_parameters": max_rms["parameters"],
    }
    summary["max_absolute_error"] = {
        "value": max_abs["errors"]["max_absolute"],
        "case": max_abs["name"],
        "case_parameters": max_abs["parameters"],
    }
    summary["case_names"] = [r["name"] for r in records]
    return summary


def _positive_int(text):
    value = int(text)
    if value <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer, got %r" % text)
    return value


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Run the Fast Marschner energy validator matrix through "
                    "Windows Godot (never the Linux binary) and emit a JSON report.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    parser.add_argument("--godot", default=GODOT_DEFAULT,
                        help="Windows Godot executable (godot.exe)")
    parser.add_argument("--project", default=PROJECT_DEFAULT,
                        help="Godot project path")
    parser.add_argument("--grid", type=_positive_int, default=128,
                        help="fine quadrature grid per axis (grid_theta = grid_phi)")
    parser.add_argument("--coarse", type=_positive_int, default=64,
                        help="coarse grid per axis for the drift probe")
    parser.add_argument("--out", default=None,
                        help="optional path to write the JSON report to")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)

    # Windows Godot only: never route this matrix through the Linux binary.
    if not os.path.basename(args.godot).lower().endswith(".exe"):
        _die("refusing to run non-Windows Godot binary %r: this matrix runner is "
             "Windows-only (WSL interop godot.exe); pass --godot pointing at a "
             "Windows executable" % args.godot)
    if not os.path.exists(args.godot):
        _die("Windows Godot executable not found: %r" % args.godot)
    # The project argument is intentionally a Windows-visible UNC path for
    # Godot. WSL's Linux filesystem APIs cannot stat //wsl.localhost/... even
    # though Windows Godot can resolve it, so only validate ordinary local
    # paths here and let Godot validate UNC paths at process startup.
    if not args.project.startswith("//wsl.localhost/") and not os.path.isdir(args.project):
        _die("Godot project directory not found: %r" % args.project)

    records = []
    for index, case in enumerate(CASES, start=1):
        payload = _run_case(args, case, index)
        records.append(_build_case_record(case, payload))

    report = {
        "tool": "run_fast_marschner_energy_matrix",
        "grid": args.grid,
        "coarse": args.coarse,
        "case_count": len(records),
        "cases": records,
        "summary": _build_summary(records),
        "limitations": LIMITATIONS,
    }
    text = json.dumps(report, indent=2)
    sys.stdout.write(text + "\n")
    if args.out:
        try:
            with open(args.out, "w", encoding="utf-8") as handle:
                handle.write(text + "\n")
        except OSError as exc:
            _die("failed to write report to %r: %s" % (args.out, exc))
    return 0


if __name__ == "__main__":
    sys.exit(main())
