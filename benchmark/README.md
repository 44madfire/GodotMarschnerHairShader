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
- `BUILTIN_ALPHA_HASH_CONTROL`

The baseline, coverage, and approximate Kajiya–Kay variants clone each active source `ShaderMaterial` per mesh surface, preserve its parameters and groom textures, replace only the shader resource, and use `set_surface_override_material()`. Mesh material resources are never edited. `benchmark/reference/BASELINE_COMMIT.txt` freezes the source commit, and the reference shader/include are immutable copies of the current source.

Two variants exercise the source alpha path with different discard methods. `COVERAGE_CONTROL` is the exact custom control: it keeps the source `ShaderMaterial` interface, reads coverage/depth/seed from the packed `attributes_texture` (R/G/B) and reproduces the production shader's distance/depth-biased Bayer + `TIME` discard, so its coverage behavior matches the source hash path pixel-for-pixel (the temporal hash is effectively frozen during benchmark runs). `BUILTIN_ALPHA_HASH_CONTROL` is an approximation: at runtime the controller converts each source attributes PNG (RGB, coverage in red, no alpha) into a transient in-memory texture with white RGB and the source red channel copied to alpha, assigns it as `albedo_texture` on a per-surface `StandardMaterial3D` (`TRANSPARENCY_ALPHA_HASH`, unshaded, cull disabled, nearest filtering, `SPECULAR_DISABLED`, roughness 1, albedo color from the source `albedo` parameter with alpha 1), and lets Godot's built-in alpha-hash discard fragments. The converted textures are cached per process and never written to disk; missing or empty attributes textures fail the start with a clear message instead of crashing. Because the built-in hash has no distance/depth bias and no `TIME`-driven Bayer pattern, coverage edges differ from the exact `COVERAGE_CONTROL`; the variant exists to compare the built-in hash's cost and coverage against the custom path. Shadow and depth participation follow the built-in alpha-hash defaults.

## Resource-backed groom definitions and profiles

Stable groom and material contracts live under `benchmark/resources/` and never modify imported scenes or materials:

- `hair_groom_definition.gd` (`HairGroomDefinition`): stable `groom_id` (node-name based, must match the pattern of ASCII letters/digits/underscores), `display_name`, `category`, `groom_root` (NodePath relative to `Head`), `hair_mesh_paths` (relative to `groom_root`), explicit `hair_surface_indices` (never an implicit "all surfaces"), `expected_material_profile` (a profile id), and `notes`. `validation_errors()` enforces stable IDs, a non-empty root, at least one mesh path, and explicit, non-negative, duplicate-free surface selection.
- `hair_benchmark_profile.gd` (`HairBenchmarkProfile`): canonical material parameters. Source-compatible fields mirror the current production shader interface (`albedo`, `longitudinal_roughness`, `azimuthal_roughness`, `cuticle_tilt_offset`, `specular`, `coords_texture`, `attributes_texture`) and can be applied today by cloning the source `ShaderMaterial`s and setting the matching shader parameters. Future-tier placeholder fields (absorption/melanin, `index_of_refraction`, R/TT/TRT lobe weights, multiple scattering, root/tip colors, flow texture, coverage/alpha overrides) are typed and validated but not yet read by the controller — they are documented as placeholders for the profile adapter.
- `hair_groom_catalog.gd` (`HairGroomCatalog`): ordered resource-backed catalog of `HairGroomDefinition`s with duplicate-id validation.
- Data: `benchmark/resources/profiles/source_current.tres` is the default profile (id `&"source_current"`, mirroring the source shader defaults); `benchmark/resources/grooms/hair_groom_catalog.tres` defines the ten fixture grooms.

`BenchmarkCase` gained `profile_id: StringName` defaulting to `&"source_current"`; it is validated (non-empty) and recorded in `run_manifest.json`/`summary.json` as `profile_id`. Existing `.tres` cases load unchanged because the default applies. The controller's runtime groom catalog now exposes stable `groom_id`/`name` and display metadata (`display_name`, `category`) separately from the transient per-process instance `id`, merging `display_name`/`category` from `hair_groom_catalog.tres` when it loads (falling back to node names otherwise); `run_manifest.json` grooms entries include both. `Blowout` case selection and all material assignment paths are unchanged — the existing source-material clone path still applies variants.

