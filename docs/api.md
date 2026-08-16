# Runtime API reference

Concise, manually maintained reference for the production hair runtime. The
runtime keeps four quality tiers as separate compiled shaders behind one
authoring surface (`HairMaterialProfile`) plus groom-specific card data
(`HairGroomData`) and a shared coverage policy (`HairCoveragePolicy`).

For authoring workflows, LUT contracts, shader switching internals, and the
preserved-parameter list, see [`hair_material_authoring.md`](hair_material_authoring.md).
For the optical wetness model and calibration, see [`hair_wetness.md`](hair_wetness.md).

## `HairMaterialProfile`

`Resource` (`class_name HairMaterialProfile`). One authoring surface that
selects the compiled lighting model and coverage path. Reusable across grooms.

### Quality tiers

Serialized values remain stable for compatibility:

```text
0  Approx / Kajiya-Kay
1  Fast Marschner
2  Cinematic Marschner
3  Reference Marschner
```

```gdscript
HairMaterialProfile.QualityTier.APPROX
HairMaterialProfile.QualityTier.FAST_MARSCHNER
HairMaterialProfile.QualityTier.CINEMATIC_MARSCHNER
HairMaterialProfile.QualityTier.REFERENCE_MARSCHNER
```

| Tier | Intended use | Main tradeoff |
| --- | --- | --- |
| Approx / Kajiya-Kay | Constrained hardware, fallback, non-Marschner comparison | Lowest cost, least physical fidelity |
| Fast Marschner | Normal production Marschner path | Good quality/cost balance; fixed eta `1.55` LUT contract |
| Cinematic Marschner | High-fidelity shots where extra per-light cost is acceptable | Conditioned longitudinal 3D LUT is the most expensive production tier |
| Reference Marschner | Analytic comparison and validation | Validation baseline rather than the default shipping tier |

Validated production cost ordering: `Approx < Fast < Reference < Cinematic`.

### Exported properties

- **Quality** — `quality_tier: int` selects the compiled lighting model and
  refreshes the Inspector; controls that do not affect the selected tier are
  hidden while their serialized values are preserved.
- **Coverage** — `coverage_mode: int` (`HairCoveragePolicy.Mode`); `AUTO` is
  the normal recommendation.
- **Base Hair** — `albedo`, `longitudinal_roughness`, `azimuthal_roughness`,
  `specular`, `cuticle_tilt_offset`.
- **Wetness** — `wetness` plus the calibrated film/fiber-response endpoints:

  | Control | Default |
  | --- | ---: |
  | `wetness` | `0.0` |
  | `wet_film_roughness` | `0.10` |
  | `wet_film_specular_strength` | `2.0` |
  | `wet_longitudinal_roughness_scale` | `0.45` |
  | `wet_azimuthal_roughness_scale` | `0.55` |
  | `wet_internal_scatter_scale` | `0.35` |
  | `wet_transmission_scale` | `0.65` |
  | `wet_cuticle_shift_scale` | `0.50` |

- **Fast Marschner** — `absorption_mode` (Albedo reparameterization / Direct
  absorption / Melanin), `absorption`, `eumelanin`, `pheomelanin`,
  `melanin_absorption_scale`, optional `unity_azimuthal_lut_data` override.
- **Cinematic Marschner** — `ior` (default `1.55`), optional
  `cinematic_longitudinal_lut_data` override.
- **Approx / Kajiya-Kay** — primary/secondary lobe `color`, `shift`,
  `roughness`, `strength`, and wrapped `scatter`.

Every exported property carries an Inspector hover description.

### Primary methods

```text
get_shader_resource(viewport = null) -> Shader
get_effective_coverage_mode(viewport = null) -> int
apply_to(material, groom_data = null, viewport = null) -> bool
create_material(groom_data = null, viewport = null) -> ShaderMaterial
update_coverage_for_viewport(material, viewport, rendered_frame_index = -1) -> bool
bind_mode_resources(material) -> bool
```

- `get_shader_resource()` returns the compiled shader for the selected tier and
  effective coverage policy. `AUTO` without a viewport resolves to stable Bayer.
