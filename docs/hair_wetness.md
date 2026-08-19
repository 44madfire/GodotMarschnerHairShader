# Hair optical wetness

This feature models **optical wetness only**. It does not deform the groom, clump cards/strands, add weight, or simulate surface-tension geometry. Those effects should be authored through a separate wet groom, shape keys, strand simulation, or another deformation layer.

A production character can drive both systems from the same gameplay/animation wetness signal:

```text
gameplay wetness
  |-- HairMaterialProfile.wetness      -> optical response
  `-- wet groom / shape key / solver   -> geometry response
```

Keeping those responsibilities separate lets geometry quality scale independently from shading quality and prevents a material parameter from unexpectedly changing the groom silhouette.

## Design goals

The dry model remains the reference point. `wetness = 0.0` is the strict compatibility endpoint: the wetness helpers reduce to the existing dry shader behavior.

Increasing wetness adds a distinct smooth dielectric film response and modifies the underlying fiber transport instead of treating wet hair as merely dry hair with a different IOR.

The Fast tier deliberately keeps its eta `1.55` azimuthal-LUT contract. Wetness never changes that LUT's IOR. The water layer is modeled as a separate untinted dielectric reflection using approximate visible-light water IOR `1.333`.

## Authoring controls

| Control | Calibrated default | Meaning |
| --- | ---: | --- |
| `wetness` | `0.0` | Master optical wetness from dry (`0`) to saturated (`1`) |
| `wet_film_roughness` | `0.10` | Width of the added strand-aligned water-film highlight |
| `wet_film_specular_strength` | `2.0` | Artistic strength of the film reflection at full wetness |
| `wet_longitudinal_roughness_scale` | `0.45` | Remaining longitudinal roughness at full wetness |
| `wet_azimuthal_roughness_scale` | `0.55` | Remaining Marschner azimuthal roughness at full wetness |
| `wet_internal_scatter_scale` | `0.35` | Remaining diffuse/multiple-scattering intensity at full wetness |
| `wet_transmission_scale` | `0.65` | Remaining Marschner TT/TRT transport at full wetness |
| `wet_cuticle_shift_scale` | `0.50` | Remaining cuticle/tangent-shift separation at full wetness |

The endpoint values are production calibration choices, not claimed measured physical constants. In ordinary authoring, `wetness` should be the main control; the endpoint parameters exist for look-development and material-specific tuning.

Example runtime animation:

```gdscript
func set_hair_wetness(profile: HairMaterialProfile, amount: float) -> void:
    profile.wetness = clampf(amount, 0.0, 1.0)
```

If the material already exists, reapply the profile or set the shader parameter directly according to the application's material-management strategy.

## Optical decomposition

The wet response is intentionally split into three visible mechanisms:

```text
wetness
  |-- transport suppression
  |     `-- darker TT/TRT and multiple-scattering body response
  |
  |-- lobe narrowing / shift reduction
  |     `-- tighter underlying hair highlights
  |
  `-- dielectric water film
        `-- separate untinted bright reflection
