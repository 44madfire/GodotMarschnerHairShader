# Godot Hair Shader Comparison Harness Plan

**Target:** Godot 4.7.1, Forward+  
**Primary fixture:** Existing head scene with multiple hair grooms  
**Reference shader:** Current `2Retr0/GodotHair` material and shader  
**Purpose:** Establish a reproducible visual and GPU-performance baseline, then compare Kajiya–Kay, fast Marschner, high Marschner, LUT, multiple-scattering, area-light, and indirect-light variants.

---

## 1. Core Principle

Do not replace the current head-and-grooms scene with a synthetic benchmark.

Use the existing scene as the primary comparison fixture because it already contains the geometry, textures, card layouts, tangent data, alpha behavior, depth variation, skin adjacency, and realistic overdraw patterns that the new shaders must handle.

The harness should instance the existing scene and control it externally:

```text
BenchmarkHarness.tscn
└── BenchmarkController
    ├── TestSceneHost
    │   └── ExistingHeadAndGroomsScene
    ├── BenchmarkCamera
    ├── LightingRigHost
    ├── WorldEnvironment
    └── OptionalStatusUI
```

The original scene remains usable by artists. Benchmark-specific behavior lives in a wrapper scene and scripts.

---

## 2. What the Baseline Must Contain

A useful baseline is not a single GPU number. Establish four related references.

### 2.1 Scene-floor baseline

Render the complete scene with:

- the head visible;
- the current environment;
- the selected benchmark lighting rig;
- all hair grooms hidden.

This measures the non-hair cost:

```text
head
eyes
skin
background
environment
lights
shadows unrelated to hair
post-processing
renderer overhead
```

Name:

```text
NO_HAIR
```

### 2.2 Hair geometry/coverage control

Render the selected groom using a deliberately cheap control shader that preserves:

- the same mesh;
- the same card coverage texture;
- the same alpha hash/scissor/discard behavior;
- the same tangent/attribute texture reads required by card setup;
- the same culling mode;
- the same depth behavior;
- the same shadow participation;
- the same number of material passes.

Replace only the expensive hair-lighting calculation with a trivial constant or inexpensive Lambert result.

Name:

```text
HAIR_COVERAGE_CONTROL
```

This approximates the cost of:

```text
card geometry
skin deformation
texture fetches needed for coverage
overdraw
discard
depth testing
shadow rendering
draw submission
```

### 2.3 Frozen current-shader reference

Create an immutable copy of the current production shader before refactoring begins.

Recommended files:

```text
benchmark/reference/
├── baseline_hair.gdshader
├── baseline_hair.gdshaderinc
└── baseline_hair_material.tres
```

Source the copy from:

```text
2Retr0/GodotHair:
assets/hair/materials/shaders/hair.gdshader
assets/hair/materials/shaders/hair.gdshaderinc
```

Record the original repository commit hash in:

```text
benchmark/reference/BASELINE_COMMIT.txt
```

Name:

```text
CURRENT_MARSCHNER_BASELINE
```

This reference must not change when the production shader is refactored. Otherwise the baseline moves and historical comparisons become invalid.

### 2.4 Candidate shader

Render the same groom with the candidate material:

```text
KAJIYA_KAY
FAST_MARSCHNER_ANALYTIC
FAST_MARSCHNER_LUT
HIGH_MARSCHNER_REFACTORED
HIGH_MARSCHNER_DUAL_SCATTER
HIGH_MARSCHNER_ENVIRONMENT
HIGH_MARSCHNER_SCREEN_INDIRECT
```

---

## 3. Metrics Derived from the Four References

For each camera, lighting, groom, resolution, and shader case, report the raw viewport GPU time first.

Then derive approximate incremental costs:

```text
Realistic total hair cost
    = candidate GPU time - NO_HAIR GPU time

Card/coverage cost
    = HAIR_COVERAGE_CONTROL GPU time - NO_HAIR GPU time

Approximate lighting-model increment
    = candidate GPU time - HAIR_COVERAGE_CONTROL GPU time

Change from current shader
    = candidate GPU time - CURRENT_MARSCHNER_BASELINE GPU time

Relative current-shader ratio
    = candidate GPU time / CURRENT_MARSCHNER_BASELINE GPU time
```

These differences are useful engineering estimates, not exact additive decompositions. GPU cache behavior, early depth rejection, scheduling, clock state, shader occupancy, and overdraw interact across the complete frame.

Always retain the raw measurements in the output.

---

## 4. Treat Each Groom as a Test Unit

The existing scene contains multiple grooms. The harness should test them both individually and together.

### 4.1 Groom registration

Add each groom root to a group:

```text
benchmark_groom
```

Add metadata or a small component script:

```gdscript
groom_id = "long_wavy"
display_name = "Long Wavy"
category = "hero"
```

A groom root may include multiple `MeshInstance3D` nodes and multiple hair surfaces. Do not assume one groom equals one mesh.

Recommended resource:

```text
benchmark/resources/HairGroomDefinition.gd
```

Suggested fields:

```gdscript
@export var groom_id: StringName
@export var groom_root: NodePath
@export var hair_mesh_paths: Array[NodePath]
@export var hair_surface_indices: Dictionary
@export var expected_material_profile: Resource
@export var notes: String
```

`hair_surface_indices` identifies only the surfaces that should receive the benchmark hair material. This avoids replacing scalp, ribbons, accessories, or non-hair surfaces on the same mesh.

### 4.2 Groom test modes

For every groom, support:

```text
INDIVIDUAL
    One groom visible.

ALL_GROOMS
    All registered grooms visible.

REPRESENTATIVE
    One selected medium-cost groom used for rapid iteration.

HEAVIEST
    The groom with the highest observed realistic GPU cost.

HAIR_ONLY
    Groom visible, head hidden. Used for diagnostics, not the primary result.
```

The primary production measurement should keep the head visible because depth rejection, card overlap, skin adjacency, and screen coverage affect actual cost.

### 4.3 Per-groom metadata

Record:

```text
groom ID
visible mesh count
visible object count
primitive count
draw calls
shadow draw calls
screen-space coverage estimate
number of hair material surfaces
```

Godot's viewport render information can supply objects, primitives, and draw calls for visible and shadow passes. It cannot directly report “hair pixels,” so screen coverage requires a separate mask capture.

---

## 5. Non-Destructive Material Swapping

Do not edit imported mesh resources or replace the materials permanently.

At startup, the harness should:

1. Find all registered hair mesh/surface pairs.
2. Store each original surface material.
3. Create or load the selected benchmark material.
4. Assign it with a surface override.
5. Restore original materials when the suite ends or changes groom.

Use:

```gdscript
mesh_instance.set_surface_override_material(surface_index, material)
```

Prefer surface overrides over a whole-object `material_override` when a mesh contains mixed surfaces.

### 5.1 Shared material profile

All candidate shaders should consume one canonical profile resource.

Recommended:

```text
benchmark/resources/HairBenchmarkProfile.gd
```

Canonical fields:

```text
base reflectance
absorption mode
absorption coefficient
eumelanin
pheomelanin
longitudinal roughness
azimuthal roughness
cuticle tilt
IOR
specular strength
R scale
TT scale
TRT scale
multiple-scattering strength
root/tip color controls
coords texture
attributes texture
flow/tangent texture
coverage controls
alpha controls
```

Tier-specific adapters translate the canonical profile into shader uniforms.

Examples:

```text
Current Marschner adapter
Kajiya–Kay adapter
Fast Marschner adapter
High Marschner adapter
```

This prevents a material comparison from accidentally becoming a texture or parameter comparison.

### 5.2 Preserve per-groom texture differences

Each groom may use different:

- `coords_texture`;
- `attributes_texture`;
- coverage map;
- base color;
- root/tip controls;
- tangent or flow data.

