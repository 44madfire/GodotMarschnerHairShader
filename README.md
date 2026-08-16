# Marschner Hair Shader — Demo Package (0.1.0-rc3)

Mixed-license demo release for the Godot 4.7 production hair shader stack:
an embedded MIT addon (`addons/marschner_hair/`) plus CC BY-NC 4.0 demo
hair-card grooms under `assets/hair/models/`.

## Requirements

- Godot 4.7 (Forward+ renderer). Open the project folder in the editor and
  let the initial import finish before running.

## Default scene and run instructions

The project opens on `demos/HairMaterialProfileEditor.tscn`, an editor-facing
preview scene showing the Blowout groom on a head mesh under a calibrated
studio rig.

1. Open the project in Godot 4.7.
2. Wait for the groom `.glb`/`.png` import to complete.
3. Press **F5** (or select the scene and open it directly) to run the demo.

The preview is also live in the editor: select the `HairMaterialProfileEditor`
root node and edit the assigned `HairMaterialProfile` resource. Change
`quality_tier` to compare Approx / Fast Marschner / Cinematic Marschner /
Reference Marschner, and move `wetness` from 0 (dry) to 1 (saturated) to see
the optical water-film response. The groom is switched by assigning a
different groom mesh or a matching `HairGroomData` resource pair.

All ten bundled hairstyles (`bangs`, `blowout`, `bob`, `curly`, `jewfro`,
`jheri`, `moptop`, `pixie`, `wavy`, `wings`) import with the default scene's
workflow; Blowout is the calibrated reference groom of this release.

## Embedded addon (MIT)

`addons/marschner_hair/` is the validated production runtime:

- `HairMaterialProfile`, `HairGroomData`, `HairMarschnerLUTAdapter`,
  `HairCoveragePolicy`, `HairCoverageController` — authoring/runtime APIs.
- `shaders/` — Approx, Fast Marschner, Cinematic Marschner, and Reference
  Marschner tiers, each with a normal and an alpha-to-coverage variant.
- `luts/` — the Fast (64x64x64 RGBA16F) and Cinematic (128x128x64 R16F)
  production LUTs as directly serialized `ImageTexture3D` resources. They are
  packaged: no LUT-generation step is needed.

The addon is distributed under the MIT License (see `LICENSE`). Third-party
attributions for code and assets are in `THIRD_PARTY_NOTICES.md`.

## Supplied demo grooms (CC BY-NC 4.0)

The demo hair-card meshes and groom maps under `assets/hair/models/**` are
adapted from the CT2Hair dataset (Meta Research) via the GodotHair project
and are **not** part of the MIT license. They remain under
**Creative Commons Attribution-NonCommercial 4.0 International (CC BY-NC 4.0)** —
see `assets/hair/models/LICENSE.md` and `THIRD_PARTY_NOTICES.md` for the full
attribution. Do not use these grooms in commercial projects; replace them with
your own appropriately licensed models.

## Standalone addon archive

The standalone MIT addon archive (no demo grooms, no demo media) is released
separately from this demo package. The `addons/marschner_hair/` tree embedded
here is byte-identical to that validated addon build; for an addon-only
distribution, copy just `addons/marschner_hair/` plus the MIT `LICENSE` and
`THIRD_PARTY_NOTICES.md` into your project.

## Licensing summary

| Path | License |
| --- | --- |
| Project code, embedded addon (`addons/marschner_hair/`, scripts, shaders) | MIT |
| Demo grooms and maps (`assets/hair/models/**`) | CC BY-NC 4.0 |
| Upstream reference code (GodotHair) | MIT (see `THIRD_PARTY_NOTICES.md`) |

See `CHANGELOG.md` for release history and `VERSION` for the current version.
