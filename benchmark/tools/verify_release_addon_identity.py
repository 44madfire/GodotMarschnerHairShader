#!/usr/bin/env python3
"""Verify that a demo package embeds the exact standalone addon tree."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import sys


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("standalone_addon", help="Path to the validated standalone addons/marschner_hair directory")
    parser.add_argument("demo_addon", help="Path to the demo package addons/marschner_hair directory")
    return parser.parse_args()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def tree_manifest(root: Path) -> dict[str, tuple[int, str]]:
    if not root.is_dir():
        raise FileNotFoundError(root)
    result: dict[str, tuple[int, str]] = {}
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(root).as_posix()
        result[relative] = (path.stat().st_size, sha256(path))
    return result


def main() -> int:
    args = parse_args()
    standalone = Path(args.standalone_addon).resolve()
    demo = Path(args.demo_addon).resolve()

    standalone_manifest = tree_manifest(standalone)
    demo_manifest = tree_manifest(demo)

    standalone_paths = set(standalone_manifest)
    demo_paths = set(demo_manifest)
    missing = sorted(standalone_paths - demo_paths)
    extra = sorted(demo_paths - standalone_paths)
    changed = sorted(
        path
        for path in standalone_paths & demo_paths
        if standalone_manifest[path] != demo_manifest[path]
    )

    if missing or extra or changed:
        if missing:
            print("Missing from demo addon:", file=sys.stderr)
            for path in missing:
                print(f"  {path}", file=sys.stderr)
        if extra:
            print("Extra in demo addon:", file=sys.stderr)
            for path in extra:
                print(f"  {path}", file=sys.stderr)
        if changed:
            print("Content differs:", file=sys.stderr)
            for path in changed:
                print(f"  {path}", file=sys.stderr)
        print("RELEASE_ADDON_IDENTITY_FAILED", file=sys.stderr)
        return 1

    print(f"Compared {len(standalone_manifest)} files")
    print("RELEASE_ADDON_IDENTITY_OK")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except FileNotFoundError as exc:
        print(f"RELEASE_ADDON_IDENTITY_FAILED: directory not found: {exc}", file=sys.stderr)
        raise SystemExit(1)
