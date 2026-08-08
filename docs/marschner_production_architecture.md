# Marschner production tier split

This branch promotes the recent Unity/Cinematic experiments into an explicit production architecture. The older `hair_marschner_fast*` selector family remains benchmark/experimental evidence; the production tiers are separate compile-time shaders.

## Quality ladder

| Tier | Shader | Longitudinal M | Azimuthal N | Correctness oracle |
| --- | --- | --- | --- | --- |
| Fast | `hair_marschner_unity_fast.gdshader` | Unity Standard separable Gaussian | Unity preintegrated RGB 3D LUT | Unity Standard source/generator parity |
| Cinematic | `hair_marschner_cinematic.gdshader` | Physical-domain energy-conserving 3D LUT | Existing analytic baseline N/A | Full analytic reference |
| Reference | `hair.gdshader` | Full analytic non-separable d'Eon path | Existing baseline | Validation only |

`HairMaterialProfile` now exposes `APPROX`, `FAST_MARSCHNER`, `CINEMATIC_MARSCHNER`, and `REFERENCE_MARSCHNER`. Existing serialized tier value `2` now selects Cinematic; the analytic reference is value `3`.

## Fast contract

Fast is intentionally a coherent Unity HDRP Standard-style model rather than a progressively simplified copy of the analytic baseline:

- longitudinal lobe shifts: R `-alpha`, TT `+0.5 alpha`, TRT `+1.5 alpha`;
- longitudinal widths: R `beta`, TT `0.5 beta`, TRT `2 beta`;
- three cheap Gaussian M evaluations;
- one trilinear RGB 3D azimuthal lookup returning `N_R`, `N_TT`, and `N_TRT`;
- analytic R Fresnel and fixed-h TT/TRT Fresnel/Beer attenuation;
- no Bessel/log-Bessel longitudinal math, longitudinal LUT, low-beta branch, or azimuth-dependent longitudinal cone/width.

The Unity azimuthal/modified-refraction contract is baked at human-hair eta `1.55`. `HairMarschnerLUTAdapter` therefore pins Fast `ior` to the LUT eta instead of permitting an inconsistent arbitrary-IOR combination.

The azimuthal volume is also generated according to Unity's actual `ComputeAzimuthalScattering` implementation rather than an idealized continuous version: 64³ texel-center coordinates, the `1.19 / cosThetaD + 0.36 * cosThetaD` modified-refraction fit, Unity's `FastASin`, `h` integrated over `[-1, 1)` in `0.1` increments, and RGBA16F storage.

Fast is **not** required to match the analytic reference's integrated energy. Baseline energy/angular/visual differences are diagnostic quality measurements, not the Fast correctness oracle.

### Why the Unity LUT gate is texel parity

A first validation attempt compared trilinearly filtered values from Unity's fixed 64³ table to the continuous direct fiber-width integral at arbitrary off-grid coordinates. That produced very large pointwise relative errors at narrow azimuthal roughness, including a local measured p95 near 99%. This is not an appropriate port-correctness test: the coarse 64³ filtered table is itself Unity Standard's approximation, so comparing it to the continuous distribution measures the approximation Unity chose rather than whether the Godot table matches Unity.

The production Fast gate is therefore **texel-center parity with Unity's compute generator**, allowing only the expected RGBA16F quantization error. The validator currently requires:

- p99 relative error at active texel-center samples `<= 0.1%`;
- maximum absolute texel-center error `<= 0.01`.

The previous off-grid direct-integral comparison is retained in the JSON report as `characterization_only`, including a separate `beta >= 0.2` slice. It remains useful for understanding the quality cost of Unity's 64³ approximation but cannot fail the Godot port.

## Cinematic contract

Cinematic keeps the high-tier baseline's non-separable geometry and analytic azimuthal/attenuation behavior. The only intended single-scattering approximation is longitudinal preintegration.

The generic scalar LUT is indexed by the physical rectangular domain:

- `U = 0.5 + 0.5 * sin(theta_cone)`;
- `V = 0.5 + 0.5 * sin(theta_o)`;
- `W = normalized log2(beta_eff)`.

