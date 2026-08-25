---
layout: default
title: Godot Marschner Hair Shader
---

# Godot Marschner Hair Shader

A Godot 4.7 hair-card shading stack with three explicit production quality tiers, viewport-aware coverage, packaged 3D LUT resources, and a shared optical-wetness model.

- **[Runtime API reference](api.md)** — `HairMaterialProfile`, `HairGroomData`, coverage policy, LUT adapter.
- **[Material authoring](hair_material_authoring.md)** — authoring workflow, shader switching internals, preserved parameters.
- **[Optical wetness](hair_wetness.md)** — wetness model and calibration endpoints.
- **[Direct LUT storage](direct_lut_storage.md)** — production `ImageTexture3D` contracts.
- **[Production architecture](marschner_production_architecture.md)** — how the tiers and includes fit together.

## Getting the addon

Download the standalone MIT addon or the mixed-license demo from the [releases page](https://github.com/44madfire/GodotMarschnerHairShader/releases/latest). The demo groom assets are CC BY-NC 4.0 (CT2Hair / GodotHair); the addon runtime itself is MIT.

## Repository docs index

| Document | Contents |
| --- | --- |
| [api.md](api.md) | Runtime API reference |
| [hair_material_authoring.md](hair_material_authoring.md) | Authoring workflows and internals |
| [hair_wetness.md](hair_wetness.md) | Wetness model and calibration |
| [direct_lut_storage.md](direct_lut_storage.md) | Direct ImageTexture3D LUT contracts |
| [marschner_production_architecture.md](marschner_production_architecture.md) | Tier/include architecture |
| [demo_release.md](demo_release.md) | Demo packaging and licensing split |
| [release_validation.md](release_validation.md) | Release validation gates |
| [release_media.md](release_media.md) | Deterministic media capture workflow |
| Benchmark docs | Coverage/LUT/wetness benchmark methodology |

The full README with demo videos lives in the [repository root](https://github.com/44madfire/GodotMarschnerHairShader#godot-marschner-hair-shader).
