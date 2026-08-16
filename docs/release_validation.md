# Release validation checklist

Release validation is split into three layers:

1. **MIT addon package** — the production runtime that users can ship in commercial/non-commercial projects under MIT.
2. **Mixed-license demo package** — a consumer of that exact addon build plus the CC BY-NC 4.0 CT2Hair/GodotHair demo grooms.
3. **Demo release media** — deterministic videos recorded from the validated demo package.

The production algorithms are already validated on `development`. Release validation should catch packaging, path, import, license-boundary, and presentation regressions without rerunning every historical numerical/performance benchmark.

## Current development validation status

Already validated on `development`:

- four separate quality tiers: Approx, Fast, Cinematic, Reference;
- Static Bayer, 16-phase TAA Bayer, and A2C coverage behavior;
- viewport-aware Auto coverage policy;
- direct Fast/Cinematic `ImageTexture3D` LUT loading and contract binding;
- Fast eta/IOR `1.55` pinning;
- optical wetness interface and runtime propagation across all four tiers and both normal/A2C shader families;
- wetness dry compatibility, visual progression, component ablation, and final film calibration;
- wetness GPU cost on RTX 5090 and AMD integrated graphics;
- shader-parameter documentation comments are present in the production shader sources;
- repository/runtime license decision: MIT;
- demo groom provenance/license: CT2Hair/GodotHair assets remain CC BY-NC 4.0.

The release package therefore does **not** need another full production benchmark before each RC unless packaging or shader math changes again.

# Gate A — standalone MIT addon

## A1. Package from the current production sources

The release addon should contain only the runtime surface:

```text
addons/marschner_hair/
  HairGroomData.gd
  HairMaterialProfile.gd
  HairMarschnerLUTAdapter.gd
  HairCoveragePolicy.gd
  HairCoverageController.gd
  shaders/
    hair_approx.gdshader
    hair_approx_a2c.gdshader
    hair_marschner_unity_fast.gdshader
    hair_marschner_unity_fast_a2c.gdshader
    hair_marschner_cinematic.gdshader
    hair_marschner_cinematic_a2c.gdshader
    hair.gdshader
    hair_a2c.gdshader
    ...shared production includes...
  luts/
    unity_azimuthal_64.res
    cinematic_longitudinal_kernel_128x128x64.res
    README.md
```

The standalone addon release should also carry the project MIT `LICENSE` and applicable MIT third-party notice text at the archive/release level.

Do **not** ship benchmark raw LUT resources, raw-data reconstruction fixtures, generated result sets, development scenes, experimental shader variants, `.uid` files, Windows `Zone.Identifier` artifacts, demo models, groom maps, or generated demo videos in the MIT addon archive.

## A2. Static path audit

After repathing, search the distributed addon for stale development-only paths. The addon should not reference:

```text
res://assets/hair/
res://benchmark/
res://demos/
```

Every production preload/LUT path should resolve under `res://addons/marschner_hair/`, while shader `#include` paths should remain relative inside the packaged shader directory.

## A3. Fresh-project import smoke

Create a fresh Godot 4.7 project containing only the release addon plus a tiny validation scene/script. Open it once in the editor before judging import errors.

Check that the global classes register:

```text
HairMaterialProfile
HairGroomData
HairMarschnerLUTAdapter
HairCoveragePolicy
HairCoverageController
```

There should be no missing preload, missing include, parser, or class-registration errors.

## A4. Package-level material smoke

In the fresh project, construct one complete `HairGroomData` using known-valid groom textures and one `HairMaterialProfile`.

For each quality tier, create both compiled coverage shader families:

```text
4 quality tiers x 2 compiled coverage families = 8 variants
```

For every variant verify:

- `ShaderMaterial` creation succeeds;
- the shader resource path is under `res://addons/marschner_hair/shaders/`;
- shared groom textures bind;
- wetness defaults bind (`0.0`, film `2.0 / 0.10`, remaining calibrated endpoints);
- setting `wetness = 1.0` propagates to the resulting material;
- Fast binds a valid direct 64^3 RGBA16F LUT and eta/IOR stays `1.55`;
- Cinematic binds a valid direct 128x128x64 R16F LUT;
- A2C requests select `_a2c.gdshader` variants.

Run this with a normal rendering context. On the validated Godot 4.7 setup, do not rely on `--headless` for direct `ImageTexture3D` validation.

