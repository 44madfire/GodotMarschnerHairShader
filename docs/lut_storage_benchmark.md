# Production LUT storage benchmark

This benchmark compares the two serialization strategies available for the production Fast and Cinematic Marschner lookup tables:

1. **Raw-data Resource** — the current production representation. The `.res` stores dimensions, image format, numerical/model contract metadata, and a `PackedByteArray`. `HairMarschnerLUTAdapter` validates the resource and reconstructs a cached `ImageTexture3D` at runtime.
2. **Direct ImageTexture3D** — the exact same texel payload is serialized by Godot 4.7 directly as an `ImageTexture3D` `.res` and loaded without the raw-data reconstruction step.

The benchmark does not propose changing the release format by itself. It measures the startup/storage tradeoff now that direct `ImageTexture3D` persistence is known to work in the current engine target.

## Production inputs

The benchmark uses the actual generated resources consumed by the production shaders:

```text
Fast
res://benchmark/resources/luts/unity_azimuthal_64.res
64 x 64 x 64 RGBA16F
unity_hdrp_azimuthal_n_v1

Cinematic
res://benchmark/resources/luts/cinematic_longitudinal_kernel_128x128x64.res
128 x 128 x 64 R16F
deon_physical_longitudinal_log2q_v2
```

Both contain 2 MiB of uncompressed texel payload, but their serialized `.res` representation and reconstruction behavior may differ.

## What is measured

Each timing sample runs in a **fresh Godot process**. This prevents a sample from benefiting from Godot's `ResourceLoader` cache or `HairMarschnerLUTAdapter` texture cache.

For the raw-data representation the timed path is:

```text
ResourceLoader.load(raw .res)
  -> validation_errors()
  -> HairMarschnerLUTAdapter.texture3d_from_resource()
  -> valid Texture3D RID
```

For the direct representation the timed path is:

```text
ResourceLoader.load(ImageTexture3D .res)
  -> dimension/format checks
  -> valid Texture3D RID
```

The case script records:

```text
resource_load_us
validation_us
texture_build_us
ready_us
```

`ready_us` is the primary apples-to-apples metric: CPU-side elapsed time from starting `ResourceLoader.load()` until the process has a structurally valid `Texture3D` with a valid RID.

This is **not** a GPU sampling benchmark and does not measure shader execution. Once loaded, both representations produce the same `ImageTexture3D` data used by the shader. It also does not force a render-thread/GPU synchronization point, so the result should be interpreted as engine-side resource readiness rather than guaranteed physical GPU upload completion.

Fresh processes remove Godot-level resource caches but do **not** flush the operating system's filesystem/page cache. The repeated measurements therefore characterize resource deserialization and texture construction under normal warm/warm-ish filesystem conditions, not true cold-storage latency.

## Preparation integrity check

Before timing, `prepare_lut_storage_benchmark.gd` converts each production raw resource to a temporary direct `ImageTexture3D` under `user://`.

Preparation fails unless the direct round trip preserves:

- width, height, and depth;
- image format;
- slice count;
- every byte of the complete production texel payload.

It also records the on-disk byte size of the raw and direct `.res` files.

Temporary direct resources are removed after the benchmark unless `--keep-direct-resources` is supplied.

## Run

If the production LUTs already exist:

```bash
python benchmark/tools/run_lut_storage_benchmark.py \
  --godot /mnt/c/Tools/Godot/godot.exe \
  --project .
```

If either production LUT is missing, generate it automatically first:

```bash
python benchmark/tools/run_lut_storage_benchmark.py \
  --godot /mnt/c/Tools/Godot/godot.exe \
  --project . \
  --generate
```

A short smoke run can use three repeats:

```bash
python benchmark/tools/run_lut_storage_benchmark.py \
  --godot /mnt/c/Tools/Godot/godot.exe \
  --project . \
  --repeats 3
```

The default is 12 fresh-process samples for each of the four cases:

```text
Fast / raw
Fast / direct
Cinematic / raw
Cinematic / direct
```

Case order rotates and reverses between repeats to reduce systematic ordering bias.

An optional headless comparison is available:

```bash
python benchmark/tools/run_lut_storage_benchmark.py \
  --godot /mnt/c/Tools/Godot/godot.exe \
  --project . \
  --headless
```

For the release decision, prefer a normal renderer run because it is closer to how the resources are used by an actual project. Headless mode is useful as an additional serialization/tooling compatibility check.

## Outputs

By default the runner writes:

```text
benchmark/results/lut_storage_benchmark/latest/
  samples.csv
  summary.json
  commands.txt
```

`summary.json` contains median and median absolute deviation (MAD) for each timing field, plus:

```text
direct_ready_over_raw_ready
direct_ready_delta_us
direct_size_over_raw_size
direct_size_delta_bytes
```

Expected final marker:

```text
LUT_STORAGE_BENCHMARK_OK
```

## Interpreting the result

The raw-data representation has capabilities that a bare `ImageTexture3D` does not carry:

- explicit Fast/Cinematic contract identifiers;
- eta or beta-range metadata;
- channel semantics;
- deterministic raw payload access for CPU-side numerical validation;
- validation before the runtime texture is created.

A direct texture can recover some of this only by adding a wrapper resource or relying on external conventions, which reduces the simplicity advantage.

Therefore the release-format decision should not be based on load time alone. A useful decision rule is:

- **Keep the current raw representation** if direct serialization produces only a small startup/file-size improvement. The current format is validated, explicit, and already integrated with the production adapter.
- **Consider a direct or wrapped-direct representation** only if it produces a material and repeatable reduction in package size and/or `ready_us` large enough to justify changing the LUT contract and migration path.

Any format change should remain separate from the shader-math validation: this experiment changes only how identical LUT texels reach an `ImageTexture3D`.
