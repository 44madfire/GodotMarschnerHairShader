# Hair benchmark harness

## Open and run

Open `benchmark/BenchmarkHarness.tscn` in the Godot 4.7 editor and run the current scene. Set `BenchmarkController.auto_start_smoke` to `true` for an automatic smoke run, or call `start_smoke()` / `start_benchmark()` on the controller from a script or the debugger. Results are written below:

```text
user://hair_benchmarks/<timestamp>/
```

Each completed run contains `run_manifest.json`, `samples.csv`, `summary.json`, and `color.png`.

## Preview overlay

`BenchmarkHarness.tscn` includes an optional `BenchmarkPreviewOverlay` Control in a
separate CanvasLayer. It is visible by default (`show_preview_ui = true`) and
provides compact groom, variant, and mode selectors for the ten registered
grooms. **Apply Preview** calls the controller's non-timed `apply_variant()` path
and leaves the selected configuration visible. The overlay reports the active
groom/variant/profile, benchmark state, live or completed-render CPU/GPU timing,
visible/shadow draw calls and primitives, and validation state.

Preview telemetry is not a benchmark sample: it does not create output files or
enter PREWARM/SAMPLE. The overlay hides itself for PREWARM, SETTLE, SAMPLE, and
CAPTURE so it cannot affect timed measurements or captures. Timed smoke and
visual suites remain available through the existing controller and CLI APIs;
preview controls intentionally do not launch suites from inside the overlay.
Disable the tool by turning off `BenchmarkPreviewOverlay.show_preview_ui` in the
scene instance. The fixture camera, light, and environment layout is unchanged.

## Tier-2 runtime test

`benchmark/tests/test_fast_marschner_runtime.gd` is a focused, durable runtime
test for the `FAST_MARSCHNER_ANALYTIC` preview variant (enum value 5). It
instantiates `BenchmarkHarness.tscn`, hides the preview overlay, calls
`apply_preview(INDIVIDUAL_GROOM, FAST_MARSCHNER_ANALYTIC, &"Blowout")`, asserts
the selected surface override is a `ShaderMaterial` on
`res://assets/hair/materials/shaders/hair_marschner_fast.gdshader`, checks the
viewport capture has usable dimensions and a lit (non-background) pixel count
robust to dark brown hair, and then re-captures after enough preview frames for
the Bayer `TIME` phase to move, asserting a nonzero frame diff so a static flat
fallback cannot pass. It prints tagged `EVIDENCE` lines and
`FAST_MARSCHNER_RUNTIME_TEST_OK` on success (exit 0), or pushed errors and exit
1 on failure. It never starts a timed run and writes no benchmark artifacts.

The normal windowed Godot binary is required (not `--headless`), because the
test exercises the live preview path with `Engine.time_scale == 1.0`:

```text
/mnt/c/Tools/Godot/godot.exe --path "//wsl.localhost/Ubuntu/home/jeffreymwang/godot-hair-shader/.slim/worktrees/tier-2-marschner-hair-shader" --script res://benchmark/tests/test_fast_marschner_runtime.gd
```

The known unrelated `util/light_controller.gd:36` Camera3D `_current_mode`
script warning may appear while the harness runs; it is fixture noise and not a
test failure.

## Tier-2 Fast Marschner energy contract

The Fast Marschner **analytic core** is validated as a coherent, fixed-exposure
approximation of the baseline—not as an energy-parity replacement. Validation
covers one Blowout material/IOR and five incoming angles; it excludes LUT,
dual-scatter, environment, and full Karis-energy behavior. Exposure and lobe
scales stay at 1.0, and no compensation is applied. The deterministic
angular-integrated validator is:

```text
/mnt/c/Tools/Godot/godot.exe --headless --path "//wsl.localhost/Ubuntu/home/jeffreymwang/godot-hair-shader" --script res://benchmark/tools/validate_fast_marschner_energy.gd
```

The validator intentionally exits with `FAIL` against the rejected historical
parity gates; that result is expected for the accepted approximation contract.
The current reference run converges from a 128- to 512-sample grid with
`0.000723` maximum drift. Fast/baseline integrated energy is `0.8625x` overall
(R `0.5902x`, TT `0.9156x`, TRT `1.0700x`), with per-incoming-angle totals
from `0.3931x` to `1.7227x`. These angle-dependent results intentionally remain
documented evidence of approximation behavior; they do not justify a global
exposure or lobe multiplier. The timed baseline/reference shader and harness
timing/output paths remain unchanged; the Fast candidate remains subject to the
normal benchmark comparison process.

### Second-pass convention checks

The shipping Fast path now uses the baseline-compatible artist-facing cuticle
tilt convention (`R = +alpha`, `TT = -0.5*alpha`, `TRT = -1.5*alpha`). The
validator's CPU port matches that convention and accepts `--cuticle=0` for an
isolated zero-tilt control. At the material tilt, the 512-grid result remains
`0.8625x` overall (R `0.5902x`, TT `0.9156x`, TRT `1.0700x`); zero tilt gives
`0.8848x` on the same five-angle diagnostic, so the sign correction changes
angular placement more than aggregate energy.