```

This separation was validated with component ablation before the final film calibration.

## Tier behavior

### Approx / Kajiya-Kay

Wetness:

- narrows the primary/secondary Kajiya-Kay highlights;
- reduces their tangent-shift separation;
- suppresses wrapped diffuse scatter;
- adds the untinted water-film highlight.

`wet_azimuthal_roughness_scale` and `wet_transmission_scale` remain in the standardized cross-tier interface but do not have direct physical counterparts in Approx.

### Fast Marschner

Fast keeps the eta `1.55` preintegrated azimuthal LUT contract. Wetness:

- samples the existing LUT at a lower effective azimuthal roughness;
- narrows the separable longitudinal R/TT/TRT Gaussians;
- reduces cuticle-driven lobe separation;
- attenuates TT/TRT transport;
- attenuates the Karis-style multiple-scattering approximation;
- adds the separate water-film reflection.

The dry absorption reparameterization is intentionally left unchanged so wet darkening comes from explicit transport changes rather than an accidental change in the albedo-to-absorption fit.

### Cinematic Marschner

Cinematic applies the same optical policy while retaining its analytic azimuthal geometry and conditioned longitudinal LUT. Effective wet roughness is fed through the existing Chiang-style roughness reparameterization before the R/TT/TRT longitudinal kernel is evaluated. TT/TRT and multiple scattering are attenuated separately, and the water-film lobe is added on top.

### Reference Marschner (benchmark-only)

Reference preserves the analytic Marschner baseline and is a development/benchmark shader outside the packaged addon. Wetness narrows effective roughness, reduces cuticle shift, suppresses multiple scattering, and adds the water-film lobe. Internal wet attenuation is approximated by increasing the existing fiber absorption coefficient according to `wet_transmission_scale`; this leaves the surface R path unaffected while preferentially darkening TT/TRT.

## Water-film lobe

The film is a cheap strand-aligned dielectric highlight. It uses a roughness-to-power mapping over the half-vector's transverse component and Schlick-style Fresnel with eta `1.333`. The lobe is intentionally untinted so saturated dark hair can develop bright light-colored wet streaks.

This is a real-time approximation, not a full layered microfacet solution. A future Reference/Cinematic experiment could replace it with a more rigorous layered dielectric model if visual validation justifies the cost.

The final calibration selected:

```text
wet_film_specular_strength = 2.0
wet_film_roughness         = 0.10
```

The film strength intentionally exceeds a literal unit-scale interface response because the shader does not model the geometry clumping that also makes real wet hair read as wet. The separate control keeps that artistic compensation explicit.

## Dry compatibility

`wetness = 0` is designed to leave the dry model numerically unchanged. In particular:

- roughness interpolation starts from the exact authored dry roughness;
- tangent/frizz perturbation continues to use the dry authored roughness rather than the wet optical roughness;
- Fast keeps its original dry absorption reparameterization;
- Reference keeps its original dry absorption path before the wet multiplier is applied;
- the water-film term evaluates to zero.

This allows wetness to be added to existing material profiles without changing their dry look.

## Geometry remains out of scope

Wet-hair clumping is visually important, but it should not be hidden inside a shading parameter. Recommended production setup:

1. use material `wetness` for the optical response;
2. use a separate wet groom, shape keys, or strand/card deformation for clumping and volume collapse;
3. drive both from the same higher-level wetness signal when appropriate.

This separation also avoids coupling shader quality tiers to groom simulation quality.

## Validation completed

Validation was completed on the final calibrated implementation before PR #10 was merged into `development`.

### Interface test

```bash
godot --headless --path . \
  --script res://benchmark/tests/test_hair_wetness_interface.gd
```

Expected and observed marker:

```text
HAIR_WETNESS_INTERFACE_OK
```

This validates the shared wetness interface/defaults without loading the production 3D LUTs.

### Runtime binding test

Use a normal rendering context; do **not** add `--headless` on the validated Godot 4.7 setup because the headless display path can load direct `ImageTexture3D` resources as empty 1x1x1 stubs.

```bash
godot --path . \
  --script res://benchmark/tests/test_hair_wetness_runtime.gd
```

Expected and observed marker:

```text
HAIR_WETNESS_RUNTIME_OK
```

The runtime test covers:

- the three production tiers plus the benchmark-only Reference shader;
- Static Bayer and A2C compiled shader families;
- wetness values `0`, `0.25`, `0.5`, `0.75`, and `1`;
- direct Fast/Cinematic LUT binding;
- Fast's fixed eta/IOR `1.55` contract;
- propagation of the calibrated endpoint controls to the resulting material.

### Visual calibration

Visual validation used a fixed camera/exposure/tone-mapping setup under both broad-area and spot lighting. The validation included:

- dry-to-wet progression captures;
- dark-hair and light-hair comparisons;
- a ten-image component ablation separating film, narrowing/shift, and transport darkening;
- a three-preset film sweep.

The ablation established that the three components contribute in the intended directions:

- removing film reduces positive highlight energy;
- removing narrowing/shift flattens the concentrated highlight response;
- removing transport darkening raises body luminance.

Preset B (`2.0 / 0.10`) was selected for the final film calibration.

### GPU benchmark

1920x1080, Fast tier, broad lighting, 300 samples:

| GPU | Dry | Wet | Delta |
| --- | ---: | ---: | ---: |
| RTX 5090 | `0.297 ms` | `0.298 ms` | `+0.001 ms` |
| AMD Radeon Graphics | `24.045 ms` | `24.043 ms` | `-0.002 ms` |

The measured wetness cost is therefore within run-to-run noise for this benchmark. The feature adds no extra texture lookup of its own; its common per-light cost is the analytic film-lobe evaluation plus scalar interpolations/transport multipliers.

## Release considerations

The development wetness implementation is validated. A release still needs a **package-level smoke test after repathing** the production files from `assets/hair/` to `addons/marschner_hair/`. That test is intended to catch broken preload/include/LUT paths and to confirm the six normal/A2C production variants in the actual distributable addon.

See [`release_validation.md`](release_validation.md) for the final package checklist.
