# Marschner production tier split

This branch promotes the recent Unity/Cinematic experiments into an explicit production architecture. The older `hair_marschner_fast*` selector family remains benchmark/experimental evidence; the production tiers are separate compile-time shaders.

## Quality ladder

| Tier | Shader | Longitudinal M | Azimuthal N | Correctness oracle |
| --- | --- | --- | --- | --- |
| Fast | `hair_marschner_unity_fast.gdshader` | Unity Standard separable Gaussian | Unity preintegrated RGB 3D LUT | Unity Standard source/generator parity |
| Cinematic | `hair_marschner_cinematic.gdshader` | angle-domain/log-Q energy-conserving 3D LUT | Existing analytic baseline N/A | Full analytic reference |
| Reference | `hair.gdshader` | Full analytic non-separable d'Eon path | Existing baseline | Validation only |

The packaged addon's `HairMaterialProfile` exposes `APPROX`, `FAST_MARSCHNER`, and `CINEMATIC_MARSCHNER` (serialized values `0`-`2`). The analytic Reference shader (`hair.gdshader`) is a benchmark-only validation baseline outside the addon and is not part of the tier enum.

## Fast contract

Fast is intentionally a coherent Unity HDRP Standard-style model rather than a progressively simplified copy of the analytic baseline:

- longitudinal lobe shifts: R `-alpha`, TT `+0.5 alpha`, TRT `+1.5 alpha`;
- longitudinal widths: R `beta`, TT `0.5 beta`, TRT `2 beta`;
- three cheap Gaussian M evaluations;
- one trilinear RGB 3D azimuthal lookup returning `N_R`, `N_TT`, and `N_TRT`;
- analytic R Fresnel and fixed-h TT/TRT Fresnel/Beer attenuation;
- no Bessel/log-Bessel longitudinal math, longitudinal LUT, low-beta branch, or azimuth-dependent longitudinal cone/width.

The Unity azimuthal/modified-refraction contract is baked at human-hair eta `1.55`. `HairMarschnerLUTAdapter` therefore pins Fast `ior` to the LUT eta instead of permitting an inconsistent arbitrary-IOR combination.

The azimuthal volume is generated according to Unity's actual `ComputeAzimuthalScattering` implementation: 64³ texel-center coordinates, the `1.19 / cosThetaD + 0.36 * cosThetaD` modified-refraction fit, Unity's `FastASin`, `h` integrated over `[-1, 1)` in `0.1` increments, and RGBA16F storage.

Fast is **not** required to match the analytic reference's integrated energy. Baseline energy/angular/visual differences are diagnostic quality measurements, not the Fast correctness oracle.

### Why the Unity LUT gate is texel parity

A first validation attempt compared trilinearly filtered values from Unity's fixed 64³ table to the continuous direct fiber-width integral at arbitrary off-grid coordinates. That produced very large pointwise relative errors at narrow azimuthal roughness, including a local measured p95 near 99%. This is not an appropriate port-correctness test: the coarse 64³ filtered table is itself Unity Standard's approximation, so comparing it to the continuous distribution measures the approximation Unity chose rather than whether the Godot table matches Unity.

The production Fast gate is therefore **texel-center parity with Unity's compute generator**, allowing only expected RGBA16F quantization error. The validator requires:

- p99 relative error at active texel-center samples `<= 0.1%`;
- maximum absolute texel-center error `<= 0.01`.

The off-grid direct-integral comparison remains in the JSON report as `characterization_only`, including a separate `beta >= 0.2` slice.

## Cinematic contract

Cinematic keeps the high-tier baseline's non-separable geometry and analytic azimuthal/attenuation behavior. The only intended single-scattering approximation is longitudinal preintegration.

The original v1 representation used uniform `sin(theta_cone)` / `sin(theta_o)` axes and stored linear `Q`. Local validation measured an off-grid p95 relative error of about `18.55%` and a maximum projected-integral relative error of about `7.18%`, outside the intended `10%/5%` gates.

The v2 representation keeps the same **128×128×64 R16F / 2 MiB** budget but changes the conditioning:

- X = `theta_cone` in `[-PI/2, PI/2]`;
- Y = `theta_o` in `[-PI/2, PI/2]`;
- Z = normalized `log2(beta_eff)` over `[0.05, 64]`;
- R = `log2(Q)`, where `Q = beta * sqrt(cos(theta_cone) * cos(theta_o)) * cos(theta_o) * M`.

The runtime derives `theta_cone` and `beta_eff` separately for R/TT/TRT using the analytic baseline's azimuth-dependent geometry, then samples the same scalar volume three times. Azimuth therefore still moves/broadens the longitudinal lobes without becoming another LUT dimension.

The narrow-beta path is:

- `beta_eff <= 0.05`: analytic asymptotic;
- `0.05 < beta_eff < 0.10`: asymptotic/LUT transition;
- `beta_eff >= 0.10`: LUT.

Normal Cinematic sampling is one filtered 3D texture lookup per lobe. There is no valid-corner reconstruction, boundary renormalization, or direct Bessel fallback in the shader.