`FM_LONGITUDINAL_MODE 1` and
`--longitudinal=baseline` provide a separately measured, baseline-compatible
separable `sin(theta_o)` Gaussian diagnostic. It compiles, but its aggregate
result is only `0.5398x` (R `0.3840x`, TT `0.5701x`, TRT `0.6587x`), so it is
not the shipping default. The Unity-standard theta-h mode remains
`FM_LONGITUDINAL_MODE 0` until a full non-separable R/longitudinal correction is
implemented and validated.

The opt-in `FM_R_LONGITUDINAL_MODE 1` /
`--r-longitudinal=nonseparable` diagnostic applies the cheap phi-dependent R
width/tilt approximation while leaving TT/TRT unchanged. At the 256-grid
reference it worsens R to `0.4262x` and total energy to `0.8329x`, so it also
remains non-shipping pending a fuller d'Eon-compatible model.

The validator now reports absolute errors and applies a diagnostic `1e-3`
baseline-energy ratio mask. All five reference angles remain valid; the
standard Unity-mode 256-grid audit reports weighted ratio `0.8626x`, total-ratio
range `0.3620–1.7226`, RMS absolute total error `1.9771`, and maximum absolute
total error `3.1889`. These metrics do not alter the unmasked acceptance gate.

Analytic roughness now keeps the full reparameterized beta after its `1e-3`
floor. The azimuthal LUT treats derived beta-N outside `[0.001, 1.0]` as a
resource incompatibility and falls back to the analytic path instead of
silently clamping the material into the LUT domain. The Gaussian helper also
enforces its own positive variance floor.

Remaining baseline differences are intentional and documented: Fast uses a
clamped Schlick Fresnel path, fixed representative azimuthal `h` values, and
the Unity fixed-`h` attenuation Fresnel argument. Matching the full baseline
requires its non-separable d'Eon widths/tilts and is deferred; no compensation
is inferred from the current five-angle dataset.

### Energy contract modes and matrix

`validate_fast_marschner_energy.gd` supports three exit contracts:

- `--contract=regression` (default) passes when the accepted shipping model
  matches `benchmark/reference/fast_marschner_energy_contract_v1.json`.
- `--contract=parity` retains the strict aspirational energy-parity bands and
  intentionally fails for the current approximation.
- `--contract=report` always exits successfully when execution is valid while
  preserving the strict parity result in the report.

The designed material subset can be run through Windows Godot with:

```text
python3 benchmark/tools/run_fast_marschner_energy_matrix.py --grid 128 --coarse 64 --out /tmp/fast-marschner-energy-matrix.json
```

The runner invokes `/mnt/c/Tools/Godot/godot.exe` explicitly, covers 12
representative roughness, cuticle, color, and IOR cases, and reports worst-case
ratios/errors. It is a designed subset of five-angle aggregates, not a full
material-domain proof.

Timed Fast benchmark runs explicitly force `comparison_exposure_gain=1.0`,
`lobe_scales=vec3(1)`, and the default area-light multipliers, and record those
values under `timed_material_contract` in `run_manifest.json`. Preview-only
flows retain their diagnostic presentation controls.

### Unity HDRP R-lobe attribution study

The benchmark-only `--r-study` selector attributes the R discrepancy as
`M_R*N_R*A_R` without changing the shipping shader. Supported modes are:

- `current`: current Fast M/N/A control.
- `unity_fresnel`: current M/N with Unity's half-vector Fresnel A.
- `unity_nf`: current M with Unity's direct 20-sample preintegrated N_R and
  Unity Fresnel A.
- `baseline_m_unity_nf`: existing high-tier baseline M_R with Unity N_R/A_R.
- `unity_exact`: Unity standard raw-roughness Gaussian M_R with Unity N_R/A_R.

All non-current modes require `--contract=report`; TT/TRT and the shipping
shader remain unchanged. Unity R never uses Beer-Lambert absorption. The
standalone reference checks cover N_R normalization, symmetry, periodicity,
roughness broadening, and R absorption independence:

```text
/mnt/c/Tools/Godot/godot.exe --headless --path "//wsl.localhost/Ubuntu/home/jeffreymwang/godot-hair-shader" --script res://benchmark/tests/test_fast_marschner_unity_r_reference.gd
python3 benchmark/tools/run_fast_marschner_r_study.py --grid 128 --coarse 64 --out benchmark/results/unity_r_study_128.json
```

The study runner emits aggregate and per-incoming-angle R ratios, RMS and
maximum total errors, grid drift, and attribution multipliers. It is an
exploratory evidence path; no shader implementation should be selected from
the output until the angular results are reviewed.

The final 512/128 study measured these aggregate Fast/baseline R ratios:

| R study | R ratio | total ratio | incoming-angle R range |
| --- | ---: | ---: | ---: |
| `current` | `0.5902x` | `0.8625x` | `0.2088–1.8398x` |
| `unity_fresnel` | `0.5275x` | `0.8512x` | `0.1904–1.6668x` |
| `unity_nf` | `0.6901x` | `0.8806x` | `0.2322–2.2872x` |
| `baseline_m_unity_nf` | `1.2271x` | `0.9777x` | `1.0967–1.4797x` |
| `unity_exact` | `0.6654x` | `0.8761x` | `0.2906–2.2117x` |

