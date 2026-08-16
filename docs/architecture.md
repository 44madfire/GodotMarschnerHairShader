# Marschner Hair Addon Architecture

The release addon is intentionally split into **authoring data**, **groom data**, **coverage policy**, and **compiled shader tiers**. The three release tiers share one public material API without sharing one generalized lighting implementation.

```text
HairMaterialProfile            HairGroomData
(appearance + tier)            (card atlas data)
        |                            |
        +------------+---------------+
                     |
              ShaderMaterial
                     |
       +-------------+-------------+
       |             |             |
    Approx          Fast       Cinematic
  Kajiya-Kay      Marschner     Marschner
       |             |             |
       |        Fast 3D LUT    Longitudinal
       |             |          3D LUT
       +-------------+-------------+
                     |
          HairCoverageController
       (optional runtime AA policy)
```

## Public resources

### `HairMaterialProfile`

`hair_material_profile.gd` is the user-facing appearance resource. It owns parameters such as color, longitudinal/azimuthal roughness, cuticle tilt, wetness, and tier-specific controls. Its main APIs are:

```gdscript
var material := profile.create_material(groom_data, viewport)
profile.apply_to(material, groom_data, viewport)
```

The profile chooses one of three release tiers:

| Tier | Purpose | Production LUT |
| --- | --- | --- |
| Approx / Kajiya-Kay | inexpensive fallback | none |
| Fast Marschner | Unity HDRP Standard-style approximation | 64×64×64 RGBA16F azimuthal LUT |
| Cinematic Marschner | higher-fidelity non-separable model | 128×128×64 R16F longitudinal LUT |

Each tier has a normal ordered-dither shader and an alpha-to-coverage variant. The wrappers remain separate compiled shaders so Godot can select the correct render mode.

### `HairGroomData`

`hair_groom_data.gd` owns generated card-atlas data rather than appearance:

- `coords_texture`: RGB tangent direction, A root-to-tip coordinate.
- `attributes_texture`: R coverage, G strand depth, B deterministic strand seed.

This separation lets one material profile be reused across multiple grooms without moving geometry-specific data into the appearance resource.

## Coverage

`hair_coverage_policy.gd` resolves the requested coverage mode against the current renderer and viewport AA settings:

- MSAA → alpha-to-coverage.
- Forward+ TAA → temporal 16-phase Bayer coverage.
- Otherwise → stable Bayer coverage.

`hair_coverage_controller.gd` is optional runtime glue. Register a material when AUTO coverage should track viewport AA state after creation.

## Shader layout

```text
shaders/
├── hair_approx.gdshader
├── hair_approx_a2c.gdshader
├── hair_kajiya_kay.gdshaderinc
├── hair_marschner_fast.gdshader
├── hair_marschner_fast_a2c.gdshader
├── hair_marschner_fast_body.gdshaderinc
├── hair_marschner_cinematic.gdshader
├── hair_marschner_cinematic_a2c.gdshader
├── hair_marschner_cinematic_body.gdshaderinc
├── hair_marschner_common.gdshaderinc
└── hair_card_common.gdshaderinc
```

Top-level `.gdshader` files intentionally own their uniform declarations. Godot 4.7 runtime uniform reflection is not reliable when an interface is declared only inside nested includes. Shared mathematical implementations and card preparation remain in `.gdshaderinc` files.

The former full analytic Reference Marschner implementation was a development/validation tier and is intentionally **not distributed in the release addon**.

## LUT binding

`hair_marschner_lut_adapter.gd` validates packaged `ImageTexture3D` resources before binding them. It checks dimensions, image format, and rendering RID. Fast Marschner is calibrated to eta 1.55; Cinematic Marschner keeps authorable IOR and uses its conditioned longitudinal kernel contract.

## Internal utilities

`internal/hair_shader_utils.gd` centralizes shader-uniform reflection and parameter preservation. Public resources use it when switching compiled tiers so groom/debug parameters survive shader replacement when both variants expose the same uniform.
