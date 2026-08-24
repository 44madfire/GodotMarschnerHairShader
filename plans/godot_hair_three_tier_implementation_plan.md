# Godot Hair Shader: Three-Tier Implementation Plan

**Target engine:** Godot 4.7.1, Forward+ for the complete feature set  
**Primary repository:** `2Retr0/GodotHair`  
**Reference repositories:**

- `Unity-Technologies/Graphics`
- `LiveTrower/Godot-Hair-Shading`

## 1. Objective

Refactor `2Retr0/GodotHair` into a production-oriented hair material system with three explicit quality tiers:

1. **Approximate — Kajiya–Kay**
2. **Fast — Marschner**
3. **High — Marschner / cinematic approximation**

The tiers must share the same material data, hair-card geometry conventions, alpha handling, strand orientation, and artist-facing color controls. They should differ only in lighting cost and fidelity.

The implementation should preserve the current repository's strongest feature: its high-quality direct single-scattering model. The main work is to add:

- a cheap Kajiya–Kay path;
- a production-oriented fast Marschner path;
- better multiple scattering;
- Godot 4.7 area-light handling;
- practical indirect/environment approximations;
- clean shader variants and measurable quality/performance targets.

This plan treats Unity HDRP as an architectural and mathematical reference. Do not copy Unity source into the Godot project. Reimplement the published equations and algorithms, using the referenced papers and the existing MIT-licensed Godot repositories.

---

## 2. Source Map

### 2.1 Primary implementation: `2Retr0/GodotHair`

Current material entry point:

```text
assets/hair/materials/shaders/hair.gdshader
```

Current high-quality scattering implementation:

```text
assets/hair/materials/shaders/hair.gdshaderinc
```

Important existing behavior to preserve:

- hair-card tangent reconstruction from `coords_texture.rgb`;
- root-to-tip parameter from `coords_texture.a`;
- coverage, depth, and seed packing in `attributes_texture`;
- alpha hashing/discard behavior;
- per-strand roughness and tangent variation;
- color-to-absorption reparameterization;
- R, TT, and TRT lobe isolation/debug support;
- energy-conserving longitudinal scattering;
- non-separable longitudinal widths and tilts;
- analytic effective IOR;
- current direct-light integration through `light()`.

### 2.2 Unity HDRP references

Material data and feature tiers:

```text
Packages/com.unity.render-pipelines.high-definition/Runtime/Material/Hair/Hair.cs
Packages/com.unity.render-pipelines.high-definition/Runtime/Material/Hair/Hair.hlsl
```

Reference BSDF:

```text
Packages/com.unity.render-pipelines.high-definition/Runtime/Material/Hair/Reference/HairReference.hlsl
Packages/com.unity.render-pipelines.high-definition/Runtime/Material/Hair/Reference/HairReferenceCommon.hlsl
```

Preintegrated scattering:

```text
Packages/com.unity.render-pipelines.high-definition/Runtime/Material/Hair/PreIntegratedAzimuthalScattering.hlsl
Packages/com.unity.render-pipelines.high-definition/Runtime/Material/Hair/MultipleScattering/HairMultipleScatteringPreIntegration.compute
```

Dual scattering:

```text
Packages/com.unity.render-pipelines.high-definition/Runtime/Material/Hair/MultipleScattering/HairMultipleScattering.hlsl
```

LUT setup and binding:

```text
Packages/com.unity.render-pipelines.high-definition/Runtime/Material/Hair/Hair.cs
```

The Unity implementation is especially useful for:

- feature-tier organization;
- two-lobe Kajiya–Kay controls;
- fast Marschner lobe parameterization;
- 3D azimuthal and longitudinal LUT design;
- local and global dual scattering;
- environment-light quality tiers;
- area-light approximations;
- compile-time feature stripping.

### 2.3 LiveTrower Godot references

Kajiya–Kay:

```text
Shaders/KajiyaKayHair.gdshader
Shaders/KajiyaKayBSDF.gdshaderinc
```

Approximate Marschner:

```text
Shaders/MarschnerHair.gdshader
Shaders/MarschnerBSDF.gdshaderinc
```

These files are useful for:

- Godot shader-language integration;
- two shifted Kajiya–Kay lobes;
- cheap Gaussian Marschner expressions;
- flow-map support;
- wrapped diffuse;
- alpha hashing;
- a low-cost baseline suitable for Mobile or Compatibility testing.

---

## 3. Godot Lighting API Findings

### 3.1 `light()` is the correct direct-light integration point

