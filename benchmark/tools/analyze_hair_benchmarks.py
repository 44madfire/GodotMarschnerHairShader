#!/usr/bin/env python3
"""Cross-run analysis for the Godot hair benchmark harness.

Standard-library-only. Discovers run/suite artifacts under one or more
directories, validates them, groups comparable cases, computes per-case
statistics and the plan's derived delta/ratio fields, and emits deterministic
JSON + CSV reports plus a human-readable stdout summary.

Usage:
  python3 benchmark/tools/analyze_hair_benchmarks.py DIR [DIR ...] [--out DIR]
  python3 benchmark/tools/analyze_hair_benchmarks.py --check

The tool only writes inside the directory given with --out (created if
missing); without --out it writes nothing and prints to stdout only.
"""

import argparse
import csv
import json
import math
import os
import sys

SCHEMA_VERSION = 1
VALIDITY_MARKER = "material_override_precedence_repair_v1"
REQUIRED_METRICS = ["cpu_ms", "gpu_ms"]
REQUIRED_STAT_KEYS = ["median", "mean", "p95", "p99"]
COUNTER_METRICS = [
    "visible_objects",
    "visible_primitives",
    "visible_draw_calls",
    "shadow_objects",
    "shadow_primitives",
    "shadow_draw_calls",
]
VARIANTS = {
    0: "NO_HAIR",
    1: "COVERAGE_CONTROL",
    2: "CURRENT_MARSCHNER_BASELINE",
    3: "APPROX_KAJIYA_KAY",
    4: "BUILTIN_ALPHA_HASH_CONTROL",
    5: "FAST_MARSCHNER_ANALYTIC",
    6: "FAST_MARSCHNER_LUT",
    7: "FAST_MARSCHNER_DUAL_SCATTER",
    8: "FAST_MARSCHNER_ENVIRONMENT",
}
REFERENCE_VARIANTS = ["NO_HAIR", "COVERAGE_CONTROL", "CURRENT_MARSCHNER_BASELINE"]


# ---------------------------------------------------------------------------
# Pure helpers (exercised by --check with in-memory data)
# ---------------------------------------------------------------------------

def nearest_rank_percentile(values, fraction):
    """Nearest-rank percentile matching the controller's rule.

    index = ceil((n - 1) * p), clamped to [0, n - 1]; p in [0, 1].
    """
    if not values:
        return None
    ordered = sorted(values)
    index = int(math.ceil((len(ordered) - 1) * fraction))
    index = max(0, min(index, len(ordered) - 1))
    return ordered[index]


def compute_statistics(values):
    """Deterministic statistics from raw sample values.

    Returns count/median/mean/p95/p99/stddev/variance/spread (population
    standard deviation, matching the controller). None-safe for empty input.
    """
    if not values:
        return {
            "count": 0,
            "median": None,
            "mean": None,
            "p95": None,
            "p99": None,
            "stddev": None,
            "variance": None,
            "spread": None,
        }
    count = len(values)
    mean = sum(values) / count
    median = nearest_rank_percentile(values, 0.50)
    p95 = nearest_rank_percentile(values, 0.95)
    p99 = nearest_rank_percentile(values, 0.99)
    variance = 0.0
    if count >= 2:
        variance = sum((v - mean) ** 2 for v in values) / count
    return {
        "count": count,
        "median": median,
        "mean": mean,
        "p95": p95,
        "p99": p99,
        "stddev": math.sqrt(variance),
        "variance": variance,
        "spread": max(values) - min(values),
    }


def stats_from_summary(summary):
    """Extract the required per-metric statistics from a summary.json.

    Returns {metric: {median/mean/p95/p99/count/variance/stddev/spread}} or
    None when any required statistic is missing for any required metric
    (caller then falls back to raw samples.csv).
    """
    statistics = summary.get("statistics")
    if not isinstance(statistics, dict):
        return None
    result = {}
    for metric in REQUIRED_METRICS:
        metric_stats = statistics.get(metric)
        if not isinstance(metric_stats, dict):
            return None
        values = {}
        for key in REQUIRED_STAT_KEYS:
            value = metric_stats.get(key)
            if not isinstance(value, (int, float)):
                return None
            values[key] = float(value)
        values["count"] = metric_stats.get("count")
        if not isinstance(values["count"], int) or values["count"] < 0:
            values["count"] = None
        values["variance"] = _optional_float(metric_stats.get("variance"))
        values["stddev"] = _optional_float(metric_stats.get("stddev"))
        values["spread"] = _optional_float(metric_stats.get("spread"))
        result[metric] = values
    return result


