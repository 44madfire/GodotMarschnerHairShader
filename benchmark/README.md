# Hair benchmark harness

## Open and run

Open `benchmark/BenchmarkHarness.tscn` in the Godot 4.7 editor and run the current scene. Set `BenchmarkController.auto_start_smoke` to `true` for an automatic smoke run, or call `start_smoke()` / `start_benchmark()` on the controller from a script or the debugger. Results are written below:

```text
user://hair_benchmarks/<timestamp>/
```

Each completed run contains `run_manifest.json`, `samples.csv`, `summary.json`, and `color.png`.

## Scope

This first slice discovers direct `MeshInstance3D` groom children under `Head` at runtime and currently covers the ten fixture grooms. It has no UI, suites, CLI, profiles, masks, multi-light setups, candidate management, or diffing. The harness owns the camera, directional light, and environment; the fixture camera/light/environment are disabled without changing the fixture scene.

Modes are exactly:

- `NO_HAIR`
- `INDIVIDUAL_GROOM`
- `ALL_GROOMS`
- `REPRESENTATIVE_DEFAULT`

Variants are exactly:

- `NO_HAIR`
- `COVERAGE_CONTROL`
- `CURRENT_MARSCHNER_BASELINE`

The baseline and coverage variants clone each active source `ShaderMaterial` per mesh surface, preserve its parameters and groom textures, replace only the shader resource, and use `set_surface_override_material()`. Mesh material resources are never edited. `benchmark/reference/BASELINE_COMMIT.txt` freezes the source commit, and the reference shader/include are immutable copies of the current source.

## Measurements and data collection

The state sequence is `PREWARM` (180 frames), `SETTLE` (30), `SAMPLE` (300), `CAPTURE` (1), and `COMPLETE`. During `SAMPLE` only, the controller records previous-frame viewport CPU/GPU render time and visible/shadow object, primitive, and draw-call counters through the Godot 4.7 `RenderingServer` viewport APIs. The color capture waits for `RenderingServer.frame_post_draw` and never runs in the timing phase. `summary.json` reports median and p95 for each collected metric.

Use the editor for smoke validation only. Canonical data should come from a release build with vsync and any FPS cap disabled. Compare median and p95, not a single frame. Results are hardware, driver, renderer, resolution, and build dependent; viewport timing APIs do not provide a complete whole-system GPU profile.