For a spatial shader, Godot calls `light()` for each light affecting each rendered pixel. The function can read the current light direction, color, attenuation, view vector, material values, and strand basis passed from `fragment()`.

Relevant Godot 4.7 spatial `light()` built-ins include:

```text
VIEW
LIGHT
LIGHT_COLOR
ATTENUATION
SPECULAR_AMOUNT
LIGHT_IS_DIRECTIONAL
LIGHT_IS_AREA
LIGHT_AREA_DIFFUSE_MULTIPLIER
LIGHT_AREA_SPECULAR_MULTIPLIER
NORMAL
UV
UV2
ALBEDO
ROUGHNESS
METALLIC
BACKLIGHT
DIFFUSE_LIGHT
SPECULAR_LIGHT
SCREEN_UV
```

Consequences:

- All three direct-light tiers can be implemented in ordinary Godot shaders.
- Direct-light shadows and attenuation are already folded into `ATTENUATION`.
- The shader can distinguish directional lights and the new `AreaLight3D`.
- The shader can use Godot's area-light diffuse/specular multipliers.
- `light()` must not be used when project settings force vertex shading; the custom hair BSDF depends on per-pixel light processing.
- The project and material must not enable `render_mode vertex_lighting`.

### 3.2 Area-light information is useful but incomplete

Godot 4.7 exposes:

```text
LIGHT_IS_AREA
LIGHT_AREA_DIFFUSE_MULTIPLIER
LIGHT_AREA_SPECULAR_MULTIPLIER
```

This is enough to identify an area light and use Godot's precomputed area-light response as an energy/shape proxy.

It does **not** expose the complete rectangle geometry to the custom spatial shader:

- no rectangle corner positions;
- no light width/height;
- no light orientation basis;
- no light-space sampling function;
- no public per-light solid angle;
- no direct access to the light's texture;
- no arbitrary sampling of multiple points on the light.

Therefore, a stock spatial shader cannot reproduce Unity's sampled cinematic rectangle-light integral. The practical approach is:

1. evaluate the hair BSDF using Godot's supplied `LIGHT` direction;
2. use the area diffuse/specular multipliers to scale or broaden the response;
3. tune lobe-specific heuristics against reference scenes.

This should be described as an **area-light approximation**, not a true Marschner area integral.

### 3.3 Screen reading is not an environment sampler

Godot supports screen color, depth, and—under Forward+—normal/roughness textures:

```glsl
uniform sampler2D screen_texture
    : hint_screen_texture, repeat_disable, filter_linear_mipmap;

uniform sampler2D depth_texture
    : hint_depth_texture, repeat_disable, filter_nearest;

uniform sampler2D normal_roughness_texture
    : hint_normal_roughness_texture, repeat_disable, filter_nearest;
```

These are useful for a screen-space indirect proxy, but they are not equivalent to Unity's environment-map sampling:

- the screen texture is copied after opaque rendering and before transparent rendering;
- transparent geometry is absent;
- screen-reading materials are themselves classified as transparent;
- the screen copy is captured once;
- some sampled opaque pixels can be in front of the hair;
- only visible screen-space surfaces are available;
- the color is already shaded display radiance, not an unlit incident-radiance field;
- off-screen lighting is unavailable;
- reflection probes and the active sky cubemap are not directly readable by a spatial shader.

The screen buffer can still approximate local colored surroundings, backlighting, and broad ambient response. It cannot replace a true directional environment integral.

### 3.4 Screen-reading must not be added directly to the main hair pass

Adding `hint_screen_texture` to the primary hair material changes it to the transparent pipeline. That would undermine the current opaque/alpha-hashed design and can remove or degrade:

- shadow casting;
- depth participation;
- screen-space reflections;
- visibility in other screen-reading materials;
- stable opaque ordering.

The recommended architecture is a separate optional pass:

```text
Pass 1: opaque/alpha-hashed direct hair shading and shadows
Pass 2: additive screen-space indirect overlay
```

The second pass can be attached through `Material.next_pass` or by a duplicate mesh/material setup. Because next-pass materials are not guaranteed to render immediately after the source material, validate render priority and transparent sorting.

### 3.5 Environment access options

There is no built-in readable sky or reflection-probe cubemap in a normal spatial shader. `RADIANCE` and `IRRADIANCE` are fragment outputs that alter environment contribution; they are not input samplers.

Available approaches, in priority order:

1. **Explicit environment texture**
   - Bind a panorama or cubemap to the hair material/global shader parameters.
   - Sample it directionally in the high tier.
   - Keep it synchronized with the scene environment through project code or tooling.

