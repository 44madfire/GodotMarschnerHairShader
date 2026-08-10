# Consolidated hair material authoring

The production hair models remain separate compiled shaders, but artists and runtime callers should treat `HairMaterialProfile` as the single material-look authoring surface and `HairGroomData` as the groom-specific card-data surface.

This deliberately avoids one runtime-branching mega-shader. Approx/Kajiya-Kay, Unity Fast, Cinematic, and analytic Reference keep independent shader binaries and benchmark identities while sharing the card preparation contract.

## Material profile versus groom data

The two resources own different things:

```text
HairMaterialProfile                 HairGroomData
-------------------                 -------------
shader mode                         coords texture
hair color                          attributes texture
roughness
specular strength
cuticle tilt
absorption / melanin
mode-specific LUT overrides
```

`HairMaterialProfile` is reusable across multiple grooms. `HairGroomData` belongs to one generated card atlas and contains the maps produced with that groom.

The shared texture contract is:

```text
coords_texture
  RGB = tangent direction, encoded [0,1] for a [-1,1] vector
  A   = root-to-tip coordinate

attributes_texture
  R = coverage / occupancy
  G = strand depth
  B = deterministic per-strand seed
```

This replaces the previous authoring assumption that those textures had to already exist as parameters on a generated `hair.gdshader` source material.

## Creating a new groom

Create a `HairGroomData` resource and assign the two generated textures in the Inspector. Then either apply it to an existing `ShaderMaterial`:

```gdscript
var ok: bool = profile.apply_to(shader_material, groom_data)
```

or create the hair material from scratch:

```gdscript
var material: ShaderMaterial = profile.create_material(groom_data)
hair_mesh.material_override = material
```

No pre-authored hair `ShaderMaterial` is required for this path.

For migration, `HairGroomData.from_shader_material(old_material)` can capture `coords_texture` and `attributes_texture` from an existing generated source material without modifying it.

## Shader mode

`HairMaterialProfile.quality_tier` is serialized with the existing integer mapping:

```text
0  Approx / Kajiya-Kay
1  Fast Marschner
2  Cinematic Marschner
3  Reference Marschner
```

The Inspector presents those values with friendly dropdown labels. Changing the dropdown refreshes the profile property list and hides controls that do not affect the selected compiled shader. Hidden fields remain serialized, so switching away from a mode and back does not discard its previous settings.

## Visible controls by mode

Common controls remain available to the production Marschner variants:

- albedo;
- longitudinal roughness;
- azimuthal roughness;
- specular strength;
- cuticle tilt.

Approx keeps albedo, longitudinal roughness/frizz behavior, and specular, then exposes its Kajiya-Kay primary/secondary lobe colors, shifts, roughnesses, strengths, and scatter. Approx hides azimuthal roughness and cuticle tilt because the current Kajiya-Kay implementation does not consume them.

Fast exposes its absorption model and optional Unity azimuthal LUT override. Its IOR control is intentionally hidden: the Unity Standard azimuthal/modified-refraction contract is baked for eta `1.55`, and `HairMarschnerLUTAdapter` pins the shader to the LUT metadata. The absorption selector further controls its own Inspector surface:

```text
Albedo reparameterization -> no extra absorption fields
Direct absorption         -> absorption / sigma_a
Melanin                   -> eumelanin, pheomelanin, absorption scale
```

Cinematic exposes arbitrary IOR plus the optional conditioned longitudinal LUT override. Reference intentionally exposes no additional profile controls beyond its existing analytic shader interface.

## Applying a profile

`apply_to()` performs the whole mode switch:

1. chooses the compiled shader variant for `quality_tier`;
2. captures caller-owned parameters from the previous shader;
3. assigns the selected shader;
4. restores caller-owned parameters that also exist on the target shader;
5. applies profile values supported by the target shader;
6. binds the LUT required by Fast or Cinematic;
7. when `HairGroomData` is supplied, explicitly binds the groom's two generated card textures.

The parameters preserved across shader swaps are currently:

```text
coords_texture
attributes_texture
show_hair_cards
show_hashed_strands
freeze_bayer_phase
comparison_exposure_gain
lobe_scales
use_area_light_multipliers
```

Preservation keeps older source-material workflows working. Explicit `HairGroomData` takes precedence for new grooms and rebinds the two texture parameters after the shader change.

`apply_to_shader_material()` remains as a compatibility API for benchmark and experimental callers that deliberately select a shader themselves. It applies supported profile values and resources to the material's current shader but does not replace that shader.

`bind_quality_resources()` is likewise retained as a compatibility alias for `bind_mode_resources()`.

## Shared card preparation

All four production variants now include `hair_card_common.gdshaderinc` for the behavior that is independent of the lighting model:

```text
coverage/depth Bayer discard
root-to-tip base-color darkening
per-strand hash
frizz amount and tangent perturbation
orthonormal TBN reconstruction
```

The top-level shaders still declare `coords_texture` and `attributes_texture` themselves because Godot 4.7 uniform reflection is unreliable when material interfaces exist only inside nested includes. The include centralizes math, not the reflected material interface.

Fast, Cinematic, Approx, and Reference still own their distinct BSDF code. This refactor does not merge the lighting models or change the validated Fast/Cinematic LUT representations.

## Editor preview demo

Open `demos/HairMaterialProfileEditor.tscn` in the Godot editor. The root node now exposes both:

```text
material_profile
groom_data
```

The demo uses `demos/resources/blowout_groom_data.tres`, which directly references the Blowout coords/attributes maps. There is no source hair `ShaderMaterial` containing those texture assignments in the demo anymore; the preview creates its local `ShaderMaterial` and composes the profile with the groom data.

`groom_source_material` remains an optional fallback on the preview script for older imported/generated assets during migration. It is not required for a new groom.

Fast and Cinematic need the generated LUT resources. If those resources are absent, the profile still selects the shader variant but the preview reports a warning until the LUTs are generated.

## Why the shaders stay split

The dropdown is an authoring/runtime material decision, not a uniform branch inside one shader program. Keeping separate compiled variants means Fast does not carry the Cinematic longitudinal LUT or analytic Reference machinery, Cinematic does not carry the Unity azimuthal LUT, and Approx does not carry Marschner code at all.

That preserves:

- independent shader compilation;
- independent sampler/register pressure;
- mode-specific resource binding;
- no runtime `if/else` over complete BSDF implementations;
- clean attribution when a tier changes performance or rendering behavior.

## Validation

The existing production profile test still covers shader selection, dynamic Inspector visibility, LUT reconstruction/binding, Fast eta pinning, and Cinematic metadata:

```bash
godot --headless --path . --script res://benchmark/tests/test_marschner_production_profile.gd
```

The new LUT-independent groom/card smoke test verifies that every production shader exposes the shared texture contract and that a material can be created from a profile plus `HairGroomData` without a source material:

```bash
godot --headless --path . --script res://benchmark/tests/test_hair_groom_binding.gd
```