## Shader layout

```text
assets/hair/materials/shaders/
    hair_marschner_common.gdshaderinc

    hair_marschner_unity_fast.gdshader
    hair_marschner_unity_fast_body.gdshaderinc

    hair_marschner_cinematic.gdshader
    hair_marschner_cinematic_body.gdshaderinc
```

Uniform and varying declarations intentionally remain in the top-level `.gdshader` wrappers. Godot 4.7 also requires care around inferred locals sourced from dynamic APIs, so the production LUT adapter and headless profile test use explicit local types at those seams.

## Generated resources

```text
benchmark/resources/luts/
    unity_azimuthal_64.res
    cinematic_longitudinal_kernel_128x128x64.res
```

These files are generated locally rather than checked in by this branch. They are benchmark raw-data fixtures: production now ships the same texel payload as directly serialized `ImageTexture3D` resources under `addons/marschner_hair/luts/`, and `HairMarschnerLUTAdapter` loads those directly without raw-data reconstruction.

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

The longitudinal resource validator gates:

- off-grid p95 relative error in the stored/runtime `Q` reconstruction: `<= 10%`;
- maximum projected-integral relative error through the actual low-beta runtime path: `<= 5%`.

The complete single-scattering validator targets:

- worst aggregate R/TT/TRT lobe energy relative error: `<= 2%`;
- worst per-incoming-angle total energy relative error: `<= 5%`;
- R, TT, and TRT reported independently.

`validate_marschner_cinematic_energy.gd` accepts `--beta-m`, `--beta-n`, `--cuticle`, and `--eta` so the same direct-vs-candidate oracle can be used across the material domain. `--contract=report` records results without turning an out-of-gate candidate into a process failure.

Material-domain validation is defined in `docs/marschner_cinematic_material_matrix.md` and implemented by `benchmark/tools/run_marschner_cinematic_material_matrix.py`.

The final local Godot 4.7 full Cartesian material sweep evaluated all `3×3×3×3 = 81` selected-domain material combinations at `128×96` integration sampling and passed **81/81** cases:

```text
worst aggregate lobe error: 0.5377%   (gate 2%)
worst per-angle total error: 0.7670%   (gate 5%)
worst R error:              0.5377%
worst TT error:             0.5062%
worst TRT error:            0.3348%
```

The hardest region is the narrow `beta_m=0.08` end. The worst aggregate lobe case was R at `beta_m=0.08`, `beta_n=0.08`, `cuticle=0.2`, `eta=1.8`. The worst per-angle case was `beta_m=0.08`, `beta_n=1.8`, `cuticle=0`, `eta=1.3`, `theta_i=0°`.

Across all 405 material/angle rows, the mean candidate/direct ratio was `0.99760485`, the minimum was `0.99232977`, the maximum was `0.99951286`, and no sample exceeded unity. This small under-energy interpolation bias is bounded well inside the acceptance contract and is not globally corrected.

The maximum low-beta-path sample share was `35.38%`, while `beta_eff > LUT beta_max` sample share remained `0%` across the full domain. The Cinematic v2 LUT representation, `beta_max=64`, `128×128×64` resolution, and `0.05/0.10` low-beta transition are therefore considered **material-domain validated** and should remain unchanged unless later renderer-level evidence identifies a distinct failure mode.

## One-command local study

From WSL, using the repository's current Windows-Godot convention:

```bash
python3 benchmark/tools/run_marschner_tier_split_study.py \
  --project "//wsl.localhost/Ubuntu/path/to/your/checkout"
```

The runner:

1. generates the Unity Fast azimuthal LUT;
2. gates that LUT against Unity compute-generator texel-center parity and records off-grid direct-integral error as characterization;
3. generates the 128×128×64 angle-domain/log-Q Cinematic LUT;
4. validates its off-grid interpolation and projected integrals through the actual `0.05/0.10` low-beta transition;
5. runs `test_marschner_production_profile.gd` to verify shader selection, top-level uniform reflection, LUT binding, Fast eta pinning, and Cinematic v2 metadata;
6. reports complete Cinematic energy parity;
7. runs the existing windowed GPU comparison unless `--skip-runtime` is passed;
8. writes `benchmark/results/marschner_tier_split_study.json`.

For a CPU/resource-only pass:

```bash
python3 benchmark/tools/run_marschner_tier_split_study.py --skip-runtime
```

The separate material matrix can be rerun with:

```bash
python3 benchmark/tools/run_marschner_cinematic_material_matrix.py \
  --preset full \
  --project "//wsl.localhost/Ubuntu/path/to/your/checkout"
```

## Deferred work

The production split deliberately does not fold the older Fast experimental selector family into either new shader. In particular, the standardized-R LUT, local/preintegrated dual scattering, and camera-space environment stand-in remain benchmark evidence until independently justified.

Full world-space environment/irradiance and screen-indirect hair lighting also remain a separate architectural milestone. Direct-light Marschner parity is now settled for the current Cinematic longitudinal path; those lighting features should be evaluated as separate renderer-level work.
