# ImageTexture3D persistence probe

The LUT adapter stores production lookup tables as validated raw-data resources and reconstructs `ImageTexture3D` objects at runtime. That representation remains useful because it keeps dimensions, format, numerical metadata, and model contracts explicit; it is **not** intended to work around a current Godot 4.7 inability to serialize `ImageTexture3D`.

Godot historically had an `ImageTexture3D` serialization defect, but modern engine versions contain an `_images` serialization path. This development probe verifies the behavior independently in the version/build actually used by this project.

## What the probe checks

`benchmark/tests/test_imagetexture3d_persistence.gd` creates a deterministic 8x6x4 RGBA8 `ImageTexture3D` and saves it as both:

```text
user://marschner_imagetexture3d_roundtrip.res
user://marschner_imagetexture3d_roundtrip.tres
```

A **separate Godot process** then reloads each resource and checks:

- resource type is `ImageTexture3D`;
- width, height, depth, format, and mipmap state survived;
- all four image slices survived;
- every slice's byte payload exactly matches the generated source data.

The separate write/verify processes are intentional so ResourceLoader caching cannot make a same-process round trip look successful.

## Recommended run

```bash
python benchmark/tools/run_imagetexture3d_persistence_probe.py \
  --godot /mnt/c/Tools/Godot/godot.exe \
  --project .
```

Expected final marker:

```text
IMAGE_TEXTURE_3D_PERSISTENCE_ROUNDTRIP_OK
```

To additionally test Godot's headless display/rendering path:

```bash
python benchmark/tools/run_imagetexture3d_persistence_probe.py \
  --godot /mnt/c/Tools/Godot/godot.exe \
  --project . \
  --headless
```

The runner cleans up the temporary `user://` resources after verification.

## Interpretation

If both normal and headless runs pass on Godot 4.7, we can treat direct `ImageTexture3D` serialization as supported for our current engine target. That does **not** automatically mean the production LUT format should change: the current raw-data resource still provides explicit contract metadata, deterministic serialized payloads, CPU-side validation/sampling access, and controlled runtime texture construction.

A later experiment can compare package size, load time, editor behavior, and validation ergonomics between the current LUT resource and a directly serialized production-size `ImageTexture3D` before considering any format migration.
