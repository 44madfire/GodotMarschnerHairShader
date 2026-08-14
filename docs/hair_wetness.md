# Hair optical wetness

This feature models **optical wetness only**. It does not deform the groom, clump cards/strands, add weight, or simulate surface-tension geometry. Those effects should be authored through a separate groom, shape keys, strand simulation, or another deformation layer.

## Design goals

The dry model remains the reference point. `wetness = 0.0` is intended to reproduce the existing dry shader behavior exactly. Increasing wetness adds a distinct smooth dielectric film response and progressively changes the underlying fiber transport instead of pretending wet hair is only dry hair with a different IOR.

The Fast tier deliberately keeps its existing eta=1.55 azimuthal-LUT contract. Wetness never changes that LUT's IOR. The water layer is modeled as a separate untinted dielectric reflection with an approximate water IOR of 1.333.

## Shared controls

- `wetness`: master 0..1 optical wetness amount.
- `wet_film_roughness`: width of the added strand-aligned water-film highlight.
- `wet_film_specular_strength`: intensity of the water-film reflection at full wetness.
- `wet_longitudinal_roughness_scale`: saturated endpoint multiplier for longitudinal highlight width.
- `wet_azimuthal_roughness_scale`: saturated endpoint multiplier for Marschner azimuthal roughness.
- `wet_internal_scatter_scale`: remaining diffuse/multiple-scattering intensity at full wetness.
- `wet_transmission_scale`: remaining Marschner internal transmission at full wetness.
- `wet_cuticle_shift_scale`: remaining cuticle/tangent-shift separation at full wetness.

Current calibration defaults are intentionally conservative starting points rather than measured constants:

| Control | Default |
|---|---:|
| Wetness | 0.0 |
| Film roughness | 0.10 |
| Film specular strength | 2.0 |
| Longitudinal roughness scale | 0.45 |
| Azimuthal roughness scale | 0.55 |
| Internal scatter scale | 0.35 |
| Transmission scale | 0.65 |
| Cuticle shift scale | 0.50 |

## Tier behavior

### Approx / Kajiya-Kay

Wetness narrows the primary/secondary Kajiya-Kay highlights, reduces their tangent-shift separation, suppresses wrapped diffuse scatter, and adds the untinted water-film highlight. `wet_azimuthal_roughness_scale` and `wet_transmission_scale` remain in the standardized interface but have no direct physical counterpart in this tier.

### Fast Marschner

Fast keeps the eta=1.55 preintegrated azimuthal LUT contract. Wetness:

- samples the existing LUT at a lower effective azimuthal roughness,
- narrows the separable longitudinal R/TT/TRT Gaussians,
- reduces cuticle-driven lobe separation,
- attenuates TT/TRT transport,
- attenuates the Karis-style multiple-scattering approximation,
- adds the separate water-film reflection.

The dry absorption reparameterization is intentionally left unchanged so wet darkening comes from explicit transport changes rather than an accidental change in the albedo-to-absorption fit.

### Cinematic Marschner

Cinematic applies the same optical policy while retaining its analytic azimuthal geometry and conditioned longitudinal LUT. The effective wet roughness is fed through the same Chiang-style roughness reparameterization before the R/TT/TRT longitudinal kernel is evaluated. TT/TRT and multiple scattering are attenuated separately, and the water-film lobe is added on top.

### Reference Marschner

Reference preserves the original analytic Marschner implementation. Wetness narrows its effective roughness, reduces cuticle shift, suppresses multiple scattering, and adds the water-film lobe. Internal wet attenuation is approximated by increasing the existing fiber absorption coefficient according to `wet_transmission_scale`; this leaves the surface R path unaffected while preferentially darkening TT/TRT.

## Water-film lobe

The film is a cheap strand-aligned dielectric highlight. It uses a roughness-to-power mapping over the half-vector's transverse component and Schlick-style Fresnel with eta 1.333. The lobe is intentionally untinted so saturated dark hair can develop bright light-colored wet streaks.

This is a real-time approximation, not a layered microfacet solution. A later Reference/Cinematic experiment can replace it with a more rigorous layered dielectric model if visual validation justifies the cost.

## Geometry is explicitly out of scope

Wet-hair clumping is visually important, but it should not be hidden inside a shading parameter. Recommended production setup:

1. use this material wetness for optical response;
2. use a separate wet groom, shape keys, or strand/card deformation for clumping and collapse;
3. drive both from the same gameplay/animation wetness signal when appropriate.

Keeping those systems separate makes the shader deterministic and lets geometry quality scale independently from lighting quality.

## Validation plan

Run the interface/default test first; it is safe in headless mode because it does not load the production ImageTexture3D LUTs:

```bash
godot --headless --path . \
  --script res://benchmark/tests/test_hair_wetness_interface.gd
```

Expected marker: `HAIR_WETNESS_INTERFACE_OK`.

Then run the runtime binding smoke with a real Forward+/Mobile RenderingDevice. Do **not** add `--headless`: Godot 4.7's headless path cannot reliably load these ImageTexture3D resources on the currently tested setup.

```bash
godot --path . \
  --script res://benchmark/tests/test_hair_wetness_runtime.gd
```

Expected marker: `HAIR_WETNESS_RUNTIME_OK`. This checks all four tiers, both static-Bayer and A2C compiled families, wetness values 0 / 0.25 / 0.5 / 0.75 / 1, direct LUT binding, and Fast's fixed eta=1.55 contract.

Before merging, also verify visually in Godot 4.7:

1. all eight production shader variants compile/render;
2. `wetness = 0` visually matches the dry baseline;
3. wetness 0.25 / 0.5 / 0.75 / 1.0 produces progressively narrower/brighter film highlights and darker body scattering;
4. Fast still binds the eta=1.55 direct LUT without contract changes;
5. Cinematic still binds its direct longitudinal LUT;
6. switching Static/TAA Bayer to A2C preserves all wetness parameters;
7. Approx, Fast, Cinematic, and Reference all respond to the same `HairMaterialProfile` wetness values.

Performance should be measured after visual calibration. The new common cost is one analytic film-lobe evaluation per light plus a small number of scalar wetness interpolations; no additional texture lookup is introduced by wetness itself.
