# Changelog

## Unreleased

Release-branch cleanup before the public launch.

### Changed

- Removed the development-only analytic Reference Marschner tier from the release addon and public `HairMaterialProfile` API. Release quality tiers are now Approx, Fast Marschner, and Cinematic Marschner.
- Renamed public addon scripts to Godot-style snake_case filenames while preserving their PascalCase `class_name` APIs.
- Renamed the Fast Marschner shader files to describe their release tier rather than their Unity implementation provenance.
- Centralized shader-uniform reflection and parameter preservation in `internal/hair_shader_utils.gd`.
- Replaced dictionary-based coverage-controller entries with a typed internal entry class.
- Refocused the README on the release workflow and added `docs/architecture.md`.
- The demo profile now opens on Cinematic Marschner instead of the removed Reference tier.

## 0.1.0-rc3

Third release candidate of the Godot 4.7 production hair shader stack, packaged
as a mixed-license demo release.

### Added

- Optical wetness across all four quality tiers (Approx, Fast Marschner,
  Cinematic Marschner, Reference Marschner) and both normal/A2C shader
  families, with calibrated dry/wet endpoints and a wet-film response.
- Shader-parameter documentation comments (Inspector tooltips) on every
  production shader uniform.
- Viewport-aware hair-card coverage policy with Auto, Static Bayer, TAA
  Temporal Bayer, and Alpha-to-Coverage modes, plus `HairCoveragePolicy` and
  `HairCoverageController` runtime APIs.
- Alpha-to-coverage compiled shader variants for every quality tier.
- Repository license adoption: MIT for project code, CC BY-NC 4.0 terms for
  the demo hair-card groom assets, with `THIRD_PARTY_NOTICES.md` documenting
  upstream GodotHair/CT2Hair attribution.

### Changed

- The demo package now opens on `demos/HairMaterialProfileEditor.tscn`, an
  editor-facing preview scene; all development autoloads, editor plugins
  (MCP/ImGui), and benchmark/reference material are excluded from the release
  tree.
- Fast and Cinematic default LUT binding loads the packaged direct
  `ImageTexture3D` resources and validates dimensions, format, and RID before
  binding; legacy raw-data reconstruction and benchmark LUT fixtures are not
  shipped.
- The embedded `addons/marschner_hair/` tree is the byte-identical addon
  build distributed in the standalone MIT addon archive.

### Packaging

- Default scene: `res://demos/HairMaterialProfileEditor.tscn`.
- Embedded addon: `res://addons/marschner_hair/` (MIT).
- Demo grooms: `res://assets/hair/models/**` (CC BY-NC 4.0), ten hairstyles.
- Fast LUT: `unity_hdrp_azimuthal_n_v1`, 64x64x64 RGBA16F, eta 1.55.
- Cinematic LUT: `deon_physical_longitudinal_log2q_v2`, 128x128x64 R16F.
- Release users need no LUT-generation step after copying the addon into a
  project.

## 0.1.0-rc2

Second release candidate of the Godot 4.7 production hair shader stack.

### Added

- Viewport-aware hair-card coverage policy with Auto, Static Bayer, TAA Temporal Bayer, and Alpha-to-Coverage modes.
- Alpha-to-coverage compiled shader variants for Approx, Fast Marschner, Cinematic Marschner, and Reference Marschner.
- `HairCoveragePolicy` and `HairCoverageController` runtime APIs for selecting and updating coverage from viewport AA state.
- Packaged Fast and Cinematic production LUTs as directly serialized `ImageTexture3D` resources.

### Changed

- Temporal Bayer coverage now advances from deterministic rendered-frame indices rather than the previous continuously time-driven phase, removing the prior high-frequency phase-flicker path.
- Fast and Cinematic default LUT binding now loads the packaged direct `Texture3D` resources and validates dimensions, format, and RID before binding.
- Removed consumer-side LUT generation and raw `PackedByteArray -> ImageTexture3D` reconstruction from the distributed addon. Numerical generators and legacy storage fixtures remain on the `development` branch.
- Preserved the existing Approx / Fast / Cinematic / Reference quality-tier architecture and the validated numerical LUT contracts.

### Packaging

- Fast LUT: `unity_hdrp_azimuthal_n_v1`, 64x64x64 RGBA16F.
- Cinematic LUT: `deon_physical_longitudinal_log2q_v2`, 128x128x64 R16F.
- Release users no longer need a LUT-generation step after copying `addons/marschner_hair/` into a project.

### Validation notes

The direct LUT migration was validated on the development branch with byte-identical texel payloads against the numerical source resources and real-renderer material/profile binding. On the validated Godot 4.7 setup, direct `ImageTexture3D` materialization/integrity verification used a normal rendering context rather than the headless display path.

A repository license still needs to be selected before publishing a public redistribution release if none is already established externally.

## 0.1.0-rc1

First packaged release candidate of the production hair shader stack for Godot 4.7.

### Added

- `HairMaterialProfile` authoring resource with four explicit quality tiers.
- `HairGroomData` resource for groom-owned coordinate/attribute textures.
- Approx / Kajiya-Kay production fallback.
- Unity HDRP Standard-style Fast Marschner tier.
- Conditioned-LUT Cinematic Marschner tier.
- Full analytic Reference Marschner tier.
- Shared hair-card coverage, root shading, frizz, and strand-frame preparation.
- Inspector mode filtering and documentation hints.
- Transactional groom validation when applying a profile.
- Runtime LUT adapter with `Texture3D` reconstruction/cache handling.
- Standalone LUT-data classes and offline LUT generators under the release addon.

### Packaging

- Production files are isolated under `addons/marschner_hair/`.
- Development benchmark harnesses, raw benchmark runs, experimental shader variants, demo fixtures, reference submodules, MCP tooling, and debug-camera tooling are excluded from the release branch.
- Generated `.uid` files and Windows `Zone.Identifier` artifacts are excluded.

### Validated performance ordering

The full dual-GPU development benchmark established the production cost ordering:

```text
Approx < Fast < Reference < Cinematic
```

At 1920x1080, production coverage, and eight total directional lights, median measured GPU times were 0.271/0.300/0.357/0.423 ms on RTX 5090 and 26.311/34.756/41.978/50.104 ms on the tested AMD integrated GPU for Approx/Fast/Reference/Cinematic respectively.

### Historical rc1 requirement

Fast and Cinematic LUT `.res` files were generated inside the consuming Godot project using the included generator scripts. rc2 supersedes that workflow by shipping direct production LUT resources.
