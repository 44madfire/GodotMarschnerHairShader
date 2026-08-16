#!/usr/bin/env python3
"""Generate looping GIF previews for the PR13 demo media.

Captures fixed-wetness full-orbit state clips (Approx / Kajiya-Kay, Fast
Marschner, and Cinematic Marschner at wetness 0.00 / 0.33 / 0.67 / 1.00) with
Godot Movie Maker mode and converts each clip individually to a looping GIF
under docs/images/ using ffmpeg palettegen/paletteuse.

Each wetness GIF is a full 6-second seamless orbit (the same duration as one
quality-tier segment), not a crop from the changing-wetness ramp video. Every
tier/wetness combination is an individual GIF; the wetness README matrix lays
them out as one GIF per cell with no side-by-side stacking. The quality-tier
GIFs are split from the calibrated quality-tiers.mp4 release clip and are
retained as-is; this script only (re)generates the wetness-state GIFs.

The generated media depicts the CC BY-NC 4.0 demo groom. It is release media,
not part of the MIT-only addon package.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import json
import math
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
from typing import Iterator

SCENE = "res://demos/HairReleaseCapture.tscn"
MOVIE_MARKER = "HAIR_RELEASE_CAPTURE_OK"
MEDIA_LICENSE = "CC BY-NC 4.0 (video depicts the CT2Hair/GodotHair demo groom)"

WETNESS_VALUES = (0.00, 0.33, 0.67, 1.00)
# One individual GIF per tier at every fixed wetness state.
TIERS = ("approx", "fast", "cinematic")
# Wetness code embedded in the GIF file name: 0.00 -> 000, 1.00 -> 100.
WETNESS_CODE = {0.00: "000", 0.33: "033", 0.67: "067", 1.00: "100"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot", help="Godot 4.7 editor executable")
    parser.add_argument("--project", default=".", help="Godot project root")
    parser.add_argument(
        "--output",
        default="docs/images",
        help="GIF output directory, relative to the project unless absolute",
    )
    parser.add_argument(
        "--work",
        default="benchmark/results/release_media/state",
        help="Temporary OGV work directory, relative to the project unless absolute",
    )
    parser.add_argument("--fps", type=int, default=60, help="Godot MovieWriter capture fps")
    parser.add_argument("--width", type=int, default=1920)
    parser.add_argument("--height", type=int, default=1080)
    parser.add_argument("--gif-fps", type=int, default=15, help="GIF frame rate")
    parser.add_argument("--gif-width", type=int, default=480, help="Individual GIF width")
    parser.add_argument("--gif-height", type=int, default=270, help="Individual GIF height")
    parser.add_argument("--ffmpeg", default="ffmpeg", help="ffmpeg executable")
    parser.add_argument("--ffprobe", default="ffprobe", help="ffprobe executable")
    parser.add_argument("--keep-intermediate", action="store_true", help="Keep state OGVs after GIF conversion")
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
    Windows .exe; ffmpeg/ffprobe keep the POSIX path.
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
    """Temporarily configure a high-resolution Movie Maker viewport."""
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


def capture_state_clip(
    godot: str,
    project: Path,
    work_dir: Path,
    tier: str,
    wetness: float,
    fps: int,
    width: int,
    height: int,
) -> Path:
    raw_path = work_dir / f"state-{tier}-{wetness:.2f}.ogv"
    raw_path.unlink(missing_ok=True)

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
        str(fps),
        "--resolution",
        f"{width}x{height}",
        "--disable-vsync",
        "--",
        "--capture=wetness_state",
        f"--tier={tier}",
        f"--wetness={wetness:.2f}",
    ]
    run_streamed(godot_command, MOVIE_MARKER)
    if not raw_path.is_file() or raw_path.stat().st_size == 0:
        raise RuntimeError(f"MovieWriter did not produce {raw_path}")
    return raw_path


def convert_to_gif(
    ffmpeg: str,
    source_path: Path,
    gif_path: Path,
    gif_fps: int,
    gif_width: int,
    gif_height: int,
) -> None:
    palette_path = gif_path.with_suffix(".palette.png")
    scale = f"scale={gif_width}:{gif_height}:flags=lanczos"

    # Pass 1: derive a palette from the individual clip.
    palette_command = [
        ffmpeg,
        "-y",
        "-i",
        str(source_path),
        "-filter_complex",
        f"fps={gif_fps},{scale},palettegen=stats_mode=diff",
        str(palette_path),
    ]
    run_streamed(palette_command)

    # Pass 2: apply the palette. The GIF muxer writes an infinite-loop
    # NETSCAPE extension by default.
    gif_command = [
        ffmpeg,
        "-y",
        "-i",
        str(source_path),
        "-i",
        str(palette_path),
        "-filter_complex",
        f"fps={gif_fps},{scale}[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle",
        str(gif_path),
    ]
    run_streamed(gif_command)
    palette_path.unlink(missing_ok=True)


def ratio_to_float(value: str) -> float:
    numerator, separator, denominator = value.partition("/")
    if not separator:
        return float(value)
    return float(numerator) / float(denominator)


def probe_gif(
    ffprobe: str,
    path: Path,
    expected_width: int,
    expected_height: int,
    expected_fps: int,
    expected_frames: int,
) -> dict:
    command = [
        ffprobe,
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=width,height,r_frame_rate,nb_frames:format=duration",
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
    actual_frames = int(stream.get("nb_frames", 0))
    actual_duration = float(payload["format"]["duration"])

    if (actual_width, actual_height) != (expected_width, expected_height):
        raise RuntimeError(
            f"{path.name}: got {actual_width}x{actual_height}, expected {expected_width}x{expected_height}"
        )
    if not math.isclose(actual_fps, float(expected_fps), rel_tol=0.0, abs_tol=0.02):
        raise RuntimeError(f"{path.name}: got {actual_fps:.3f} fps, expected {expected_fps}")
    if actual_frames != expected_frames:
        raise RuntimeError(f"{path.name}: got {actual_frames} frames, expected {expected_frames}")
    if not math.isclose(actual_duration, expected_frames / expected_fps, rel_tol=0.0, abs_tol=0.20):
        raise RuntimeError(
            f"{path.name}: got {actual_duration:.3f}s, expected about {expected_frames / expected_fps:.3f}s"
        )

    return {
        "width": actual_width,
        "height": actual_height,
        "fps": actual_fps,
        "frames": actual_frames,
        "duration": actual_duration,
    }


def check_infinite_loop(path: Path) -> bool:
    """Return True when the GIF carries an infinite-loop NETSCAPE extension."""
    data = path.read_bytes()
    index = data.find(b"NETSCAPE2.0")
    if index < 0:
        return False
    # After "NETSCAPE2.0": sub-block size, loop indicator, loop count (LE), terminator.
    loop = int.from_bytes(data[index + 13 : index + 15], "little")
    return loop == 0


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

    work_dir = Path(args.work)
    if not work_dir.is_absolute():
        work_dir = project / work_dir
    work_dir.mkdir(parents=True, exist_ok=True)

    ffmpeg = resolve_executable(args.ffmpeg)
    try:
        ffprobe = resolve_executable(args.ffprobe)
    except FileNotFoundError:
        print("warning: ffprobe not found; GIF metadata verification will be skipped", file=sys.stderr)
        ffprobe = None

    manifest = {
        "scene": SCENE,
        "license": MEDIA_LICENSE,
        "capture_fps": args.fps,
        "capture_resolution": [args.width, args.height],
        "gif_fps": args.gif_fps,
        "gif_resolution": [args.gif_width, args.gif_height],
        "wetness_values": list(WETNESS_VALUES),
        "tiers": list(TIERS),
        "gifs": [],
    }

    with movie_viewport_override(project, args.width, args.height):
        clips: dict[tuple[str, float], Path] = {}
        for tier in TIERS:
            for wetness in WETNESS_VALUES:
                clips[(tier, wetness)] = capture_state_clip(
                    godot, project, work_dir, tier, wetness, args.fps, args.width, args.height
                )

    for tier in TIERS:
        for wetness in WETNESS_VALUES:
            source_path = clips[(tier, wetness)]
            wetness_code = WETNESS_CODE[wetness]
            gif_name = f"demo-video-wetness-{tier}-{wetness_code}.gif"
            gif_path = output / gif_name
            convert_to_gif(ffmpeg, source_path, gif_path, args.gif_fps, args.gif_width, args.gif_height)

            if gif_path.stat().st_size > 10 * 1024 * 1024:
                raise RuntimeError(f"{gif_name}: {gif_path.stat().st_size} bytes exceeds the 10 MB limit")

            probe = None
            if ffprobe is not None:
                probe = probe_gif(
                    ffprobe,
                    gif_path,
                    args.gif_width,
                    args.gif_height,
                    args.gif_fps,
                    int(args.gif_fps * 6.0),
                )
            if not check_infinite_loop(gif_path):
                raise RuntimeError(f"{gif_name}: missing infinite-loop NETSCAPE extension")

            manifest["gifs"].append(
                {
                    "file": gif_name,
                    "tier": tier,
                    "wetness": wetness,
                    "size_bytes": gif_path.stat().st_size,
                    "probe": probe,
                    "infinite_loop": True,
                }
            )

    if not args.keep_intermediate:
        for path in clips.values():
            path.unlink(missing_ok=True)

    manifest_path = work_dir / "release_gifs_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {manifest_path}")
    print("RELEASE_GIFS_OK")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FileNotFoundError, RuntimeError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"RELEASE_GIFS_FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1)
