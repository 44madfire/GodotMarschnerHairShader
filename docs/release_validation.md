# Release validation checklist

This checklist separates **development-model validation** from **distributable-addon validation**.

The production algorithms are validated on `development`; a release still needs a final smoke after the files are repathed under `addons/marschner_hair/`. The package smoke is intentionally small: it should catch packaging, preload/include, LUT-path, and editor-interface regressions without rerunning every historical numerical benchmark.

## Current validation status

Already validated on `development`:

- four separate quality tiers: Approx, Fast, Cinematic, Reference;
- Static Bayer, 16-phase TAA Bayer, and A2C coverage behavior;
- viewport-aware Auto coverage policy;
- direct Fast/Cinematic `ImageTexture3D` LUT loading and contract binding;
- Fast eta/IOR `1.55` pinning;
- optical wetness interface and runtime propagation across all four tiers and both normal/A2C shader families;
- wetness dry compatibility, visual progression, component ablation, and final film calibration;
- wetness GPU cost on RTX 5090 and AMD integrated graphics;
- shader-parameter documentation comments are present in the production shader sources.

The release package therefore does **not** need another full production benchmark before each RC unless packaging or shader math changes again.

## Required before publishing the next release candidate

### 1. Package from the current `development` production sources

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

Do not ship benchmark raw LUT resources, raw-data reconstruction fixtures, generated result sets, development scenes, experimental shader variants, `.uid` files, or Windows `Zone.Identifier` artifacts.

### 2. Static path audit

After repathing, search the distributed addon for stale development-only paths. The addon should not reference:

```text
res://assets/hair/
res://benchmark/
res://demos/
```

Every production preload/LUT path should resolve under `res://addons/marschner_hair/`, while shader `#include` paths should remain relative inside the packaged shader directory.

### 3. Fresh-project import smoke

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

### 4. Package-level material smoke

In the fresh project, construct one complete `HairGroomData` using known-valid groom textures and one `HairMaterialProfile`.

For each quality tier, create both coverage shader families:

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

### 5. Force a real draw/compile of all eight variants

Material/RID creation alone is not a complete shader-compile test. Render at least one frame with each of the eight production variants on a small card/quad mesh under a light.

The goal is not image-quality benchmarking. Confirm only that:

- the renderer compiles the shader;
- no shader/include errors appear;
- the mesh produces visible output;
- Fast/Cinematic do not fall back because of missing LUTs;
- switching normal <-> A2C variants does not drop the wetness parameters.

A small sequential harness is preferable to opening eight separate editor windows.

### 6. Auto coverage smoke

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

### 7. Editor tooltip smoke

PR #9 added GDShader documentation comments, but the release should verify the actual packaged editor experience once.

Open one normal shader material and one A2C shader material in Godot 4.7 and hover representative parameters:

```text
wetness
wet_film_roughness
longitudinal_roughness
coords_texture
unity_azimuthal_lut      (Fast)
cinematic_longitudinal_lut (Cinematic)
bayer_phase_index        (normal Bayer variant)
```

Confirm the Inspector displays the intended descriptions and that repackaging did not strip or break the comments.

### 8. Wetness visual sanity check

A full recalibration is unnecessary. Render one representative groom at:

```text
wetness = 0.0
wetness = 1.0
```

under a broad light and a narrower/high-contrast light. Confirm:

- dry still matches the existing dry appearance;
- wet hair has a darker body plus tighter/neutral film response;
- no NaNs, white-out, or tier-specific discontinuity appears after repathing.

### 9. Release metadata and docs

Before publishing:

- bump `VERSION` to the next RC/version;
- add a changelog entry for shader-parameter tooltips and optical wetness;
- update the release README with the calibrated wetness controls and geometry-out-of-scope guidance;
- ensure the release README says LUTs are packaged and requires no LUT-generation step;
- verify all documented addon paths use `res://addons/marschner_hair/`;
- choose/confirm a repository license before public redistribution if one has not been established elsewhere.

## Tests that do not need to be repeated for this release

Unless the underlying math changes again, the following expensive investigations are already sufficient evidence and do not need to block the next RC:

- full dual-GPU production tier matrix;
- full coverage-path performance matrix;
- LUT storage/manifest benchmark;
- production LUT byte-equality migration benchmark;
- wetness component ablation and film sweep;
- wetness 300-sample dry/wet GPU comparison.

## Release gate

The next release candidate is ready to publish when all of the following are true:

```text
[ ] current development production files are repackaged under addons/marschner_hair
[ ] no development-only resource paths remain in the addon
[ ] fresh-project import has no parser/preload/include errors
[ ] all 8 quality/coverage variants create and render at least one frame
[ ] Fast and Cinematic direct LUTs validate in the packaged paths
[ ] Auto coverage resolves correctly for a small Forward+/Mobile/Compatibility smoke
[ ] one normal and one A2C shader show the expected Inspector parameter tooltips
[ ] dry/wet package-level visual sanity check passes
[ ] VERSION / CHANGELOG / release README are current
[ ] public-distribution license decision is resolved
```

The package-level checks are the only substantive new technical validation still needed after the current development results.