Store those values in the groom's benchmark profile. The shader variant changes; the groom data does not.

---

## 6. Proposed Harness File Layout

```text
benchmark/
├── BenchmarkHarness.tscn
├── README.md
├── reference/
│   ├── baseline_hair.gdshader
│   ├── baseline_hair.gdshaderinc
│   ├── baseline_hair_material.tres
│   └── BASELINE_COMMIT.txt
├── shaders/
│   ├── hair_coverage_control.gdshader
│   ├── hair_coverage_mask.gdshader
│   └── hair_debug_normals.gdshader
├── scripts/
│   ├── hair_benchmark_controller.gd
│   ├── hair_material_adapter.gd
│   ├── hair_result_writer.gd
│   ├── hair_capture_service.gd
│   └── hair_benchmark_cli.gd
├── resources/
│   ├── HairBenchmarkCase.gd
│   ├── HairBenchmarkSuite.gd
│   ├── HairBenchmarkVariant.gd
│   ├── HairBenchmarkProfile.gd
│   ├── HairGroomDefinition.gd
│   ├── HairCameraPose.gd
│   └── HairLightingRig.gd
├── cases/
│   ├── smoke_suite.tres
│   ├── visual_suite.tres
│   ├── performance_suite.tres
│   ├── light_scaling_suite.tres
│   └── full_regression_suite.tres
└── lighting/
    ├── key_directional.tscn
    ├── front_omni.tscn
    ├── back_spot.tscn
    ├── rectangle_area.tscn
    ├── four_light_rig.tscn
    ├── eight_light_rig.tscn
    └── environment_only.tscn
```

---

## 7. Benchmark Case Model

A benchmark case is one controlled combination of inputs.

Recommended resource:

```gdscript
class_name HairBenchmarkCase
extends Resource

@export var case_id: StringName
@export var groom_ids: Array[StringName]
@export var shader_variant_id: StringName
@export var profile_id: StringName
@export var camera_pose_id: StringName
@export var lighting_rig_id: StringName
@export var viewport_size := Vector2i(1920, 1080)
@export var warmup_frames := 300
@export var settle_frames := 60
@export var sample_frames := 900
@export var repeat_count := 3
@export var capture_color := true
@export var capture_coverage_mask := false
@export var capture_debug_outputs := false
```

Case identity should include every setting that can affect rendering:

```text
groom
shader
profile
camera
lighting
resolution
renderer
sample count
screen-indirect state
environment-sample count
LUT resolution
shadow mode
```

---

## 8. Fixed Camera Set

Use static camera poses for timing. Static views produce lower variance than a moving camera and make image comparisons meaningful.

Minimum camera set:

### 8.1 Front portrait

```text
Purpose:
- frontal highlight placement;
- hairline;
- face/hair interaction;
- front-card overdraw.
```

### 8.2 Three-quarter portrait

```text
Purpose:
- primary visual reference;
- simultaneous front, side, and backlit regions;
- card silhouette behavior.
```

### 8.3 Side/grazing

```text
Purpose:
- anisotropic lobe shape;
- cuticle shift;
- tangent errors;
- grazing-angle instability.
```

### 8.4 Rear/backlit

```text
Purpose:
- TT transmission;
- multiple scattering;
- rear-card coverage;
- silhouette transparency.
```

### 8.5 Close-up crop

```text
Purpose:
- lobe fidelity;
- aliasing;
- tangent interpolation;
- alpha hashing;
- per-pixel shader cost.
```

### 8.6 Distant/LOD

```text
Purpose:
- low-tier suitability;
- screen-space coverage scaling;
- alpha stability;
- practical LOD thresholds.
```

Store transforms as resources rather than relying on hand-positioned runtime cameras.

A separate deterministic orbit can be added for temporal validation, but it should not replace static timing cases.

---

## 9. Lighting Set

Use fixed scene files or resources. Do not move lights interactively during a recorded run.