## A5. Force a real draw/compile of all eight variants

Material/RID creation alone is not a complete shader-compile test. Render at least one frame with each of the eight production variants on a small card/quad mesh under a light.

The goal is not image-quality benchmarking. Confirm only that:

- the renderer compiles the shader;
- no shader/include errors appear;
- the mesh produces visible output;
- Fast/Cinematic do not fall back because of missing LUTs;
- switching normal <-> A2C variants does not drop the wetness parameters.

A small sequential harness is preferable to opening eight separate editor windows.

## A6. Auto coverage smoke

In Forward+:

```text
MSAA off, TAA off -> Static Bayer
MSAA off, TAA on  -> TAA Bayer
MSAA on           -> A2C
```

In Mobile:

```text
MSAA on  -> A2C
MSAA off -> Static Bayer
```

Compatibility should resolve Auto to Static Bayer.

This is a small regression check; the full coverage performance benchmark does not need to be rerun unless the coverage math changes.

## A7. Editor tooltip smoke

Open one normal shader material and one A2C shader material from the packaged addon in Godot 4.7 and hover representative parameters:

```text
wetness
wet_film_roughness
longitudinal_roughness
coords_texture
unity_azimuthal_lut         (Fast)
cinematic_longitudinal_lut  (Cinematic)
bayer_phase_index           (normal Bayer variant)
```

Confirm the Inspector displays the intended descriptions and that repackaging did not strip or break the comments.

## A8. Dry/wet visual sanity check

A full recalibration is unnecessary. Render one representative groom at:

```text
wetness = 0.0
wetness = 1.0
```

under a broad light and a narrower/high-contrast light. Confirm:

- dry still matches the existing dry appearance;
- wet hair has a darker body plus tighter/neutral film response;
- no NaNs, white-out, or tier-specific discontinuity appears after repathing.

## A9. Addon metadata

Before publishing:

- bump `VERSION` to the next RC/version;
- add a changelog entry for shader-parameter tooltips, optical wetness, and licensing;
- update the release README with calibrated wetness controls and geometry-out-of-scope guidance;
- ensure the release README says LUTs are packaged and requires no LUT-generation step;
- verify all documented addon paths use `res://addons/marschner_hair/`;
- include the MIT license and applicable third-party MIT notice;
- state explicitly that the standalone addon contains no CC BY-NC demo groom assets.

# Gate B — mixed-license demo package

Build the demo only after Gate A passes. The demo should consume the **exact validated addon build**, not a separately repathed copy.

## B1. Addon identity

Compare the embedded demo `addons/marschner_hair/**` tree against the standalone addon staging tree. File names and bytes must match.

If the demo requires a different runtime source file, that difference belongs in the addon first; do not patch the demo's private copy.

## B2. License boundary audit

The demo archive must contain prominent license/notices:

```text
LICENSE                         # project/addon MIT license
THIRD_PARTY_NOTICES.md
assets/hair/models/LICENSE.md   # demo groom CC BY-NC 4.0 notice
```

Confirm:

- addon/code files are not incorrectly labeled CC BY-NC;
- `assets/hair/models/**` is not incorrectly labeled MIT;
- the demo README describes the archive as mixed-license;
- the NonCommercial restriction is visible before users treat the supplied grooms as production assets;
- no CC BY-NC groom/media file leaked into the standalone addon archive.

## B3. Fresh demo import

Extract the demo archive into a new directory and open it in Godot 4.7.

There should be no missing resources, stale development paths, parser errors, shader include errors, or broken imports.

The demo should resolve runtime shader/profile/LUT dependencies through the embedded `addons/marschner_hair/` copy.

## B4. Demo groom smoke

The source demo contains the following ten CT2Hair/GodotHair hairstyle directories:

```text
bangs
blowout
bob
curly
jewfro
jheri
moptop
pixie
wavy
wings
```

Cycle each groom once and confirm its mesh and associated groom textures import and render without missing-resource errors. One production tier is sufficient for this all-groom asset smoke; the eight-variant shader matrix is already covered by Gate A.

Use Blowout as the standardized release-validation/media groom because the current profile and groom-data resources are already calibrated around it.

## B5. Interactive demo controls

Confirm the interactive demo still supports its intended camera/light/hairstyle controls after packaging. In particular, verify the inherited GodotHair-style orbit camera can rotate and zoom around the head without losing framing.