def stats_from_samples(samples_path):
    """Compute the required statistics from raw samples.csv rows."""
    try:
        with open(samples_path, "r", encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return None
    if not lines:
        return None
    header = [column.strip() for column in lines[0].split(",")]
    if "cpu_ms" not in header or "gpu_ms" not in header:
        return None
    cpu_index = header.index("cpu_ms")
    gpu_index = header.index("gpu_ms")
    cpu_values = []
    gpu_values = []
    for line in lines[1:]:
        if not line.strip():
            continue
        parts = line.split(",")
        if len(parts) <= max(cpu_index, gpu_index):
            continue
        try:
            cpu_values.append(float(parts[cpu_index]))
            gpu_values.append(float(parts[gpu_index]))
        except ValueError:
            continue
    if not cpu_values:
        return None
    return {
        "cpu_ms": compute_statistics(cpu_values),
        "gpu_ms": compute_statistics(gpu_values),
    }


def _optional_float(value):
    if isinstance(value, (int, float)):
        return float(value)
    return None


def group_key_of(run):
    """Comparable-group key: groom/profile/camera/lighting/resolution."""
    return (
        run["groom"],
        run["profile"],
        run["camera"],
        run["lighting"],
        run["resolution"],
    )


def _reference_value(entries, variant_name, metric):
    for entry in entries:
        if entry["variant"] == variant_name:
            stats = entry["metrics"].get(metric)
            if stats and isinstance(stats.get("median"), (int, float)):
                return float(stats["median"])
    return None


def compute_derived(entries):
    """Mutates each entry with delta/ratio fields against reference variants
    present in the same comparable group.

    Deltas use the median of the given metric. References are never invented:
    when a reference variant is absent, the delta/ratio is None and its name is
    listed in derived.missing_references.
    """
    references = {}
    for variant_name in REFERENCE_VARIANTS:
        references[variant_name] = {
            metric: _reference_value(entries, variant_name, metric)
            for metric in REQUIRED_METRICS
        }
    for entry in entries:
        derived = {}
        missing = []
        for variant_name in REFERENCE_VARIANTS:
            for metric in REQUIRED_METRICS:
                reference = references[variant_name][metric]
                candidate = entry["metrics"].get(metric, {}).get("median")
                field = "delta_%s_vs_%s" % (metric, _field_suffix(variant_name))
                if reference is None or not isinstance(candidate, (int, float)):
                    derived[field] = None
                    if variant_name not in missing:
                        missing.append(variant_name)
                    continue
                derived[field] = round(candidate - reference, 6)
            if variant_name == "CURRENT_MARSCHNER_BASELINE":
                for metric in REQUIRED_METRICS:
                    reference = references[variant_name][metric]
                    candidate = entry["metrics"].get(metric, {}).get("median")
                    field = "%s_baseline_ratio" % metric
                    if reference is None or not isinstance(candidate, (int, float)) or reference == 0.0:
                        derived[field] = None
                        continue
                    derived[field] = round(candidate / reference, 6)
        derived["missing_references"] = missing
        entry["derived"] = derived
    return references


def _field_suffix(variant_name):
    return variant_name.lower().replace("-", "_")


def validation_result(summary):
    validation = summary.get("validation")
    if not isinstance(validation, dict):
        return {"valid": None, "notes": ["validation block not recorded in this run"]}
    notes = validation.get("validation_notes", [])
    if not isinstance(notes, list):
        notes = []
    return {
        "valid": validation.get("valid") if isinstance(validation.get("valid"), bool) else None,
        "notes": [str(note) for note in notes],
    }


# ---------------------------------------------------------------------------
# Artifact discovery and validation
# ---------------------------------------------------------------------------

def load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            parsed = json.load(handle)
    except (OSError, ValueError) as error:
        return None, "unreadable or malformed JSON: %s" % error
    if not isinstance(parsed, dict):
        return None, "not a JSON object"
    return parsed, None


def validate_run(run_manifest, summary, run_dir):
    """Returns (ok, reason). Reason is None when the run is acceptable."""
    if not run_manifest:
        return False, "run_manifest.json is missing or malformed"
    validity = run_manifest.get("comparison_validity")
    if not isinstance(validity, dict) or validity.get("marker") != VALIDITY_MARKER:
        return False, "comparison_validity.marker is not %r" % VALIDITY_MARKER
    summary_validity = summary.get("comparison_validity") if summary else None
    if isinstance(summary_validity, dict) and summary_validity.get("marker") != VALIDITY_MARKER:
        return False, "summary comparison_validity.marker is not %r" % VALIDITY_MARKER
    if not summary:
        return False, "summary.json is missing"
    sample_count = run_manifest.get("sample_count")
    if not isinstance(sample_count, int) or sample_count <= 0:
        return False, "incomplete run: sample_count is missing or zero"
    summary_stats = summary.get("statistics")
    samples_path = os.path.join(run_dir, "samples.csv")
    has_samples = os.path.isfile(samples_path)
    if not isinstance(summary_stats, dict) and not has_samples:
        return False, "incomplete run: no summary statistics and no samples.csv"
    return True, None


def discover(input_dirs):
    """Returns (runs, suites, rejected)."""
    runs = []
    suites = []
    rejected = []
    seen_run_dirs = set()

    def walk(root):
        for current, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in (".godot", ".git", "__pycache__")]
            if "run_manifest.json" in filenames:
                run_dir = os.path.realpath(current)
                if run_dir not in seen_run_dirs:
                    seen_run_dirs.add(run_dir)
                    _collect_run(run_dir, runs, rejected)
            if "suite_manifest.json" in filenames:
                _collect_suite(os.path.realpath(os.path.join(current, "suite_manifest.json")), suites, rejected)

    def _collect_run(run_dir, runs_out, rejected_out):
        manifest_path = os.path.join(run_dir, "run_manifest.json")
        summary_path = os.path.join(run_dir, "summary.json")
        run_manifest, manifest_error = load_json(manifest_path)
        summary, _summary_error = load_json(summary_path) if os.path.isfile(summary_path) else (None, None)
        if manifest_error:
            rejected_out.append({"path": manifest_path, "reason": manifest_error})
            return
        ok, reason = validate_run(run_manifest, summary, run_dir)
        if not ok:
            rejected_out.append({"path": run_dir, "reason": reason})
            return
        runs_out.append(_build_run(run_manifest, summary, run_dir))

    def _collect_suite(suite_path, suites_out, rejected_out):
        suite, error = load_json(suite_path)
        if error:
            rejected_out.append({"path": suite_path, "reason": "suite manifest: %s" % error})
            return
        assert suite is not None
        suites_out.append({
            "id": suite.get("id", "unknown"),
            "display_name": suite.get("display_name", ""),
            "completed_runs": suite.get("completed_runs"),
            "case_count": suite.get("case_count"),
            "directory": os.path.dirname(suite_path),
        })

    for input_dir in input_dirs:
        walk(input_dir)
    return runs, suites, rejected