2. **Screen-space indirect proxy**
   - Gather screen color around the hair pixel.
   - Reconstruct sample positions from depth.
   - Reject samples using depth and normal tests.
   - Treat accepted samples as a low-frequency local radiance proxy.

3. **Matched-camera SubViewport**
   - Render an auxiliary view and bind its texture.
   - More flexible than the single screen copy, but significantly more expensive.

4. **Renderer extension**
   - Use a CompositorEffect, RenderingDevice integration, or engine/GDExtension changes.
   - Reserve this for a later milestone after the stock shader design is measured.

---

## 4. Quality Tier Definition

## 4.1 Tier 1 — Approximate Kajiya–Kay

### Purpose

Provide the lowest-cost production path for:

- distant hair;
- background characters;
- lower-end GPUs;
- Mobile/Compatibility targets;
- high light counts;
- fallback when LUT resources are unavailable.

### Direct-light model

Use two independently shifted longitudinal specular lobes:

```text
Primary lobe:
- typically narrow;
- typically close to neutral/light color;
- primary roughness;
- primary tangent shift;
- primary tint and strength.

Secondary lobe:
- typically wider;
- artist-tinted toward hair color;
- secondary roughness;
- secondary tangent shift;
- secondary tint and strength.
```

Reference:

```text
Unity HDRP:
Hair.hlsl — Kajiya–Kay branch in EvaluateBSDF()

LiveTrower:
Shaders/KajiyaKayBSDF.gdshaderinc
```

Recommended core:

```glsl
T1 = normalize(T + shift_primary * N);
T2 = normalize(T + shift_secondary * N);
H  = normalize(L + V);

D1 = kajiya_kay_distribution(T1, H, exponent_primary);
D2 = kajiya_kay_distribution(T2, H, exponent_secondary);

specular = fresnel * (
    primary_tint * primary_strength * D1 +
    secondary_tint * secondary_strength * D2
);
```

### Diffuse/multiple-scattering approximation

Start with one selectable cheap mode:

- wrapped Lambert; or
- the current Karis-style fake multiple-scattering term.

Do not attempt dual scattering in Tier 1.

### Indirect lighting

Use Godot's ordinary material/environment response or a single broad approximation. No explicit screen-space gather and no custom environment integration.

### Area lights

When `LIGHT_IS_AREA` is true:

- multiply the specular result by a scalar or RGB value derived from `LIGHT_AREA_SPECULAR_MULTIPLIER`;
- multiply wrapped diffuse by `LIGHT_AREA_DIFFUSE_MULTIPLIER`;
- do not alter tangent shifts.

### Required inputs

```text
base_color / reflectance
primary_specular_tint
secondary_specular_tint
primary_roughness
secondary_roughness
primary_shift
secondary_shift
primary_strength
secondary_strength
scatter_strength
strand_tangent
coverage
depth
seed
```

### Acceptance criteria

- Primary and secondary lobes can be debug-isolated.
- Highlight position follows strand direction and flow map.
- No discontinuity on card backfaces.
- Alpha-hash behavior matches the current shader.
- Cost is materially lower than the current GodotHair shader.
- Works in Forward+.
- Compatibility and Mobile results are documented, even where area-light support differs.

---

## 4.2 Tier 2 — Fast Marschner

### Purpose

Provide the default production tier: visibly Marschner-like R, TT, and TRT behavior at a predictable real-time cost.

### Direct-light model

Use:

- R, TT, TRT lobes;
- Gaussian longitudinal scattering;
- separate per-lobe tilt and roughness scales;
- analytical/Fresnel attenuation;
- preintegrated azimuthal scattering;
- color-to-absorption conversion;
- compile-time lobe skipping for debugging and reduced variants.

Recommended per-lobe scales based on the Unity production model:

```text
Cuticle tilt:
R   = -alpha
TT  = +0.5 alpha
TRT = +1.5 alpha

Longitudinal roughness:
R   = beta
TT  = 0.5 beta
TRT = 2.0 beta
```

These should be defaults, not hard-coded artistic limits.

### Azimuthal distribution

Implement a generated 3D LUT storing R, TT, and TRT azimuthal distributions:

```text
X: relative azimuth phi
Y: cos(theta_d)
Z: azimuthal roughness
RGB: R, TT, TRT distributions
```

Reference architecture:

```text
Unity HDRP:
PreIntegratedAzimuthalScattering.hlsl
HairMultipleScatteringPreIntegration.compute
Hair.cs
```

Generate the LUT from the published trimmed-logistic/fiber-width integration, not by copying Unity shader source.

Recommended initial resolution:

```text
32 x 32 x 32 for development
64 x 64 x 64 for final comparison
```

Benchmark both. Prefer a compressed or lower-precision representation only after validating lobe shape and energy.

### Attenuation

Use representative cross-section offsets for fast attenuation:

```text
h_TT  = 0
h_TRT = sqrt(3) / 2
```

Retain analytical IOR support where inexpensive. A human-hair-only Karis IOR approximation may be provided as a compile-time fast option.

### Multiple scattering

Tier 2 should eventually use local dual scattering, but implementation can be staged:

**Stage A**

- retain the current Karis approximation;
- connect strength and density controls cleanly.

**Stage B**

- add a preintegrated average attenuation LUT;
- compute local dual scattering;
- use the existing `attributes_texture.g` depth channel as a density/visibility proxy;
- omit global directional strand-count integration.

Reference:

```text
Unity HDRP:
MultipleScattering/HairMultipleScattering.hlsl
MultipleScattering/HairMultipleScatteringPreIntegration.compute
```

### Indirect/environment response

Implement two options:

1. **Default fast IBL**
   - use ordinary Godot environment response only as a broad base;
   - optionally add a single supplied environment-texture sample;
   - evaluate R and TRT using a representative environment direction;
   - skip or strongly reduce TT;
   - broaden R/TRT roughness.

2. **No custom IBL**
   - for Mobile/Compatibility or constrained targets.

Do not use a screen-space gather in Tier 2 by default.

### Area lights

Use an explicit `LIGHT_IS_AREA` path:

```text
R/TRT:
- scale using area specular multiplier.

TT:
- test specular multiplier;
- test a blend of area specular and area diffuse multipliers;
- choose empirically based on backlit rectangle-light scenes.

All lobes:
- optionally broaden longitudinal roughness using a monotonic area proxy
  derived from the multiplier magnitude.
```

Do not introduce an unvalidated heuristic into the final default. Keep the choices behind debug modes during the area-light research milestone.

### Required inputs

```text
base_color / reflectance
absorption_mode
absorption
eumelanin
pheomelanin
longitudinal_roughness
azimuthal_roughness
cuticle_tilt
ior
specular_strength
R/TT/TRT scales
scatter_strength
density/depth influence
strand_tangent
coverage
depth
seed
```

### Acceptance criteria

- R is neutral and narrow.
- TT becomes prominent and colored under backlighting.
- TRT is dimmer, broader, and more saturated than TT.
- Azimuthal roughness affects all three lobes.
- The LUT path is visually stable under camera rotation.
- Direct-light cost is substantially below Tier 3.
- Local dual scattering does not brighten with the number of direct lights except where physically expected.
- Area lights produce wider, more stable highlights than point-light treatment.
- A fallback operates without LUTs.

---

## 4.3 Tier 3 — High Marschner / Cinematic Approximation

### Purpose

Preserve and extend the current high-quality GodotHair direct model for:

- hero characters;
- cinematics;
- close shots;
- low direct-light counts;
- Forward+ desktop targets.

### Direct-light model

Refactor rather than replace the current implementation in:

```text
assets/hair/materials/shaders/hair.gdshaderinc
```

Retain:

- energy-conserving longitudinal scattering;
- Bessel approximation;
- non-separable longitudinal widths and tilts;
- analytical effective IOR;
- cross-section-dependent R/TT/TRT behavior;
- optional exact lobe-tilt calculation;
- optional analytical TRT cross-section solution;
- per-lobe debug scales.

Move its functions into a dedicated include:

```text
hair_marschner_high.gdshaderinc
```

Expose compile-time variants for:

```text
HIGH_LONGITUDINAL_ENERGY_CONSERVING
HIGH_NON_SEPARABLE_LOBES
HIGH_EXACT_TILT
HIGH_ANALYTIC_TRT_H
HIGH_RESIDUAL_LOBE
```

The defaults should match the current repository until the refactor is visually verified.

### Multiple scattering

Add local and optional global dual scattering.

**Local mode**

- preintegrated forward/backward attenuation;
- average backscattering shift and variance;
- one- and three-event backward scattering;
- existing depth texture as local strand-density proxy.

**Global approximation**

Godot does not expose Unity's spline visibility or strand-count probe automatically. Add a project-owned proxy:

```text
Option A: packed per-card/per-pixel density texture
Option B: low-order spherical-harmonic strand-count data supplied by script
Option C: volume texture or probe generated around the hairstyle
```

Start with Option A. Design the data API so B or C can be added later without changing the BSDF interface.

