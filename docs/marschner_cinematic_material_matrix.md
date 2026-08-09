# Cinematic Marschner material-matrix validation

The nominal Cinematic v2 validation establishes that the 128×128×64 R16F angle-domain/log-Q longitudinal LUT closely tracks the analytic d'Eon-style longitudinal reference at the default material point. Promotion additionally requires evidence that the same generic LUT remains accurate when material parameters change the non-separable longitudinal geometry and the azimuthal weighting of its residual error.

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

The gated values are:

```text
beta_m effective: 0.08, 0.30, 1.20
beta_n effective: 0.08, 0.80, 1.80
cuticle:          0.000, 0.087, 0.200
eta:              1.30, 1.55, 1.80
```

The default `promotion` preset uses two complementary gated sub-matrices:

1. **Geometry product** — `beta_m × cuticle × eta`, holding `beta_n=0.8`.
2. **Azimuthal-weighting plane** — `beta_m × beta_n`, holding cuticle/IOR nominal.

The three nominal-`beta_n` rows in the weighting plane duplicate rows already present in the geometry product and are removed. This gives **33 gated cases** (`27 + 9 - 3`) rather than the full 81-case Cartesian product. The promotion preset also records five report-only UI-edge stress cases: longitudinal beta `5.238`, azimuthal beta `6.831`, cuticle `0.5`, IOR `1.05`, and IOR `2.0`.

The `full` preset evaluates every `3×3×3×3 = 81` material combination in the selected gated domain and is the final material-domain confirmation.

## Promotion result

The local Godot 4.7 promotion matrix at `128×96` integration sampling passed all **33/33 gated cases**.

```text
worst aggregate lobe error: 0.5377%   (gate 2%)
worst per-angle total error: 0.7010%   (gate 5%)
worst R error:              0.5377%
worst TT error:             0.4625%
worst TRT error:            0.3345%
```

The worst aggregate lobe case was `beta_m=0.08`, `beta_n=0.8`, `cuticle=0.2`, `eta=1.8`, where R reached `0.5377%`. The worst per-angle case was `beta_m=0.08`, `beta_n=0.8`, `cuticle=0`, `eta=1.3` at `theta_i=0°`, with `0.7010%` total-energy error.

The maximum low-beta-path sample share was `35.38%`. No gated or report-only stress case produced any `beta_eff > LUT beta_max` samples. All five report-only stress cases also remained inside the normal `2%/5%` thresholds.

## Full Cartesian result

The exhaustive local Godot 4.7 `full` preset at the same `128×96` integration sampling passed **81/81 material cases** and all **405** reported material/incoming-angle rows.

```text
worst aggregate lobe error: 0.5377%   (gate 2%)
worst per-angle total error: 0.7670%   (gate 5%)
worst R error:              0.5377%
worst TT error:             0.5062%
worst TRT error:            0.3348%
```

The worst aggregate lobe case remained at the narrow longitudinal end: `beta_m=0.08`, `beta_n=0.08`, `cuticle=0.2`, `eta=1.8`, where R reached `0.5377%`. The full Cartesian sweep exposed a slightly stronger azimuthal-weighting interaction for the worst per-angle case: `beta_m=0.08`, `beta_n=1.8`, `cuticle=0`, `eta=1.3`, `theta_i=0°`, with `0.7670%` total-energy error. This is still only about 15% of the allowed 5% per-angle gate.

The candidate/direct energy ratio remained below unity in every one of the 405 reported rows:

```text
mean candidate/direct ratio: 0.99760485
minimum ratio:               0.99232977
maximum ratio:               0.99951286
samples above unity:         0 / 405
```

This confirms a small, consistent under-energy interpolation bias. The mean shortfall is about `0.240%`; the maximum shortfall is the `0.7670%` worst case. No global correction factor is proposed because the bias is already far inside the acceptance contract and changes with material and angle.

The maximum low-beta/asymptotic-transition sample share remained `35.38%`, and `beta_eff > LUT beta_max` sample share remained exactly `0%` across the full gated domain. The selected `beta_max=64`, the `128×128×64` LUT resolution, the angle-domain/log-Q conditioning, and the `0.05/0.10` low-beta transition therefore require no further tuning for this production material domain.

**Material-domain longitudinal correctness is considered validated.** Further Cinematic work should not modify this LUT representation unless a later renderer-level test reveals a distinct failure mode.

## Presets

### Smoke

Nominal material plus the low/high endpoint of each gated dimension:

```bash
python3 benchmark/tools/run_marschner_cinematic_material_matrix.py \
  --preset smoke \
  --project "//wsl.localhost/Ubuntu/path/to/checkout"
```

### Promotion

33 gated cases plus five report-only stress cases:

```bash
python3 benchmark/tools/run_marschner_cinematic_material_matrix.py \
  --preset promotion \
  --project "//wsl.localhost/Ubuntu/path/to/checkout"
```

### Full Cartesian

All 81 selected-domain material combinations:

```bash
python3 benchmark/tools/run_marschner_cinematic_material_matrix.py \
  --preset full \
  --project "//wsl.localhost/Ubuntu/path/to/checkout"
```

The runner exits nonzero after writing the report if any gated case exceeds the `2%/5%` acceptance contract. Add `--report-only` when collecting exploratory evidence that should not fail the process.

## Report interpretation

The top-level summary records:

- whether all gated cases passed;
- the worst gated aggregate-lobe error and its material parameters;
- the worst gated per-incoming-angle error and incoming angle;
- the worst gated R, TT, and TRT errors independently;
- candidate/direct ratio bias across all gated per-angle samples;
- the highest low-beta asymptotic/transition sample share;
- the highest share of samples whose `beta_eff` exceeds the LUT's beta domain;
- report-only stress results when the selected preset includes them.

A nonzero `beta_above_lut_sample_share` in a gated case deserves investigation even when the energy gates pass, because it means the candidate is reconstructing from the LUT's `beta_max` clamp instead of evaluating the requested effective width directly.

## Scope

This matrix validates **single-scattering longitudinal preintegration** across material-domain changes. It does not validate world/environment/indirect lighting, multiple-scattering model fidelity, or GPU performance. Those remain separate concerns so a failure can be attributed to the correct subsystem.
