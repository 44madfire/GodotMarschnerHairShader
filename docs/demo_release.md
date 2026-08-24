# Demo release and asset licensing

The downloadable demo should be distributed separately from the standalone Marschner hair addon so users can clearly distinguish the permissive runtime package from the non-commercial demo assets.

## Recommended release split

### Runtime addon

The standalone addon contains only the production runtime under:

```text
addons/marschner_hair/**
```

This package is distributed under the repository's MIT License, while retaining any applicable third-party notices for incorporated MIT-licensed source/reference material.

The runtime addon must not contain the demo hair-card dataset under `assets/hair/models/**`.

### Demo package

The demo download contains the scene/project material required to try the shader with the supplied hair-card examples. The hair-card models and their associated groom maps originate from CT2Hair and the GodotHair adaptation pipeline and remain licensed under **Creative Commons Attribution-NonCommercial 4.0 International (CC BY-NC 4.0)**.

A demo archive may also contain MIT-licensed project code or a copy of the runtime addon. The archive is therefore a **mixed-license distribution** rather than a package in which every file is relicensed under CC BY-NC 4.0:

- project/addon code and documentation: MIT, except where another notice says otherwise;
- demo hair-card models and associated groom maps: CC BY-NC 4.0.

The presence of MIT code in the demo does not remove the NonCommercial restriction from the CC BY-NC demo assets.

## Demo package contents

A demo release should include at minimum:

```text
README.md
LICENSE                         # MIT project/runtime license
THIRD_PARTY_NOTICES.md
assets/hair/models/LICENSE.md   # demo-asset CC BY-NC notice
addons/marschner_hair/**        # embedded copy of the matching addon build
demo scene / demo resources
demo hair-card models and groom maps
```

The embedded addon should be byte-for-byte identical to the matching standalone addon archive. The demo is a consumer of that build, not a separately maintained copy of the shader implementation.

The demo README should prominently state before installation/use that the bundled hair-card assets are **CC BY-NC 4.0** and are intended for evaluation, learning, and non-commercial adaptation unless the user separately obtains rights permitting another use.

## Demo release videos

The demo release should also include or link a small standardized media set:

```text
quality-tiers.mp4
fast-wetness.mp4
cinematic-wetness.mp4
```

These project-supplied videos visibly reproduce the CC BY-NC demo groom, so they are distributed with the **demo media under CC BY-NC 4.0**, not as MIT addon assets. Each capture contains an in-frame attribution and the release description must repeat the attribution/license notice.

The deterministic capture workflow is documented in [`release_media.md`](release_media.md). It uses Godot Movie Maker mode and the original GodotHair camera-orbit convention so every quality tier is recorded from the same camera path.

The videos are release/presentation artifacts and should not be placed inside `addons/marschner_hair/`.

## Attribution

The demo package should preserve the attribution recorded in `THIRD_PARTY_NOTICES.md` and `assets/hair/models/LICENSE.md`, including:

- CT2Hair and its authors / Meta Research as the original dataset source;
- GodotHair / Ethan Truong as the hair-card adaptation source;
- the CC BY-NC 4.0 license notice;
- an indication that additional Godot integration/packaging changes are present in this repository.

The same attribution should accompany project-published screenshots and videos that visibly reproduce the supplied demo groom.

## Validation relationship

Validate the two deliverables in order:

1. Build and validate the standalone MIT addon package.
2. Construct the demo package using that exact addon build.
3. Validate the demo project and all bundled groom assets.
4. Record the release videos from the validated demo package rather than from a different development checkout.

This ordering ensures the media demonstrates the actual package users will download and prevents the demo from hiding an addon packaging/path regression.

The detailed package gates are maintained in [`release_validation.md`](release_validation.md).

## Versioning

The addon and demo downloads should carry matching version identifiers where practical, for example:

```text
marschner-hair-addon-0.1.0-rc3.zip
marschner-hair-demo-0.1.0-rc3.zip
```

They can be published as separate release artifacts or separate releases, but their descriptions should cross-reference the matching version so users know which demo was validated against which addon build.
