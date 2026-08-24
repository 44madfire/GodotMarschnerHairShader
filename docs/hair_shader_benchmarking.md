# Production hair shader benchmarking

This benchmark suite measures the four development tiers (the three production `HairMaterialProfile` tiers plus the benchmark-only Reference shader) on the same Blowout groom, camera, lighting rig, groom textures, and material profile:

| Tier | Runtime shader |
| --- | --- |
| Approx / Kajiya-Kay | `hair_approx.gdshader` |
| Fast Marschner | `hair_marschner_unity_fast.gdshader` |
| Cinematic Marschner | `hair_marschner_cinematic.gdshader` |
| Reference Marschner | `hair.gdshader` |

The suite is designed to answer two different questions without conflating them:

1. **How expensive is each complete production tier on this GPU?** Measured with Godot viewport GPU timing under controlled resolution, coverage, and light-count sweeps.
2. **What kind of GPU work is this device sensitive to?** Characterized with common-card, synthetic arithmetic, and synthetic 3D-LUT probes plus a source-level shader inventory.

The probe results are calibration measurements. They do **not** decompose a production shader into exact ALU milliseconds or texture milliseconds.

## Requirements

Use Godot 4.7 with Forward+ or Mobile and a real graphics device. Do not use `--headless` for runtime GPU timing. Godot's global `RenderingDevice` is unavailable in headless mode, and the runtime benchmark exits rather than silently producing misleading results.

Generate the production LUTs first:

```bash
godot --headless --path . --script res://benchmark/tools/generate_unity_hair_azimuthal_lut.gd
godot --headless --path . --script res://benchmark/tools/generate_marschner_cinematic_longitudinal_lut.gd
```

The LUT generation step may be headless; the GPU timing step must not be.

## Recommended entry point

Run the Python matrix driver from the repository root:

```bash
python benchmark/tools/run_production_hair_benchmarks.py --godot godot --preset standard
```

The standard preset runs:

```text
resolution      1920x1080
coverage modes  cards, coverage
extra lights    0, 7
process repeats 3
```

Each Godot process measures `NO_HAIR`, the three calibration/control shaders, and all four development tiers (three production plus benchmark-only Reference). The production tier order rotates and reverses across process repeats to reduce order bias.

Useful presets:

```bash
# One workload, three process repeats.
python benchmark/tools/run_production_hair_benchmarks.py --godot godot --preset quick

# Resolution + coverage + light-count sweeps, five process repeats.
python benchmark/tools/run_production_hair_benchmarks.py --godot godot --preset full
```

The full preset is intentionally expensive. Use it for promotion/performance decisions, not routine smoke testing.

## Selecting a GPU

Godot exposes `--gpu-index` for Forward+ and Mobile. Run Godot with `--verbose` to see the available device list, then pass one or more indices to the benchmark runner:

```bash
python benchmark/tools/run_production_hair_benchmarks.py \
  --godot /mnt/c/Tools/Godot/godot.exe \
  --gpu-index 0 \
  --gpu-index 1 \
  --preset standard
```

The runner records the adapter name, vendor, API version, Godot device type (`integrated_gpu`, `discrete_gpu`, etc.), and pipeline-cache UUID inside every runtime payload. Never infer which adapter ran from the requested index alone; verify the recorded GPU metadata.

## Workload dimensions

### `cards`

`show_hair_cards=true` disables the coverage discard. This intentionally maximizes stable shaded-fragment work and is the clearest tier/BSDF comparison.

### `coverage`

`show_hair_cards=false` exercises the production Bayer coverage/depth path. The suite freezes supported Bayer phases and sets an extremely small engine time scale so the Reference shader's TIME-based pattern also remains effectively fixed during normal runs.

### Light-count sweep

The harness already contains one directional light. `--extra-lights=N` adds N shadowless directional lights. Comparing the production-minus-card-control delta across light counts gives an empirical **per-light BSDF scaling slope**. This is much more useful as an ALU/BSDF cost signal than trying to assign cycle weights to GDScript-style shader source tokens.

### Resolution sweep

Increasing resolution increases fragment workload while leaving groom geometry unchanged. The aggregate tool derives a production-minus-card-control slope in milliseconds per megapixel when at least two resolutions are present.

## Controls and probes

### `NO_HAIR`

Scene/runtime baseline with hair hidden. `incremental_vs_no_hair_ms` removes most non-hair viewport cost from a measurement.

### `CARD_CONTROL`

Uses the production `hair_card_common.gdshaderinc` path for:

```text
two groom Texture2D reads
coverage/depth Bayer decision
root-to-tip base shading
strand hash
frizz perturbation
orthonormal TBN reconstruction
```