### Cinematic environment option A: explicit environment texture

This is the preferred high-tier environment path.

Inputs:

```text
samplerCube or panorama texture
environment rotation
environment intensity
sample count
sample sequence texture or deterministic Hammersley sequence
frame/sample jitter
```

Algorithm:

1. Build a local hair frame from strand tangent and geometric normal.
2. Generate 2–8 directional samples around the sphere.
3. Sample the supplied environment texture.
4. Evaluate the hair BSDF for each direction.
5. Accumulate once per fragment.
6. Add the result as indirect/specular emission, not inside `light()`.
7. Optionally jitter over frames for temporal accumulation by the renderer.

Quality presets:

```text
High-low:   2 samples
High:       4 samples
Cinematic:  8 samples
Reference: 16 samples for validation only
```

This is still an approximation because it lacks direct access to reflection-probe blending, light hierarchy weights, and renderer-owned sky filtering.

### Cinematic environment option B: screen-space indirect proxy

Implement this as an optional second pass.

Inputs:

```text
screen color
depth texture
normal/roughness texture
inverse projection matrix
inverse view matrix
sample radius
sample count
depth rejection threshold
normal rejection threshold
distance falloff
intensity
maximum mip level
frame index / blue-noise offset
```

Algorithm:

1. Sample neighboring screen positions around `SCREEN_UV`.
2. Reconstruct each sampled opaque position from depth.
3. Compute a direction from the hair fragment to the sampled position.
4. Reject:
   - invalid/far-plane depth;
   - surfaces in front of the hair when inappropriate;
   - samples crossing strong depth discontinuities;
   - samples with incompatible normals;
   - excessively distant samples.
5. Read blurred screen color at an LOD tied to sample radius.
6. Evaluate a reduced hair response for that direction.
7. Accumulate a low-frequency indirect term.
8. Clamp to prevent recursive-looking brightness.
9. Output once through the additive overlay pass.

This mode should be named clearly, for example:

```text
Screen-Space Hair Indirect
```

Do not call it true cinematic environment sampling.

### Screen-space pass architecture

Recommended:

```text
hair_marschner_high.gdshader
    Main opaque/alpha-hashed direct and multiple-scattering pass.

hair_screen_indirect.gdshader
    Transparent additive next pass using screen/depth/normal textures.
```

The overlay pass should not define a per-light `light()` function. It should add only the indirect proxy once.

Validate both integration methods:

- `Material.next_pass`;
- a duplicate hair mesh with a dedicated overlay material.

Prefer `next_pass` if ordering and skinning behavior are stable.

### Area lights

Use the same direct approximation as Tier 2 but retain the high-quality BSDF. Add a separate validation-only experiment that broadens or offsets sample directions to imitate multiple representative points.

Do not claim full cinematic area-light sampling unless the renderer is extended to expose rectangle geometry.

### Acceptance criteria

- Refactored direct lighting matches current GodotHair within a defined image-difference tolerance.
- Local dual scattering removes the overly dark single-scattering appearance without flattening R/TT/TRT.
- Explicit environment sampling responds to off-screen HDR features.
- Screen-space indirect responds to nearby opaque colored surfaces.
- Screen-space indirect is invariant to direct-light count.
- Hair shadows remain provided by the main pass.
- Screen-space overlay does not visibly double coverage or alter alpha-hash silhouettes.
- Performance and sample-count scaling are documented.

---

## 5. Shader Architecture

Use separate shader entry files instead of one runtime `quality` branch. Expensive functions must not remain compiled into low tiers.

Recommended layout:

```text
assets/hair/materials/shaders/
├── hair_common.gdshaderinc
├── hair_surface_data.gdshaderinc
├── hair_absorption.gdshaderinc
├── hair_card_geometry.gdshaderinc
├── hair_alpha.gdshaderinc
├── hair_kajiya_kay.gdshaderinc
├── hair_marschner_fast.gdshaderinc
├── hair_marschner_high.gdshaderinc
├── hair_multiple_scattering.gdshaderinc
├── hair_area_light.gdshaderinc
├── hair_screen_indirect.gdshaderinc
├── hair_approx.gdshader
├── hair_marschner_fast.gdshader
├── hair_marschner_high.gdshader
└── hair_screen_indirect.gdshader
```

### 5.1 Shared data contract

Godot shader language does not provide the same struct workflow as Unity in every context, so organize data through consistently named varyings and helper arguments.

Canonical conceptual data:

