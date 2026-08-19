# Release/demo media capture

Release videos are generated from the demo project after the matching addon build has passed package-level validation. The media is meant to make the three shipped shader tiers and optical wetness behavior easy to evaluate without requiring users to configure a scene first.

Because the captures visibly reproduce the supplied CT2Hair/GodotHair demo groom, **project-supplied release videos are distributed with the demo media under CC BY-NC 4.0**, not as part of the MIT-only addon package. The capture overlay includes the attribution in-frame and the release description must repeat it.

## Capture scene

Use:

```text
res://demos/HairReleaseCapture.tscn
```

The scene instances `HairMaterialProfileEditor.tscn` so the same lighting, head, groom, material profile, and groom data used for normal previewing are also used for release capture.

The deterministic orbit is based on the original GodotHair demo camera controller:

- the preview keeps the original demo camera transform;
- the original controller uses a default orbit distance of `0.45`;
- the capture controller reconstructs the same pivot from `camera_position - camera_basis_z * 0.45`;
- offline capture then rotates the initial camera offset around world up rather than depending on mouse input.

This preserves the familiar demo framing while making every tier use exactly the same camera path.

Release media uses **Static Bayer** coverage for deterministic presentation. Auto/TAA/A2C behavior is validated separately by the release tests and should not change the visual-comparison camera clips.

## Standard capture set

The current release media set contains five composite previews, each a horizontal 3-panel strip of the three quality tiers (Approx / Kajiya-Kay | Fast Marschner | Cinematic Marschner):

```text
demo-video-quality-composite.mp4     # dry, wetness 0.00
demo-video-wetness-000-composite.mp4 # wetness 0.00
demo-video-wetness-033-composite.mp4 # wetness 0.33
demo-video-wetness-067-composite.mp4 # wetness 0.67
demo-video-wetness-100-composite.mp4 # wetness 1.00
```

Every composite is 1440x270 (480x270 per panel), H.264/yuv420p, 15 fps, 90 frames, and exactly 6 seconds — one full seamless orbit. The quality composite is dry and isolates the lighting-model difference across the three tiers. The four wetness composites fix the wetness state at 0.00, 0.33, 0.67, and 1.00 so the optical response can be compared across tiers and states without a changing-wetness ramp.

Reference Marschner is intentionally omitted from release media: it remains a development/validation tier, and its analytic baseline is documented separately in the authoring and wetness docs.

## Building the composites

Each composite is assembled from three source GIFs by `docs/images/make_composite_mp4s.sh`:

```bash
bash docs/images/make_composite_mp4s.sh
```

The source GIFs are generated first by `benchmark/tools/generate_release_gifs.py`:

```bash
python benchmark/tools/generate_release_gifs.py \
  --godot /path/to/godot \
  --project .
```

The GIF runner captures one state clip per tier (approx, fast, cinematic) per fixed wetness state (0.00, 0.33, 0.67, 1.00) with Godot Movie Maker and converts each clip to a looping 480x270 GIF at 15 fps. Every wetness GIF is a full 6-second seamless orbit at its fixed state. The composite script then h-stacks the three tier GIFs and re-encodes each strip at 1440x270, 15 fps, 6 seconds (90 frames), CRF 18 H.264/yuv420p.

## In-frame labels

Every generated capture includes:

- current shader tier;
- current wetness value for wetness clips;
- `Demo groom: CT2Hair / GodotHair — CC BY-NC 4.0`.

Do not crop the attribution out of project-published media.

## Recording with Godot Movie Maker

Godot Movie Maker mode performs non-real-time recording with fixed simulation timing, which is preferable to a desktop screen recorder for shader comparisons. The capture controller exits through `SceneTree.quit()` so MovieWriter can finalize the output container cleanly.

