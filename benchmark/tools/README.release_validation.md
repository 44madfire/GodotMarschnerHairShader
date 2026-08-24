# Release validation helper tools

Three small helpers support the package/media gates in `docs/release_validation.md`.

## Verify the demo embeds the exact addon build

After staging the standalone addon and demo package:

```bash
python benchmark/tools/verify_release_addon_identity.py \
  /path/to/addon-staging/addons/marschner_hair \
  /path/to/demo-staging/addons/marschner_hair
```

Expected marker:

```text
RELEASE_ADDON_IDENTITY_OK
```

The comparison is recursive and byte-exact (SHA-256 per file). Missing, extra, or changed files fail the check.

## Capture release/demo videos

From the validated demo package/project:

```bash
python benchmark/tools/capture_release_media.py \
  --godot /path/to/godot \
  --project .
```

Expected marker:

```text
RELEASE_MEDIA_CAPTURE_OK
```

See `docs/release_media.md` for clip contents, licensing, visual review, and output details.

## Generate the wetness-state GIF previews

Looping previews for the wetness matrix below are generated from individual
fixed-wetness state captures (one full 6-second orbit per tier/wetness cell):

```bash
python benchmark/tools/generate_release_gifs.py \
  --godot /path/to/godot \
  --project .
```

Expected marker:

```text
RELEASE_GIFS_OK
```

The runner captures Approx, Fast, and Cinematic at wetness 0.00/0.33/0.67/1.00
(12 clips), converts each clip separately to a 480x270, 15 fps, infinitely
looping GIF under `docs/images/demo-video-wetness-{tier}-{code}.gif`, and
fails if any GIF exceeds 10 MB. Temporary OGV intermediates are removed unless
`--keep-intermediate` is passed.

## Demo video previews

Looping GIF previews of the validated captures live in this repository under
`docs/images/` (source MP4s stay attached to the private
[PR13 demo media release](https://github.com/44madfire/GodotMarschnerHairShader/releases/tag/pr13-demo-media)).
The demo groom and these videos are released under **CC BY-NC 4.0**. Every GIF
is a full 6-second seamless orbit. The quality row shows one orbit per tier
(Approx, Fast Marschner, and Cinematic Marschner; Reference is omitted). The
wetness matrix shows one individual GIF per cell for every tier at the fixed
wetness states 0.00, 0.33, 0.67, and 1.00.

### Quality tiers (dry, wetness 0.00)

| <strong>Approx / Kajiya-Kay</strong><br>[![Approx preview](../../docs/images/demo-video-approx.gif)](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/quality-tiers.mp4) | <strong>Fast Marschner</strong><br>[![Fast Marschner preview](../../docs/images/demo-video-fast.gif)](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/quality-tiers.mp4) |
| --- | --- |
| <strong>Cinematic Marschner</strong><br>[![Cinematic Marschner preview](../../docs/images/demo-video-cinematic.gif)](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/quality-tiers.mp4) | <strong>Reference omitted</strong><br>See the [quality-tiers.mp4](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/quality-tiers.mp4) release clip |

### Wetness matrix (fixed wetness states, one individual GIF per cell)

MP4s: [fast-wetness.mp4](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/fast-wetness.mp4) and [cinematic-wetness.mp4](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/cinematic-wetness.mp4). The Approx column has no separate wetness MP4; its GIFs are standalone previews.

| | <strong>Approx / Kajiya-Kay</strong> | <strong>Fast Marschner</strong> | <strong>Cinematic Marschner</strong> |
| --- | --- | --- | --- |
| <strong>Wetness 0.00</strong> | [![Approx wetness 0.00](../../docs/images/demo-video-wetness-approx-000.gif)](../../docs/images/demo-video-wetness-approx-000.gif) | [![Fast wetness 0.00](../../docs/images/demo-video-wetness-fast-000.gif)](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/fast-wetness.mp4) | [![Cinematic wetness 0.00](../../docs/images/demo-video-wetness-cinematic-000.gif)](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/cinematic-wetness.mp4) |
| <strong>Wetness 0.33</strong> | [![Approx wetness 0.33](../../docs/images/demo-video-wetness-approx-033.gif)](../../docs/images/demo-video-wetness-approx-033.gif) | [![Fast wetness 0.33](../../docs/images/demo-video-wetness-fast-033.gif)](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/fast-wetness.mp4) | [![Cinematic wetness 0.33](../../docs/images/demo-video-wetness-cinematic-033.gif)](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/cinematic-wetness.mp4) |
| <strong>Wetness 0.67</strong> | [![Approx wetness 0.67](../../docs/images/demo-video-wetness-approx-067.gif)](../../docs/images/demo-video-wetness-approx-067.gif) | [![Fast wetness 0.67](../../docs/images/demo-video-wetness-fast-067.gif)](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/fast-wetness.mp4) | [![Cinematic wetness 0.67](../../docs/images/demo-video-wetness-cinematic-067.gif)](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/cinematic-wetness.mp4) |
| <strong>Wetness 1.00</strong> | [![Approx wetness 1.00](../../docs/images/demo-video-wetness-approx-100.gif)](../../docs/images/demo-video-wetness-approx-100.gif) | [![Fast wetness 1.00](../../docs/images/demo-video-wetness-fast-100.gif)](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/fast-wetness.mp4) | [![Cinematic wetness 1.00](../../docs/images/demo-video-wetness-cinematic-100.gif)](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/cinematic-wetness.mp4) |