```text
HairSurfaceData
- base_reflectance
- absorption
- alpha/coverage
- strand_u
- depth
- seed
- geometric_normal
- strand_tangent
- strand_binormal
- view_direction
- longitudinal_roughness
- azimuthal_roughness
- cuticle_tilt
- ior
- lobe_scales
```

All tiers must use the same conventions:

- strand tangent points root to tip;
- all lighting directions are normalized and in one documented space;
- roughness is perceptual at the material boundary;
- scattering-space beta is derived once;
- color values are linear when used in scattering equations;
- absorption is non-negative;
- epsilon policy is centralized.

### 5.2 Material wrapper

Create a script/resource that selects the shader variant and maps one artist-facing profile into variant-specific uniforms.

Suggested resource:

```text
assets/hair/materials/HairMaterialProfile.gd
```

Responsibilities:

- quality-tier enum;
- common color/roughness/tilt settings;
- absorption mode;
- tier-specific overrides;
- texture assignment;
- optional LUT assignment;
- optional screen-indirect next pass;
- renderer/feature warnings;
- debug mode selection.

Switching tiers should not require reauthoring textures.

### 5.3 Compile-time and resource variants

Create material resources for:

```text
HairApprox.tres
HairFastMarschner.tres
HairHighMarschner.tres
HairHighMarschnerScreenIndirect.tres
```

Use compile-time shader variants for expensive optional paths where possible. Avoid uniform-controlled branches around large algorithms unless Godot's generated shader can prove the branch constant.

---

## 6. Common Material Interface

### Color mode

```text
Reflectance color
Direct absorption coefficient
Melanin concentrations
```

All modes convert to canonical `sigma_a`.

### Geometry and cards

```text
coords_texture
attributes_texture
optional flow map
tangent perturbation/frizz
root/tip gradient
coverage bias
alpha-hash controls
```

### Scattering

```text
longitudinal roughness
azimuthal roughness
cuticle tilt
IOR
specular strength
R scale
TT scale
TRT scale
multiple-scattering strength
density/depth strength
```

### Kajiya–Kay-only controls

```text
primary tint
secondary tint
primary roughness
secondary roughness
primary shift
secondary shift
primary strength
secondary strength
```

### High-tier indirect controls

```text
environment mode
explicit environment texture
environment sample count
screen-indirect enable
screen sample count
screen radius
depth rejection
normal rejection
temporal jitter
indirect clamp
```

### Debug controls

```text
show cards
show coverage
show depth
show seed
show strand tangent
show R
show TT
show TRT
show direct scattering
show local multiple scattering
show global multiple scattering
show screen-space indirect
show area multiplier
```

---

## 7. Implementation Milestones

## Milestone 0 — Baseline and Test Harness

### Tasks

- Lock the initial comparison to a known `2Retr0/GodotHair` commit.
- Capture reference images and GPU timings from the current shader.
- Create a deterministic test scene with:
  - one directional light;
  - one OmniLight3D;
  - one SpotLight3D;
  - one AreaLight3D;
  - an HDR environment;
  - colored opaque walls;
  - backlit and grazing-angle cameras;
  - overlapping cards;
  - dark, blond, red, and gray hair profiles.
- Add lobe-isolation screenshots.
- Record render resolution, MSAA/TAA settings, shadow quality, and renderer.

### Exit criteria

- Repeatable baseline images.
- Repeatable per-frame and per-draw GPU timings.
- A visual checklist for R, TT, TRT, alpha, roots/tips, and card seams.

---

## Milestone 1 — Shared Refactor Without Visual Change

### Tasks

- Split card geometry, alpha, absorption, and high Marschner functions into includes.
- Create `hair_marschner_high.gdshader`.
- Preserve existing material uniform names through a compatibility wrapper where practical.
- Centralize safe math:
  - clamped square root;
  - safe normalize;
  - minimum roughness;
  - safe luminance;
  - safe logarithm;
  - bounded exponent.
- Add debug output modes.

### Exit criteria

- New high-tier shader matches the current shader.
- No change to alpha silhouette or card tangent orientation.
- No measurable performance regression beyond normal compiler variation.

---

## Milestone 2 — Tier 1 Kajiya–Kay

### Tasks

- Port/reimplement the two-lobe design.
- Add separate tint, roughness, shift, and strength per lobe.
- Add wrapped diffuse or existing cheap multiple scattering.
- Add directional, omni, and spot-light testing.
- Add area-light multiplier path.
- Add material profile mapping.

### Exit criteria

- Tier switch works without texture changes.
- Stable two-lobe highlights.
- Measured cost target established relative to baseline.
- Mobile/Compatibility behavior documented.

---

## Milestone 3 — Tier 2 Fast Marschner Core