Current limitation: per-groom catalog assets and the profile adapter (resolving `groom_root`, applying `expected_material_profile` per surface, and rewriting material assignment around adapters) are the next step; for now the catalog is a metadata contract only.

## Resource-backed suites

Phase 2 resources live under `benchmark/cases/`, `benchmark/cameras/`, and `benchmark/lighting/`. A case is started with `BenchmarkController.start_case(case_resource)`. A suite validates all of its cases before queueing them and can be started with `BenchmarkController.start_suite(suite_resource)`. Cases and repeats run sequentially; output uses:

```text
user://hair_benchmarks/<timestamp>/<suite>/<case>/repeat_001/
```

Camera poses (all against the real fixture head at the origin, fov 60, look-at math): `front_portrait`, `three_quarter`, `rear_backlit` (original), plus `side_grazing` (0.55 m on the +X side, shallow angle), `close_up` (≈0.24 m, near 0.01), and `distant_lod` (≈1.5 m). Lighting fixtures: `single_directional_key`, `rear_spot`, `four_light_rig` (original), plus `front_omni` (one shadow-casting omni in front), `area_light` (one 0.6×0.4 m rectangle `AreaLight3D` softbox — Godot 4.7 Forward+ only, which is the project renderer), `eight_light_stress` (four shadow-casting directionals + four shadow-casting omnis), and `environment_only` (no light nodes; ambient/background only, the lower-bound lighting reference). All requested fixtures were representable with existing node types, so nothing is deferred.

Three representative suites were added (all cases at 1920×1080, default timing 180/30/300, `capture_color` only):

- `visual_suite.tres` (7 cases): exercises the new poses and rigs — frozen baseline at `side_grazing`/`close_up`/`distant_lod`, coverage control at `side_grazing` (rear spot), approximate Kajiya–Kay at `close_up` (area light), built-in alpha hash at `distant_lod` (front omni), and a `NO_HAIR` side reference.
- `performance_suite.tres` (6 cases): the five Blowout variants (NO_HAIR, exact coverage control, frozen baseline, approximate Kajiya–Kay, built-in alpha hash) at `three_quarter` + `single_directional_key`, plus an `ALL_GROOMS` frozen-baseline case (all ten grooms — the heaviest supported scene) at the same camera/rig.
- `light_scaling_suite.tres` (7 cases): frozen baseline at `three_quarter` across the lighting sweep — `environment_only`, `single_directional_key`, `front_omni`, `rear_spot`, `four_light_rig`, `area_light`, `eight_light_stress`.

All case/suite/camera/lighting ids are unique; the existing `smoke_suite.tres` and `capture_smoke_suite.tres` are unchanged and still validate. The shorter timing used by `capture_smoke_suite` cases is intentional (diagnostic captures); the new suites keep the 180/30/300 smoke defaults.

Each case directory contains the normal run artifacts plus resource metadata in `run_manifest.json`. The suite directory contains `suite_manifest.json` after every case and repeat has completed; every case entry there includes the run's `validation` result (`valid` + `validation_notes`) so unstable cases can be flagged at suite level without opening each summary. Newly written run, summary, and suite manifests include `comparison_validity.marker = "material_override_precedence_repair_v1"`; analysis should reject artifacts that lack this marker. Manual `start_benchmark()` calls retain the existing `user://hair_benchmarks/<timestamp>/` layout.

Diagnostic suite cases can additionally request `coverage.png` and `tangent.png` through their capture flags. Coverage metrics are computed only from `coverage.png`: a pixel qualifies as white when R, G, and B are each at least `0.95`; the manifest and summary record the white-pixel count, percentage of total frame pixels, and the inclusive white-pixel bounding rectangle. Each capture record includes the process frame and monotonic timestamp immediately after its post-draw frame.