### 9.1 Single directional key

Measures the basic per-light shader cost and broad highlight shape.

### 9.2 Frontal omni

Measures local light direction changes and attenuation.

### 9.3 Rear spot

Measures TT, transmission, and backlighting.

### 9.4 AreaLight3D

Measures the Godot area-light approximation and `LIGHT_AREA_*_MULTIPLIER` response.

### 9.5 Four-light rig

Represents a moderate cinematic/character-lighting setup.

### 9.6 Eight-light stress rig

Measures the slope of work performed inside `light()`.

### 9.7 Environment only

Measures indirect/environment contribution without direct-light loops.

### 9.8 Colored near-wall setup

Places colored opaque surfaces near the hair. This is specifically for validating explicit environment and screen-space indirect modes.

For light-scaling results, compare identical lights where possible:

```text
1 light
2 lights
4 lights
8 lights
```

Estimate:

```text
per-light GPU slope =
    (GPU time at 8 lights - GPU time at 1 light) / 7
```

---

## 10. Deterministic Scene State

The harness must remove sources of run-to-run variation.

Lock:

```text
camera transform
head pose
skeleton pose
groom transforms
animation time
wind
simulation
particles
light transforms
light energy
environment
exposure
resolution
render scale
MSAA
TAA
shadow settings
volumetric settings
screen-space effects
LOD state
```

### 10.1 Animation

For initial comparisons:

- pause animation;
- seek to one named frame;
- stop wind and physics;
- update the skeleton once;
- begin warm-up only after the pose has settled.

Later add a deterministic animation case with fixed timestep.

### 10.2 Randomness

The current shader uses `TIME` in alpha-hash-related behavior. A changing time source can introduce temporal variation into both screenshots and timings.

The benchmark reference should expose a deterministic mode:

```text
benchmark_time
benchmark_frame_index
fixed alpha-hash phase
```

Do not change the visual algorithm for production. Add a benchmark-only path that freezes temporal randomness for still captures.

For temporal tests, advance the benchmark frame index deterministically.

### 10.3 Post-processing

Create two profiles:

```text
RAW_SHADER
    Minimal post-processing for BSDF comparison.

PRODUCTION_VIEW
    Actual project environment and post-processing.
```

The raw profile makes shader differences easier to inspect. The production profile answers whether those differences survive the real rendering pipeline.

---

## 11. Benchmark State Machine

Implement one controller-driven state machine.

```text
INITIALIZE
    Discover grooms.
    Load variants and profiles.
    Record hardware and project metadata.
    Enable viewport render-time measurement.

LOAD_CASE
    Apply viewport size.
    Configure environment.
    Instantiate lighting rig.
    Select groom visibility.
    Apply material variant.
    Position camera.
    Freeze animation.

PREWARM
    Render enough frames to compile shaders,
    create pipelines, upload resources,
    initialize shadows, and raise GPU clocks.

SETTLE
    Reset sample arrays.
    Allow temporal history and material changes to settle.

SAMPLE
    Read measured GPU and rendering CPU time every frame.
    Read render-info counters.
    Do not save screenshots during this phase.

CAPTURE
    Wait for RenderingServer.frame_post_draw.
    Capture color and requested debug images.

WRITE_RESULTS
    Calculate statistics.
    Write raw samples and summary.
    Save case manifest.

REPEAT_OR_NEXT
    Repeat case or move to next case.

COMPLETE
    Restore original materials and scene state.
    Write suite-level summary.
```

Do not perform file I/O, texture readback, screenshot saving, verbose logging, or UI updates during the timed sample window.

---

## 12. GPU Timing

Enable viewport timing once:

```gdscript
var viewport_rid := get_viewport().get_viewport_rid()

RenderingServer.viewport_set_measure_render_time(
    viewport_rid,
    true
)
```

During the sample state:

```gdscript
var gpu_ms := RenderingServer.viewport_get_measured_render_time_gpu(
    viewport_rid
)

var render_cpu_ms := RenderingServer.viewport_get_measured_render_time_cpu(
    viewport_rid
)
```

The GPU value is the time used to render the viewport's previous measured frame. It is not a per-material timestamp.

Record one sample per rendered frame after warm-up and settling.

### 12.1 Default timing parameters

Development smoke test:

```text
warm-up:  180 frames
settle:    30 frames
sample:   300 frames
repeats:    1
```

Normal regression:

```text
warm-up:  300 frames
settle:    60 frames
sample:   900 frames
repeats:    3
```

Release validation:

```text
warm-up:  600 frames
settle:   120 frames
sample:  1800 frames
repeats:    5
```

### 12.2 Reported statistics

For GPU and rendering CPU samples, calculate:

```text
minimum
maximum
mean
median
standard deviation
p90
p95
p99
trimmed mean, excluding lowest/highest 5%
```

Use median GPU milliseconds as the primary comparison. Use p95 and p99 to detect instability.

### 12.3 Clock and thermal control

For serious comparison runs:

- run uncapped;
- disable V-Sync;
- use an external power supply on laptops;
- use the same OS power mode;
- avoid simultaneous GPU-heavy applications;
- keep the benchmark window focused;
- use the same display arrangement;
- allow a consistent prewarm;
- repeat cases in alternating or shuffled order;
- monitor thermal throttling with external tools when publishing results.

Suggested repeat order for two critical candidates:

```text
A B B A
```

or shuffled blocks rather than all A runs followed by all B runs.

This reduces bias from temperature and clock drift.

---

## 13. Render Information

Record viewport counters after the case has rendered for several frames:

```gdscript
RenderingServer.viewport_get_render_info(
    viewport_rid,
    RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
    RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME
)
```

Collect for visible and shadow pass types:

```text
objects in frame
primitives in frame
draw calls in frame
```

Use these counters to reject invalid comparisons.

Examples:

- candidate has an unexpected extra pass;
- one groom remained visible accidentally;
- shadow casting was disabled;
- a next pass doubled draw calls;
- a material swap changed surface visibility.

A timing comparison with mismatched geometry or pass counts must be marked invalid unless the pass-count change is the feature being tested.

---

## 14. Screenshot and Debug Capture

After the timed sample window:

```gdscript
await RenderingServer.frame_post_draw

var image := get_viewport().get_texture().get_image()
image.save_png(output_path)
```

Capture:

```text
final color
hair coverage mask
strand tangent debug
R-only
TT-only
TRT-only
direct scattering
multiple scattering
indirect/environment term
screen-space indirect
area-light multiplier visualization
```

### 14.1 Coverage mask

Apply a temporary mask material:

```text
hair pixels = white
everything else = black
```

Preserve the same alpha cutoff/hash behavior.

Capture the image and count white pixels offline. Store:

```text
covered pixel count
coverage percentage
bounding rectangle
```

This normalizes performance interpretation across:

- different grooms;
- different camera distances;
- different card silhouettes.

Do not time the mask capture as a candidate shader result.

### 14.2 Sequential, not split-screen, capture

For visual comparison, capture variants sequentially from identical scene state.

Do not use two simultaneous SubViewports for the primary performance result. Rendering both variants together changes workload, cache behavior, memory use, and clock state.

A split-screen viewer can be added later as an inspection tool only.

---

## 15. Output Format

Write benchmark output under:

```text
user://hair_benchmarks/<timestamp>/
```

Recommended structure:

```text
2026-07-26_153012/
├── run_manifest.json
├── summary.csv
├── cases/
│   ├── groomA__baseline__three_quarter__directional/
│   │   ├── case_manifest.json
│   │   ├── samples.csv
│   │   ├── summary.json
│   │   ├── color.png
│   │   ├── coverage.png
│   │   ├── r.png
│   │   ├── tt.png
│   │   └── trt.png
│   └── ...
└── logs/
    └── benchmark.log
```