It then emits a trivial unshaded result. Production-minus-card-control is the suite's preferred end-to-end estimate of additional shaded hair/BSDF work. It still is not a literal instruction-level decomposition.

### `ALU_PROBE_96`

Runs the same common card preparation followed by a fixed 96-iteration dependent arithmetic chain. The delta versus `CARD_CONTROL` indicates how strongly the selected device responds to an intentionally ALU-heavy fragment workload.

This probe is intentionally synthetic. It is **not** a statement that any production tier executes 96 equivalent iterations.

### `LUT_PROBE_16`

Runs the same common card preparation followed by 16 dependent trilinear `Texture3D` samples from the generated Cinematic LUT. The delta versus `CARD_CONTROL` indicates device sensitivity to 3D LUT sampling/cache behavior.

Again, the number is calibration data, not an attribution of Fast or Cinematic runtime.

## Source operation inventory

The runtime runner also executes:

```bash
python benchmark/tools/analyze_production_shader_costs.py --project . --pretty
```

The analyzer recursively expands Godot `#include` directives and reports, per production tier:

```text
sampler2D / sampler3D declarations
explicit texture()/textureLod()/textureGrad()/texelFetch() calls
textureSize() calls
special math calls such as pow/log/exp/sqrt/trigonometric functions
vector functions such as normalize/dot/cross
lexical arithmetic operator tokens
```

These are **source-level structural counts only**. Godot and the GPU driver can inline, eliminate, fold, vectorize, specialize, or lower those expressions differently. The inventory must never be presented as post-compile GPU instruction count, cycles, occupancy, register pressure, or exact ALU cost.

For vendor ISA/register/occupancy data, capture the benchmark workload with an external GPU profiler appropriate to the target hardware. Keep the runtime JSON alongside that capture so the exact resolution, coverage mode, lights, shader tier, adapter, and pipeline-cache identity are known.

## Direct single-process run

For debugging the benchmark itself:

```bash
godot \
  --path . \
  --rendering-method forward_plus \
  --disable-vsync \
  --gpu-index 0 \
  --script res://benchmark/tools/benchmark_production_hair_tiers.gd \
  -- \
  --resolution=1920x1080 \
  --coverage=cards \
  --extra-lights=7 \
  --prewarm=120 \
  --settle=30 \
  --sample=300 \
  --repeat-index=0
```

A successful run prints one machine-readable line beginning with:

```text
HAIR_BENCHMARK_JSON:
```

and ends with:

```text
PRODUCTION_HAIR_TIER_RUNTIME_BENCHMARK_OK
```

## Output

The Python runner creates a timestamped directory under `benchmark/results/` containing:

```text
source_inventory.json
source_inventory.log
commands.txt
run_*.json
run_*.log
process_rows.csv
aggregate.csv
aggregate.json
```

`aggregate.json` contains per-process-repeat medians/MADs plus derived light-count and resolution slopes. Raw process logs are retained because shader compiler warnings, adapter selection, or driver messages can invalidate an otherwise plausible number.

## Interpreting results

Prefer the following evidence order:

1. Verify every run reports the expected adapter, device type, renderer, viewport size, coverage mode, and light count.
2. Check process-repeat MAD. If it is large relative to the tier delta, run more repeats or increase the workload.
3. Compare production `incremental_vs_no_hair_ms` for total hair cost.
4. Compare production `incremental_vs_card_control_ms` for additional shaded hair/BSDF work.
5. Use light-count slope as the primary empirical per-light BSDF/ALU signal.
6. Use resolution slope as the primary fragment-scaling signal.
7. Use `ALU_PROBE_96` and `LUT_PROBE_16` only to explain device sensitivity, not to manufacture an exact production cost decomposition.
8. Use `source_inventory.json` to explain structural differences, not as a benchmark result.

GPU clocks can downshift when utilization is too low. The suite therefore prewarms every variant and supports heavier light/resolution workloads. For close results, use multiple process-level repeats and a workload large enough that the measured tier delta is comfortably above repeat noise.

## Custom matrix examples

```bash
# iGPU-focused shader-bound pass.
python benchmark/tools/run_production_hair_benchmarks.py \
  --godot /mnt/c/Tools/Godot/godot.exe \
  --gpu-index 1 \
  --resolutions 1920x1080,2560x1440 \
  --coverage-modes cards \
  --extra-lights 0,3,7 \
  --repeats 5 \
  --sample 600

# Coverage/overdraw comparison without synthetic probes.
python benchmark/tools/run_production_hair_benchmarks.py \
  --godot godot \
  --coverage-modes cards,coverage \
  --extra-lights 3 \
  --repeats 5 \
  --no-probes
```

For a dry run that only prints the process matrix:

```bash
python benchmark/tools/run_production_hair_benchmarks.py --preset full --dry-run
```
