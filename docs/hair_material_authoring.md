# Consolidated hair material authoring

The production hair models remain separate compiled shaders, but artists and runtime callers should treat `HairMaterialProfile` as the single authoring surface.

This deliberately avoids one runtime-branching mega-shader. Approx/Kajiya-Kay, Unity Fast, Cinematic, and analytic Reference keep independent shader binaries, sampler interfaces, and benchmark identities while the profile owns mode selection and parameter presentation.

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

New production/runtime code should prefer:

```gdscript
var ok: bool = profile.apply_to(shader_material)
```

`apply_to()` performs the whole mode switch:

1. chooses the compiled shader variant for `quality_tier`;
2. captures caller-owned parameters from the previous shader;
3. assigns the selected shader;
4. restores caller-owned parameters that also exist on the target shader;
5. applies profile values supported by the target shader;
6. binds the LUT required by Fast or Cinematic.

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

This keeps groom textures and benchmark/debug state attached to the material while the lighting model changes.

`apply_to_shader_material()` remains as a compatibility API for benchmark and experimental callers that deliberately select a shader themselves. It applies supported profile values and resources to the material's current shader but does not replace that shader.

`bind_quality_resources()` is likewise retained as a compatibility alias for the new `bind_mode_resources()` name.

## Editor preview demo

Open `demos/HairMaterialProfileEditor.tscn` in the Godot editor. Select the
`HairMaterialProfileEditor` root node and expand its `Material Profile`
property. The scene assigns the editable resource
`demos/resources/hair_material_profile_demo.tres`, so you can open that
resource in the Inspector and change its `quality_tier` dropdown:

```text
Approx / Kajiya-Kay
Fast Marschner
Cinematic Marschner
Reference Marschner
```

The `@tool` preview updates the visible Blowout groom in the 3D viewport as
soon as the resource changes; play mode is not required. The scene starts from
a copy of the groom's source `ShaderMaterial` and applies the profile to that
copy as a `material_override`, so imported materials and other scenes are not
mutated. Its camera, environment, key, fill, and rim lights are also useful
when running the scene directly.

Fast and Cinematic need the generated LUT resources described below. If those
resources are absent, the profile still selects the shader variant but the
preview script reports a warning and the selected tier cannot render its full
lighting path until the LUTs are generated.

## Why the shaders stay split

The dropdown is an authoring/runtime material decision, not a uniform branch inside one shader program. Keeping separate compiled variants means Fast does not carry the Cinematic longitudinal LUT or analytic Reference machinery, Cinematic does not carry the Unity azimuthal LUT, and Approx does not carry Marschner code at all.

That preserves the properties needed for meaningful tier benchmarking:

- independent shader compilation;
- independent sampler/register pressure;
- mode-specific resource binding;
- no runtime `if/else` over complete BSDF implementations;
- clean attribution when a tier changes performance or rendering behavior.

## Validation

`benchmark/tests/test_marschner_production_profile.gd` covers the consolidated surface in addition to the existing LUT contracts. It checks:

- tier-to-shader selection;
- mode-specific Inspector property visibility;
- Fast absorption sub-mode visibility;
- automatic `apply_to()` shader switching;
- preservation of groom textures and common debug parameters across swaps;
- Fast eta pinning and Unity LUT binding;
- Cinematic arbitrary IOR, LUT metadata, and low-beta transition binding;
- compatibility of the explicit-current-shader API.

Run it after the two generated LUT resources exist:

```bash
godot --headless --path . --script res://benchmark/tests/test_marschner_production_profile.gd
```