### 15.1 Run manifest

Record:

```text
date/time
Git commit
baseline commit
Godot version
build type
rendering method
rendering driver/API
GPU adapter
GPU driver
OS
viewport resolution
window mode
V-Sync mode
maximum FPS setting
render scale
MSAA/TAA settings
shadow settings
environment resource
suite ID
case count
```

Useful runtime metadata APIs include:

```text
Engine.get_version_info()
RenderingServer.get_current_rendering_method()
RenderingServer.get_video_adapter_name()
RenderingServer.get_video_adapter_api_version()
OS.get_video_adapter_driver_info()
```

The driver-info call may be slow on its first invocation. Collect it before benchmark timing begins.

### 15.2 Sample CSV

Example columns:

```text
frame_index
repeat_index
gpu_ms
render_cpu_ms
visible_objects
visible_primitives
visible_draw_calls
shadow_objects
shadow_primitives
shadow_draw_calls
```

### 15.3 Summary CSV

Example columns:

```text
case_id
groom_id
variant_id
camera_id
lighting_id
resolution
median_gpu_ms
mean_gpu_ms
p95_gpu_ms
p99_gpu_ms
median_render_cpu_ms
visible_draw_calls
shadow_draw_calls
coverage_pixels
coverage_percent
hair_total_delta_ms
lighting_increment_delta_ms
baseline_delta_ms
baseline_ratio
valid
validation_notes
```

---

## 16. Initial Test Suites

Do not begin with the Cartesian product of every groom, shader, camera, and light. Build progressively.

### 16.1 Smoke suite

Run after every shader edit.

```text
Groom:
- one representative groom

Cameras:
- three-quarter
- rear/backlit

Lighting:
- single directional
- rear spot

Variants:
- coverage control
- frozen current baseline
- current candidate

Resolution:
- 1920x1080

Samples:
- 300
```

Purpose:

- detect broken material mapping;
- detect NaNs;
- confirm timing output;
- catch major regressions quickly.

### 16.2 Visual suite

```text
Grooms:
- representative
- one straight/dark groom
- one light/blond groom
- one dense/curly or heavy groom

Cameras:
- front
- three-quarter
- side
- rear
- close-up

Lighting:
- directional
- rear spot
- area light
- environment only
- colored-wall indirect setup

Variants:
- frozen baseline
- all shipping candidates
```

Purpose:

- lobe placement;
- color and absorption;
- TT/TRT visibility;
- area response;
- indirect response;
- card artifacts.

### 16.3 Performance suite

```text
Grooms:
- each groom individually
- all grooms
- heaviest groom

Cameras:
- three-quarter
- close-up
- distant

Lighting:
- 1 directional
- 4 lights
- 8 lights
- area light
- environment only

Variants:
- no hair
- coverage control
- frozen baseline
- Tier 1
- Tier 2
- Tier 3
- Tier 3 plus optional indirect pass

Resolutions:
- 1920x1080
- 2560x1440
- optional 3840x2160
```

### 16.4 Light-scaling suite

Keep groom, camera, and all material settings fixed.

Run:

```text
1 light
2 lights
4 lights
8 lights
```

Separately for:

```text
directional
omni
spot
shadowed
unshadowed
```

Purpose:

- identify cost inside `light()`;
- verify fragment-only indirect terms do not scale with light count.

### 16.5 Screen-indirect suite

Compare:

```text
main hair pass only
main pass plus empty transparent next pass
main pass plus 4-sample indirect
main pass plus 8-sample indirect
main pass plus 16-sample indirect
```

This separates:

- transparent-pass overhead;
- screen/depth texture overhead;
- actual sample-loop cost.

---

## 17. Fairness Rules

A comparison is valid only when the following remain constant unless they are the tested variable:

```text
groom geometry
skin pose
camera
viewport resolution
hair textures
coverage behavior
shadow behavior
light rig
environment
post-processing
material pass count, except explicit pass tests
animation state
quality settings
renderer
driver
hardware
```

### 17.1 Alpha fairness

The Kajiya–Kay, fast Marschner, and high Marschner variants must share the same alpha implementation.

Do not compare:

```text
baseline alpha hash
versus candidate alpha blend
```

and attribute the total difference to the BSDF.

### 17.2 Texture fairness

Keep the same texture import settings:

```text
compression
mipmaps
filtering
anisotropic filtering
color space
resolution
```

### 17.3 Shader compilation

Runtime shader compilation is not part of steady-state material cost.

Prewarm every variant before sampling. Track first-use compilation separately only when shader-compile behavior becomes a shipping concern.

### 17.4 Editor versus export

Primary performance results should come from an exported release build.

The editor is suitable for:

- smoke tests;
- visual inspection;
- debugging;
- Godot Visual Profiler investigation.

It is not the canonical source for published timing numbers.

---

## 18. Visual Validation Strategy

For every shipping candidate, compare it against the frozen baseline.

### 18.1 Required visual questions

```text
Does the highlight follow the strand tangent?
Are R, TT, and TRT positioned correctly?
Does cuticle tilt move lobes in the expected direction?
Does azimuthal roughness broaden the correct response?
Does dark hair retain readable highlights?
Does light hair avoid excessive white energy?
Does backlighting reveal transmission without a flat halo?
Do deep cards receive plausible multiple scattering?
Are card edges or shells visible?
Does the result remain stable during camera motion?
Does the area light create a broader, stable response?
Does indirect lighting change when nearby opaque colors change?
```

### 18.2 Difference images

A later offline analysis script should produce:

```text
absolute RGB difference
relative luminance difference
false-color heat map
masked hair-only difference
mean hair-pixel error
p95 hair-pixel error
structural similarity metric
```

Do not use a single image metric as the definition of quality. A cheaper tier is intentionally different from the high-quality reference.

---

## 19. Validation Gates

A candidate cannot be promoted into the main comparison matrix until it passes:

### Functional gate

- shader compiles;
- material profile maps correctly;
- no missing textures;
- no NaNs or infinities;
- alpha silhouette is intact;
- shadows are present where expected.

### Measurement gate

- viewport timing is nonzero;
- draw-call count is plausible;
- selected groom visibility is correct;
- no screenshot capture occurred during samples;
- repeat variance is within the configured threshold;
- metadata was written.

### Visual gate

- tangent orientation is correct;
- lobe debug modes work;
- no camera-dependent discontinuity;
- no obvious card-surface shading inversion;
- black and white parameter extremes remain bounded.

### Regression gate

Set thresholds per tier, for example:

```text
Tier 1:
- must be substantially cheaper than frozen baseline.

Tier 2:
- must be cheaper than Tier 3.
- must preserve recognizable R/TT/TRT behavior.

Tier 3 refactor:
- visual output must match frozen baseline within agreed tolerance.
- GPU cost must not regress beyond agreed tolerance.

Optional indirect pass:
- cost must be reported independently.
- contribution must not scale with direct-light count.
```

Do not hard-code numerical thresholds before the first baseline data is collected.

---

## 20. Implementation Milestones

### Milestone 1 — Freeze and Register

- Copy the current shader/include into `benchmark/reference`.
- Record the source commit.
- Instance the existing head scene in `BenchmarkHarness.tscn`.
- Register all grooms.
- Identify all hair mesh/surface indices.
- Create canonical benchmark profiles.

**Exit:** Every groom can be shown individually and restored without modifying imported resources.

### Milestone 2 — Controls

- Create `NO_HAIR`.
- Create `HAIR_COVERAGE_CONTROL`.
- Create coverage-mask and tangent-debug materials.
- Verify alpha and shadow parity.

**Exit:** Baseline decomposition cases render correctly.

### Milestone 3 — Material Variant System

