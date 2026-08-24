# Production hair LUTs

Direct `ImageTexture3D` production resources live here:

- `unity_azimuthal_64.res`
- `cinematic_longitudinal_kernel_128x128x64.res`

To regenerate them from the validated benchmark raw LUTs, use a normal Godot rendering context:

```bash
godot --path . --script res://benchmark/tools/materialize_direct_production_luts.gd
```

Do not add `--headless`: on the Godot 4.7 build validated by this project, `ImageTexture3D` save/load in the headless display path serializes an empty 1x1x1 resource instead of the texture payload.

See `docs/direct_lut_storage.md` for contracts, validation, and the smoke-test workflow.