### Tasks

- Implement Gaussian longitudinal R/TT/TRT.
- Implement fixed per-lobe roughness/tilt defaults.
- Implement color/absorption/melanin input modes.
- Add analytic azimuthal fallback based on the inexpensive reference implementation.
- Add lobe debug switches.
- Compare with current high tier.

### Exit criteria

- Correct qualitative R, TT, TRT behavior.
- No LUT dependency yet.
- Fast tier is materially cheaper than high tier.
- No NaNs at roughness, angle, and color extremes.

---

## Milestone 4 — Preintegrated Azimuthal LUT

### Tasks

- Implement an offline LUT generator.
- Generate 32³ and 64³ candidates.
- Add importer/resource setup.
- Add runtime sampling.
- Validate periodic phi mapping and edge continuity.
- Compare LUT result to:
  - high-tier runtime model;
  - analytic fast fallback;
  - Unity reference screenshots where available.

### Exit criteria

- All three lobes respond to azimuthal roughness.
- No seams at azimuth wrap.
- LUT memory and sample cost documented.
- Fallback remains functional.

---

## Milestone 5 — Dual Scattering

### Tasks

- Implement attenuation LUT generation.
- Add local dual scattering to fast and high tiers.
- Map `attributes_texture.g` into density/visibility.
- Add controls for local scattering strength and density response.
- Add optional global-density input interface without requiring it yet.
- Ensure multiple scattering is evaluated once per light only where the formulation is light-dependent and once per fragment for global/ambient terms.

### Exit criteria

- Deep strands brighten and saturate plausibly.
- Backlit hair retains TT structure.
- No arbitrary diffuse term remains enabled by default in fast/high tiers.
- Tier 1 keeps its cheap approximation.

---

## Milestone 6 — Godot 4.7 Area-Light Approximation

### Research variants

Evaluate these variants against the same AreaLight3D scenes:

**A. Scalar specular scaling**

```text
hair_bsdf * luminance(LIGHT_AREA_SPECULAR_MULTIPLIER)
```

**B. RGB specular scaling**

```text
hair_bsdf * LIGHT_AREA_SPECULAR_MULTIPLIER
```

**C. Lobe-specific scaling**

```text
R/TRT use area specular multiplier
TT uses a tuned blend of area diffuse and specular multipliers
```

**D. Roughness broadening**

```text
derive a bounded area proxy from multiplier magnitude
increase beta_R, beta_TT, beta_TRT
renormalize approximately
```

### Tasks

- Test all variants for small/large rectangular lights.
- Test light rotation and camera motion.
- Test textured AreaLight3D.
- Document Forward+, Mobile, and Compatibility behavior.
- Select one default per tier.

### Exit criteria

- No sudden intensity jumps between area and non-area lights.
- Large rectangle lights produce broader highlights.
- Backlighting remains plausible.
- Limitations are documented as an approximation.

---

## Milestone 7 — Explicit Environment Sampling

### Tasks

- Add a project-owned environment cubemap/panorama input.
- Build local sampling basis.
- Implement 2/4/8-sample presets.
- Add deterministic and temporally jittered sequences.
- Accumulate in `fragment()`, never once per direct light.
- Add roughness-dependent environment LOD.
- Compare with low-mip representative-direction mode.

### Exit criteria

- Off-screen bright environment features affect high-tier hair.
- Result is invariant to direct-light count.
- Sample scaling and temporal stability are measured.
- Fast tier can use a one-sample subset.

---

## Milestone 8 — Screen-Space Hair Indirect

### Tasks

- Build a separate additive overlay shader.
- Add screen/depth/normal sampling.
- Reconstruct sample positions.
- Add sample rejection and falloff.
- Add 4/8/16-sample presets.
- Add temporal jitter using a script-supplied frame index or blue-noise texture.
- Test `next_pass` and duplicate-mesh integration.
- Test foreground contamination and camera-edge behavior.
- Add explicit off switch and Forward+ requirement.

### Exit criteria

- Main pass still casts shadows and retains opaque alpha-hash behavior.
- Overlay reacts to nearby opaque scene colors.
- Transparent hair does not incorrectly self-feed.
- Foreground contamination is bounded.
- Indirect contribution does not scale with light count.
- Performance is documented separately from the direct tier.

---

## Milestone 9 — Optimization and Shipping Profiles

### Tasks

- Inspect generated shaders.
- Remove duplicated calculations between `fragment()` and `light()`.
- Move material-invariant calculations to CPU/resource setup.
- Quantize or pack LUTs where visually safe.
- Add static low/high variants.
- Add distance-based tier switching through material or LOD setup.
- Document supported renderer matrix.
- Add automated visual captures where practical.