The current workflow records state clips with Movie Maker and produces the composite previews in two steps (`generate_release_gifs.py`, then `make_composite_mp4s.sh`, see above). The GIF runner writes its temporary OGV intermediates under `benchmark/results/release_media/state/`; those intermediates and its manifest are intentionally not source-controlled. The source GIFs and the five composite MP4s under `docs/images/` are tracked by Git so the previews render inline in the README.

The GIF runner parameters are:

```text
MovieWriter capture: 1920 x 1080, 60 fps, OGV intermediate
GIF output:          480 x 270, 15 fps, 6 s (90 frames), infinite loop
Composite output:    1440 x 270, H.264/yuv420p, 15 fps, 6 s (90 frames), CRF 18
```

Useful overrides:

```bash
# Capture only the wetness-state GIFs (12 clips: 3 tiers x 4 states).
python benchmark/tools/generate_release_gifs.py \
  --godot /path/to/godot \
  --project .

# Keep the MovieWriter OGV intermediates for inspection.
python benchmark/tools/generate_release_gifs.py \
  --godot /path/to/godot \
  --keep-intermediate

# Rebuild only the composite MP4s from the existing GIFs (no Godot needed).
bash docs/images/make_composite_mp4s.sh
```

The GIF runner prints:

```text
RELEASE_GIFS_OK
```

only after every requested Godot capture exits successfully. When `ffprobe` is available it additionally verifies GIF resolution, frame rate, frame count, duration, and the infinite-loop extension; `make_composite_mp4s.sh` should be followed by the same ffprobe verification on each composite (1440x270, 15 fps, 90 frames, 6 s).

### Historical capture workflow

The pre-composite release workflow recorded three full-resolution clips with `benchmark/tools/capture_release_media.py` (`quality-tiers.mp4` about 18 s, `fast-wetness.mp4` and `cinematic-wetness.mp4` about 10 s each, 1920x1080 / 60 fps, OGV intermediate converted to H.264/yuv420p MP4 at CRF 15, marker `RELEASE_MEDIA_CAPTURE_OK`). That script is retained for reference and its clips remain attached to the PR13 demo media release as full-resolution downloads, but the five composite previews above are the current standard capture set.

## Visual review gate

Automated metadata checks are not sufficient. Review the final composite MP4s at normal playback speed and frame-step representative sections.

For `demo-video-quality-composite.mp4`, confirm:

- all three tier labels appear in the intended order across the strip;
- each panel starts from the same camera framing and follows the same orbit;
- no tier unexpectedly loses the groom textures or packaged LUT;
- there are no black frames, shader-error frames, NaNs, or discontinuities at tier changes.

For the four wetness composites, confirm:

- each panel shows its fixed wetness state (`0.00`, `0.33`, `0.67`, or `1.00`) rather than a ramp;
- the four composites progress monotonically from dry to saturated;
- the body darkens while highlights become tighter/more neutral rather than simply bleaching the groom;
- the saturated (`1.00`) frame remains finite and stable;
- camera movement is smooth and returns to the starting view;
- the attribution remains readable throughout.

Compare the dry (`0.00`) wetness composite against the quality composite. Material and lighting should agree apart from encoding noise.

## Release placement

Recommended release assets:

```text
marschner-hair-addon-<version>.zip       # MIT runtime, no demo groom/media
marschner-hair-demo-<version>.zip        # mixed-license demo package
demo-video-quality-composite.mp4         # demo media, CC BY-NC 4.0
demo-video-wetness-000-composite.mp4     # demo media, CC BY-NC 4.0
demo-video-wetness-033-composite.mp4     # demo media, CC BY-NC 4.0
demo-video-wetness-067-composite.mp4     # demo media, CC BY-NC 4.0
demo-video-wetness-100-composite.mp4     # demo media, CC BY-NC 4.0
```

The demo release text should cross-reference the matching addon version and state that the videos and supplied groom assets are CC BY-NC 4.0 evaluation/demo material. Users who only need the shader/runtime should be directed to the MIT addon package.
