# Godot Marschner Hair Shader

A Godot 4.7 hair-card shading stack with three explicit production quality tiers, viewport-aware coverage, packaged 3D LUT resources, and a shared optical-wetness model.

- **Approx / Kajiya-Kay** — lightweight fallback for constrained hardware.
- **Fast Marschner** — Unity HDRP Standard-style Marschner with a preintegrated azimuthal LUT.
- **Cinematic Marschner** — higher-fidelity Marschner using the conditioned longitudinal LUT while retaining analytic azimuthal/attenuation behavior.

The packaged addon exposes only these three tiers. The analytic **Reference Marschner** shader remains a development/benchmark validation baseline outside the addon; it is not part of the shipped `HairMaterialProfile` tier enum.

The tiers remain **separate compiled shaders**. `HairMaterialProfile` is the common authoring API and selects the appropriate shader instead of compiling one runtime-branching mega-shader.

## Requirements

- Godot 4.7.
- Hair-card meshes with the groom data maps described below.
- Forward+ is required for TAA. MSAA/A2C is supported by Forward+ and Mobile according to Godot's viewport capabilities.
- Fast and Cinematic use the packaged direct `ImageTexture3D` LUT resources. Normal users do **not** need to generate LUTs.

## Repository layout

The `development` branch contains demos, benchmarks, validation tools, experimental/reference material, and the production sources under:

```text
res://assets/hair/
```

The distributable release branch repackages the production runtime under:

```text
res://addons/marschner_hair/
```

Release users should copy only the addon package described by the release README. Development-only raw LUT fixtures and benchmark generators are not runtime dependencies.

## Quick start

### 1. Create groom data

Create one `HairGroomData` resource for each card atlas and assign the two generated textures:

```text
coords_texture
  RGB = strand tangent encoded from [-1, 1] into [0, 1]
  A   = root-to-tip coordinate

attributes_texture
  R = coverage / occupancy
  G = strand depth
  B = deterministic per-strand seed
```

These textures describe the groom/card atlas, not the hair appearance. Keep them paired with the mesh and UVs that generated them. Lossless import is recommended when compression alters tangent, coverage, depth, or seed values.

### 2. Create a `HairMaterialProfile`

Choose a `quality_tier` and normally leave `coverage_mode` on **Auto**. The Inspector hides controls that do not affect the selected tier while preserving their serialized values.

The main authoring groups are:

- **Quality** — Approx, Fast, or Cinematic.
- **Coverage** — Auto, Static Bayer, TAA Temporal Bayer, or Alpha-to-Coverage.
- **Base Hair** — color, longitudinal/azimuthal roughness, specular scale, and cuticle tilt.
- **Wetness** — optical wetness and its film/fiber-response endpoints.
- **Fast Marschner** — absorption model and optional azimuthal LUT override.
- **Cinematic Marschner** — IOR and optional longitudinal LUT override.
- **Approx / Kajiya-Kay** — primary/secondary lobe controls and wrapped scatter.

Both `HairMaterialProfile` properties and direct ShaderMaterial uniforms carry Inspector hover documentation.

### 3. Create and assign the material

Pass the owning viewport when creating runtime materials so `coverage_mode = Auto` resolves immediately:

```gdscript
@export var profile: HairMaterialProfile
@export var groom_data: HairGroomData
@export var hair_mesh: MeshInstance3D

func _ready() -> void:
    var material: ShaderMaterial = profile.create_material(groom_data, get_viewport())
    hair_mesh.material_override = material
```

For callers that need an explicit success result:

```gdscript
var material := ShaderMaterial.new()
if not profile.apply_to(material, groom_data, get_viewport()):
    push_error("Hair material setup failed")
    return
hair_mesh.material_override = material
```

`apply_to()` validates a supplied groom before mutating the material and binds the production LUT required by Fast or Cinematic.

If the viewport's AA configuration can change after material creation, register the material with a `HairCoverageController`:

```gdscript
coverage_controller.register_material(profile, material, get_viewport())
```