def _build_run(run_manifest, summary, run_dir):
    """Builds the analysis entry for one accepted run."""
    camera = run_manifest.get("camera_pose")
    lighting = run_manifest.get("lighting_rig")
    viewport = run_manifest.get("viewport_size")
    if isinstance(viewport, list) and len(viewport) == 2:
        resolution = "%dx%d" % (int(viewport[0]), int(viewport[1]))
    else:
        resolution = "unknown"
    run = {
        "suite_id": run_manifest.get("suite_id", ""),
        "case_id": run_manifest.get("case_id", "unknown"),
        "case_display_name": run_manifest.get("case_display_name", ""),
        "repeat": run_manifest.get("repeat", 1),
        "directory": run_dir,
        "variant": run_manifest.get("variant", "unknown"),
        "variant_value": run_manifest.get("variant_value"),
        "mode": run_manifest.get("mode", "unknown"),
        "groom": run_manifest.get("individual_groom", "unknown"),
        "profile": run_manifest.get("profile_id", "unknown") or "unknown",
        "camera": camera.get("id", "") if isinstance(camera, dict) else "",
        "lighting": lighting.get("id", "") if isinstance(lighting, dict) else "",
        "resolution": resolution,
        "coverage_metrics": summary.get("coverage_metrics") or run_manifest.get("coverage_metrics") or {},
        "validation": validation_result(summary),
        "captures": run_manifest.get("captures", []),
        "runtime": run_manifest.get("runtime", {}),
    }
    stats = stats_from_summary(summary)
    source = "summary"
    if stats is None:
        stats = stats_from_samples(os.path.join(run_dir, "samples.csv"))
        source = "samples_fallback"
    run["metric_source"] = source
    run["metrics"] = stats if stats is not None else {}
    return run


