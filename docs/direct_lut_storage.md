# Direct ImageTexture3D production LUT migration

## Decision

Production Fast and Cinematic LUTs are stored and loaded as directly serialized `ImageTexture3D` resources. The shader slot owns the semantic contract; `HairMarschnerLUTAdapter` validates dimensions/format/RID before binding.

The development raw-data resources remain under `benchmark/resources/luts/` only as numerical source/benchmark fixtures. They are no longer the default production runtime path.

## Evidence

Local Godot 4.7-stable results supplied on 2026-08-13 from an RTX 5090, 12 fresh-process repeats per kind/mode:

| storage | Fast ready_us median (MAD) | Cinematic ready_us median (MAD) |
|---|---:|---:|
| raw scripted resource | 51,604 (1,548) | 53,380 (1,881) |
| direct `ImageTexture3D` | 2,260 (68) | 2,188 (76) |
| scripted manifest -> direct texture | 29,903 (568) | 30,060 (368) |

The manifest retained the contract and was about 1.75x faster than the raw representation, but remained 13.2-13.7x slower than loading the direct texture. Manifest validation itself was about 13 us; the approximately 30 ms cost was the scripted metadata-resource load, not texture construction. Direct/manifest footprint was only about 0.6% above the old raw resource.

Therefore a runtime GDScript manifest is not used. Semantic metadata that the shader requires is represented by adapter constants associated with each LUT slot. Authoring/provenance notes remain in development documentation rather than being deserialized on the render path.

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

Development production paths:

```text
res://assets/hair/luts/unity_azimuthal_64.res
res://assets/hair/luts/cinematic_longitudinal_kernel_128x128x64.res
```

The distributable addon repaths the same validated resources to:

```text
res://addons/marschner_hair/luts/unity_azimuthal_64.res
res://addons/marschner_hair/luts/cinematic_longitudinal_kernel_128x128x64.res
```

## Godot 4.7 rendering-context constraint

The project persistence probe and the production-size migration smoke test establish an important distinction on the validated Godot 4.7 build:

- normal/windowed rendering context: `ImageTexture3D` save and cross-process reload preserve the complete payload;
- `--headless` display path: save/load yields an empty 1x1x1 texture resource instead of the stored 3D image payload.

This is independent of the LUT format or size: the project's small RGBA8 persistence probe also fails in headless mode. Consequently, direct production LUT materialization and integrity verification must run with a real rendering context. The numerical raw-LUT generators themselves remain headless-safe.

Runtime hair rendering already requires a real renderer/RID, so this constraint does not change the production shader path. It does mean build/asset-generation tooling must not regenerate or validate these direct `ImageTexture3D` resources under Godot's headless display driver.

## Materialize the direct resources

The existing raw generators remain the numerical source of truth. Once their validated resources exist, materialize byte-identical direct textures with a normal Godot rendering context:

```bash
godot --path . \
  --script res://benchmark/tools/materialize_direct_production_luts.gd
```

Do not add `--headless` to this command.

If the raw resources are missing, generate them first with the existing generator scripts, or use the smoke runner with `--generate-raw`.

The materializer refuses success unless the saved/reloaded `ImageTexture3D` has the expected structure and the complete texel payload is byte-identical to the validated raw source.

## Regression checks

Fresh-process storage/integrity check, also requiring a real rendering context:

```bash
godot --path . \
  --script res://benchmark/tests/test_direct_lut_resource_integrity.gd
```

Real-renderer material/profile binding check:

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

Add `--generate-raw` only if the benchmark raw LUTs are absent. Add `--gpu-index N` to choose the renderer for all windowed migration stages. `--skip-binding` skips the final profile-binding check, but materialization and integrity verification still require normal Godot processes.

Expected final marker:

```text
DIRECT_LUT_MIGRATION_SMOKE_OK
```

The validated migration run produced two byte-identical direct resources with 2,097,152-byte texel payloads:

- Fast: 64^3 RGBA16F;
- Cinematic: 128x128x64 R16F.

Both direct `.res` files are committed on `development` and handled as binary resources by `.gitattributes`.

## Release status

The direct-LUT migration is already part of `development` and the current rc2 release package. Release users should receive the direct resources; they should not be asked to run the numerical generators or raw-data reconstruction path.

When preparing a later release update, copy the validated direct textures unchanged into `addons/marschner_hair/luts/` and run the package-level smoke described in [`release_validation.md`](release_validation.md). That smoke is intended to verify the repathed preload/include/LUT paths in the actual distributable addon, not to regenerate the LUT payloads.
