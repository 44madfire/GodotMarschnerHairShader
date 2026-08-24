#!/usr/bin/env bash
# Build the five composite H.264 MP4 previews from the aligned demo GIFs.
#
# Each composite is a horizontal 3-panel strip (Approx | Fast Marschner |
# Cinematic Marschner) at 480x270 per panel -> 1440x270 total, preserving the
# exact 6-second / 15 fps timing of the source GIFs.
#
# Outputs (written next to this script):
#   demo-video-quality-composite.mp4
#   demo-video-wetness-000-composite.mp4
#   demo-video-wetness-033-composite.mp4
#   demo-video-wetness-067-composite.mp4
#   demo-video-wetness-100-composite.mp4
#
# Source GIFs are read-only inputs and are never modified.
#
# Usage: bash docs/images/make_composite_mp4s.sh
set -euo pipefail

cd "$(dirname "$0")"

# CRF 18 keeps the composites visually lossless for preview purposes while
# staying small enough to host in the repository.
CRF=18
PRESET=medium

build_composite() {
    local approx="$1" fast="$2" cinematic="$3" output="$4"
    ffmpeg -y -loglevel error \
        -i "$approx" \
        -i "$fast" \
        -i "$cinematic" \
        -filter_complex "[0:v][1:v][2:v]hstack=inputs=3,format=yuv420p[v]" \
        -map "[v]" \
        -c:v libx264 -preset "$PRESET" -crf "$CRF" \
        -r 15 -t 6 \
        -movflags +faststart \
        "$output"
    echo "built $output"
}

build_composite \
    demo-video-approx.gif \
    demo-video-fast.gif \
    demo-video-cinematic.gif \
    demo-video-quality-composite.mp4

for wetness in 000 033 067 100; do
    build_composite \
        "demo-video-wetness-approx-${wetness}.gif" \
        "demo-video-wetness-fast-${wetness}.gif" \
        "demo-video-wetness-cinematic-${wetness}.gif" \
        "demo-video-wetness-${wetness}-composite.mp4"
done