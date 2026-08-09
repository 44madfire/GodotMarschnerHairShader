# Cinematic Marschner material-matrix validation

The nominal Cinematic v2 validation establishes that the 128×128×64 R16F angle-domain/log-Q longitudinal LUT closely tracks the analytic d'Eon-style longitudinal reference at the default material point. Promotion additionally requires evidence that the same generic LUT remains accurate when the material changes the non-separable longitudinal geometry and the azimuthal weighting of its residual error.

## Validator seam

`benchmark/tools/validate_marschner_cinematic_energy.gd` is the per-material oracle. It compares complete single-scattering energy with identical analytic geometry, azimuthal distribution, Fresnel/Beer attenuation, and integration sampling on both sides; only the longitudinal evaluation differs:

- direct: analytic log-Bessel longitudinal `M`;
- candidate: Cinematic v2 angle-domain/log-Q LUT plus the `0.05/0.10` low-beta asymptotic transition.

The validator accepts material overrides for:

```text
--beta-m=<effective longitudinal beta>
--beta-n=<effective azimuthal beta>
--cuticle=<cuticle tilt in radians>
--eta=<IOR, 1.0..2.0>
```

The complete-energy gates remain:

- worst aggregate R/TT/TRT lobe relative error `<= 2%`;
- worst per-incoming-angle total relative error `<= 5%`.

## Matrix runner

`benchmark/tools/run_marschner_cinematic_material_matrix.py` drives the per-material validator through Windows Godot and writes:

```text
benchmark/results/marschner_cinematic_material_matrix.json
```

The default `promotion` preset uses two complementary gated sub-matrices:

1. **Geometry product** — `beta_m × cuticle × eta`, holding `beta_n=0.8`.
2. **Azimuthal-weighting plane** — `beta_m × beta_n`, holding cuticle/IOR nominal.

The three nominal-`beta_n` rows in the weighting plane duplicate rows already present in the geometry product and are removed. This gives **33 gated cases** (`27 + 9 - 3`) rather than the largely redundant 81-case four-dimensional Cartesian product while still covering the interactions most likely to change LUT coordinates or reweight the R/TT/TRT residuals.

The gated values are:

```text
beta_m effective: 0.08, 0.30, 1.20
beta_n effective: 0.08, 0.80, 1.80
cuticle:          0.000, 0.087, 0.200
eta:              1.30, 1.55, 1.80
```

The promotion preset also records five **report-only UI-edge stress cases**:

- longitudinal beta corresponding to the raw roughness-1 endpoint (`5.238`);
- azimuthal beta corresponding to the raw roughness-1 endpoint (`6.831`);
- cuticle `0.5`;
- IOR `1.05`;
- IOR `2.0`.

These stress rows expose beta-domain clamping and extreme shader-UI behavior without redefining the intended human-hair promotion domain.

## Presets

### Smoke

Nominal material plus the low/high endpoint of each gated dimension:

```bash
python3 benchmark/tools/run_marschner_cinematic_material_matrix.py \
  --preset smoke \
  --project "//wsl.localhost/Ubuntu/path/to/checkout"
```

Use this first after validator/parser changes.

### Promotion

Default 33 gated cases plus five report-only stress cases, at the same `128×96` integration sampling used by the nominal complete-energy validation:

```bash
python3 benchmark/tools/run_marschner_cinematic_material_matrix.py \
  --preset promotion \
  --project "//wsl.localhost/Ubuntu/path/to/checkout"
```

The runner exits nonzero after writing the report if any gated case exceeds the `2%/5%` acceptance contract. Add `--report-only` when collecting exploratory evidence that should not fail the process.

### Full Cartesian

For final exhaustive confirmation of the chosen three-point gated domain:

```bash
python3 benchmark/tools/run_marschner_cinematic_material_matrix.py \
  --preset full \
  --project "//wsl.localhost/Ubuntu/path/to/checkout"
```

This runs all `3×3×3×3 = 81` combinations and excludes the separate UI-edge stress rows.

## Report interpretation

The top-level summary records:

- whether all gated cases passed;
- the worst gated aggregate-lobe error and its material parameters;
- the worst gated per-incoming-angle error and incoming angle;
- the worst gated R, TT, and TRT errors independently;
- the highest low-beta asymptotic/transition sample share;
- the highest share of samples whose `beta_eff` exceeds the LUT's beta domain;
- the worst report-only stress results.

A nonzero `beta_above_lut_sample_share` in a gated case deserves investigation even when the energy gates pass, because it means the candidate is reconstructing from the LUT's `beta_max` clamp instead of evaluating the requested effective width directly. The stress cases are expected to be the first place this appears.

## Scope

This matrix validates **single-scattering longitudinal preintegration** across material-domain changes. It does not validate world/environment/indirect lighting, multiple-scattering model fidelity, or GPU performance. Those remain separate concerns so a failure can be attributed to the correct subsystem.