The runtime derives `sin(theta_cone)` and `beta_eff` separately for R/TT/TRT using the analytic baseline's azimuth-dependent geometry, then samples the same scalar volume three times. Azimuth therefore still moves/broadens the longitudinal lobes without becoming another LUT dimension.

The stored quantity is the conditioned bounded kernel `Q`, reconstructed to M at runtime. The narrow-beta handling remains:

- `beta_eff <= 0.015`: analytic asymptotic;
- `0.015 < beta_eff < 0.03`: asymptotic/LUT transition;
- `beta_eff >= 0.03`: LUT.

Normal sampling is a single filtered `texture()` operation per lobe. There is no valid-corner reconstruction, boundary renormalization, or direct Bessel fallback.

## Shader layout

```text
assets/hair/materials/shaders/
    hair_marschner_common.gdshaderinc

    hair_marschner_unity_fast.gdshader
    hair_marschner_unity_fast_body.gdshaderinc

    hair_marschner_cinematic.gdshader
    hair_marschner_cinematic_body.gdshaderinc
```

Uniform and varying declarations intentionally remain in the top-level `.gdshader` wrappers. Godot 4.7 also requires care around inferred locals sourced from dynamic APIs, so the production LUT adapter and headless profile test use explicit local types at those seams. If a local checkout still reports a parser failure, preserve the local diff and report the exact parser location before reconciling it with the branch.

## Generated resources

```text
benchmark/resources/luts/
    unity_azimuthal_64.res
    cinematic_longitudinal_kernel_128x128x64.res
```

These files are generated locally rather than checked in by this branch. Godot 4.7 does not reliably self-contain `ImageTexture3D` data in `.res`; the resource stores raw image bytes and `HairMarschnerLUTAdapter` reconstructs/caches the runtime `Texture3D`.

Generate them with:

```bash
godot --headless --path . --script res://benchmark/tools/generate_unity_hair_azimuthal_lut.gd
godot --headless --path . --script res://benchmark/tools/generate_marschner_cinematic_longitudinal_lut.gd
```

## Validation contracts

### Fast

Fast validation keeps these concerns separate:

1. Unity source formula/parameterization parity;
2. Unity compute-generator / serialized-LUT texel-center parity;
3. continuous off-grid LUT error as quality characterization only;
4. finite/renderable output and production material binding;
5. baseline energy/angular/visual differences as reports;
6. GPU timing.

Do not introduce a global exposure/lobe multiplier merely to make Fast match baseline aggregate energy.

### Cinematic

The initial acceptance targets are:

- worst aggregate R/TT/TRT lobe energy relative error: `<= 2%`;
- worst per-incoming-angle total energy relative error: `<= 5%`;
- R, TT, and TRT reported independently;
- material-domain sweeps across roughness, cuticle, and IOR before final promotion.

`validate_marschner_cinematic_energy.gd --contract=report` records results without turning an out-of-gate candidate into a process failure; omit `--contract=report` to enforce the current gates.

## One-command local study

From WSL, using the repository's current Windows-Godot convention:

```bash
python3 benchmark/tools/run_marschner_tier_split_study.py \
  --project "//wsl.localhost/Ubuntu/path/to/your/checkout"
```

The runner:

1. generates the Unity Fast azimuthal LUT;
2. gates that LUT against Unity compute-generator texel-center parity and records off-grid direct-integral error as characterization;
3. generates and validates the Cinematic longitudinal LUT;
4. runs `test_marschner_production_profile.gd` to verify shader selection, top-level uniform reflection, LUT reconstruction/binding, Fast eta pinning, and Cinematic beta metadata;
5. reports complete Cinematic energy parity;
6. runs the existing windowed GPU comparison unless `--skip-runtime` is passed;
7. writes `benchmark/results/marschner_tier_split_study.json`.

For a CPU/resource-only pass:

```bash
python3 benchmark/tools/run_marschner_tier_split_study.py --skip-runtime
```

## Deferred work

The production split deliberately does not fold the older Fast experimental selector family into either new shader. In particular, the standardized-R LUT, local/preintegrated dual scattering, and camera-space environment stand-in remain benchmark evidence until independently justified.

Full world-space environment/irradiance and screen-indirect hair lighting also remain a separate architectural milestone. Direct-light Marschner parity should be settled before those features are added.
