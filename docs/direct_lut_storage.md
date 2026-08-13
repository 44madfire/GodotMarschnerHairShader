# Direct ImageTexture3D production LUT migration

## Decision

Production Fast and Cinematic LUTs should be stored and loaded as directly serialized `ImageTexture3D` resources. The shader slot owns the semantic contract; `HairMarschnerLUTAdapter` validates dimensions/format/RID before binding.

The development raw-data resources remain under `benchmark/resources/luts/` only as numerical source/benchmark fixtures. They are no longer the default production runtime path.

## Evidence

Local Godot 4.7-stable results supplied on 2026-08-13 from an RTX 5090, 12 fresh-process repeats per kind/mode:

| storage | Fast ready_us median (MAD) | Cinematic ready_us median (MAD) |
|---|---:|---:|
| raw scripted resource | 51,604 (1,548) | 53,380 (1,881) |
| direct `ImageTexture3D` | 2,260 (68) | 2,188 (76) |
| scripted manifest -> direct texture | 29,903 (568) | 30,060 (368) |

The manifest retained the contract and was about 1.75x faster than the raw representation, but remained 13.2-13.7x slower than loading the direct texture. Manifest validation itself was about 13 us; the approximately 30 ms cost was the scripted metadata-resource load, not texture construction. Direct/manifest footprint was only about 0.6% above the old raw resource.

Therefore a runtime GDScript manifest is not used. Semantic metadata that the shader requires is represented by adapter constants associated with each LUT slot. Authoring/provenance notes can remain in development documentation rather than being deserialized on the render path.

## Runtime contracts

Fast:

- contract: `unity_hdrp_azimuthal_n_v1`
- dimensions: 64 x 64 x 64
- format: RGBA16F (`Image.FORMAT_RGBAH`)
- eta: 1.55
- channels: `R=N_R,G=N_TT,B=N_TRT,A=1`

Cinematic:

- contract: `deon_physical_longitudinal_log2q_v2`
- dimensions: 128 x 128 x 64
- format: R16F (`Image.FORMAT_RH`)
- beta range: [0.05, 64]
- low-beta transition: [0.05, 0.10]
- channel: `R=log2(Q)`

Production paths:

```text
res://assets/hair/luts/unity_azimuthal_64.res
res://assets/hair/luts/cinematic_longitudinal_kernel_128x128x64.res
```

## Materialize the direct resources

The existing raw generators remain the numerical source of truth. Once their validated resources exist, materialize byte-identical direct textures with:

```bash
godot --headless --path . \
  --script res://benchmark/tools/materialize_direct_production_luts.gd
```

If the raw resources are missing, generate them first with the existing generator scripts, or use the smoke runner with `--generate-raw`.

The materializer refuses success unless the saved/reloaded `ImageTexture3D` has the expected structure and the complete texel payload is byte-identical to the validated raw source.

## Regression checks

Fresh-process storage/integrity check, safe in headless mode:

```bash
godot --headless --path . \
  --script res://benchmark/tests/test_direct_lut_resource_integrity.gd
```

Real-renderer material/profile binding check (one normal Godot window; do not use `--headless`):

```bash
godot --path . \
  --script res://benchmark/tests/test_direct_lut_binding.gd
```

Or run the complete sequence:

```bash
python benchmark/tools/run_direct_lut_migration_smoke.py \
  --godot /mnt/c/Tools/Godot/godot.exe \
  --project .
```

Add `--generate-raw` if needed. Add `--gpu-index N` to choose the renderer for the binding test. `--skip-binding` performs only the headless serialization/integrity stages.

Expected final marker:

```text
DIRECT_LUT_MIGRATION_SMOKE_OK
```

## Release migration

The direct binary `.res` files should be generated and committed after local validation. Once those artifacts are available, the release branch can ship them directly and remove the consumer-side LUT generation requirement. The benchmark-only raw resource classes/reconstruction compatibility path can remain on `development` to preserve historical storage comparisons; they do not need to ship in the addon.