Attribution multipliers relative to the preceding substitution are `0.8937x`
for Unity Fresnel, `1.3083x` for Unity N_R, and `1.7781x` for the baseline M
substitution. Unity N_R is the strongest isolated improvement, but the broad
angular range means this result does not justify a shipping shader change yet.

## Tier-2 azimuthal LUT

The `FAST_MARSCHNER_LUT` variant (enum 6) is a separately selectable,
LUT-backed version of the fast Marschner shader. `FAST_MARSCHNER_ANALYTIC`
(enum 5) remains the default/reference path with the fixed-h logistic analytic
approximation; the shared `hair_marschner_fast.gdshader` carries an opt-in
`use_azimuthal_lut` flag (default false) that only the LUT variant enables.
The `sampler3D` LUT holds the R/TT/TRT azimuthal terms in RGB over a 64^3
RGBAF grid (axes: U = relative azimuth phi in [-PI, PI], V = cos_theta_d,
W = azimuthal_roughness). The U/phi axis wraps continuously: linear sampling
with repeat enabled plus `fract()` on U interpolates across the seam between
the last and first texels, while V and W are half-texel clamped into the
interior texel-center range so repeat never wraps those axes. Only the
light-invariant width axis is hoisted to `fragment()`, and the per-light sample
stays in `light()`.

Godot 4.7 cannot self-contain an `ImageTexture3D` (ResourceSaver writes a
`local://` stub for `.res` and a data-less `.tres`, and the static
`ImageTexture3D.create` does not resolve in GDScript), so the generator commits
the raw texel data as a `FastMarschnerLUTData` resource and the material
adapter builds the `ImageTexture3D` at runtime with the instance `create()`
call, cached per process. Artifacts:

- `benchmark/tools/generate_marschner_azimuthal_lut.gd` — offline generator
  (exact GDScript port of the include's fresnel/logistic/angular-offset math,
  fixed eta 1.55, h_TT = 0, h_TRT = sqrt(3)/2):
  `godot --headless --path <project> --script res://benchmark/tools/generate_marschner_azimuthal_lut.gd`
- `benchmark/resources/luts/fast_marschner_azimuthal_lut_64.res` — committed
  4 MB data blob (round-trip verified by the generator).
- `benchmark/tools/validate_marschner_azimuthal_lut.gd` — GPU-matching
  trilinear numerical validation (max/RMS per channel plus the phi seam delta):
  `godot --headless --path <project> --script res://benchmark/tools/validate_marschner_azimuthal_lut.gd`

Measured error vs the analytic formulas (64^3): R max 0.0061 / RMS 0.0028, TT
max 0.0033 / RMS 0.0010, TRT max 0.130 / RMS 0.0087 with a zero phi-seam delta
for R/TT and 0.025 for TRT; the TRT worst point sits at the extreme corner
(azimuthal_roughness 0.1, cos_theta_d = 1) — over the realistic benchmark
roughness range (>= 0.3; profiles use 0.75–1.0) the worst error is 0.0132.
Environment sampling and screen-indirect remain deferred; global strand-count dual scattering is out of scope.

`benchmark/tests/test_fast_marschner_lut_runtime.gd` asserts shader selection,
the enable flag, the bound 64^3 texture, non-black output, live preview frame
changes, and that the analytic variant keeps the flag false. Performance and
visual cases `perf_blowout_fast_marschner_lut` and
`visual_blowout_fast_marschner_lut_close_up` are wired into the performance and
visual suites for analytic-vs-LUT comparisons.

## Tier-2 local dual scattering

The `FAST_MARSCHNER_DUAL_SCATTER` variant (enum 7) is an experimental opt-in
local dual-scattering slice on the same shared fast shader. It carries the
packed `attributes_texture.g` depth value into `light()` via a varying and
replaces — never adds on top of — the Karis multiple-scattering diffuse term
with a Zinke-style local approximation: the depth channel is the
density/visibility proxy, the forward-scattered term is Beer-Lambert attenuated
through that density with the existing `sigma_a`, and the backward-scattered
term peaks for opposing light/view directions. `dual_scatter_strength` and
`dual_scatter_density` are profile-driven controls (defaults 0.5/0.5, validation
ranges [0,2] and [0,1]); a zero strength removes the dual diffuse contribution.
The analytic and LUT variants keep `use_dual_scatter=false` and their Karis
reference path exactly; area diffuse/specular multipliers remain at the final
direct-light accumulation. This phase is direct-light only: no environment
sampling, screen-indirect, LUT changes, global strand-count integration, or
roughness heuristics.

`benchmark/tests/test_fast_marschner_dual_scatter_runtime.gd` asserts variant
selection, the bound controls, non-black output, live preview frame changes,
and that the analytic/LUT flags stay false. The rear/backlit case
`visual_blowout_fast_marschner_dual_scatter_rear_backlit` (rear_backlit camera,
rear_spot rig) is wired into the visual suite.