- Implement material adapters.
- Add frozen baseline as the first variant.
- Add one placeholder candidate.
- Support non-destructive surface overrides.
- Restore source materials on exit.

**Exit:** One button or command changes every hair surface of a selected groom consistently.

### Milestone 4 — Timing Controller

- Implement benchmark state machine.
- Enable viewport GPU/CPU timing.
- Add warm-up, settle, sample, and repeat stages.
- Add render-info counters.
- Suppress UI/logging during samples.

**Exit:** Repeated runs produce stable raw sample arrays.

### Milestone 5 — Capture and Output

- Add post-draw screenshot capture.
- Save color and coverage masks.
- Write JSON manifests and CSV samples/summaries.
- Record hardware and project metadata.

**Exit:** A benchmark run is self-contained and auditable.

### Milestone 6 — Suites

- Create smoke suite.
- Create visual suite.
- Create performance suite.
- Create light-scaling suite.
- Add command-line suite selection.

**Exit:** Exported release build can run a named suite unattended.

### Milestone 7 — Analysis

- Add a separate Python or tooling script for aggregation.
- Calculate deltas and ratios.
- Count mask pixels.
- Generate plots and image differences.
- Flag invalid or high-variance cases.

**Exit:** One command turns run folders into a comparison report.

---

## 21. First Pull Request Scope

The first harness pull request should include only:

1. `BenchmarkHarness.tscn` wrapping the existing scene.
2. Groom registration and visibility control.
3. Frozen current-shader reference.
4. No-hair and coverage-control cases.
5. Non-destructive material swapping.
6. Three fixed camera poses.
7. Three lighting rigs.
8. Viewport GPU/CPU sample collection.
9. CSV/JSON output.
10. Sequential PNG capture.
11. A small smoke suite.

Do not include:

```text
automated image differences
screen-space indirect
LUT generators
dual scattering
renderer extensions
large UI
continuous integration thresholds
```

Those features should be added after the harness has produced its first stable baseline dataset.

---

## 22. Recommended First Baseline Run

Use this run to validate the harness before adding new shaders.

```text
Grooms:
- each groom individually
- all grooms

Variants:
- NO_HAIR
- HAIR_COVERAGE_CONTROL
- CURRENT_MARSCHNER_BASELINE

Cameras:
- three-quarter
- close-up
- rear/backlit

Lighting:
- single directional
- rear spot
- four-light rig

Resolution:
- 1920x1080

Timing:
- 300 warm-up frames
- 60 settle frames
- 900 sample frames
- 3 repeats
```

From this run, identify:

```text
representative groom
heaviest groom
highest-overdraw view
most expensive light rig
baseline median GPU time
baseline p95 GPU time
coverage-control cost
approximate current BSDF increment
per-groom screen coverage
run-to-run variance
```

Use those observations to set the final smoke suite and regression thresholds.

---

## 23. Official Godot References

- `RenderingServer` viewport timing and render information:  
  <https://docs.godotengine.org/en/4.7/classes/class_renderingserver.html>

- `RenderingServer.frame_post_draw`:  
  <https://docs.godotengine.org/en/4.7/classes/class_renderingserver.html>

- `ViewportTexture`:  
  <https://docs.godotengine.org/en/4.7/classes/class_viewporttexture.html>

- `Image.save_png()`:  
  <https://docs.godotengine.org/en/4.7/classes/class_image.html>

- `FileAccess`:  
  <https://docs.godotengine.org/en/4.7/classes/class_fileaccess.html>

- `ShaderMaterial`:  
  <https://docs.godotengine.org/en/4.7/classes/class_shadermaterial.html>

- Godot debugger and performance monitors:  
  <https://docs.godotengine.org/en/4.7/tutorials/scripting/debug/debugger_panel.html>

- Internal rendering architecture and renderer characteristics:  
  <https://docs.godotengine.org/en/4.7/engine_details/architecture/internal_rendering_architecture.html>
