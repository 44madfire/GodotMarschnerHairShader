#!/usr/bin/env python3
"""Run the ImageTexture3D serialization probe in separate Godot processes."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

SCRIPT = "res://benchmark/tests/test_imagetexture3d_persistence.gd"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Verify that ImageTexture3D survives ResourceSaver/ResourceLoader "
            "round trips in both .res and .tres formats."
        )
    )
    parser.add_argument("--godot", default="godot", help="Godot executable path")
    parser.add_argument("--project", default=".", help="Project root passed to --path")
    parser.add_argument(
        "--headless",
        action="store_true",
        help="Run the probe with Godot's headless display driver as an additional compatibility check",
    )
    return parser.parse_args()


def run_phase(args: argparse.Namespace, phase: str) -> int:
    command = [args.godot]
    if args.headless:
        command.append("--headless")
    command.extend([
        "--path",
        str(Path(args.project)),
        "--script",
        SCRIPT,
        "--",
        phase,
    ])

    print("+", " ".join(command), flush=True)
    completed = subprocess.run(command, text=True, capture_output=True)
    if completed.stdout:
        print(completed.stdout, end="")
    if completed.stderr:
        print(completed.stderr, end="", file=sys.stderr)
    return completed.returncode


def main() -> int:
    args = parse_args()

    write_code = run_phase(args, "--write")
    if write_code != 0:
        run_phase(args, "--cleanup")
        return write_code

    verify_code = run_phase(args, "--verify")
    cleanup_code = run_phase(args, "--cleanup")

    if verify_code != 0:
        return verify_code
    if cleanup_code != 0:
        return cleanup_code

    print("IMAGE_TEXTURE_3D_PERSISTENCE_ROUNDTRIP_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