## Tier-2 preintegrated dual scattering (Stage B)

The `FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED` variant (enum 9) is an opt-in
Stage-B upgrade of the local dual-scattering slice on the same shared fast
shader. Variant identity is authoritative: it forces `use_dual_scatter=true`
and `use_preintegrated_dual_scatter=true` and `use_azimuthal_lut=false` /
`use_environment=false`, then binds a committed 2D LUT. `light()` then samples
the LUT instead of the analytic Stage-A `fm_dual_scattering()` (variant 7
remains the untouched analytic fallback; both dual variants replace — never
add on top of — the Karis diffuse term).

The LUT stores **scalar one-/three-event aggregate event weights** over a
**scalar density/event-proxy/cosine domain** (64x64 RGBAF, linear filtering,
repeat disabled):

- U = scalar density/event proxy `tau_d = 4 * local_density` in `[0, 4]` — the
  reachable domain (local_density is clamped to `[0, 1]`, so tau_d never
  exceeds 4); the shader derives it from the bounded depth-density proxy and
  the resource's `tau_max` metadata (4.0) is propagated to the runtime
  `dual_scatter_lut_tau_max` uniform, so the runtime never silently claims a
  wider baked domain. RGB absorption is applied separately after the lookup
- V = scattering cosine `c` (light/view alignment) in `[-1, 1]`
- `P1 = 1 - exp(-tau_d)` and `P3 = 1 - exp(-1.5*tau_d)`
- R = one-event forward weight `0.5*(1+c)*(1-F0)^2*P1`
- G = one-event backward weight `0.5*(1-c)*(1-F0)^2*P1`
- B = three-event forward weight `0.5*(1+c)*(1-F0)^2*F0*P3`
- A = three-event backward weight `0.5*(1-c)*(1-F0)^2*F0*P3`

with `F0 = ((1-eta)/(1+eta))^2` at the plan's fixed `eta = 1.55` (same
convention as the azimuthal LUT). Zero density produces zero secondary energy;
increasing density increases and then saturates the one-/three-event terms.
Runtime `sigma_a` stays RGB and is applied as the four per-direction path
responses `T1f = exp(-sigma_a)`, `T1b = exp(-0.5*sigma_a)`,
`T3f = exp(-1.5*sigma_a)`, `T3b = exp(-0.75*sigma_a)` (one-event forward base
path 1.0, backward paths half the forward paths, three-event paths 1.5x the
one-event paths), so the LUT never bakes one hair color and the
forward/backward split stored in the four channels survives at runtime — the
previous `R+G` / `B+A` summation cancelled it. The resource carries
`eta` / `tau_max` / `contract` metadata that the adapter propagates into the
shader's `dual_scatter_lut_eta` and `dual_scatter_lut_tau_max` uniforms; the
incompatible-IOR analytic Contract B fallback uses the exact same four-path
reconstruction and event weights. All terms are bounded in `[0, 1]`, monotone
(weights grow with tau_d, three-event never exceeds one-event,
forward/backward lobes split monotonically with c), and `ATTENUATION` enters
only as the direct-light visibility ramp, never into the LUT math.

As with the azimuthal LUT, Godot 4.7 cannot self-contain an `ImageTexture`, so
the generator commits the raw RGBAF data as a `FastMarschnerDualLUTData`
resource and the material adapter builds the `ImageTexture` at runtime
(`Image.create_from_data` / `ImageTexture.create_from_image`), cached per
process with the same defensive RID/size checks. Artifacts:

- `benchmark/tools/generate_marschner_dual_scatter_lut.gd` — offline
  deterministic generator:
  `godot --headless --path <project> --script res://benchmark/tools/generate_marschner_dual_scatter_lut.gd`
- `benchmark/resources/luts/fast_marschner_dual_scatter_lut_64.res` — committed
  64x64 data blob (round-trip verified by the generator).
- `benchmark/tools/validate_marschner_dual_scatter_lut.gd` — GPU-matching
  bilinear numerical validation (metadata checks for eta/tau_max/contract,
  finite/bounded data, edge-clamp seam continuity, monotone event weights,
  max/RMS error vs the generator's analytic formulas, and directional
  non-cancellation evidence: the four-path reconstruction with colored
  absorption differs across the alignment endpoints c = -1 / 0 / +1 while the
  pure-forward endpoint matches the summed reconstruction exactly), ending
  with `DUAL_SCATTER_LUT_VALIDATION_OK`:
  `godot --headless --path <project> --script res://benchmark/tools/validate_marschner_dual_scatter_lut.gd`

Endpoint-preserving sampling represents zero-density and extreme-cosine values
with the first/last texels; the interior gate (tau_d >= 0.25, |cosine| <= 0.9)
remains inside the 0.02 release threshold. Monotonicity, zero-density behavior,
and energy bounds hold across the whole grid.