### Shipping profiles

```text
Low:
Kajiya–Kay
No LUT
Cheap scatter
No screen indirect

Medium:
Fast Marschner
Azimuthal LUT
Local dual scattering
One-sample environment approximation

High:
High Marschner direct
Local dual scattering
4-sample explicit environment

Cinematic:
High Marschner direct
Local/global scattering proxy
8-sample explicit environment
Optional screen-space indirect overlay
```

---

## 8. Performance and Validation Matrix

Measure at minimum:

```text
1920 x 1080
2560 x 1440
1, 4, and 8 active lights
directional-only
mixed point/spot
AreaLight3D
screen indirect off
screen indirect 4/8/16 samples
environment sampling 1/2/4/8 samples
```

Record:

```text
GPU frame time
hair draw time where available
shader compilation time
texture memory
LUT memory
overdraw
transparent overlay cost
shadow-pass cost
```

Visual cases:

```text
front light
back light
grazing light
large area light
small area light
high-frequency HDR environment
colored wall near hair
dark room with small bright source
camera orbit
animated/skinned hair cards
extreme roughness
extreme cuticle tilt
near-black reflectance
near-white reflectance
```

Numerical checks:

- no NaN or infinity output;
- non-negative lobe energy;
- stable behavior near `cos(theta) = 0`;
- no divide by zero at black albedo;
- normalized tangent basis;
- smooth phi wrap;
- bounded multiple scattering;
- bounded screen-space indirect;
- approximate energy tracking while varying roughness.

---

## 9. Decisions to Lock Early

1. **Full target is Godot 4.7.1 Forward+.**
   Tier 1 and portions of Tier 2 may support other renderers.

2. **Use separate entry shaders per tier.**
   Do not use one large runtime quality branch.

3. **Preserve the current GodotHair direct model as Tier 3.**
   Refactor only after baseline capture.

4. **Implement Tier 2 around Gaussian longitudinal scattering and an azimuthal LUT.**

5. **Evaluate indirect contributions once per fragment, not once per light.**

6. **Do not add `hint_screen_texture` to the main hair material.**
   Use a separate overlay pass.

7. **Treat Godot area-light data as an approximation interface.**
   The public shader API does not expose enough geometry for sampled rectangle integration.

8. **Prefer explicit environment textures over screen-space color for directional IBL.**

9. **Use existing coverage/depth data for hair density.**
   Screen textures cannot model transparent hair self-scattering.

10. **Maintain an analytic fallback for every required LUT.**

11. **Reimplement algorithms from papers.**
    Unity source is a reference, not code to port verbatim.

---

## 10. Initial Agent Work Order

The implementation agent should begin with this sequence:

1. Create the baseline test scene and capture current output.
2. Split `hair.gdshaderinc` into high-tier and common includes without changing output.
3. Create `hair_approx.gdshader` and implement two-lobe Kajiya–Kay.
4. Create `hair_marschner_fast.gdshader` with analytic Gaussian R/TT/TRT.
5. Add the material-profile resource/script that swaps variants.
6. Add common debug views and lobe isolation.
7. Add Godot 4.7 `LIGHT_IS_AREA` instrumentation and capture multiplier behavior.
8. Implement the azimuthal LUT generator and runtime sampler.
9. Implement local dual scattering.
10. Add explicit environment sampling.
11. Add the separate screen-space indirect overlay.
12. Optimize and define shipping presets.

The first pull request should stop after steps 1–6. It should establish the three-tier architecture and material API without introducing LUT generation, dual scattering, or screen reading. This keeps the architectural refactor reviewable and minimizes simultaneous visual changes.

---

## 11. Official Godot Documentation

- Spatial shader reference:  
  <https://docs.godotengine.org/en/stable/tutorials/shaders/shader_reference/spatial_shader.html>

- Screen-reading shaders:  
  <https://docs.godotengine.org/en/stable/tutorials/shaders/screen-reading_shaders.html>

- Material `next_pass`:  
  <https://docs.godotengine.org/en/stable/classes/class_material.html>

- AreaLight3D:  
  <https://docs.godotengine.org/en/stable/classes/class_arealight3d.html>

- Renderer feature comparison:  
  <https://docs.godotengine.org/en/stable/tutorials/rendering/renderers.html>

- Using a SubViewport as a texture:  
  <https://docs.godotengine.org/en/stable/tutorials/shaders/using_viewport_as_texture.html>
