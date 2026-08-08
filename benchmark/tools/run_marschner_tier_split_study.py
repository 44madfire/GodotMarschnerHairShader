#!/usr/bin/env python3
"""Generate and validate the production Marschner Fast/Cinematic tier split.

Default flow:
  1. Generate Unity HDRP-style 64^3 RGBA16F azimuthal N LUT.
  2. Validate Unity LUT texel-center parity with HDRP's compute generator and
     report off-grid continuous-integral error as approximation characterization.
  3. Generate the 128x128x64 R16F physical-domain Cinematic longitudinal LUT.
  4. Validate the generic longitudinal LUT off-grid and by projected integrals.
  5. Validate production profile selection, uniform reflection, and LUT binding.
  6. Report complete Cinematic R/TT/TRT energy against the analytic baseline.
  7. Run the non-headless GPU comparison unless --skip-runtime is supplied.

The default production dimensions are intentionally fixed here because the
runtime adapter binds those exact resource paths. Resolution sweeps should run
the generators/validators directly rather than silently benchmarking a stale
runtime resource.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

DEFAULT_GODOT = "/mnt/c/Tools/Godot/godot.exe"
DEFAULT_PROJECT = "//wsl.localhost/Ubuntu/home/jeffreymwang/godot-hair-shader"

UNITY_GENERATOR = "res://benchmark/tools/generate_unity_hair_azimuthal_lut.gd"
UNITY_VALIDATOR = "res://benchmark/tools/validate_unity_hair_azimuthal_lut.gd"
CINEMATIC_GENERATOR = "res://benchmark/tools/generate_marschner_cinematic_longitudinal_lut.gd"
CINEMATIC_VALIDATOR = "res://benchmark/tools/validate_marschner_cinematic_longitudinal_lut.gd"
PRODUCTION_PROFILE_TEST = "res://benchmark/tests/test_marschner_production_profile.gd"
CINEMATIC_ENERGY = "res://benchmark/tools/validate_marschner_cinematic_energy.gd"
RUNTIME_BENCHMARK = "res://benchmark/tools/benchmark_marschner_tier_split_runtime.gd"
TIMEOUT = 7200.0


def die(message: str) -> "NoReturn":
    print(f"run_marschner_tier_split_study: error: {message}", file=sys.stderr)
    raise SystemExit(1)


def run_godot(godot: str, project: str, script: str, *, headless: bool, user_args: list[str] | None = None) -> str:
    cmd = [godot]
    if headless:
        cmd.append("--headless")
    cmd += ["--path", project, "--script", script]
    if user_args:
        cmd += ["--", *user_args]
    print("+ " + " ".join(cmd), file=sys.stderr, flush=True)
    completed = subprocess.run(
        cmd,
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
        check=False,
        timeout=TIMEOUT,
    )
    if completed.stdout:
        print(completed.stdout, end="")
    if completed.stderr:
        print(completed.stderr, file=sys.stderr, end="")
    if completed.returncode != 0:
        die(f"{script} failed with exit code {completed.returncode}")
    return completed.stdout


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
            obj, end = decoder.raw_decode(stdout, index)
        except json.JSONDecodeError:
            index += 1
            continue
        if isinstance(obj, dict) and obj.get("schema") == schema:
            found = obj
        index = end
    return found


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", default=DEFAULT_GODOT)
    parser.add_argument("--project", default=DEFAULT_PROJECT)
    parser.add_argument("--skip-generate", action="store_true", help="reuse the fixed default LUT resources")
    parser.add_argument("--skip-runtime", action="store_true", help="run CPU generation/validation and profile wiring only")
    parser.add_argument("--out", type=Path, default=Path("benchmark/results/marschner_tier_split_study.json"))
    args = parser.parse_args()

    if not os.path.exists(args.godot):
        die(f"Godot executable not found: {args.godot}")
    if not os.path.basename(args.godot).lower().endswith(".exe"):
        die("this runner expects the Windows Godot executable")

    if not args.skip_generate:
        run_godot(args.godot, args.project, UNITY_GENERATOR, headless=True, user_args=["--size=64"])
    unity_stdout = run_godot(args.godot, args.project, UNITY_VALIDATOR, headless=True)

    if not args.skip_generate:
        run_godot(args.godot, args.project, CINEMATIC_GENERATOR, headless=True, user_args=["--size=128x128x64"])
    cinematic_stdout = run_godot(args.godot, args.project, CINEMATIC_VALIDATOR, headless=True)

    run_godot(args.godot, args.project, PRODUCTION_PROFILE_TEST, headless=True)
    cinematic_energy_stdout = run_godot(
        args.godot,
        args.project,
        CINEMATIC_ENERGY,
        headless=True,
        user_args=["--grid=128", "--phi-grid=96", "--contract=report"],
    )

    runtime_stdout = ""
    if not args.skip_runtime:
        runtime_stdout = run_godot(args.godot, args.project, RUNTIME_BENCHMARK, headless=False)

    payload = {
        "schema": "marschner_tier_split_study_v1",
        "configuration": {
            "unity_size": 64,
            "unity_validation_oracle": "texel_center_parity_with_unity_compute_generator",
            "unity_off_grid_error": "characterization_only",
            "cinematic_size": "128x128x64",
            "cinematic_format": "R16F",
            "production_profile_wiring": "passed",
            "runtime_executed": not args.skip_runtime,
        },
        "unity_azimuthal_validation": extract_json(unity_stdout, "unity_hair_azimuthal_lut_validation_v1"),
        "cinematic_longitudinal_validation": extract_json(cinematic_stdout, "marschner_cinematic_longitudinal_lut_validation_v1"),
        "cinematic_complete_energy": extract_json(cinematic_energy_stdout, "marschner_cinematic_complete_energy_v1"),
        "runtime": extract_json(runtime_stdout, "marschner_tier_split_runtime_v1") if runtime_stdout else None,
        "expected_artifacts": {
            "unity_azimuthal": "benchmark/resources/luts/unity_azimuthal_64.res",
            "cinematic_longitudinal": "benchmark/resources/luts/cinematic_longitudinal_kernel_128x128x64.res",
        },
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    print(f"wrote {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