# ---------------------------------------------------------------------------
# Report assembly
# ---------------------------------------------------------------------------

def make_report(runs, suites, rejected, input_dirs):
    """Deterministic report: sorted groups, sorted runs, sorted keys."""
    by_group = {}
    for run in runs:
        key = group_key_of(run)
        by_group.setdefault(key, []).append(run)
    groups = []
    for key in sorted(by_group):
        entries = by_group[key]
        for entry in entries:
            entry["group"] = "%s|%s|%s|%s|%s" % key
        references = compute_derived(entries)
        reference_payload = {}
        for variant_name in REFERENCE_VARIANTS:
            values = references[variant_name]
            if all(value is None for value in values.values()):
                reference_payload[variant_name] = None
            else:
                reference_payload[variant_name] = values
        groups.append({
            "key": "%s|%s|%s|%s|%s" % key,
            "groom": key[0],
            "profile": key[1],
            "camera": key[2],
            "lighting": key[3],
            "resolution": key[4],
            "references": reference_payload,
            "runs": sorted(
                entries,
                key=lambda entry: (
                    entry["variant_value"] if isinstance(entry["variant_value"], int) else 99,
                    entry["case_id"],
                    entry["repeat"],
                    entry["directory"],
                ),
            ),
        })
    rejected_sorted = sorted(rejected, key=lambda item: (item["path"], item["reason"]))
    return {
        "schema_version": SCHEMA_VERSION,
        "validity_marker": VALIDITY_MARKER,
        "inputs": [os.path.realpath(path) for path in input_dirs],
        "discovered": {
            "accepted_runs": len(runs),
            "rejected_runs": len(rejected_sorted),
            "suites": len(suites),
        },
        "suites": sorted(suites, key=lambda item: item["directory"]),
        "rejected": rejected_sorted,
        "groups": groups,
    }


CSV_COLUMNS = [
    "group", "case_id", "case_display_name", "repeat", "variant", "mode",
    "groom", "profile", "camera", "lighting", "resolution",
    "gpu_median", "gpu_mean", "gpu_p95", "gpu_p99", "gpu_variance", "gpu_spread",
    "cpu_median", "cpu_mean", "cpu_p95", "cpu_p99", "cpu_variance", "cpu_spread",
    "metric_source", "valid",
    "delta_gpu_vs_no_hair", "delta_gpu_vs_coverage", "delta_gpu_vs_baseline", "gpu_baseline_ratio",
    "delta_cpu_vs_no_hair", "delta_cpu_vs_coverage", "delta_cpu_vs_baseline", "cpu_baseline_ratio",
    "coverage_white_pct", "directory",
]


def _csv_value(value):
    if value is None:
        return ""
    if isinstance(value, float):
        return "%.6f" % value
    if isinstance(value, bool):
        return "1" if value else "0"
    return str(value)


