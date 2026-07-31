# Hair benchmark harness

## Open and run

Open `benchmark/BenchmarkHarness.tscn` in the Godot 4.7 editor and run the current scene. Set `BenchmarkController.auto_start_smoke` to `true` for an automatic smoke run, or call `start_smoke()` / `start_benchmark()` on the controller from a script or the debugger. Results are written below:

```text
user://hair_benchmarks/<timestamp>/
```

Each completed run contains `run_manifest.json`, `samples.csv`, `summary.json`, and `color.png`.

## Scope

The harness discovers direct `MeshInstance3D` groom children under `Head` at runtime and currently covers the ten fixture grooms. Resource-backed cases and suites own their camera pose, lighting PackedScene, viewport target, timing, repeats, and capture flags; the controller still preserves the manual API. The harness owns the camera, directional-light fallback, and environment; fixture camera/light/environment state is restored on reset or exit without changing the fixture scene.

Modes are exactly:

- `NO_HAIR`
- `INDIVIDUAL_GROOM`
- `ALL_GROOMS`
- `REPRESENTATIVE_DEFAULT`

Variants are exactly:

- `NO_HAIR`
- `COVERAGE_CONTROL`
- `CURRENT_MARSCHNER_BASELINE`
- `APPROX_KAJIYA_KAY`

The baseline, coverage, and approximate Kajiya–Kay variants clone each active source `ShaderMaterial` per mesh surface, preserve its parameters and groom textures, replace only the shader resource, and use `set_surface_override_material()`. Mesh material resources are never edited. `benchmark/reference/BASELINE_COMMIT.txt` freezes the source commit, and the reference shader/include are immutable copies of the current source.

## Resource-backed suites

Phase 2 resources live under `benchmark/cases/`, `benchmark/cameras/`, and `benchmark/lighting/`. A case is started with `BenchmarkController.start_case(case_resource)`. A suite validates all of its cases before queueing them and can be started with `BenchmarkController.start_suite(suite_resource)`. Cases and repeats run sequentially; output uses:

```text
user://hair_benchmarks/<timestamp>/<suite>/<case>/repeat_001/
```

Each case directory contains the normal run artifacts plus resource metadata in `run_manifest.json`. The suite directory contains `suite_manifest.json` after every case and repeat has completed. Newly written run, summary, and suite manifests include `comparison_validity.marker = "material_override_precedence_repair_v1"`; analysis should reject artifacts that lack this marker. Manual `start_benchmark()` calls retain the existing `user://hair_benchmarks/<timestamp>/` layout.

Diagnostic suite cases can additionally request `coverage.png` and `tangent.png` through their capture flags. Coverage metrics are computed only from `coverage.png`: a pixel qualifies as white when R, G, and B are each at least `0.95`; the manifest and summary record the white-pixel count, percentage of total frame pixels, and the inclusive white-pixel bounding rectangle. Each capture record includes the process frame and monotonic timestamp immediately after its post-draw frame. The production `TIME`-driven Bayer/hash sequence is recorded, not frozen, so diagnostic captures remain temporally hash-dependent.

Variant artifacts generated before the material-override precedence repair are invalid for comparison because groom-level overrides could hide the intended per-surface shader variants. Rerun the replacement smoke suite; those post-marker results are the first trustworthy baseline/control/Kajiya comparisons.

## Command line

User arguments are read after `--`. To run the checked-in smoke suite and exit only after all output has been written:

```text
godot --path . res://benchmark/BenchmarkHarness.tscn -- --suite=res://benchmark/cases/smoke_suite.tres --quit-on-complete
```

The explicit `res://benchmark/BenchmarkHarness.tscn` scene path is required so the harness controller and CLI node run instead of the project main scene. `--suite=<res path>` selects the suite resource; `--quit-on-complete` requests exit code 0 only after the suite manifest and all case outputs are written (or exit code 1 after a failure). Manual/editor runs do not quit automatically.

## Measurements and data collection

The state sequence is `PREWARM` (180 frames), `SETTLE` (30), `SAMPLE` (300), `CAPTURE` (1), and `COMPLETE`. During `SAMPLE` only, the controller records previous-frame viewport CPU/GPU render time and visible/shadow object, primitive, and draw-call counters through the Godot 4.7 `RenderingServer` viewport APIs. The color capture waits for `RenderingServer.frame_post_draw` and never runs in the timing phase. `summary.json` reports median and p95 for each collected metric.

Use the editor for smoke validation only. Canonical data should come from a release build with vsync and any FPS cap disabled. Compare median and p95, not a single frame. Results are hardware, driver, renderer, resolution, and build dependent; viewport timing APIs do not provide a complete whole-system GPU profile.