Benchmark hash timing is deterministic: before rendering starts the controller saves `Engine.time_scale`, sets it to the tiny positive `BENCHMARK_TIME_SCALE` (`1e-6`), and restores the caller's prior value on every completion, failure, cancellation, and exit path (manual runs restore on `reset_benchmark()` or scene exit; ordinary use of the harness scene without a started benchmark is unaffected). At this scale shader `TIME` advances at one millionth of real time, so the production `TIME*500` integer Bayer coordinate stays constant for normal benchmark durations — effectively frozen, not mathematically zero. The stability budget is `1 / (TIME_FACTOR * scale)` ≈ 33 minutes of real time before the Bayer offset can advance one texel; no benchmark approaches that. The controller's state machine advances by frame counters, not delta time, so `PREWARM`/`SETTLE`/`SAMPLE`/`CAPTURE` still complete. The strategy is recorded in every run, summary, and suite manifest under `runtime.hash_time` (`strategy`, `benchmark_time_scale`, `engine_time_scale`, `effectively_frozen`, `hash_bayer_time_factor`, `hash_stability_budget_seconds`, `phase`).

The positive scale (instead of an exact `0.0`) keeps the engine frame delta positive, so the imgui-godot addon's `NewFrame` receives a nonzero delta and does not log its `IM_ASSERT (DeltaTime > 0)` error. The overlay content is still suppressed during runs (`DebugManager.should_render_imgui = false`), so ImGui does not appear in captures or measurements.

Variant artifacts generated before the material-override precedence repair are invalid for comparison because groom-level overrides could hide the intended per-surface shader variants. Rerun the replacement smoke suite; those post-marker results are the first trustworthy baseline/control/Kajiya comparisons. The checked-in `smoke_suite.tres` runs the Blowout smoke matrix (8 cases, 1920x1080 viewport target, default 180/30/300 warmup/settle/sample timing): five front cases use the three-quarter camera with the single directional key light — `COVERAGE_CONTROL`, the frozen baseline, approximate Kajiya–Kay, `BUILTIN_ALPHA_HASH_CONTROL`, and the `NO_HAIR` empty-scene case — and three rear/backlit cases repeat the core comparison variants (`COVERAGE_CONTROL`, the frozen baseline, approximate Kajiya–Kay) under the `rear_backlit` camera with the cool `rear_spot` rim light to exercise backlit coverage and translucency-sensitive rendering.

## Command line

User arguments are read after `--`. To run the checked-in smoke suite and exit only after all output has been written:

```text
godot --path . res://benchmark/BenchmarkHarness.tscn -- --suite=res://benchmark/cases/smoke_suite.tres --quit-on-complete
```

The explicit `res://benchmark/BenchmarkHarness.tscn` scene path is required so the harness controller and CLI node run instead of the project main scene. `--suite=<res path>` selects the suite resource; `--quit-on-complete` requests exit code 0 only after the suite manifest and all case outputs are written (or exit code 1 after a failure). Manual/editor runs do not quit automatically.

## Measurements and data collection

The state sequence is `PREWARM` (180 frames), `SETTLE` (30), `SAMPLE` (300), `CAPTURE` (1), and `COMPLETE`. During `SAMPLE` only, the controller records previous-frame viewport CPU/GPU render time and visible/shadow object, primitive, and draw-call counters through the Godot 4.7 `RenderingServer` viewport APIs. The color capture waits for `RenderingServer.frame_post_draw` and never runs in the timing phase. Raw per-frame values are preserved verbatim in `samples.csv`; aggregated `summary.json` reports, for each of the eight metrics (`cpu_ms`, `gpu_ms`, and the six scene counters), `count`, `min`, `max`, `mean`, `median`, `stddev` and `variance` (population), `p90`, `p95`, `p99`, `trimmed_mean_5pct`, and `spread` (`max - min`). Percentiles use the same nearest-rank rule as before. `trimmed_mean_5pct` excludes the lowest and highest 5% of samples; when a sample window is too small for the trim to leave any samples, it safely falls back to the plain `mean`.

Run validation: every `run_manifest.json` and `summary.json` includes a `validation` block with `valid` and `validation_notes`. A run is valid when at least one sample was collected and all six visible/shadow object/primitive/draw-call counters are constant across the sample window (the scene is static and `TIME` is effectively frozen, so any counter variance marks the run unstable/mismatched — e.g. an animated scene, a changed camera, or a variant that failed to apply). Intentional short sample windows are never rejected: a case that sets `sample_frames` below the 300-frame default for a quick pass-count test stays `valid` as long as the counters are stable; the short window is only recorded in `validation_notes`. Per-metric `variance`/`spread` are always reported regardless of the verdict so borderline runs can be judged by data.

