# Hair material authoring

The production hair models remain separate compiled shaders, but artists and runtime callers should treat `HairMaterialProfile` as the single material-look authoring surface and `HairGroomData` as the groom-specific card-data surface.

This deliberately avoids a runtime-branching mega-shader. Approx/Kajiya-Kay, Fast Marschner, Cinematic Marschner, and analytic Reference retain independent shader binaries while sharing the same groom, coverage, wetness, and card-preparation contracts.

## Material profile versus groom data

The two resources own different things:

```text
HairMaterialProfile                 HairGroomData
-------------------                 -------------
quality tier                         coords_texture
coverage policy                      attributes_texture
hair color
roughness / specular / cuticle
optical wetness
absorption / melanin
mode-specific LUT overrides
Kajiya-Kay controls
```

`HairMaterialProfile` is reusable across multiple grooms. `HairGroomData` belongs to one generated card atlas and contains the maps produced with that groom.

The shared texture contract is:

```text
coords_texture
  RGB = tangent direction encoded [0,1] for a [-1,1] vector
  A   = root-to-tip coordinate

attributes_texture
  R = coverage / occupancy
  G = strand depth
  B = deterministic per-strand seed
```

These textures are shader data, not ordinary albedo/metallic/roughness textures. Keep them paired with the card mesh/UV atlas that generated them.

## Creating a new groom

Create a `HairGroomData` resource and assign the two generated textures in the Inspector. Then either apply it to an existing `ShaderMaterial`:

```gdscript
var ok: bool = profile.apply_to(shader_material, groom_data, get_viewport())
```

or create the hair material from scratch:

```gdscript
var material: ShaderMaterial = profile.create_material(groom_data, get_viewport())
hair_mesh.material_override = material
```

No pre-authored hair `ShaderMaterial` is required.

For migration, `HairGroomData.from_shader_material(old_material)` can capture `coords_texture` and `attributes_texture` from an existing generated source material without modifying it.

## Quality tier

`HairMaterialProfile.quality_tier` retains the serialized mapping:

```text
0  Approx / Kajiya-Kay
1  Fast Marschner
2  Cinematic Marschner
3  Reference Marschner
```

The Inspector presents friendly dropdown labels. Changing the tier refreshes the property list and hides controls that do not affect the selected shader. Hidden fields remain serialized, so switching away from a tier and back does not discard its settings.

### Approx / Kajiya-Kay

Approx exposes the shared albedo/specular/wetness controls plus primary/secondary Kajiya-Kay lobe color, shift, roughness, strength, and wrapped scatter. It does not consume the Marschner azimuthal-roughness or physical TT/TRT controls directly.

### Fast Marschner

Fast uses the Unity HDRP Standard-style approximation and the packaged `unity_hdrp_azimuthal_n_v1` 3D LUT. Its IOR is intentionally pinned to `1.55`; arbitrary IOR would be inconsistent with the preintegrated LUT contract.

The absorption selector controls the Inspector surface:

```text
Albedo reparameterization -> no extra absorption fields
Direct absorption         -> absorption / sigma_a
Melanin                   -> eumelanin, pheomelanin, absorption scale
```

The optional Fast LUT override accepts a compatible `Texture3D`. Normal users should leave it null and use the packaged direct `ImageTexture3D` resource.

### Cinematic Marschner

Cinematic exposes authorable IOR and an optional conditioned-longitudinal LUT override. The default `deon_physical_longitudinal_log2q_v2` LUT is packaged as a direct `ImageTexture3D` resource.

### Reference Marschner

Reference preserves the analytic baseline and is primarily intended for validation/comparison. It still receives the shared base-hair, coverage, and wetness parameters.

## Coverage authoring

`coverage_mode` supports:

```text
Auto
Static Bayer
TAA Temporal Bayer
Alpha-to-Coverage
```

`Auto` uses both the owning viewport and the active rendering method:

```text
Forward+ or Mobile + MSAA  -> Alpha-to-Coverage
otherwise Forward+ + TAA   -> TAA Temporal Bayer
otherwise                  -> Static Bayer
```

This avoids the old failure mode where a time-driven Bayer phase animated even when no temporal reconstruction was active.

Static and temporal Bayer share the normal compiled shader family. Temporal Bayer changes only `bayer_phase_index`, advancing through all 16 ordered-dither phases once per rendered frame. Alpha-to-coverage requires a separate shader variant because `alpha_to_coverage` is a compile-time render mode.

For one-time creation, pass the owning viewport to `create_material()` or `apply_to()`. If the viewport's AA configuration can change later, register the material with `HairCoverageController` so it can swap normal/A2C variants and update the Bayer phase.

## Optical wetness authoring

Wetness is a shading feature, not a groom deformation system. The material does not clump hair, reduce groom volume, add weight, or move cards/strands. Use a wet groom, shape keys, or another deformation/simulation system for geometry changes.

`wetness = 0` is the strict dry endpoint. Increasing it modifies the optical response through three coupled mechanisms:

```text
wetness
  |-- darker internal transport / multiple scattering
  |-- narrower underlying hair highlights and reduced cuticle shift
  `-- separate untinted dielectric water-film reflection