The controller keeps the compiled coverage variant and 16-phase Bayer index in sync with the rendered frame. For the full runtime API reference see [`docs/api.md`](docs/api.md).

## Editor workflow

The development preview scene is:

```text
res://demos/HairMaterialProfileEditor.tscn
```

Assign a profile and groom resource, then change `quality_tier`, `coverage_mode`, or `wetness` while inspecting the result in the editor viewport.

The three screenshots below show the basic resource hand-off:

1. Create `HairGroomData` and assign the groom maps.
2. Create `HairMaterialProfile` and choose the quality/appearance settings.
3. Compose the two resources into a `ShaderMaterial` on the hair MeshInstance3D.

[![HairGroomData resource](docs/images/new-groom-01-hair-groom-data.png)](docs/images/new-groom-01-hair-groom-data.png)

[![HairMaterialProfile resource](docs/images/new-groom-02-hair-material-profile.png)](docs/images/new-groom-02-hair-material-profile.png)

[![Material assignment](docs/images/new-groom-03-material-assignment.png)](docs/images/new-groom-03-material-assignment.png)

## Demo videos

The demo groom and these videos are released under **CC BY-NC 4.0**. The MP4s
are attached to the private [PR13 demo media release](https://github.com/44madfire/GodotMarschnerHairShader/releases/tag/pr13-demo-media)
instead of being stored in the repository; the looping GIF previews below are
stored in this repository and reflect the calibrated captures. Every GIF is a
full 6-second seamless orbit. The quality row shows one orbit per tier (Approx,
Fast Marschner, and Cinematic Marschner; Reference is omitted). The wetness
matrix shows one individual GIF per cell for every tier at the fixed wetness
states 0.00, 0.33, 0.67, and 1.00.

### Composite videos

Repository-hosted MP4 links may download instead of playing inline; GitHub attachment URLs (release downloads) are needed for inline playback. Each MP4 is a horizontal strip of the three quality tiers (Approx | Fast Marschner | Cinematic Marschner) at 1440x270, H.264, 15 fps, 6 seconds (90 frames).

- [Quality tiers composite (Approx / Fast / Cinematic)](docs/images/demo-video-quality-composite.mp4)
- [Wetness 0.00 composite](docs/images/demo-video-wetness-000-composite.mp4)
- [Wetness 0.33 composite](docs/images/demo-video-wetness-033-composite.mp4)
- [Wetness 0.67 composite](docs/images/demo-video-wetness-067-composite.mp4)
- [Wetness 1.00 composite](docs/images/demo-video-wetness-100-composite.mp4)

Regenerate them from the source GIFs with:

```bash
bash docs/images/make_composite_mp4s.sh
```

### Quality tiers (dry, wetness 0.00)

| <strong>Approx / Kajiya-Kay</strong><br>[![Approx preview](docs/images/demo-video-approx.gif)](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/quality-tiers.mp4) | <strong>Fast Marschner</strong><br>[![Fast Marschner preview](docs/images/demo-video-fast.gif)](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/quality-tiers.mp4) |
| --- | --- |
| <strong>Cinematic Marschner</strong><br>[![Cinematic Marschner preview](docs/images/demo-video-cinematic.gif)](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/quality-tiers.mp4) | <strong>Reference omitted</strong><br>See the [quality-tiers.mp4](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/quality-tiers.mp4) release clip |

### Wetness matrix (fixed wetness states, one individual GIF per cell)

MP4s: [fast-wetness.mp4](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/fast-wetness.mp4) and [cinematic-wetness.mp4](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/cinematic-wetness.mp4). The Approx column has no separate wetness MP4; its GIFs are standalone previews.

| | <strong>Approx / Kajiya-Kay</strong> | <strong>Fast Marschner</strong> | <strong>Cinematic Marschner</strong> |
| --- | --- | --- | --- |
| <strong>Wetness 0.00</strong> | [![Approx wetness 0.00](docs/images/demo-video-wetness-approx-000.gif)](docs/images/demo-video-wetness-approx-000.gif) | [![Fast wetness 0.00](docs/images/demo-video-wetness-fast-000.gif)](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/fast-wetness.mp4) | [![Cinematic wetness 0.00](docs/images/demo-video-wetness-cinematic-000.gif)](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/cinematic-wetness.mp4) |
| <strong>Wetness 0.33</strong> | [![Approx wetness 0.33](docs/images/demo-video-wetness-approx-033.gif)](docs/images/demo-video-wetness-approx-033.gif) | [![Fast wetness 0.33](docs/images/demo-video-wetness-fast-033.gif)](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/fast-wetness.mp4) | [![Cinematic wetness 0.33](docs/images/demo-video-wetness-cinematic-033.gif)](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/cinematic-wetness.mp4) |
| <strong>Wetness 0.67</strong> | [![Approx wetness 0.67](docs/images/demo-video-wetness-approx-067.gif)](docs/images/demo-video-wetness-approx-067.gif) | [![Fast wetness 0.67](docs/images/demo-video-wetness-fast-067.gif)](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/fast-wetness.mp4) | [![Cinematic wetness 0.67](docs/images/demo-video-wetness-cinematic-067.gif)](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/cinematic-wetness.mp4) |
| <strong>Wetness 1.00</strong> | [![Approx wetness 1.00](docs/images/demo-video-wetness-approx-100.gif)](docs/images/demo-video-wetness-approx-100.gif) | [![Fast wetness 1.00](docs/images/demo-video-wetness-fast-100.gif)](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/fast-wetness.mp4) | [![Cinematic wetness 1.00](docs/images/demo-video-wetness-cinematic-100.gif)](https://github.com/44madfire/GodotMarschnerHairShader/releases/download/pr13-demo-media/cinematic-wetness.mp4) |

## Validation

The development branch contains focused tests for the production contracts. The current release-relevant minimum is:

```bash
# Coverage policy / 16-phase sequence
godot --headless --path . --script res://benchmark/tests/test_hair_coverage_phase_sequence.gd
godot --headless --path . --script res://benchmark/tests/test_hair_coverage_policy.gd

# Groom/profile interface
godot --headless --path . --script res://benchmark/tests/test_hair_groom_binding.gd
godot --headless --path . --script res://benchmark/tests/test_marschner_production_profile.gd

# Wetness interface
godot --headless --path . --script res://benchmark/tests/test_hair_wetness_interface.gd

# Real-renderer resource/variant checks: do not use --headless
godot --path . --script res://benchmark/tests/test_direct_lut_binding.gd
godot --path . --script res://benchmark/tests/test_hair_coverage_runtime_policy.gd
godot --path . --script res://benchmark/tests/test_hair_wetness_runtime.gd
```

The direct `ImageTexture3D` checks require a normal rendering context on the validated Godot 4.7 setup; the headless display path can serialize/load those resources as empty 1x1x1 stubs.

Before publishing a release package, also run the package-level checks in [`docs/release_validation.md`](docs/release_validation.md). Those checks exist specifically to catch repathing/import mistakes introduced when the production sources move from `assets/hair/` to `addons/marschner_hair/`.

## Further documentation

- [`docs/api.md`](docs/api.md) — runtime API reference for `HairMaterialProfile`, `HairGroomData`, `HairCoveragePolicy`, quality tiers, and coverage modes.
- [`docs/hair_material_authoring.md`](docs/hair_material_authoring.md) — profile/groom ownership, coverage, LUT binding, shader switching, and runtime APIs.
- [`docs/hair_wetness.md`](docs/hair_wetness.md) — optical wetness model, calibrated controls, tier behavior, and validation.
- [`docs/direct_lut_storage.md`](docs/direct_lut_storage.md) — direct `ImageTexture3D` storage decision and benchmarks.
- [`docs/hair_coverage_benchmark.md`](docs/hair_coverage_benchmark.md) — coverage-path benchmark and policy rationale.
- [`docs/release_media.md`](docs/release_media.md) — release/demo media capture workflow and licensing.
- [`docs/release_validation.md`](docs/release_validation.md) — release packaging and final validation checklist.