- `apply_to()` validates a supplied groom, resolves coverage, selects the
  compiled variant, preserves caller-owned shared parameters across shader
  swaps, applies profile values, binds the Fast/Cinematic production LUT when
  required, and binds the groom textures. Returns `false` on any failure.
- `create_material()` builds a new `ShaderMaterial` through `apply_to()`.
- `update_coverage_for_viewport()` is the runtime path used by
  `HairCoverageController`; it swaps normal/A2C compiled variants when policy
  changes and advances the 16-phase temporal Bayer index.
- `bind_mode_resources()` binds only the LUT required by the material's
  explicit shader variant and returns `true` for tiers without a production LUT.

Compatibility APIs retained for benchmark/experimental callers:

```text
apply_to_shader_material(material) -> void
bind_quality_resources(material) -> bool
```

`apply_to_shader_material()` applies supported profile values to the material's
current shader without replacing it; `bind_quality_resources()` is an alias of
`bind_mode_resources()`.

## `HairGroomData`

`Resource` (`class_name HairGroomData`). Groom-specific card textures owned by
the card atlas that generated them. A `HairMaterialProfile` can be reused
across many grooms; `HairGroomData` cannot.

### Exported properties

- `coords_texture: Texture2D` — RGB = strand tangent encoded from `[-1, 1]`
  into `[0, 1]`, A = root-to-tip coordinate.
- `attributes_texture: Texture2D` — R = coverage/occupancy, G = strand depth,
  B = deterministic per-strand seed.

### Methods

```text
is_complete() -> bool
validation_message() -> String
apply_to_shader_material(material, warn_on_failure = true) -> bool
from_shader_material(material) -> Resource   # static
```

- `is_complete()` / `validation_message()` report whether both textures are
  assigned and what is missing.
- `apply_to_shader_material()` binds both textures to any production hair
  shader and returns `false` when the material lacks the shared groom contract
  or a required texture is missing.
- `from_shader_material()` is a migration convenience that reads the two groom
  uniforms from an existing generated material without modifying it.

## `HairCoveragePolicy`

`RefCounted` (`class_name HairCoveragePolicy`). Static coverage strategy shared
by `HairMaterialProfile` and `HairCoverageController`.

### Coverage modes

```gdscript
HairCoveragePolicy.Mode.AUTO
HairCoveragePolicy.Mode.STATIC_BAYER
HairCoveragePolicy.Mode.TAA_BAYER
HairCoveragePolicy.Mode.ALPHA_TO_COVERAGE
```

`AUTO` follows both viewport AA state and the active rendering method:

```text
Forward+ or Mobile + MSAA  -> Alpha-to-Coverage
otherwise Forward+ + TAA   -> 16-phase temporal Bayer
otherwise                  -> Static Bayer, phase 0
```

Static Bayer is the stable fallback; temporal Bayer advances once per rendered
frame and is only selected automatically when TAA is actually available. A2C
uses separate compiled shader variants because `alpha_to_coverage` is a shader
render mode, not a runtime uniform switch.

### Constants and static functions

```text
TAA_PHASE_COUNT = 16

resolve(viewport, requested_mode = Mode.AUTO, rendering_method = "") -> int
bayer_phase(effective_mode, rendered_frame_index) -> int
uses_alpha_to_coverage(effective_mode) -> bool
mode_name(effective_mode) -> String
```

## `HairCoverageController`

`Node` (`class_name HairCoverageController`). Registers materials whose
viewport AA configuration may change after creation.

```text
register_material(profile, material, viewport = null) -> bool
unregister_material(material) -> void
clear_materials() -> void
```

While registered, the controller re-resolves the effective coverage each frame
and calls `HairMaterialProfile.update_coverage_for_viewport()` so the compiled
variant and 16-phase Bayer index track the rendered-frame index.

## Coverage modes at a glance

| Mode | Behavior |
| --- | --- |
| `AUTO` | Viewport + rendering-method driven (see above); editor-safe without a viewport (stable Bayer) |
| `STATIC_BAYER` | Fixed Bayer phase 0; deterministic presentation |
| `TAA_BAYER` | 16-phase ordered dither advanced per rendered frame |
| `ALPHA_TO_COVERAGE` | Compiled A2C shader variant, no Bayer phase |