```

The calibrated defaults are:

| Parameter | Default |
| --- | ---: |
| `wetness` | `0.0` |
| `wet_film_roughness` | `0.10` |
| `wet_film_specular_strength` | `2.0` |
| `wet_longitudinal_roughness_scale` | `0.45` |
| `wet_azimuthal_roughness_scale` | `0.55` |
| `wet_internal_scatter_scale` | `0.35` |
| `wet_transmission_scale` | `0.65` |
| `wet_cuticle_shift_scale` | `0.50` |

Fast wetness never changes its eta `1.55` LUT contract. The water-film lobe is an additional dielectric response using approximate water IOR `1.333`.

See [`hair_wetness.md`](hair_wetness.md) for the tier-specific model and validation results.

## Applying a profile

`apply_to()` performs the complete composition:

1. validates a supplied groom before mutating the material;
2. resolves the effective coverage policy from the requested mode and optional viewport;
3. chooses the compiled quality/coverage shader variant;
4. captures caller-owned shared parameters from the previous shader;
5. assigns the selected shader;
6. restores compatible caller-owned parameters;
7. applies profile values supported by the target shader;
8. binds the Fast or Cinematic production LUT when required;
9. explicitly binds the supplied `HairGroomData` textures.

The currently preserved shared parameters include:

```text
coords_texture
attributes_texture
show_hair_cards
show_hashed_strands
bayer_phase_index
comparison_exposure_gain
lobe_scales
use_area_light_multipliers
```

`freeze_bayer_phase` is retained only as a compatibility-preserved name for older materials; the production coverage policy uses `bayer_phase_index` and `HairCoverageController`.

Explicit `HairGroomData` takes precedence over preserved groom textures.

`apply_to_shader_material()` remains a compatibility API for benchmark/experimental callers that deliberately select a shader themselves. It applies supported profile values to the material's current shader without replacing that shader.

`bind_quality_resources()` remains a compatibility alias for `bind_mode_resources()`.

## Direct LUT binding

Normal production code does not reconstruct the LUTs from raw byte resources.

Development paths:

```text
res://assets/hair/luts/unity_azimuthal_64.res
res://assets/hair/luts/cinematic_longitudinal_kernel_128x128x64.res
```

Release-package paths:

```text
res://addons/marschner_hair/luts/unity_azimuthal_64.res
res://addons/marschner_hair/luts/cinematic_longitudinal_kernel_128x128x64.res
```

`HairMarschnerLUTAdapter` loads these directly as `ImageTexture3D`, checks the expected dimensions/format/RID, and binds the fixed semantic contract. Legacy raw-data helpers remain only for development storage benchmarks.

On the validated Godot 4.7 setup, ImageTexture3D materialization/integrity checks must run with a normal rendering context. The headless display path can produce/load empty 1x1x1 texture stubs.

## Shared card preparation

All four production variants include `hair_card_common.gdshaderinc` for behavior independent of the lighting model:

```text
coverage/depth ordered dithering or A2C coverage preparation
root-to-tip base-color darkening
per-strand hash
frizz amount and tangent perturbation
orthonormal TBN reconstruction
```

Optical wetness intentionally leaves the tangent/frizz perturbation driven by the authored dry roughness. Wetness therefore cannot silently substitute for a clumped/deformed groom.

The top-level shaders still declare their reflected uniform interfaces directly. Shared includes centralize math, not the editor-visible material interface.

## Inspector documentation

The authoring layer has two tooltip surfaces:

- `HairMaterialProfile` exported properties use GDScript `##` documentation comments.
- Direct shader uniforms use GDShader `/** ... */` documentation comments.

This means artists authoring through either the profile or a raw ShaderMaterial can hover a parameter in the Inspector to see its purpose, units/meaning, and important contracts such as Fast eta `1.55`.

## Editor preview

Open:

```text
res://demos/HairMaterialProfileEditor.tscn
```

The preview composes:

```text
material_profile
groom_data
```

into a local `ShaderMaterial`. It is useful for comparing quality tiers, coverage variants, and wetness while retaining the same groom data.

## Why the shaders stay split

The tier and A2C choices are material/shader decisions, not one giant uniform branch. Separate compiled variants preserve:

- independent shader compilation;
- independent sampler/register pressure;
- mode-specific LUT resources;
- no runtime branch over complete BSDF implementations;
- clean performance attribution;
- a compile-time A2C render mode only where needed.

## Validation

Release-relevant development checks currently include:

```bash
# deterministic CPU/interface checks
godot --headless --path . --script res://benchmark/tests/test_hair_groom_binding.gd
godot --headless --path . --script res://benchmark/tests/test_marschner_production_profile.gd
godot --headless --path . --script res://benchmark/tests/test_hair_coverage_phase_sequence.gd
godot --headless --path . --script res://benchmark/tests/test_hair_coverage_policy.gd
godot --headless --path . --script res://benchmark/tests/test_hair_wetness_interface.gd

# real-renderer checks
godot --path . --script res://benchmark/tests/test_direct_lut_binding.gd
godot --path . --script res://benchmark/tests/test_hair_coverage_runtime_policy.gd
godot --path . --script res://benchmark/tests/test_hair_wetness_runtime.gd
```

The wetness validation additionally included visual dry/wet comparisons, component ablation, film calibration, and a Fast 1080p GPU benchmark on RTX 5090 plus AMD integrated graphics. See [`hair_wetness.md`](hair_wetness.md).

Before publishing a repackaged addon, also follow [`release_validation.md`](release_validation.md) to catch path/import errors introduced by moving the production sources under `addons/marschner_hair/`.
