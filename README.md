# Godot Marschner Hair Shader

Production hair-card shading for **Godot 4.7 Forward+**, with three release quality tiers and a reusable `HairMaterialProfile + HairGroomData` authoring workflow.

The repository contains:

- an MIT-licensed addon under `addons/marschner_hair/`;
- a Godot demo project and calibrated preview scene;
- CC BY-NC 4.0 demo grooms under `assets/hair/models/`.

See [docs/architecture.md](docs/architecture.md) for the codebase layout and responsibility boundaries.

## Release quality tiers

| Tier | Model | LUT requirement |
| --- | --- | --- |
| Approx / Kajiya-Kay | inexpensive cylindrical fallback | none |
| Fast Marschner | Unity HDRP Standard-style approximation | packaged 64×64×64 RGBA16F azimuthal LUT |
| Cinematic Marschner | higher-fidelity non-separable Marschner model | packaged 128×128×64 R16F longitudinal LUT |

Each tier has an ordered-dither and alpha-to-coverage compiled variant. `HairCoveragePolicy` can select the appropriate path from the active viewport AA configuration.

## Requirements

- Godot 4.7
- Forward+ renderer

Open the repository folder in Godot and allow the first asset import to finish before running the demo.

## Quick start

The project opens on `demos/HairMaterialProfileEditor.tscn`, which previews the Blowout groom under a calibrated studio rig.

1. Open the project in Godot 4.7.
2. Wait for `.glb` and `.png` imports to finish.
3. Press **F5**.
4. Select the `HairMaterialProfileEditor` root node to edit the assigned profile in the Inspector.
5. Change `quality_tier` to compare Approx, Fast Marschner, and Cinematic Marschner.
6. Move `wetness` from `0` to `1` to inspect the optical wetness response.

The preview also refreshes directly in the editor viewport.

## Using the addon in another project

Copy `addons/marschner_hair/` into the target Godot project. The packaged Fast and Cinematic LUTs are already included; no LUT-generation step is required.

### 1. Create groom data

Create a `HairGroomData` resource and assign the card-atlas textures generated for the groom:

- `coords_texture`: RGB tangent direction, A root-to-tip coordinate;
- `attributes_texture`: R coverage, G strand depth, B deterministic strand seed.

![Godot Inspector showing HairGroomData and its assigned groom textures](docs/images/new-groom-01-hair-groom-data.png)

### 2. Create a material profile

Create a `HairMaterialProfile` resource and select the desired `quality_tier`. The Inspector exposes only controls relevant to the selected tier.

![Godot Inspector showing HairMaterialProfile quality tiers](docs/images/new-groom-02-hair-material-profile.png)

### 3. Create and assign the material

```gdscript
var material: ShaderMaterial = profile.create_material(groom_data, get_viewport())
hair_mesh.material_override = material
```

If AUTO coverage needs to track viewport AA changes at runtime, register the material with `HairCoverageController`.

![Godot Inspector showing the preview material and groom assignments](docs/images/new-groom-03-material-assignment.png)

## Visual previews

### Quality tiers

| Approx | Fast Marschner | Cinematic Marschner |
| --- | --- | --- |
| ![Approx quality tier preview](docs/images/demo-video-approx.gif) | ![Fast Marschner preview](docs/images/demo-video-fast.gif) | ![Cinematic Marschner preview](docs/images/demo-video-cinematic.gif) |

### Wetness response

| Wetness | Approx | Fast Marschner | Cinematic Marschner |
| --- | --- | --- | --- |
| 0.00 | ![Approx wetness 0.00](docs/images/demo-video-wetness-approx-000.gif) | ![Fast wetness 0.00](docs/images/demo-video-wetness-fast-000.gif) | ![Cinematic wetness 0.00](docs/images/demo-video-wetness-cinematic-000.gif) |
| 0.33 | ![Approx wetness 0.33](docs/images/demo-video-wetness-approx-033.gif) | ![Fast wetness 0.33](docs/images/demo-video-wetness-fast-033.gif) | ![Cinematic wetness 0.33](docs/images/demo-video-wetness-cinematic-033.gif) |
| 0.67 | ![Approx wetness 0.67](docs/images/demo-video-wetness-approx-067.gif) | ![Fast wetness 0.67](docs/images/demo-video-wetness-fast-067.gif) | ![Cinematic wetness 0.67](docs/images/demo-video-wetness-cinematic-067.gif) |
| 1.00 | ![Approx wetness 1.00](docs/images/demo-video-wetness-approx-100.gif) | ![Fast wetness 1.00](docs/images/demo-video-wetness-fast-100.gif) | ![Cinematic wetness 1.00](docs/images/demo-video-wetness-cinematic-100.gif) |

## Addon layout

```text
addons/marschner_hair/
├── hair_material_profile.gd
├── hair_groom_data.gd
├── hair_coverage_policy.gd
├── hair_coverage_controller.gd
├── hair_marschner_lut_adapter.gd
├── internal/
│   └── hair_shader_utils.gd
├── luts/
└── shaders/
```

The public resources use Godot-style snake_case filenames while retaining PascalCase `class_name` APIs.

## Demo assets

All ten bundled hairstyles (`bangs`, `blowout`, `bob`, `curly`, `jewfro`, `jheri`, `moptop`, `pixie`, `wavy`, `wings`) use the same groom-data workflow. Blowout is the calibrated reference groom for the demo scene.

The demo grooms are adapted from the CT2Hair dataset (Meta Research) via the GodotHair project and are **not** covered by the addon MIT license. They remain under **CC BY-NC 4.0**. Replace them with appropriately licensed assets for commercial projects.

## Licensing

| Path | License |
| --- | --- |
| Project code and `addons/marschner_hair/` | MIT |
| Demo grooms and maps under `assets/hair/models/**` | CC BY-NC 4.0 |
| Upstream GodotHair reference code | MIT; see `THIRD_PARTY_NOTICES.md` |

See `LICENSE`, `THIRD_PARTY_NOTICES.md`, `CHANGELOG.md`, and `VERSION` for release details.