Profile fields `use_preintegrated_dual_scatter` (default false) and
`dual_scatter_lut_data` are declaration-gated through the adapter; enabling
requires the committed LUT data, and `source_current` keeps the feature off.
`benchmark/tests/test_fast_marschner_dual_scatter_runtime.gd` covers variant 9:
accepted, `use_dual_scatter=true` + `use_preintegrated_dual_scatter=true`,
azimuthal LUT/environment forced off, the committed 64x64 texture bound with
the `dual_scatter_lut_eta` (~1.55) and `dual_scatter_lut_tau_max` (4.0)
metadata guards propagated, non-black output with live frame movement, a
deterministic CPU directional proof (four-path reconstruction with colored
absorption differs across c = -1 / 0 / +1 while the pure-forward endpoint
matches the summed reconstruction), and full identity checks (the
analytic/LUT/environment/Stage-A variants force the preintegrated flag off
regardless of profile fields). Visual and performance cases
`visual_blowout_fast_marschner_dual_scatter_preintegrated_rear_backlit` (the
Stage-A rear/backlit setup) and
`perf_blowout_fast_marschner_dual_scatter_preintegrated` are wired into the
visual and performance suites for A/B Stage-A-vs-Stage-B comparisons.

## Tier-2 fragment environment response

The `FAST_MARSCHNER_ENVIRONMENT` variant (enum 8) adds an opt-in
fragment-stage environment contribution to the shared fast shader. It samples
a committed 2D equirectangular environment stand-in
(`benchmark/resources/textures/environment_gradient.tres`, a 256x128
`GradientTexture2D` with dark zenith, warm horizon, and cool sky — a
representative gradient, not a physical HDRI) once per fragment at the
reflected view direction (`u = 0.5 + atan(z, x) / TAU`, `v = 0.5 - asin(y) /
PI`) and adds the result via `EMISSION`, tinted by the existing albedo with an
absorption-attenuated R/TRT-compatible coloring (TT is skipped for the local
slice). The reflected direction is evaluated in **camera space** — this is a
local stand-in, not world-space IBL — and the sample is guarded with
`!IN_SHADOW_PASS` so shadow passes skip the unused environment read. The term is evaluated in `fragment()` only — `light()` is untouched —
so it is light-count invariant and renders even under the `environment_only`
rig with zero lights. Identity is authoritative: the environment variant
forces `use_azimuthal_lut=false`, `use_dual_scatter=false`, and
`use_preintegrated_dual_scatter=false`, and the analytic/LUT/dual variants
force `use_environment=false`. Profile fields
`use_environment` (default false), `environment_texture`, and
`environment_strength` ([0,2], default 1.0) are declaration-gated through the
adapter; `source_current` keeps the feature disabled.

`benchmark/tests/test_fast_marschner_environment_runtime.gd` asserts variant
identity, the bound texture and strength, non-black output, live preview
frames, and the zero-light (fragment-only) rendering proof. The visual case
`visual_blowout_fast_marschner_environment_only` uses the existing
`environment_only` rig and is wired into the visual suite. Environment
sampling here is a local stand-in; full environment/IRRADIANCE integration and
screen-indirect remain deferred.

## Tier-2 diagnostic variant shaders (PR4)

The fast Marschner shader was refactored into a reusable body plus committed
selector wrappers. `hair_marschner_fast_body.gdshaderinc` holds the complete
shader body (shader_type, render_mode, uniforms, varyings, and the
vertex/fragment/light functions, including the include of
`hair_marschner_fast.gdshaderinc`); `hair_marschner_fast.gdshader` is now a
small wrapper that defines the shipping selectors
(`FM_LONGITUDINAL_MODE 0`, `FM_R_LONGITUDINAL_MODE 0`,
`FM_CUTICLE_TILT_CONVENTION 0`) before including the body. The numeric
selectors in `hair_marschner_fast.gdshaderinc` are `#ifndef`-guarded so a
wrapper-defined value is honored and the include's defaults apply when the
common include is used directly. Three committed diagnostic wrappers select
compile-time variants of the same shared body with no duplicated shader code:
`hair_marschner_fast_baseline_longitudinal.gdshader` (longitudinal mode 1,
separable baseline-compatible sin(theta_o) Gaussian),
`hair_marschner_fast_r_nonseparable.gdshader` (R-only non-separable mode 1),
and `hair_marschner_fast_baseline_azimuthal.gdshader` (azimuthal mode 1,
baseline cross-section diagnostic for the analytic BSDF only).
The shipping path, variant enum behavior, and `hair_material_adapter.gd` are
unchanged, so all existing analytic/LUT/dual/environment tests continue to use
the shipping wrapper path.

`benchmark/tests/test_fast_marschner_diagnostic_variants_runtime.gd` asserts
each of the four shader paths loads/compiles and renders on the Blowout groom:
it instantiates `BenchmarkHarness.tscn`, hides the preview overlay, duplicates
the source/override `ShaderMaterial`, assigns the loaded wrapper shader, renders
several frames, and checks the RenderingServer shader code is retrievable, the
output image dimensions are valid, and a minimum lit-pixel count is met. It
prints per-variant identity/evidence lines and
`FAST_MARSCHNER_DIAGNOSTIC_VARIANTS_RUNTIME_TEST_OK` on success (exit 0), or
pushed errors and exit 1 on failure. No timed benchmarks start and no
benchmark artifacts are written.