`summary.json`'s `runtime` block records build and project metadata alongside the hash-time provenance: `git_commit` (read directly from `res://.git` — no shell calls, no writes — or `"unknown"` when unavailable), `build` (`debug_build`, `editor_build`), `render_method`, GPU adapter/API and driver, `os`/`os_distribution`, `display` (window mode, size, V-Sync mode, `max_fps`), the harness-locked `viewport` settings (`scaling_3d_mode`, `scaling_3d_scale`, `msaa_3d`, `use_taa`), `shadows` project settings (directional shadow size/16-bit, soft-shadow filter qualities, physical light units), `anti_aliasing` project settings, and the active `environment_resource_path`.

Shader `TIME` is effectively frozen for the whole run via `Engine.time_scale = BENCHMARK_TIME_SCALE` (`1e-6`, see the hash-time provenance above), so the alpha-hash discard pattern and its per-frame fragment cost are constant; samples therefore measure a stable pattern instead of a `TIME`-shimmering one. The previous `Engine.time_scale` is restored by every teardown path, so ordinary editor sessions and fixture scenes are unaffected.

Use the editor for smoke validation only. Canonical data should come from a release build with vsync and any FPS cap disabled. Compare median and p95, not a single frame. Results are hardware, driver, renderer, resolution, and build dependent; viewport timing APIs do not provide a complete whole-system GPU profile.

## Cross-run analysis

`benchmark/tools/analyze_hair_benchmarks.py` is a standard-library-only Python 3 tool that aggregates runs across any number of benchmark output directories (Linux `user://` or Windows `AppData` roots, suite directories, or single run directories — all discovered recursively):

```text
python3 benchmark/tools/analyze_hair_benchmarks.py DIR [DIR ...] --out DIR
python3 benchmark/tools/analyze_hair_benchmarks.py DIR [DIR ...]        # stdout only, no files written
python3 benchmark/tools/analyze_hair_benchmarks.py --check              # in-memory self-test
```

Behavior:

- Discovery: every directory containing `run_manifest.json` is a run candidate; `suite_manifest.json` files are collected for suite-level identity/completeness.
- Validation: runs are rejected (with a reported reason) when `comparison_validity.marker` is not `material_override_precedence_repair_v1`, when manifests are malformed, when `summary.json` is missing, or when the run is incomplete (no `sample_count`, and neither summary statistics nor `samples.csv`). Rejected artifacts are listed in the JSON report and on stdout, never silently dropped.
- Grouping: comparable runs are grouped by `groom` (`individual_groom`), `profile` (`profile_id`, `"unknown"` for pre-profile runs), camera pose id, lighting rig id, and viewport resolution; variant is the comparison axis inside a group. Raw case identity (`suite_id`, `case_id`, `display_name`, `repeat`, directory) and the full `runtime` metadata block are preserved per run.
- Statistics: per-case GPU/CPU `median`/`mean`/`p95`/`p99` are read from `summary.json` statistics when the full quartet is present, otherwise computed from raw `samples.csv` rows (`metric_source` records which; `samples.csv` itself is never modified). Variance/stddev/spread and the run `validation` block (`valid` + notes) are included per run; `coverage_metrics` (white-pixel percentage etc.) pass through when recorded.
- Derived fields (computed on medians, per group, only when the reference variant exists in the same group — otherwise reported `unavailable` and named in `missing_references`): candidate minus `NO_HAIR`, `COVERAGE_CONTROL` minus `NO_HAIR`, candidate minus exact `COVERAGE_CONTROL`, candidate minus `CURRENT_MARSCHNER_BASELINE`, and the candidate/baseline ratio. Group-level `references` hold the three reference medians.
- Output: `hair_benchmark_report.json` (deterministic, sorted) and `hair_benchmark_report.csv` (one row per run) are written only inside `--out` (created if missing); a human-readable per-group summary goes to stdout. No third-party dependencies and no writes outside the requested output directory.

Example:

```text
python3 benchmark/tools/analyze_hair_benchmarks.py \
  ~/.local/share/godot/app_userdata/Hair/hair_benchmarks \
  /mnt/c/Users/jeffr/AppData/Roaming/Godot/app_userdata/Hair/hair_benchmarks \
  --out ./analysis
```