Then confirm the packaged profile workflow can switch quality tiers and move wetness from `0` to `1` on the Blowout groom.

## B6. Demo visual regression

With Blowout selected, compare at minimum:

```text
Approx dry
Fast dry
Cinematic dry
Reference dry
Fast wetness 1.0
Cinematic wetness 1.0
```

This is a presentation sanity check, not a numerical revalidation. The expected direction of change must match the development results.

# Gate C — release media

Record media only from the **validated demo staging/extracted package**, so the videos demonstrate the same addon and resources users receive.

The canonical workflow is documented in [`release_media.md`](release_media.md).

Run:

```bash
python benchmark/tools/capture_release_media.py \
  --godot /path/to/godot \
  --project .
```

The default capture set is:

```text
quality-tiers.mp4
fast-wetness.mp4
cinematic-wetness.mp4
```

The capture harness uses deterministic Movie Maker timing and the original GodotHair camera-orbit convention. Release videos use Static Bayer coverage so camera/shader comparisons are deterministic; coverage behavior itself remains covered by Gate A.

## C1. Automated media checks

The capture runner must reach:

```text
RELEASE_MEDIA_CAPTURE_OK
```

When `ffprobe` is installed it also verifies:

```text
resolution = 1920 x 1080
fps = 60
quality-tiers duration ~= 18 s
wetness clip duration ~= 10 s each
```

Generated files live under `benchmark/results/release_media/` and are intentionally ignored by Git.

## C2. Human video review

Review the final MP4s rather than only the MovieWriter intermediate.

Confirm:

- one identical full orbit is shown for every quality tier;
- tier labels match the shader actually displayed;
- wetness clips progress monotonically from `0` to `1`;
- dry endpoints agree with the quality comparison apart from encoding noise;
- saturated wetness remains finite/stable;
- camera movement is smooth and returns to the starting view;
- there are no black/error frames at shader switches;
- the in-frame `CT2Hair / GodotHair — CC BY-NC 4.0` attribution is readable.

Project-published videos that visibly reproduce the supplied demo groom are demo media and should be released under the CC BY-NC 4.0 demo terms, not bundled inside the MIT addon archive.

# Tests that do not need to be repeated

Unless the underlying shader/coverage/LUT math changes again, the following expensive investigations are already sufficient evidence and do not need to block the next RC:

- full dual-GPU production tier matrix;
- full coverage-path performance matrix;
- LUT storage/manifest benchmark;
- production LUT byte-equality migration benchmark;
- wetness component ablation and film sweep;
- wetness 300-sample dry/wet GPU comparison.

# Final release gate

## MIT addon

```text
[ ] current development production files are repackaged under addons/marschner_hair
[ ] no development-only resource paths remain in the addon
[ ] fresh-project import has no parser/preload/include errors
[ ] all 8 quality/coverage variants create and render at least one frame
[ ] Fast and Cinematic direct LUTs validate in the packaged paths
[ ] Auto coverage resolves correctly for Forward+/Mobile/Compatibility smoke
[ ] one normal and one A2C shader show the expected Inspector parameter tooltips
[ ] dry/wet package-level visual sanity check passes
[ ] VERSION / CHANGELOG / release README are current
[ ] MIT LICENSE and applicable third-party MIT notice are present
[ ] no CC BY-NC demo groom/media is inside the addon archive
```

## Demo package

```text
[ ] embedded addon is byte-identical to the validated standalone addon
[ ] mixed-license README / LICENSE / THIRD_PARTY_NOTICES / groom LICENSE are present
[ ] fresh extracted demo project imports without missing resources
[ ] all 10 bundled hairstyle assets can be selected/rendered
[ ] interactive orbit/zoom and demo controls work
[ ] Blowout tier/wetness presentation smoke passes
```

## Release media

```text
[ ] quality-tiers.mp4 captured from the validated demo package
[ ] fast-wetness.mp4 captured from the validated demo package
[ ] cinematic-wetness.mp4 captured from the validated demo package
[ ] RELEASE_MEDIA_CAPTURE_OK reached
[ ] resolution/fps/duration metadata checks pass (when ffprobe is available)
[ ] final MP4 visual review passes
[ ] CC BY-NC attribution is visible in-frame and repeated in release text
```

When all three sections pass, the matching addon and demo releases are ready to publish.