def render_csv(report):
    rows = []
    for group in report["groups"]:
        for run in group["runs"]:
            metrics = run.get("metrics", {})
            gpu = metrics.get("gpu_ms", {})
            cpu = metrics.get("cpu_ms", {})
            coverage = run.get("coverage_metrics", {})
            derived = run.get("derived", {})
            white_pct = coverage.get("white_pixel_percentage") if isinstance(coverage, dict) else None
            rows.append({
                "group": group["key"],
                "case_id": run["case_id"],
                "case_display_name": run["case_display_name"],
                "repeat": run["repeat"],
                "variant": run["variant"],
                "mode": run["mode"],
                "groom": run["groom"],
                "profile": run["profile"],
                "camera": run["camera"],
                "lighting": run["lighting"],
                "resolution": run["resolution"],
                "gpu_median": gpu.get("median"),
                "gpu_mean": gpu.get("mean"),
                "gpu_p95": gpu.get("p95"),
                "gpu_p99": gpu.get("p99"),
                "gpu_variance": gpu.get("variance"),
                "gpu_spread": gpu.get("spread"),
                "cpu_median": cpu.get("median"),
                "cpu_mean": cpu.get("mean"),
                "cpu_p95": cpu.get("p95"),
                "cpu_p99": cpu.get("p99"),
                "cpu_variance": cpu.get("variance"),
                "cpu_spread": cpu.get("spread"),
                "metric_source": run.get("metric_source", ""),
                "valid": run.get("validation", {}).get("valid"),
                "delta_gpu_vs_no_hair": derived.get("delta_gpu_ms_vs_no_hair"),
                "delta_gpu_vs_coverage": derived.get("delta_gpu_ms_vs_coverage_control"),
                "delta_gpu_vs_baseline": derived.get("delta_gpu_ms_vs_current_marschner_baseline"),
                "gpu_baseline_ratio": derived.get("gpu_ms_baseline_ratio"),
                "delta_cpu_vs_no_hair": derived.get("delta_cpu_ms_vs_no_hair"),
                "delta_cpu_vs_coverage": derived.get("delta_cpu_ms_vs_coverage_control"),
                "delta_cpu_vs_baseline": derived.get("delta_cpu_ms_vs_current_marschner_baseline"),
                "cpu_baseline_ratio": derived.get("cpu_ms_baseline_ratio"),
                "coverage_white_pct": white_pct,
                "directory": run["directory"],
            })
    output = []
    for column in CSV_COLUMNS:
        output.append(_csv_value(rows[0][column]) if rows else "")
    return rows, output


def print_summary(report):
    print("Hair benchmark analysis")
    print("  inputs: %s" % ", ".join(report["inputs"]))
    print("  accepted runs: %d | rejected: %d | suites: %d" % (
        report["discovered"]["accepted_runs"],
        report["discovered"]["rejected_runs"],
        report["discovered"]["suites"],
    ))
    for rejected in report["rejected"]:
        print("  REJECTED %s: %s" % (rejected["path"], rejected["reason"]))
    for group in report["groups"]:
        print("\nGroup %s" % group["key"])
        references = group["references"]
        for variant_name in REFERENCE_VARIANTS:
            payload = references.get(variant_name)
            if payload:
                print("  reference %s: gpu_ms_median=%s cpu_ms_median=%s" % (
                    variant_name,
                    _fmt(payload.get("gpu_ms")),
                    _fmt(payload.get("cpu_ms")),
                ))
        for run in group["runs"]:
            gpu = run.get("metrics", {}).get("gpu_ms", {})
            cpu = run.get("metrics", {}).get("cpu_ms", {})
            derived = run.get("derived", {})
            valid = run.get("validation", {}).get("valid")
            valid_text = "valid" if valid is True else ("invalid" if valid is False else "valid=unavailable")
            print("  %-28s gpu median=%s p95=%s cpu median=%s | delta vs no_hair=%s vs coverage=%s vs baseline=%s ratio=%s | %s | %s" % (
                run["variant"],
                _fmt(gpu.get("median")),
                _fmt(gpu.get("p95")),
                _fmt(cpu.get("median")),
                _fmt(derived.get("delta_gpu_ms_vs_no_hair")),
                _fmt(derived.get("delta_gpu_ms_vs_coverage_control")),
                _fmt(derived.get("delta_gpu_ms_vs_current_marschner_baseline")),
                _fmt(derived.get("gpu_ms_baseline_ratio")),
                valid_text,
                run["metric_source"],
            ))
            for note in run.get("validation", {}).get("notes", []):
                print("    note: %s" % note)


def _fmt(value):
    if value is None:
        return "unavailable"
    return "%.3f" % value


# ---------------------------------------------------------------------------
# Self-test (fixture-free, in-memory)
# ---------------------------------------------------------------------------

