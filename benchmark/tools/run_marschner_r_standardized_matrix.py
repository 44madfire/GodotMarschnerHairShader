#!/usr/bin/env python3
"""Standardized Marschner R energy matrix runner (Windows Godot only).

Drives the Phase 3 CPU-only integrated-energy validator
(benchmark/tools/validate_marschner_r_standardized_energy.gd) over a designed
12-case material matrix and emits one top-level JSON report.

Every case runs through the WINDOWS Godot binary (WSL interop, godot.exe)
with the fixed report contract selector

    --contract=report

plus per-case material overrides (--eta, --beta-m, --cuticle, --albedo) and
the matrix quadrature grid (--grid, --phi-grid). beta_n is metadata only: the
validator has no beta_n argument (the R kernel has no longitudinal width), so
it is recorded in the report parameters but never passed on the command line.
eta and albedo are also metadata only (the R lobe has no absorption path) but
the validator accepts and records them for provenance.

The validator prints human-readable lines interleaved with a single JSON
payload (schema standardized_r_energy_v1); this runner locates that payload by
scanning from every '{' with json.JSONDecoder.raw_decode and keeping the last
decoded object whose schema is standardized_r_energy_v1.

The exit status is nonzero, with a useful stderr message, when:
  - the Godot binary is not a Windows .exe or cannot be executed,
  - the project directory is missing (UNC paths are left to Godot),
  - the process exits nonzero,
  - no payload with schema standardized_r_energy_v1 is found,
  - contract != REPORT, data_finite != true,
  - the payload LUT contract differs from the expected committed LUT
    (contract standardized_r_projected_q_v1, channels
    R=linear_Q,G=log2_Q,B=0,A=1, resolution [256, 256, 128]),
  - the payload configuration does not exactly match the CLI arguments this
    run passed for the case (grid, phi-grid, beta_m, cuticle, eta, albedo),
  - aggregate totals, branch statistics or decoder results are missing,
    non-finite or violate the contract: decoder sample_count must equal
    grid * phi_grid * 5 (five theta_i angles), every branch count must be a
    non-negative integer, and the disjoint-partition invariant
    (total == lut_interior + q_beta_fallback + grazing_fallback +
    cone_pole_fallback + exact_c_phi_seam) must hold, with
    asymptotic_beta_branch a diagnostic sub-count of q_beta_fallback,
  - the per-case diagnostics object is missing or structurally broken
    (report-only values are never gated),
  - fewer than the exact 12 designed case names are run, or the report
    records differ from them in order.

stdout carries ONLY the final JSON report (indent=2); progress and errors go
to stderr. Use --out <path> to also write the report to a file (exact JSON
plus a trailing newline).

Evidence gate: the Phase 3 plan requires the fine 512/128 run. Pass
--grid 512 --phi-grid 128 (or --grid 8 --phi-grid 16 for a smoke run); the
validator clamps neither and the runner forwards both verbatim. The
expensive 512/128 matrix is run separately from the smoke/evidence runs.

Usage:
  python3 run_marschner_r_standardized_matrix.py \
      [--godot /mnt/c/Tools/Godot/godot.exe] \
      [--project //wsl.localhost/Ubuntu/home/jeffreymwang/godot-hair-shader] \
      [--grid 32] [--phi-grid 64] [--out report.json]
"""

import argparse
import json
import math
import os
import subprocess
import sys
from typing import NoReturn, TypeGuard

# --- Defaults (Windows Godot only, never the Linux binary) -------------------
GODOT_DEFAULT = "/mnt/c/Tools/Godot/godot.exe"
PROJECT_DEFAULT = "//wsl.localhost/Ubuntu/home/jeffreymwang/godot-hair-shader"
VALIDATOR = "res://benchmark/tools/validate_marschner_r_standardized_energy.gd"
MATRIX_SCHEMA = "standardized_r_energy_matrix_v1"
PAYLOAD_SCHEMA = "standardized_r_energy_v1"
CONTRACT_MODE = "REPORT"
GRID_DEFAULT = 32
PHI_GRID_DEFAULT = 64
CASE_TIMEOUT_SECONDS = 3600.0

