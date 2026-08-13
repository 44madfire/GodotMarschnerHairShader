# Production hair LUTs

Generated direct `ImageTexture3D` resources live here:

- `unity_azimuthal_64.res`
- `cinematic_longitudinal_kernel_128x128x64.res`

Materialize them from the validated benchmark raw LUTs with:

```bash
godot --headless --path . --script res://benchmark/tools/materialize_direct_production_luts.gd
```

See `docs/direct_lut_storage.md` for contracts and validation.