def _run_check():
    failures = []

    def expect(condition, message):
        if not condition:
            failures.append(message)

    # Percentile rule matches the controller's nearest-rank behavior.
    values = [10.0, 20.0, 30.0, 40.0]
    expect(nearest_rank_percentile(values, 0.0) == 10.0, "p0 should be min")
    expect(nearest_rank_percentile(values, 1.0) == 40.0, "p100 should be max")
    expect(nearest_rank_percentile(values, 0.50) == 30.0, "median of 4 should be index ceil(1.5)=2 (0-based), matching the controller")
    expect(nearest_rank_percentile([], 0.95) is None, "empty percentile should be None")
    expect(nearest_rank_percentile([7.0], 0.95) == 7.0, "single-value percentile")

    # compute_statistics determinism and population variance.
    stats = compute_statistics([1.0, 2.0, 3.0, 4.0])
    expect(stats["mean"] == 2.5, "mean")
    expect(abs(stats["variance"] - 1.25) < 1e-12, "population variance of 1..4 is 1.25")
    expect(stats["spread"] == 3.0, "spread")
    expect(compute_statistics([])["count"] == 0, "empty statistics")

    # stats_from_summary: full quartet accepted; partial statistics rejected.
    good_summary = {"statistics": {"cpu_ms": {"median": 1.0, "mean": 1.0, "p95": 1.0, "p99": 1.0, "count": 10}, "gpu_ms": {"median": 2.0, "mean": 2.0, "p95": 2.0, "p99": 2.0, "count": 10}}}
    partial_summary = {"statistics": {"cpu_ms": {"median": 1.0, "p95": 1.0}, "gpu_ms": {"median": 2.0, "p95": 2.0}}}
    good_stats = stats_from_summary(good_summary)
    expect(good_stats is not None and good_stats["gpu_ms"]["median"] == 2.0, "summary stats extraction")
    expect(stats_from_summary(partial_summary) is None, "partial summary stats must fall back")

    # Derived math: build a comparable group in memory.
    def fake_entry(variant, gpu_median, cpu_median, case_id):
        return {
            "variant": variant,
            "variant_value": next((value for value, name in VARIANTS.items() if name == variant), 99),
            "case_id": case_id,
            "repeat": 1,
            "directory": "/fake/%s" % case_id,
            "groom": "Blowout",
            "profile": "source_current",
            "camera": "three_quarter",
            "lighting": "single_directional_key",
            "resolution": "1280x720",
            "metrics": {
                "gpu_ms": {"median": gpu_median, "mean": gpu_median, "p95": gpu_median, "p99": gpu_median, "count": 300},
                "cpu_ms": {"median": cpu_median, "mean": cpu_median, "p95": cpu_median, "p99": cpu_median, "count": 300},
            },
        }

    group = [
        fake_entry("NO_HAIR", 12.0, 0.10, "no_hair"),
        fake_entry("COVERAGE_CONTROL", 85.0, 0.15, "coverage"),
        fake_entry("CURRENT_MARSCHNER_BASELINE", 100.0, 0.18, "baseline"),
        fake_entry("BUILTIN_ALPHA_HASH_CONTROL", 90.0, 0.16, "builtin"),
    ]
    references = compute_derived(group)
    by_variant = {entry["variant"]: entry for entry in group}
    builtin = by_variant["BUILTIN_ALPHA_HASH_CONTROL"]["derived"]
    expect(builtin["delta_gpu_ms_vs_no_hair"] == 78.0, "builtin minus NO_HAIR (90-12)")
    expect(builtin["delta_gpu_ms_vs_coverage_control"] == 5.0, "builtin minus coverage (90-85)")
    expect(builtin["delta_gpu_ms_vs_current_marschner_baseline"] == -10.0, "builtin minus baseline (90-100)")
    expect(builtin["gpu_ms_baseline_ratio"] == 0.9, "builtin baseline ratio (90/100)")
    expect(builtin["missing_references"] == [], "no missing references")
    coverage_derived = by_variant["COVERAGE_CONTROL"]["derived"]
    expect(coverage_derived["delta_gpu_ms_vs_no_hair"] == 73.0, "coverage minus NO_HAIR (85-12)")
    no_hair_derived = by_variant["NO_HAIR"]["derived"]
    expect(no_hair_derived["delta_gpu_ms_vs_current_marschner_baseline"] == -88.0, "NO_HAIR minus baseline")
    expect(references["NO_HAIR"]["gpu_ms"] == 12.0, "group reference NO_HAIR")

    # Missing reference: never invent a delta.
    orphan_group = [fake_entry("BUILTIN_ALPHA_HASH_CONTROL", 90.0, 0.16, "builtin")]
    compute_derived(orphan_group)
    orphan_derived = orphan_group[0]["derived"]
    expect(orphan_derived["delta_gpu_ms_vs_no_hair"] is None, "delta must be None without NO_HAIR")
    expect(orphan_derived["gpu_ms_baseline_ratio"] is None, "ratio must be None without baseline")
    expect(sorted(orphan_derived["missing_references"]) == [
        "COVERAGE_CONTROL", "CURRENT_MARSCHNER_BASELINE", "NO_HAIR",
    ], "all three references listed as missing")

    # Validation rules: marker gate and incomplete runs.
    ok_manifest = {"comparison_validity": {"marker": VALIDITY_MARKER}, "sample_count": 300}
    bad_marker = {"comparison_validity": {"marker": "something_else"}, "sample_count": 300}
    incomplete = {"comparison_validity": {"marker": VALIDITY_MARKER}}
    ok_summary = {"statistics": {"cpu_ms": {"median": 1.0, "mean": 1.0, "p95": 1.0, "p99": 1.0}, "gpu_ms": {"median": 1.0, "mean": 1.0, "p95": 1.0, "p99": 1.0}}}
    expect(validate_run(ok_manifest, ok_summary, "/nonexistent")[0] is True, "valid run accepted")
    expect(validate_run(bad_marker, ok_summary, "/nonexistent")[0] is False, "bad marker rejected")
    expect(validate_run(incomplete, ok_summary, "/nonexistent")[0] is False, "incomplete run rejected")
    expect(validate_run(ok_manifest, None, "/nonexistent")[0] is False, "missing summary rejected")

    # Group key identity.
    run = fake_entry("NO_HAIR", 1.0, 0.1, "x")
    expect(group_key_of(run) == ("Blowout", "source_current", "three_quarter", "single_directional_key", "1280x720"), "group key composition")

    # Report determinism: same inputs produce identical JSON text.
    report_a = make_report(
        [fake_entry("BUILTIN_ALPHA_HASH_CONTROL", 90.0, 0.16, "a"), fake_entry("NO_HAIR", 12.0, 0.10, "b")],
        [], [], ["/fake/input"],
    )
    report_b = make_report(
        [fake_entry("NO_HAIR", 12.0, 0.10, "b"), fake_entry("BUILTIN_ALPHA_HASH_CONTROL", 90.0, 0.16, "a")],
        [], [], ["/fake/input"],
    )
    text_a = json.dumps(report_a, sort_keys=True, indent=2)
    text_b = json.dumps(report_b, sort_keys=True, indent=2)
    expect(text_a == text_b, "report JSON must be deterministic regardless of input order")

    if failures:
        for failure in failures:
            print("CHECK FAILED: %s" % failure)
        print("check: %d failure(s)" % len(failures))
        return 1
    print("check: OK (percentiles, statistics, fallback gating, derived math, "
          "missing-reference handling, validation rules, deterministic reports)")
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv):
    parser = argparse.ArgumentParser(description="Cross-run analysis for the Godot hair benchmark harness")
    parser.add_argument("directories", nargs="*", help="run/suite/benchmark directories to analyze")
    parser.add_argument("--out", metavar="DIR", help="output directory for report files (created if missing); without it, no files are written")
    parser.add_argument("--check", action="store_true", help="run the in-memory self-test and exit")
    arguments = parser.parse_args(argv)

    if arguments.check:
        return _run_check()

    if not arguments.directories:
        parser.error("at least one directory is required (or use --check)")

    input_dirs = [os.path.abspath(path) for path in arguments.directories]
    for input_dir in input_dirs:
        if not os.path.isdir(input_dir):
            parser.error("not a directory: %s" % input_dir)

    runs, suites, rejected = discover(input_dirs)
    report = make_report(runs, suites, rejected, input_dirs)

    if arguments.out:
        os.makedirs(arguments.out, exist_ok=True)
        json_path = os.path.join(arguments.out, "hair_benchmark_report.json")
        with open(json_path, "w", encoding="utf-8") as handle:
            json.dump(report, handle, indent=2, sort_keys=True)
            handle.write("\n")
        rows, _header = render_csv(report)
        csv_path = os.path.join(arguments.out, "hair_benchmark_report.csv")
        with open(csv_path, "w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=CSV_COLUMNS)
            writer.writeheader()
            for row in rows:
                writer.writerow({key: _csv_value(row[key]) for key in CSV_COLUMNS})
        print("wrote %s" % json_path)
        print("wrote %s" % csv_path)

    print_summary(report)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