## Tier-2 baseline azimuthal cross-section diagnostic (PR5)

The fast azimuthal model is the fixed-h logistic analytic approximation
(`FM_AZIMUTHAL_FIXED_H_ANALYTIC`); its azimuthal angular offsets are selected
by the numeric compile-time selector `FM_AZIMUTHAL_MODE`
(`#ifndef`-guarded in `hair_marschner_fast.gdshaderinc`, default 0).
Mode 0 (shipping default) keeps the fixed representative cross-section offsets
h_TT = 0 and h_TRT = sqrt(3)/2. Mode 1 (diagnostic, never the default) is an
attribution-only baseline cross-section diagnostic for the **analytic BSDF
only**: dynamic h_TT from the baseline formula
`sign(sin_phi_half) * cos_phi_half / sqrt(1 + eta_prime_inv * (1 - 2 * eta_prime_inv * abs(sin_phi_half)))`
and h_TRT = 0.91. It never alters LUT sampling semantics (the LUT's azimuthal
terms are baked at the fixed-h offsets, so the LUT BSDF is untouched in every
mode) and never alters attenuation (the Unity-style fixed-h family
`FM_ATTENUATION_MODE 0` with h_TT = 0 / h_TRT = sqrt(3)/2 stays in every
mode); mode-0 math is unchanged.

The committed wrapper `hair_marschner_fast_baseline_azimuthal.gdshader`
defines longitudinal 0, R 0, cuticle convention 0, and azimuthal mode 1 before
including the shared body (`hair_marschner_fast_body.gdshaderinc`); no shader
body is duplicated.

The validator (`validate_fast_marschner_energy.gd`) accepts
`--azimuthal=fixed_h|baseline_h` (default `fixed_h`) and reports the mode in
the payload and human-readable lines. The CPU Fast analytic port mirrors the
shader's mode-1 math in `baseline_h` mode (dynamic h_TT, h_TRT = 0.91); the
LUT is out of this CPU comparison and attenuation stays fixed-h in both modes.
Any non-default azimuthal mode makes `--contract=regression` inapplicable
(clear FAIL, never a silent pass), exactly like the other diagnostic
selectors.

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
- `FAST_MARSCHNER_ANALYTIC`
- `FAST_MARSCHNER_LUT`
- `FAST_MARSCHNER_DUAL_SCATTER`
- `FAST_MARSCHNER_ENVIRONMENT`
- `FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED`

The baseline, coverage, and approximate Kajiya–Kay variants clone each active source `ShaderMaterial` per mesh surface, preserve its parameters and groom textures, replace only the shader resource, and use `set_surface_override_material()`. Mesh material resources are never edited. `benchmark/reference/BASELINE_COMMIT.txt` freezes the source commit, and the reference shader/include are immutable copies of the current source.

Two variants exercise the source alpha path with different discard methods. `COVERAGE_CONTROL` is the exact custom control: it keeps the source `ShaderMaterial` interface, reads coverage/depth/seed from the packed `attributes_texture` (R/G/B) and reproduces the production shader's distance/depth-biased Bayer + `TIME` discard, so its coverage behavior matches the source hash path pixel-for-pixel (the temporal hash is effectively frozen during benchmark runs). `BUILTIN_ALPHA_HASH_CONTROL` is an approximation: at runtime the controller converts each source attributes PNG (RGB, coverage in red, no alpha) into a transient in-memory texture with white RGB and the source red channel copied to alpha, assigns it as `albedo_texture` on a per-surface `StandardMaterial3D` (`TRANSPARENCY_ALPHA_HASH`, unshaded, cull disabled, nearest filtering, `SPECULAR_DISABLED`, roughness 1, albedo color from the source `albedo` parameter with alpha 1), and lets Godot's built-in alpha-hash discard fragments. The converted textures are cached per process and never written to disk; missing or empty attributes textures fail the start with a clear message instead of crashing. Because the built-in hash has no distance/depth bias and no `TIME`-driven Bayer pattern, coverage edges differ from the exact `COVERAGE_CONTROL`; the variant exists to compare the built-in hash's cost and coverage against the custom path. Shadow and depth participation follow the built-in alpha-hash defaults.

## Resource-backed groom definitions and profiles

Stable groom and material contracts live under `benchmark/resources/` and never modify imported scenes or materials:

