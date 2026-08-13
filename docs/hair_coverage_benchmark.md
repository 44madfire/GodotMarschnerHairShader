# Hair-card coverage quality/performance benchmark

This experiment isolates hair-card coverage from the Marschner BSDF. It was motivated by two observations: shared card/coverage work was a major cost on the constrained GPU, and the historical `TIME * 500.0` Bayer animation visibly flickered in ordinary editor use.

The benchmark compares:

- `legacy_time_bayer`: historical wall-clock-driven Bayer animation;
- `static_bayer`: fixed ordered-Bayer phase;
- `taa_bayer`: one explicit Bayer phase per rendered frame;
- `alpha_hash`: Godot native alpha-hash coverage;
- `a2c`: alpha-to-coverage with 2x/4x 3D MSAA.

All probes keep the same groom texture reads, distance/depth coverage bias, root shading, frizz perturbation, and orthonormal strand-frame reconstruction. The coverage equation remains `pow(coverage, bias)`.

## Dual-GPU result

Godot 4.7-stable, 1920x1080, five fresh-process repeats per case.

RTX 5090 incremental coverage cost versus the pipeline-matched cards control:

| case | incremental GPU ms |
|---|---:|
| legacy Bayer | about 0.010 |
| static Bayer | about 0.011-0.012 |
| TAA Bayer | about 0.011 |
| alpha hash | about 0.085 |

The Bayer candidates are effectively tied on the discrete GPU.

AMD Radeon integrated GPU:

| case | incremental GPU ms |
|---|---:|
| legacy Bayer | about 8.07 |
| static Bayer | about 8.06-8.08 |
| TAA Bayer | about 8.04 |
| alpha hash | about 23.0 |
| A2C 2x | about 4.5 |
| A2C 4x | about 5.0 |

The integrated-GPU result confirms that coverage is a major bottleneck, but changing Bayer cadence has no measurable cost. Alpha Hash is substantially more expensive there. A2C has the lowest incremental coverage cost once MSAA is already active, but enabling MSAA raises the whole-frame cards baseline dramatically, so hair should not turn MSAA on by itself.

## Production decision

`HairCoveragePolicy.AUTO` resolves in this order:

```text
3D MSAA enabled  -> Alpha-to-Coverage
else TAA enabled -> 16-phase rendered-frame Bayer
else             -> Static Bayer (phase 0)
```

This makes static Bayer the editor/no-AA default and removes the historical wall-clock animation from production. Temporal dithering is only introduced when TAA is actually available to accumulate it. If both MSAA and TAA are enabled, A2C wins and no additional Bayer phase animation is injected.

Explicit Static, TAA Bayer, and Alpha-to-Coverage modes remain available for debugging and custom pipelines.

## TAA cadence

Godot 4.7 ordinary TAA uses a 16-frame default jitter period. The temporal Bayer path likewise cycles over 0..15 and maps those phases to all sixteen offsets of the 4x4 Bayer matrix.

The production controller uses `Engine.get_frames_drawn()` rather than `TIME`, so phase advances with rendered frames and is unaffected by time scaling. This is cadence/period alignment, not access to Godot's private TAA jitter sample index. If that index becomes public later, it can replace the rendered-frame counter.

For a root or continuously updating viewport this gives one Bayer phase per rendered frame. A project that renders a SubViewport at a different cadence can call `HairMaterialProfile.update_coverage_for_viewport()` with its own rendered-frame index instead of relying on the convenience controller.

## Compiled coverage variants

Bayer and A2C require different shader pipelines because `alpha_to_coverage` is a shader `render_mode`, not a runtime uniform. Each lighting tier therefore keeps two compiled coverage variants:

```text
Approx        Bayer / A2C
Fast          Bayer / A2C
Cinematic     Bayer / A2C
Reference     Bayer / A2C
```

The lighting math and groom preparation remain shared. Fast/Cinematic use a preprocessor coverage branch in their existing body includes; only the top-level render-mode wrapper differs.

## Runtime use

`HairMaterialProfile.coverage_mode` defaults to `Auto`. When no viewport is supplied, Auto resolves to static Bayer so editor-created materials are stable.

For automatic runtime tracking, create one `HairCoverageController` and register each profile/material pair:

```gdscript
var controller := HairCoverageController.new()
add_child(controller)
controller.register_material(profile, hair_material)
```

The controller inspects the owning viewport every process frame. It swaps the compiled shader only when the effective MSAA/TAA policy requires a different variant, and updates `bayer_phase_index` only for temporal Bayer.

A single `ShaderMaterial` cannot simultaneously use different coverage variants in two viewports with different AA settings. Use separate material instances in that case.

## Tests

Deterministic Bayer sequence:

```bash
godot --headless --path . \
  --script res://benchmark/tests/test_hair_coverage_phase_sequence.gd
```

Expected: `HAIR_COVERAGE_PHASE_SEQUENCE_OK`.

Policy/shader-selection test:

```bash
godot --headless --path . \
  --script res://benchmark/tests/test_hair_coverage_policy.gd
```

Expected: `HAIR_COVERAGE_POLICY_OK`.

Full runtime shader/binding smoke test requires a real Forward+/Mobile rendering context:

```bash
godot --path . \
  --script res://benchmark/tests/test_hair_coverage_runtime_policy.gd
```

Expected: `HAIR_COVERAGE_RUNTIME_POLICY_OK`.

The original performance matrix remains available through:

```bash
python benchmark/tools/run_hair_coverage_benchmark.py \
  --godot /mnt/c/Tools/Godot/godot.exe \
  --project .
```

## Visual considerations

GPU timing does not rank visual fidelity. Static Bayer can expose a spatial ordered pattern, temporal Bayer can still interact with TAA ghosting, and A2C quality depends on sample count. The selected AUTO policy is therefore conservative: stable without temporal reconstruction, temporally distributed only with TAA, and multisample coverage only when the viewport has already paid the MSAA cost.