# Committed LUT contract the validator must have loaded (matches
# benchmark/resources/fast_marschner_r_standardized_lut_data.gd).
LUT_CONTRACT = "standardized_r_projected_q_v1"
LUT_CHANNELS = "R=linear_Q,G=log2_Q,B=0,A=1"
LUT_RESOLUTION = [256, 256, 128]

# Phase 3 validator incoming angles (degrees); per_theta_i must match.
THETA_I_DEG = [-60, -30, 0, 30, 60]

# Every branch counter must be an integer >= 0; the first five partition the
# sample set (see the invariant below), asymptotic_beta_branch is a
# diagnostic sub-count of q_beta_fallback.
BRANCH_KEYS = ["total", "lut_interior", "q_beta_fallback",
               "grazing_fallback", "cone_pole_fallback",
               "asymptotic_beta_branch", "exact_c_phi_seam"]
BRANCH_PARTITION_KEYS = ["lut_interior", "q_beta_fallback",
                         "grazing_fallback", "cone_pole_fallback",
                         "exact_c_phi_seam"]

# Shipping reference material (matches the validator defaults).
REFERENCE_ALBEDO = (0.24774602, 0.12215338, 0.09630052)
REFERENCE_ETA = 1.55
REFERENCE_BETA_M = 0.2
REFERENCE_BETA_N = 0.75
REFERENCE_CUTICLE = 0.087

# --- Designed 12-case subset -------------------------------------------------
# Reference dark brown, beta_m 0.1/0.8, beta_n 0.1/0.9, cuticle 0.0/0.1,
# blond/red/neutral-gray albedos, eta 1.45/1.65. Everything not listed for a
# case stays at the shipping reference value. beta_n is metadata only and is
# never passed to the validator. Deliberately NOT a Cartesian sweep: see
# LIMITATIONS.
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
    "Designed 12-case representative subset covering the reference dark-brown "
    "material (eta 1.55, beta_m 0.2, beta_n 0.75, cuticle 0.087), beta_m "
    "0.1/0.8, beta_n 0.1/0.9, cuticle 0.0/0.1, blond/red/neutral-gray albedos, "
    "and eta 1.45/1.65; this is NOT a full Cartesian sweep and NOT a "
    "material-domain proof.",
    "R lobe only: the full R product M_R * N_R is validated; the TT/TRT lobes "
    "and absorption are out of scope. R has no absorption path, so eta and "
    "albedo never enter the integrand.",
    "CPU projected-solid-angle integration only: deterministic midpoint "
    "quadrature of f * cos(theta_o) dtheta_o dphi over theta_o in [-PI/2, "
    "PI/2] x phi in [-PI, PI] (the measure the light loop performs "
    "implicitly); no shader or rasterized path is exercised.",
    "eta, albedo and beta_n are metadata only: eta and albedo are passed to "
    "the validator for provenance but do not affect the integrand, and beta_n "
    "is recorded in each case's parameters but never passed to the validator "
    "(the R kernel has no longitudinal width parameter).",
    "No raw-M unit-normalization gate: the validator requires the LUT to not "
    "claim raw-M unit normalization (raw_m_unit_normalization_gate=false) and "
    "reports errors unweakened, but no acceptance band is applied to the "
    "reported errors.",
    "No shader promotion: this run only validates the committed LUT against "
    "the direct kernel reference; it does not promote any kernel, LUT or "
    "decoder into a shipping shader path.",
    "Windows Godot only by design (WSL interop godot.exe); the script refuses "
    "any non-.exe Godot binary, so the Linux editor can never be selected "
    "accidentally.",
    "Errors are absolute/relative in projected solid-angle energy units on "
    "the five-angle aggregate and per theta_i (per_theta_i stays inside each "
    "case record); the matrix-level worst errors are the per-case aggregate "
    "errors over both decoders.",
]


def _fmt(value):
    """Short, exact-enough float formatting for validator CLI arguments."""
    return "%.10g" % float(value)


def _die(message) -> NoReturn:
    sys.stderr.write("run_marschner_r_standardized_matrix: error: %s\n" % message)
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