- `hair_groom_definition.gd` (`HairGroomDefinition`): stable `groom_id` (node-name based, must match the pattern of ASCII letters/digits/underscores), `display_name`, `category`, `groom_root` (NodePath relative to `Head`), `hair_mesh_paths` (relative to `groom_root`), explicit `hair_surface_indices` (never an implicit "all surfaces"), `expected_material_profile` (a profile id), and `notes`. `validation_errors()` enforces stable IDs, a non-empty root, at least one mesh path, and explicit, non-negative, duplicate-free surface selection.
- `hair_benchmark_profile.gd` (`HairBenchmarkProfile`): canonical material parameters. Source-compatible fields mirror the current production shader interface (`albedo`, `longitudinal_roughness`, `azimuthal_roughness`, `cuticle_tilt_offset`, `specular`, `coords_texture`, `attributes_texture`) and can be applied today by cloning the source `ShaderMaterial`s and setting the matching shader parameters. Tier-2 Fast Marschner fields (`absorption_mode`, `absorption`, `eumelanin`, `pheomelanin`, `melanin_absorption_scale`, `ior`) are applied when the target shader declares them. Remaining future-tier placeholder fields (R/TT/TRT lobe weights, multiple scattering, root/tip colors, flow texture, coverage/alpha overrides) are typed and validated but not yet read by the controller.
- `hair_groom_catalog.gd` (`HairGroomCatalog`): ordered resource-backed catalog of `HairGroomDefinition`s with duplicate-id validation.
- Data: `benchmark/resources/profiles/source_current.tres` is the default profile (id `&"source_current"`, mirroring the source shader defaults); `benchmark/resources/grooms/hair_groom_catalog.tres` defines the ten fixture grooms.

`BenchmarkCase` gained `profile_id: StringName` defaulting to `&"source_current"`; it is validated (non-empty, and the profile resource must exist under `res://benchmark/resources/profiles/`) and recorded in `run_manifest.json`/`summary.json` as `profile_id`. Existing `.tres` cases load unchanged because the default applies. The controller's runtime groom catalog now exposes stable `groom_id`/`name` and display metadata (`display_name`, `category`) separately from the transient per-process instance `id`, merging them from `hair_groom_catalog.tres` when it loads (falling back to node names otherwise); `run_manifest.json` grooms entries include both.

Material adapter: `benchmark/scripts/hair_material_adapter.gd` (`HairMaterialAdapter`) owns all material construction — cloning the source `ShaderMaterial` and swapping in the selected benchmark shader, applying canonical profile parameters/textures, and building the built-in `StandardMaterial3D` alpha-hash control (including the cached red-coverage-to-alpha conversion). Variant-specific shader selection stays in the controller; the controller no longer duplicates material-construction code. Profile resolution: the case's `profile_id` resolves to `res://benchmark/resources/profiles/<profile_id>.tres`; a missing or invalid profile fails the start clearly. The default `source_current` profile sets `preserve_source_parameters = true`, so the adapter keeps every per-groom source parameter and texture while still applying declaration-gated Tier-2-only uniforms to Fast Marschner clones; canonical profiles set it false when they need to override source-compatible values.

Explicit surface selection: `hair_groom_catalog.tres` `hair_surface_indices` now drive which mesh surfaces receive benchmark overrides. Only selected surfaces get variant/diagnostic materials; non-selected surfaces are never touched. Restoration is unchanged and exact: selected surface overrides, groom-level `material_override`, visibility, and diagnostic state all return to their discovered originals. Grooms without a catalog definition keep every surface selected (backward-compatible fallback). Transient instance ids and stable groom ids remain separate. The next slice (not yet implemented) introduces HEAVIEST/HAIR_ONLY display modes.

## Resource-backed suites

Phase 2 resources live under `benchmark/cases/`, `benchmark/cameras/`, and `benchmark/lighting/`. A case is started with `BenchmarkController.start_case(case_resource)`. A suite validates all of its cases before queueing them and can be started with `BenchmarkController.start_suite(suite_resource)`. Cases and repeats run sequentially; output uses:

```text
user://hair_benchmarks/<timestamp>/<suite>/<case>/repeat_001/
```

Camera poses (all against the real fixture head at the origin, fov 60, look-at math): `front_portrait`, `three_quarter`, `rear_backlit` (original), plus `side_grazing` (0.55 m on the +X side, shallow angle), `close_up` (≈0.24 m, near 0.01), and `distant_lod` (≈1.5 m). Lighting fixtures: `single_directional_key`, `rear_spot`, `four_light_rig` (original), plus `front_omni` (one shadow-casting omni in front), `area_light` (one 0.6×0.4 m rectangle `AreaLight3D` softbox — Godot 4.7 Forward+ only, which is the project renderer), `eight_light_stress` (four shadow-casting directionals + four shadow-casting omnis), and `environment_only` (no light nodes; ambient/background only, the lower-bound lighting reference). All requested fixtures were representable with existing node types, so nothing is deferred.

Three representative suites were added (all cases at 1920×1080, default timing 180/30/300, `capture_color` only):

