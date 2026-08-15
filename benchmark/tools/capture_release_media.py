#!/usr/bin/env python3
"""Record deterministic release/demo videos with Godot Movie Maker mode.

The generated media depicts the CC BY-NC 4.0 demo groom. It is release media,
not part of the MIT-only addon package.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import json
import math
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
from typing import Iterable, Iterator

CAPTURES = (
    {
        "name": "quality-tiers",
        "args": ("--capture=quality",),
        "expected_duration": 24.0,
        "description": "Approx, Fast, Cinematic, and Reference; one identical orbit per tier.",
    },
    {
        "name": "fast-wetness",
        "args": ("--capture=wetness", "--tier=fast"),
        "expected_duration": 10.0,
        "description": "Fast Marschner wetness 0 -> 1 over one full orbit.",
    },
    {
        "name": "cinematic-wetness",
        "args": ("--capture=wetness", "--tier=cinematic"),
        "expected_duration": 10.0,
        "description": "Cinematic Marschner wetness 0 -> 1 over one full orbit.",
    },
)

SCENE = "res://demos/HairReleaseCapture.tscn"
MOVIE_MARKER = "HAIR_RELEASE_CAPTURE_OK"
MEDIA_LICENSE = "CC BY-NC 4.0 (video depicts the CT2Hair/GodotHair demo groom)"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot", help="Godot 4.7 editor executable")
    parser.add_argument("--project", default=".", help="Godot project root")
    parser.add_argument(
        "--output",
        default="benchmark/results/release_media",
        help="Output directory, relative to the project unless absolute",
    )
    parser.add_argument("--fps", type=int, default=60)
    parser.add_argument("--width", type=int, default=1920)
    parser.add_argument("--height", type=int, default=1080)
    parser.add_argument(
        "--movie-format",
        choices=("ogv", "avi"),
        default="ogv",
        help="Godot MovieWriter intermediate format; OGV requires an editor build",
    )
    parser.add_argument(
        "--captures",
        default="quality-tiers,fast-wetness,cinematic-wetness",
        help="Comma-separated capture names",
    )
    parser.add_argument("--ffmpeg", default="ffmpeg", help="ffmpeg executable")
    parser.add_argument("--ffprobe", default="ffprobe", help="ffprobe executable")
    parser.add_argument("--no-mp4", action="store_true", help="Keep only Godot MovieWriter output")
    parser.add_argument("--keep-intermediate", action="store_true", help="Keep .ogv/.avi after MP4 conversion")
    parser.add_argument("--crf", type=int, default=15, help="H.264 CRF used for release MP4 conversion")
    return parser.parse_args()


def resolve_executable(value: str) -> str:
    candidate = Path(value)
    if candidate.is_file():
        return str(candidate.resolve())
    resolved = shutil.which(value)
    if resolved:
        return resolved
    raise FileNotFoundError(f"Executable not found: {value}")


def is_windows_executable(executable: str) -> bool:
    """True when the resolved executable is a Windows .exe launched from WSL/Linux."""
    return executable.lower().endswith(".exe")


def windows_native_path(path: Path) -> str:
    """Convert a POSIX path to a Windows-native path using wslpath.

    Only used for the --write-movie argument when the Godot executable is a
    Windows .exe; ffmpeg/ffprobe keep the POSIX path. Relative paths are
    returned unchanged. Absolute paths are translated (e.g. /mnt/c/... ->
    C:\\..., /home/... -> \\\\wsl$\\<distro>\\...) so the native Windows
    process can open the file.
    """
    if not path.is_absolute():
        return str(path)
    wslpath = shutil.which("wslpath")
    if wslpath is None:
        raise RuntimeError(
            "wslpath not found: cannot convert the --write-movie path "
            f"{path} to a Windows-native path for the Windows Godot executable"
        )
    completed = subprocess.run(
        [wslpath, "-w", str(path)],
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    return completed.stdout.strip()


@contextmanager
def movie_viewport_override(project: Path, width: int, height: int) -> Iterator[None]:
    """Temporarily configure a high-resolution Movie Maker viewport.

    Godot derives Movie Maker output dimensions from the viewport. The startup
    window can be clamped by the host display, so --resolution alone cannot
    reliably produce release-sized media on a smaller desktop or WSLg display.
    """
    override_path = project / "override.cfg"
    original = override_path.read_bytes() if override_path.is_file() else None
    override_path.write_text(
        "[display]\n\n"
        f"window/size/viewport_width={width}\n"
        f"window/size/viewport_height={height}\n"
        "window/size/window_width_override=0\n"
        "window/size/window_height_override=0\n"
        'window/stretch/mode="viewport"\n',
        encoding="utf-8",
    )
    try:
        yield
    finally:
        if original is None:
            override_path.unlink(missing_ok=True)
        else:
            override_path.write_bytes(original)


def run_streamed(command: list[str], expected_marker: str | None = None) -> None:
    print("+", shlex.join(command), flush=True)
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    assert process.stdout is not None
    saw_marker = expected_marker is None
    for line in process.stdout:
        print(line, end="")
        if expected_marker and expected_marker in line:
            saw_marker = True
    return_code = process.wait()
    if return_code != 0:
        raise RuntimeError(f"Command exited with status {return_code}")
    if not saw_marker:
        raise RuntimeError(f"Expected marker not found: {expected_marker}")


def convert_to_mp4(ffmpeg: str, source: Path, target: Path, crf: int) -> None:
    command = [
        ffmpeg,
        "-y",
        "-i",
        str(source),
        "-an",
        "-c:v",
        "libx264",
        "-preset",
        "slow",
        "-crf",
        str(crf),
        "-pix_fmt",
        "yuv420p",
        "-movflags",
        "+faststart",
        str(target),
    ]
    run_streamed(command)


def ratio_to_float(value: str) -> float:
    numerator, separator, denominator = value.partition("/")
    if not separator:
        return float(value)
    return float(numerator) / float(denominator)


def probe_media(ffprobe: str, path: Path, width: int, height: int, fps: int, expected_duration: float) -> dict:
    command = [
        ffprobe,
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=width,height,r_frame_rate:format=duration",
        "-of",
        "json",
        str(path),
    ]
    print("+", shlex.join(command), flush=True)
    completed = subprocess.run(command, check=True, capture_output=True, text=True)
    payload = json.loads(completed.stdout)
    stream = payload["streams"][0]
    actual_width = int(stream["width"])
    actual_height = int(stream["height"])
    actual_fps = ratio_to_float(stream["r_frame_rate"])
    actual_duration = float(payload["format"]["duration"])

    if (actual_width, actual_height) != (width, height):
        raise RuntimeError(
            f"{path.name}: got {actual_width}x{actual_height}, expected {width}x{height}"
        )
    if not math.isclose(actual_fps, float(fps), rel_tol=0.0, abs_tol=0.02):
        raise RuntimeError(f"{path.name}: got {actual_fps:.3f} fps, expected {fps}")
    if not math.isclose(actual_duration, expected_duration, rel_tol=0.0, abs_tol=0.20):
        raise RuntimeError(
            f"{path.name}: got {actual_duration:.3f}s, expected about {expected_duration:.3f}s"
        )

    return {
        "width": actual_width,
        "height": actual_height,
        "fps": actual_fps,
        "duration": actual_duration,
    }


def selected_captures(names: Iterable[str]) -> list[dict]:
    by_name = {capture["name"]: capture for capture in CAPTURES}
    selected = []
    for name in names:
        if name not in by_name:
            raise ValueError(f"Unknown capture {name!r}; expected one of {', '.join(by_name)}")
        selected.append(by_name[name])
    return selected


def main() -> int:
    args = parse_args()
    godot = resolve_executable(args.godot)
    project = Path(args.project).resolve()
    if not (project / "project.godot").is_file():
        raise FileNotFoundError(f"No project.godot under {project}")

    output = Path(args.output)
    if not output.is_absolute():
        output = project / output
    output.mkdir(parents=True, exist_ok=True)

    capture_names = [value.strip() for value in args.captures.split(",") if value.strip()]
    captures = selected_captures(capture_names)

    ffmpeg = None
    ffprobe = None
    if not args.no_mp4:
        ffmpeg = resolve_executable(args.ffmpeg)
        try:
            ffprobe = resolve_executable(args.ffprobe)
        except FileNotFoundError:
            print("warning: ffprobe not found; media metadata verification will be skipped", file=sys.stderr)

    manifest = {
        "scene": SCENE,
        "license": MEDIA_LICENSE,
        "fps": args.fps,
        "resolution": [args.width, args.height],
        "captures": [],
    }

    with movie_viewport_override(project, args.width, args.height):
        for capture in captures:
            raw_path = output / f"{capture['name']}.{args.movie_format}"
            mp4_path = output / f"{capture['name']}.mp4"
            raw_path.unlink(missing_ok=True)
            mp4_path.unlink(missing_ok=True)

            write_movie_path = str(raw_path)
            if is_windows_executable(godot):
                write_movie_path = windows_native_path(raw_path)

            godot_command = [
                godot,
                "--path",
                str(project),
                "--scene",
                SCENE,
                "--write-movie",
                write_movie_path,
                "--fixed-fps",
                str(args.fps),
                "--resolution",
                f"{args.width}x{args.height}",
                "--disable-vsync",
                "--",
                *capture["args"],
            ]
            run_streamed(godot_command, MOVIE_MARKER)
            if not raw_path.is_file() or raw_path.stat().st_size == 0:
                raise RuntimeError(f"MovieWriter did not produce {raw_path}")

            final_path = raw_path
            media_probe = None
            if ffmpeg is not None:
                convert_to_mp4(ffmpeg, raw_path, mp4_path, args.crf)
                final_path = mp4_path
                if ffprobe is not None:
                    media_probe = probe_media(
                        ffprobe,
                        mp4_path,
                        args.width,
                        args.height,
                        args.fps,
                        float(capture["expected_duration"]),
                    )
                if not args.keep_intermediate:
                    raw_path.unlink(missing_ok=True)

            manifest["captures"].append(
                {
                    "name": capture["name"],
                    "description": capture["description"],
                    "file": final_path.name,
                    "expected_duration": capture["expected_duration"],
                    "probe": media_probe,
                }
            )

    manifest_path = output / "release_media_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {manifest_path}")
    print("RELEASE_MEDIA_CAPTURE_OK")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FileNotFoundError, RuntimeError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"RELEASE_MEDIA_CAPTURE_FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1)
