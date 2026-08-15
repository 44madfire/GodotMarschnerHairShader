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
addons/marschner_hair/**        # optional embedded copy of the matching addon build
demo scene / demo resources
demo hair-card models and groom maps
```

The demo README should prominently state before installation/use that the bundled hair-card assets are **CC BY-NC 4.0** and are intended for evaluation, learning, and non-commercial adaptation unless the user separately obtains rights permitting another use.

## Attribution

The demo package should preserve the attribution recorded in `THIRD_PARTY_NOTICES.md` and `assets/hair/models/LICENSE.md`, including:

- CT2Hair and its authors / Meta Research as the original dataset source;
- GodotHair / Ethan Truong as the hair-card adaptation source;
- the CC BY-NC 4.0 license notice;
- an indication that additional Godot integration/packaging changes are present in this repository.

## Versioning

The addon and demo downloads should carry matching version identifiers where practical, for example:

```text
marschner-hair-addon-0.1.0-rc3.zip
marschner-hair-demo-0.1.0-rc3.zip
```

They can be published as separate release artifacts or separate releases, but their descriptions should cross-reference the matching version so users know which demo was validated against which addon build.
