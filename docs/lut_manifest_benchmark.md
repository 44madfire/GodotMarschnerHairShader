# Manifest-backed LUT storage benchmark

This follow-up extends the production LUT storage experiment with a third representation:

1. `raw`: legacy/benchmark scripted resource with metadata plus `PackedByteArray`, reconstructed by `HairMarschnerLUTAdapter`.
2. `direct`: bare serialized `ImageTexture3D`.
3. `manifest`: a small validated resource containing the Fast/Cinematic semantic contract and an **external** reference to the same directly serialized `ImageTexture3D` used by the `direct` case.

The manifest preparation fails if the texture reference is embedded instead of external, if the contract is invalid, or if the referenced texture does not retain the production dimensions/format. The previously validated direct texture is therefore the identical heavy payload in both `direct` and `manifest`; the manifest case measures only the extra metadata-resource load/validation layer.

Run a smoke test:

```bash
python benchmark/tools/run_lut_manifest_benchmark.py \
  --godot /mnt/c/Tools/Godot/godot.exe \
  --project . \
  --repeats 3
```

Run the normal 12-repeat benchmark:

```bash
python benchmark/tools/run_lut_manifest_benchmark.py \
  --godot /mnt/c/Tools/Godot/godot.exe \
  --project .
```

Add `--generate` if either production raw LUT is missing. Add `--headless` only as an additional tooling check; prefer the normal renderer run for the release-format decision.

The runner launches a fresh Godot process for each of six cases (`Fast/Cinematic` x `raw/direct/manifest`), rotates/reverses ordering between repeats, and reports median/MAD for `resource_load_us`, `validation_us`, `texture_build_us`, and `ready_us`.

Output:

```text
benchmark/results/lut_storage_manifest_benchmark/latest/
  samples.csv
  summary.json
  commands.txt
```

Key comparison fields are:

```text
direct_ready_over_raw_ready
manifest_ready_over_raw_ready
manifest_ready_over_direct_ready
direct_size_over_raw_size
manifest_total_size_over_raw_size
manifest_metadata_bytes
manifest_total_bytes
```

`manifest_total_bytes` counts both files required by the representation: the direct texture `.res` plus the small manifest `.res`.

Expected marker:

```text
LUT_STORAGE_MANIFEST_BENCHMARK_OK
```
