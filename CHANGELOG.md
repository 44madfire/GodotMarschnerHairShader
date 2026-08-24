# Changelog

## 0.1.0-rc4

Release-readability and packaging cleanup for the Godot 4.7 Marschner hair shader stack.

### Added

- Deterministic production shader-wrapper generation from canonical templates under `tools/templates/`.
- `tools/generate_hair_shaders.py --check` drift validation for the six production shader wrappers plus the shared Approx body.
- Focused generator tests for missing sections, unresolved tokens, and byte-for-byte wrapper parity.
- Cached shader-uniform reflection through `addons/marschner_hair/internal/hair_shader_utils.gd`.
- Tracked Godot `.uid` sidecars for addon scripts, shaders, and shader includes.
- Repository-tracked composite demo videos for quality-tier and fixed-wetness comparisons.

### Changed

- `addons/marschner_hair/` is now the canonical production runtime location in the repository.
- The shipped `HairMaterialProfile` quality ladder contains Approx / Kajiya-Kay, Fast Marschner, and Cinematic Marschner. Analytic Reference Marschner remains available only as development/benchmark validation infrastructure.
- Approx normal and alpha-to-coverage variants now share one implementation body instead of duplicating shader behavior.
- Normal and alpha-to-coverage remain separate compiled shader variants because alpha-to-coverage is a render-mode contract, not a runtime branch.
- Fast and Cinematic continue to load the validated direct `ImageTexture3D` LUT resources from the addon tree.
- Release validation now treats `.uid` sidecars as part of the distributable addon identity.
- Authoring, LUT-storage, demo-media, and release-validation documentation now reflect the canonical addon layout.

### Packaging and licensing

- Standalone addon: MIT, with production runtime under `addons/marschner_hair/` and no CC BY-NC demo grooms/media.
- Demo package: mixed license; project/addon code remains MIT while the supplied CT2Hair/GodotHair demo groom assets remain CC BY-NC 4.0.
- Demo media that visibly reproduces the supplied demo groom is treated as demo media under the CC BY-NC 4.0 demo terms.

### Validation before publishing

Run the release gate in `docs/release_validation.md`, including:

- `python3 tools/generate_hair_shaders.py --check`;
- the focused Python generator tests;
- Godot 4.7 profile/groom/coverage/wetness smoke tests;
- real-renderer Fast/Cinematic direct-LUT checks;
- at least one actual rendered frame from all six production variants (Approx/Fast/Cinematic × normal/A2C);
- fresh-project addon import with no UID/path fallback warnings.

The historical full shader-math, LUT-quality, coverage-performance, and wetness-performance benchmark suites do not need to be rerun for rc4 unless shader math changes.
