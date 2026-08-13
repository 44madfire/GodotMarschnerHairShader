# Hair-card coverage quality/performance benchmark

This follow-up is intentionally separate from the Marschner BSDF benchmark. The existing dual-GPU results showed that shared card/coverage preparation is a major cost on constrained GPUs, while the current animated Bayer coverage can visibly flicker in normal editor use.

The benchmark compares the same Blowout groom and shared card preparation with:

- `legacy_time_bayer`: current `TIME * 500.0` phase animation.
- `static_bayer`: fixed ordered-Bayer phase.
- `taa_bayer`: ordered Bayer with one explicit phase per rendered frame.
- `alpha_hash`: Godot's native alpha-hash output path.
- `a2c`: Godot's alpha-to-coverage render mode at 2x/4x MSAA.

## TAA-aligned Bayer candidate

Godot 4.7 sets ordinary TAA's default `jitter_phase_count` to 16 in `RendererViewport::_configure_3d_render_buffers()`. Spatial shaders expose `TIME`, but they do not expose a public TAA jitter-index or rendered-frame built-in.

The `taa_bayer` benchmark therefore replaces elapsed time with an integer `bayer_phase_index` advanced once per actual rendered frame. It cycles over 0..15. The phase maps to all sixteen `(x,y)` offsets of the 4x4 Bayer matrix, so a fixed fragment sees every Bayer threshold once during the same 16-frame period used by Godot 4.7 TAA.

This is cadence/period alignment. It does not claim that phase 0 is Godot's private internal TAA sample 0. If the engine later exposes that index, the coverage phase can be driven directly from it.

The legacy `TIME * 500.0` path is not frame-aligned: it can skip/repeat phases as frame rate changes and is affected by time scaling. Because it adds the same scalar to X and Y, it also only walks four diagonal offsets of the 4x4 Bayer tile before repeating.

## Native candidates

The alpha-hash probe writes bias-adjusted groom coverage to `ALPHA` and enables `ALPHA_HASH_SCALE`. Godot 4.7's Forward+ renderer computes an object-space derivative-scaled hash threshold and discards fragments below it.

The alpha-to-coverage probe uses `render_mode alpha_to_coverage` and writes the same adjusted coverage directly to `ALPHA`. It is tested with 2x and 4x 3D MSAA because multisample count materially affects both cost and coverage fidelity.

All probes keep the same groom texture reads, distance/depth coverage bias, root shading, frizz perturbation, and orthonormal strand-frame reconstruction. They are unshaded so BSDF/light cost does not obscure coverage cost.

## Run

Smoke test:

```bash
python benchmark/tools/run_hair_coverage_benchmark.py \
  --godot /mnt/c/Tools/Godot/godot.exe \
  --project . \
  --repeats 1 \
  --sample 60 \
  --cases legacy_bayer_no_taa,static_bayer_no_taa,taa_bayer,alpha_hash_taa
```

Full matrix:

```bash
python benchmark/tools/run_hair_coverage_benchmark.py \
  --godot /mnt/c/Tools/Godot/godot.exe \
  --project .
```

Use `--gpu-index N` to select the same devices used by the production-tier benchmark.

Default cases:

```text
legacy_bayer_no_taa
legacy_bayer_taa
static_bayer_no_taa
static_bayer_taa
taa_bayer
alpha_hash_no_taa
alpha_hash_taa
a2c_2x
a2c_4x
a2c_2x_taa
```

Each fresh process measures `NO_HAIR`, a pipeline-matched `CARDS_PIPELINE_CONTROL`, and `COVERAGE`. The primary performance metric is `incremental_vs_cards_ms`.

Outputs:

```text
benchmark/results/hair_coverage_benchmark/latest/
  summary.json
  runs.json
  aggregate_rows.csv
```

Expected marker:

```text
HAIR_COVERAGE_PROCESS_MATRIX_OK
```

Run the deterministic phase test separately:

```bash
godot --headless --path . \
  --script res://benchmark/tests/test_hair_coverage_phase_sequence.gd
```

Expected marker:

```text
HAIR_COVERAGE_PHASE_SEQUENCE_OK
```

## Visual review remains required

GPU timing does not rank visual fidelity. Review the same candidates interactively for static-camera flicker, motion shimmer, visible 4x4 structure, distance stability, shadow stability, and TAA ghosting. Godot documents that TAA can ghost on moving objects and skinned meshes, so temporal coverage should not become the default solely because TAA is available.

The benchmark PR deliberately keeps the existing production `TIME` path available while gathering evidence. A production follow-up can then make stable coverage the editor/default behavior and select the best temporal/native alternative for projects that opt into it.
