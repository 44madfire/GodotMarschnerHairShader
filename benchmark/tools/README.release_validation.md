# Release validation helper tools

Two small helpers support the package/media gates in `docs/release_validation.md`.

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

## Demo video previews

Looping GIF previews of the validated captures live in this repository under
`docs/images/` (source MP4s stay attached to the private
[PR13 demo media release](https://github.com/44madfire/GodotMarschnerHairShader/releases/tag/pr13-demo-media)).
The demo groom and these videos are released under **CC BY-NC 4.0**. Quality-tier
previews show one orbit segment per tier (Approx, Fast Marschner, and Cinematic
Marschner; Reference is omitted). Wetness previews are side-by-side
Fast-vs-Cinematic comparisons at the dry, mid, and wet endpoints.

| Capture | Preview |
| --- | --- |
| [Quality tiers — Approx](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/quality-tiers.mp4) | [![Approx preview](../../docs/images/demo-video-approx.gif)](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/quality-tiers.mp4) |
| [Quality tiers — Fast Marschner](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/quality-tiers.mp4) | [![Fast Marschner preview](../../docs/images/demo-video-fast.gif)](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/quality-tiers.mp4) |
| [Quality tiers — Cinematic Marschner](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/quality-tiers.mp4) | [![Cinematic Marschner preview](../../docs/images/demo-video-cinematic.gif)](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/quality-tiers.mp4) |
| [Wetness 0.00 — Fast vs Cinematic](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/fast-wetness.mp4) ([cinematic](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/cinematic-wetness.mp4)) | [![Wetness 0.00 preview](../../docs/images/demo-video-wetness-0.gif)](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/fast-wetness.mp4) |
| [Wetness 0.50 — Fast vs Cinematic](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/fast-wetness.mp4) ([cinematic](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/cinematic-wetness.mp4)) | [![Wetness 0.50 preview](../../docs/images/demo-video-wetness-05.gif)](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/fast-wetness.mp4) |
| [Wetness 1.00 — Fast vs Cinematic](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/fast-wetness.mp4) ([cinematic](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/cinematic-wetness.mp4)) | [![Wetness 1.00 preview](../../docs/images/demo-video-wetness-1.gif)](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/fast-wetness.mp4) |