- `visual_suite.tres` (13 cases): exercises the new poses and rigs — frozen baseline at `side_grazing`/`close_up`/`distant_lod`, coverage control at `side_grazing` (rear spot), approximate Kajiya–Kay at `close_up` (area light), built-in alpha hash at `distant_lod` (front omni), a `NO_HAIR` side reference, and Fast Marschner at `close_up` (area light) plus `side_grazing` (rear spot).
- `performance_suite.tres` (9 cases): the six Blowout variants (NO_HAIR, exact coverage control, frozen baseline, approximate Kajiya–Kay, built-in alpha hash, Fast Marschner) at `three_quarter` + `single_directional_key`, plus an `ALL_GROOMS` frozen-baseline case (all ten grooms — the heaviest supported scene) at the same camera/rig.
- `light_scaling_suite.tres` (14 cases): frozen baseline and Fast Marschner each across the lighting sweep — `environment_only`, `single_directional_key`, `front_omni`, `rear_spot`, `four_light_rig`, `area_light`, `eight_light_stress`.

All case/suite/camera/lighting ids are unique; the existing `smoke_suite.tres` and `capture_smoke_suite.tres` are unchanged and still validate. The shorter timing used by `capture_smoke_suite` cases is intentional (diagnostic captures); the new suites keep the 180/30/300 smoke defaults.

Each case directory contains the normal run artifacts plus resource metadata in `run_manifest.json`. The suite directory contains `suite_manifest.json` after every case and repeat has completed; every case entry there includes the run's `validation` result (`valid` + `validation_notes`) so unstable cases can be flagged at suite level without opening each summary. Newly written run, summary, and suite manifests include `comparison_validity.marker = "material_override_precedence_repair_v1"`; analysis should reject artifacts that lack this marker. Manual `start_benchmark()` calls retain the existing `user://hair_benchmarks/<timestamp>/` layout.

Diagnostic suite cases can additionally request `coverage.png` and `tangent.png` through their capture flags. Coverage metrics are computed only from `coverage.png`: a pixel qualifies as white when R, G, and B are each at least `0.95`; the manifest and summary record the white-pixel count, percentage of total frame pixels, and the inclusive white-pixel bounding rectangle. Each capture record includes the process frame and monotonic timestamp immediately after its post-draw frame.

Benchmark hash timing is deterministic: before rendering starts the controller saves `Engine.time_scale`, sets it to the tiny positive `BENCHMARK_TIME_SCALE` (`1e-6`), and restores the caller's prior value on every completion, failure, cancellation, and exit path (manual runs restore on `reset_benchmark()` or scene exit; ordinary use of the harness scene without a started benchmark is unaffected). At this scale shader `TIME` advances at one millionth of real time, so the production `TIME*500` integer Bayer coordinate stays constant for normal benchmark durations — effectively frozen, not mathematically zero. The stability budget is `1 / (TIME_FACTOR * scale)` ≈ 33 minutes of real time before the Bayer offset can advance one texel; no benchmark approaches that. The controller's state machine advances by frame counters, not delta time, so `PREWARM`/`SETTLE`/`SAMPLE`/`CAPTURE` still complete. The strategy is recorded in every run, summary, and suite manifest under `runtime.hash_time` (`strategy`, `benchmark_time_scale`, `engine_time_scale`, `effectively_frozen`, `hash_bayer_time_factor`, `hash_stability_budget_seconds`, `phase`).

The positive scale (instead of an exact `0.0`) keeps the engine frame delta positive, so the imgui-godot addon's `NewFrame` receives a nonzero delta and does not log its `IM_ASSERT (DeltaTime > 0)` error. The overlay content is still suppressed during runs (`DebugManager.should_render_imgui = false`), so ImGui does not appear in captures or measurements.

Variant artifacts generated before the material-override precedence repair are invalid for comparison because groom-level overrides could hide the intended per-surface shader variants. Rerun the replacement smoke suite; those post-marker results are the first trustworthy baseline/control/Kajiya comparisons. The checked-in `smoke_suite.tres` runs the Blowout smoke matrix (8 cases, 1920x1080 viewport target, default 180/30/300 warmup/settle/sample timing): five front cases use the three-quarter camera with the single directional key light — `COVERAGE_CONTROL`, the frozen baseline, approximate Kajiya–Kay, `BUILTIN_ALPHA_HASH_CONTROL`, and the `NO_HAIR` empty-scene case — and three rear/backlit cases repeat the core comparison variants (`COVERAGE_CONTROL`, the frozen baseline, approximate Kajiya–Kay) under the `rear_backlit` camera with the cool `rear_spot` rim light to exercise backlit coverage and translucency-sensitive rendering.

## Settings-driven Fast Marschner preview

The preview UI exposes a single `FAST_MARSCHNER` entry that maps to the
internal `FAST_MARSCHNER_ANALYTIC` variant (5) and passes a settings dictionary
to `BenchmarkController.apply_preview(mode, variant, groom, settings)`.
Supported keys: `use_azimuthal_lut`, `use_dual_scatter`,
`use_preintegrated_dual_scatter`, `use_environment`, `dual_scatter_strength`,
`dual_scatter_density`, and `environment_strength`.
`use_preintegrated_dual_scatter` implies `use_dual_scatter=true`; requested
LUTs/textures are built through the adapter's cached builders, strength/density
values are clamped to the shader ranges, and any failure to build a requested
resource returns false and restores the original surface state. Timed
resource-backed cases are unaffected: they keep their internal variant IDs
(5-9) and exclusive `apply_variant` semantics.

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
