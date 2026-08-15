# Release/demo media capture

Release videos are generated from the demo project after the matching addon build has passed package-level validation. The media is meant to make the four shader tiers and optical wetness behavior easy to evaluate without requiring users to configure a scene first.

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

The default release media set contains three videos.

### `quality-tiers.mp4`

A dry comparison of all four compiled lighting models:

```text
Approx / Kajiya-Kay
Fast Marschner
Cinematic Marschner
Reference Marschner
```

Each tier gets a six-second segment. The first `0.5 s` is a static front view after the tier switch, followed by the same full 360-degree orbit. Total expected duration: about `24 s`.

The material remains at `wetness = 0.0` so the video isolates the lighting-model difference.

### `fast-wetness.mp4`

Fast Marschner using the calibrated optical wetness model:

```text
1 s dry hold
8 s linear wetness 0 -> 1 + one 360-degree orbit
1 s saturated hold
```

Expected duration: about `10 s`.

### `cinematic-wetness.mp4`

The same wetness progression with Cinematic Marschner. Expected duration: about `10 s`.

Fast and Cinematic are the default wetness showcase because they are the two normal production Marschner choices. The capture controller also accepts `approx` and `reference` tiers for additional diagnostic clips when needed.

## In-frame labels

Every generated capture includes:

- current shader tier;
- current wetness value for wetness clips;
- `Demo groom: CT2Hair / GodotHair — CC BY-NC 4.0`.

Do not crop the attribution out of project-published media.

## Recording with Godot Movie Maker

Godot Movie Maker mode performs non-real-time recording with fixed simulation timing, which is preferable to a desktop screen recorder for shader comparisons. The capture controller exits through `SceneTree.quit()` so MovieWriter can finalize the output container cleanly.

The project automation records an OGV intermediate by default and then converts it to H.264 MP4 for browser/release use:

```bash
python benchmark/tools/capture_release_media.py \
  --godot /path/to/godot \
  --project .
```

Default output:

```text
benchmark/results/release_media/
  quality-tiers.mp4
  fast-wetness.mp4
  cinematic-wetness.mp4
  release_media_manifest.json
```

Generated release media is intentionally not source-controlled. Attach the reviewed MP4 files to the demo release or another release-media host.

The default capture parameters are:

```text
1920 x 1080
60 fps
Godot OGV intermediate
H.264/yuv420p MP4
CRF 15
```

Use `--movie-format avi` if OGV is unavailable. OGV recording requires a Godot editor build; both OGV and AVI are intermediate capture formats and the final distribution files should normally be the generated MP4s.

Useful overrides:

```bash
# Capture only the quality comparison.
python benchmark/tools/capture_release_media.py \
  --godot /path/to/godot \
  --captures quality-tiers

# Keep the MovieWriter intermediate for inspection.
python benchmark/tools/capture_release_media.py \
  --godot /path/to/godot \
  --keep-intermediate

# Skip MP4 conversion when ffmpeg is unavailable.
python benchmark/tools/capture_release_media.py \
  --godot /path/to/godot \
  --no-mp4
```

The runner prints:

```text
RELEASE_MEDIA_CAPTURE_OK
```

only after every requested Godot capture exits successfully. When `ffprobe` is available it additionally verifies resolution, frame rate, and expected clip duration.

## Visual review gate

Automated metadata checks are not sufficient. Review the final MP4s at normal playback speed and frame-step representative sections.

For `quality-tiers.mp4`, confirm:

- all four labels appear in the intended order;
- each tier starts from the same camera framing and follows the same orbit;
- no tier unexpectedly loses the groom textures or packaged LUT;
- there are no black frames, shader-error frames, NaNs, or discontinuities at tier changes;
- Reference is visibly a comparison tier, not accidentally aliased to Fast/Cinematic.

For both wetness clips, confirm:

- the first second is the established dry endpoint;
- wetness increases monotonically from `0` to `1`;
- the body darkens while highlights become tighter/more neutral rather than simply bleaching the groom;
- the final saturated frame remains finite and stable;
- camera movement is smooth and returns to the starting view;
- the attribution remains readable throughout.

Compare the dry frame from the wetness clips against the corresponding tier in the quality clip. Material and lighting should agree apart from encoding noise.

## Release placement

Recommended release assets:

```text
marschner-hair-addon-<version>.zip       # MIT runtime, no demo groom/media
marschner-hair-demo-<version>.zip        # mixed-license demo package
quality-tiers.mp4                        # demo media, CC BY-NC 4.0
fast-wetness.mp4                         # demo media, CC BY-NC 4.0
cinematic-wetness.mp4                    # demo media, CC BY-NC 4.0
```

The demo release text should cross-reference the matching addon version and state that the videos and supplied groom assets are CC BY-NC 4.0 evaluation/demo material. Users who only need the shader/runtime should be directed to the MIT addon package.