def _sanitize(value):
    """Recursively map non-finite floats to null (report must stay valid)."""
    if isinstance(value, dict):
        return {key: _sanitize(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_sanitize(item) for item in value]
    if isinstance(value, float) and not math.isfinite(value):
        return None
    return value


def _is_number(value: object) -> TypeGuard[float | int]:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _find_payload(stdout):
    """Locate the validator JSON payload in mixed stdout.

    Scans from every '{' with json.JSONDecoder.raw_decode and keeps the LAST
    decoded object whose schema is standardized_r_energy_v1 (the validator
    report). Human-readable lines and partial/embedded JSON garbage are
    skipped naturally because raw_decode only succeeds on complete objects and
    the schema discriminator is specific to the report.
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
        if (isinstance(obj, dict) and obj.get("schema") == PAYLOAD_SCHEMA
                and "aggregate" in obj and "branch_statistics" in obj):
            candidates.append(obj)
        index = end
    return candidates[-1] if candidates else None


def _close(got, want):
    """Exact CLI-config match: both sides are IEEE doubles of the same
    decimal string (the runner formats with %.10g and the validator parses
    and JSON-round-trips it), so a tight relative tolerance is sufficient."""
    return math.isclose(got, want, rel_tol=1e-12, abs_tol=1e-15)


def _validate_payload(payload, expected=None):
    """Return a list of contract violations in the validator payload.

    Requires schema standardized_r_energy_v1, contract REPORT, data_finite,
    finite aggregate totals with both decoder results, decoder
    sample_count == grid * phi_grid * 5, the committed LUT contract
    (standardized_r_projected_q_v1, channels, resolution [256, 256, 128]),
    a configuration that exactly matches the CLI arguments passed for the
    case, integer non-negative branch statistics satisfying the
    disjoint-partition invariant
        total == lut_interior + q_beta_fallback + grazing_fallback
                 + cone_pole_fallback + exact_c_phi_seam
    with asymptotic_beta_branch a diagnostic sub-count of q_beta_fallback,
    the full five-angle per_theta_i breakdown, and a structurally sound
    report-only diagnostics object (its values are never gated). `expected`
    carries the CLI configuration of the case being validated. Empty list
    means the payload passed.
    """
    errors = []
    if not isinstance(payload, dict):
        return ["payload is not a JSON object"]
    if payload.get("schema") != PAYLOAD_SCHEMA:
        errors.append("schema must be %r, got %r" % (PAYLOAD_SCHEMA, payload.get("schema")))
    if payload.get("contract") != CONTRACT_MODE:
        errors.append("contract must be %r, got %r" % (CONTRACT_MODE, payload.get("contract")))
    if payload.get("data_finite") is not True:
        errors.append("data_finite must be true")

    lut = payload.get("lut")
    if not isinstance(lut, dict):
        errors.append("missing lut object")
    else:
        if lut.get("contract") != LUT_CONTRACT:
            errors.append("lut.contract must be %r, got %r" % (LUT_CONTRACT, lut.get("contract")))
        if lut.get("channels") != LUT_CHANNELS:
            errors.append("lut.channels must be %r, got %r" % (LUT_CHANNELS, lut.get("channels")))
        if lut.get("resolution") != LUT_RESOLUTION:
            errors.append("lut.resolution must be %r, got %r" % (LUT_RESOLUTION, lut.get("resolution")))

    configuration = payload.get("configuration")
    if not isinstance(configuration, dict):
        errors.append("missing configuration object")
    elif expected is not None:
        # The configuration must record exactly the CLI arguments this run
        # passed: grid, phi-grid, beta_m, cuticle, eta, albedo.
        for key, want in (("grid_theta", expected["grid"]),
                          ("grid_phi", expected["phi_grid"]),
                          ("beta_m", expected["beta_m"]),
                          ("cuticle_tilt_radians", expected["cuticle"]),
                          ("eta", expected["eta"])):
            got = configuration.get(key)
            if not _is_number(got) or not _close(got, want):
                errors.append("configuration.%s must be %r (CLI), got %r" % (key, want, got))
        albedo = configuration.get("albedo")
        want_albedo = list(expected["albedo"])
        if not isinstance(albedo, list) or len(albedo) != len(want_albedo) \
                or not all(_is_number(a) and _close(a, w) for a, w in zip(albedo, want_albedo)):
            errors.append("configuration.albedo must be %r (CLI), got %r" % (want_albedo, albedo))

    aggregate = payload.get("aggregate")
    expected_count = None
    if expected is not None:
        expected_count = expected["grid"] * expected["phi_grid"] * len(THETA_I_DEG)
    if not isinstance(aggregate, dict):
        errors.append("missing aggregate object")
    else:
        for key in ("direct_total", "linear_total", "log_total"):
            value = aggregate.get(key)
            if not _is_number(value) or not math.isfinite(value):
                errors.append("aggregate.%s must be a finite number" % key)
        if aggregate.get("totals_finite") is not True:
            errors.append("aggregate.totals_finite must be true")
        for decoder in ("linear", "log"):
            entry = aggregate.get(decoder)
            if not isinstance(entry, dict):
                errors.append("aggregate.%s must be an object" % decoder)
                continue
            for key in ("absolute_error", "relative_error",
                        "rms_absolute_error", "rms_relative_error"):
                value = entry.get(key)
                if not _is_number(value) or not math.isfinite(value):
                    errors.append("aggregate.%s.%s must be a finite number" % (decoder, key))
            sample_count = entry.get("sample_count")
            if not isinstance(sample_count, int) or isinstance(sample_count, bool) or sample_count <= 0:
                errors.append("aggregate.%s.sample_count must be a positive integer" % decoder)
            elif expected_count is not None and sample_count != expected_count:
                errors.append("aggregate.%s.sample_count must be %d (grid*phi_grid*%d), got %d"
                              % (decoder, expected_count, len(THETA_I_DEG), sample_count))

    branch = payload.get("branch_statistics")
    if not isinstance(branch, dict):
        errors.append("missing branch_statistics object")
    else:
        for key in BRANCH_KEYS:
            value = branch.get(key)
            if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                errors.append("branch_statistics.%s must be a non-negative integer" % key)
        partition_values: list[int] = []
        for key in BRANCH_PARTITION_KEYS:
            value = branch.get(key)
            if isinstance(value, int) and not isinstance(value, bool):
                partition_values.append(value)
        if len(partition_values) == len(BRANCH_PARTITION_KEYS):
            if branch.get("total") != sum(partition_values):
                errors.append("branch_statistics invariant violated: total != "
                              "lut_interior + q_beta_fallback + grazing_fallback "
                              "+ cone_pole_fallback + exact_c_phi_seam")
        asymptotic = branch.get("asymptotic_beta_branch")
        q_beta = branch.get("q_beta_fallback")
        if isinstance(asymptotic, int) and isinstance(q_beta, int) \
                and not isinstance(asymptotic, bool) and not isinstance(q_beta, bool) \
                and asymptotic > q_beta:
            errors.append("branch_statistics.asymptotic_beta_branch must be a "
                          "diagnostic sub-count of q_beta_fallback")

    per_theta_i = payload.get("per_theta_i")
    if not isinstance(per_theta_i, list) or len(per_theta_i) != len(THETA_I_DEG):
        errors.append("per_theta_i must be a list of %d entries" % len(THETA_I_DEG))
    else:
        for index, entry in enumerate(per_theta_i):
            label = "per_theta_i[%d]" % index
            if not isinstance(entry, dict):
                errors.append("%s must be an object" % label)
                continue
            theta_deg = entry.get("theta_i_deg")
            if not _is_number(theta_deg) or int(theta_deg) != THETA_I_DEG[index]:
                errors.append("%s.theta_i_deg must be %d" % (label, THETA_I_DEG[index]))
            for key in ("direct", "linear", "log"):
                value = entry.get(key)
                if not _is_number(value) or not math.isfinite(value):
                    errors.append("%s.%s must be a finite number" % (label, key))
            if entry.get("totals_finite") is not True:
                errors.append("%s.totals_finite must be true" % label)
            for errkey in ("linear_error", "log_error"):
                err = entry.get(errkey)
                if not isinstance(err, dict):
                    errors.append("%s.%s must be an object" % (label, errkey))
                    continue
                for key in ("absolute_error", "relative_error"):
                    value = err.get(key)
                    if not _is_number(value) or not math.isfinite(value):
                        errors.append("%s.%s.%s must be a finite number" % (label, errkey, key))

    # Report-only diagnostics: structural checks only, never a value gate.
    diagnostics = payload.get("diagnostics")
    if not isinstance(diagnostics, dict):
        errors.append("missing diagnostics object (report-only, no acceptance gate)")
    else:
        renormalized = diagnostics.get("support_renormalized")
        if not isinstance(renormalized, dict):
            errors.append("diagnostics.support_renormalized must be an object")
        else:
            samples = renormalized.get("samples")
            if not isinstance(samples, int) or isinstance(samples, bool) or samples < 0:
                errors.append("diagnostics.support_renormalized.samples must be a non-negative integer")
            elif isinstance(branch, dict) and isinstance(branch.get("lut_interior"), int):
                # The interior subset is exactly the lut_interior bucket.
                if samples != branch["lut_interior"]:
                    errors.append("diagnostics.support_renormalized.samples must equal "
                                  "branch_statistics.lut_interior")
        probe = diagnostics.get("asymptotic_branch_probe")
        if not isinstance(probe, dict):
            errors.append("diagnostics.asymptotic_branch_probe must be an object")
        elif not isinstance(probe.get("probes"), list) or len(probe["probes"]) != 4:
            errors.append("diagnostics.asymptotic_branch_probe.probes must be a 4-entry list")
        fallback = diagnostics.get("direct_fallback")
        if not isinstance(fallback, dict):
            errors.append("diagnostics.direct_fallback must be an object")
        else:
            samples = fallback.get("samples")
            if not isinstance(samples, int) or isinstance(samples, bool) or samples < 0:
                errors.append("diagnostics.direct_fallback.samples must be a non-negative integer")
            counts = fallback.get("branch_counts")
            if not isinstance(counts, dict) or not all(
                    isinstance(counts.get(key), int) and not isinstance(counts.get(key), bool)
                    for key in ("q_beta_fallback", "grazing_fallback",
                                "cone_pole_fallback", "exact_c_phi_seam")):
                errors.append("diagnostics.direct_fallback.branch_counts must hold "
                              "non-negative integers for the four fallback buckets")
            elif all(isinstance(counts.get(key), int) for key in ("q_beta_fallback",
                                                                  "grazing_fallback",
                                                                  "cone_pole_fallback",
                                                                  "exact_c_phi_seam")):
                if samples != sum(counts[key] for key in ("q_beta_fallback",
                                                          "grazing_fallback",
                                                          "cone_pole_fallback",
                                                          "exact_c_phi_seam")):
                    errors.append("diagnostics.direct_fallback.samples must equal the "
                                  "sum of its branch_counts")
    return errors


def _run_case(args, case, index):
    """Run one validator case through Windows Godot; die with a useful
    stderr message on any failure. Returns the validated validator payload."""
    sys.stderr.write(
        "run_marschner_r_standardized_matrix: case %d/%d %s (grid=%d, phi-grid=%d)\n"
        % (index, len(CASES), case["name"], args.grid, args.phi_grid))
    user_args = [
        "--grid=%d" % args.grid,
        "--phi-grid=%d" % args.phi_grid,
        "--beta-m=%s" % _fmt(case["beta_m"]),
        "--cuticle=%s" % _fmt(case["cuticle"]),
        "--eta=%s" % _fmt(case["eta"]),
        "--albedo=%s" % ",".join(_fmt(a) for a in case["albedo"]),
        "--contract=report",
    ]
    # beta_n is intentionally absent: metadata only, the validator has no
    # beta_n argument (R has no longitudinal width) and would reject it.
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
        _die("case %s: validator did not finish within %g seconds (grid=%d, phi-grid=%d)"
             % (case["name"], CASE_TIMEOUT_SECONDS, args.grid, args.phi_grid))
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
        _die("case %s: no JSON payload with schema %r found in validator stdout\n"
             "--- stdout tail ---\n%s\n--- stderr tail ---\n%s"
             % (case["name"], PAYLOAD_SCHEMA,
                _tail(completed.stdout), _tail(completed.stderr)))
    violations = _validate_payload(payload, {
        "grid": args.grid,
        "phi_grid": args.phi_grid,
        "beta_m": case["beta_m"],
        "cuticle": case["cuticle"],
        "eta": case["eta"],
        "albedo": case["albedo"],
    })
    if violations:
        _die("case %s: validator payload violates the report contract:\n  %s"
             % (case["name"], "\n  ".join(violations)))
    return payload


def _build_case_record(case, payload):
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
        "aggregate": _sanitize(payload["aggregate"]),
        "per_theta_i": _sanitize(payload["per_theta_i"]),
        "branch_statistics": _sanitize(payload["branch_statistics"]),
        "diagnostics": _sanitize(payload.get("diagnostics", {})),
    }


def _build_summary(records):
    """Deterministic matrix-level summary: worst absolute/relative aggregate
    errors over both decoders and all cases, plus summed branch counts."""
    worst: dict[str, dict[str, float | str | None]] = {
        "absolute": {"value": None, "case": None, "decoder": None},
        "relative": {"value": None, "case": None, "decoder": None},
    }
    per_decoder: dict[str, dict[str, dict[str, float | str | None]]] = {
        decoder: {
            "absolute": {"value": None, "case": None},
            "relative": {"value": None, "case": None},
        }
        for decoder in ("linear", "log")
    }
    summed = {key: 0 for key in BRANCH_KEYS}
    for record in records:
        branch = record["branch_statistics"]
        for key in BRANCH_KEYS:
            value = branch.get(key)
            if value is not None:
                summed[key] += value
        for decoder in ("linear", "log"):
            entry = record["aggregate"].get(decoder)
            if not isinstance(entry, dict):
                continue
            for metric, key in (("absolute", "absolute_error"),
                                ("relative", "relative_error")):
                value = entry.get(key)
                if value is None or not math.isfinite(value):
                    continue
                decoder_best = per_decoder[decoder][metric]
                if decoder_best["value"] is None or value > decoder_best["value"]:
                    decoder_best["value"] = value
                    decoder_best["case"] = record["name"]
                overall = worst[metric]
                if overall["value"] is None or value > overall["value"]:
                    overall["value"] = value
                    overall["case"] = record["name"]
                    overall["decoder"] = decoder
    return {
        "worst_absolute_error": worst["absolute"],
        "worst_relative_error": worst["relative"],
        "per_decoder": {
            decoder: {
                "worst_absolute_error": per_decoder[decoder]["absolute"],
                "worst_relative_error": per_decoder[decoder]["relative"],
            }
            for decoder in ("linear", "log")
        },
        "summed_branch_statistics": summed,
    }


def _positive_int(text):
    value = int(text)
    if value <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer, got %r" % text)
    return value


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Run the standardized Marschner R energy validator matrix "
                    "through Windows Godot (never the Linux binary) and emit "
                    "a JSON report.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    parser.add_argument("--godot", default=GODOT_DEFAULT,
                        help="Windows Godot executable (godot.exe)")
    parser.add_argument("--project", default=PROJECT_DEFAULT,
                        help="Godot project path")
    parser.add_argument("--grid", type=_positive_int, default=GRID_DEFAULT,
                        help="theta_o quadrature cells per axis")
    parser.add_argument("--phi-grid", type=_positive_int, default=PHI_GRID_DEFAULT,
                        help="phi quadrature cells per axis")
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

    # The Phase 3 matrix is exactly the 12 designed cases, in order.
    expected_names = [case["name"] for case in CASES]
    actual_names = [record["name"] for record in records]
    if len(expected_names) != 12:
        _die("case matrix must contain exactly 12 designed cases, got %d" % len(expected_names))
    if actual_names != expected_names:
        _die("case records must be exactly %r in order, got %r" % (expected_names, actual_names))

    summary = _build_summary(records)
    report = {
        "schema": MATRIX_SCHEMA,
        "tool": "run_marschner_r_standardized_matrix",
        "grid": args.grid,
        "phi_grid": args.phi_grid,
        "raw_m_unit_normalization_gate": False,
        "case_count": len(records),
        "cases": records,
        "aggregate": summary,
        "summary": summary,
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
