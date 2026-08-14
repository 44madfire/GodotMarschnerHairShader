shader_type spatial;
render_mode cull_disabled, world_vertex_coords, alpha_to_coverage;

/** Base hair color. Used for visible strand color, absorption reparameterization, and the multiple-scattering approximation. */
uniform vec3 albedo : source_color = vec3(0.1);
/** Perceptual roughness along the fiber. Lower values produce tighter longitudinal R/TT/TRT highlights; higher values broaden them and increase shared card frizz. */
uniform float longitudinal_roughness : hint_range(0.0, 1.0) = 0.3;
/** Perceptual roughness around the fiber. Controls the analytic azimuthal scattering width; lower values are sharper and higher values are softer. */
uniform float azimuthal_roughness : hint_range(0.0, 1.0) = 0.8;
/** Master scale for the Cinematic Marschner single-scattering/specular contribution. */
uniform float specular : hint_range(0.0, 1.0) = 1.0;
/** Cuticle scale tilt in radians. Shifts/separates the R, TT, and TRT longitudinal lobes while preserving the non-separable Cinematic geometry. */
uniform float cuticle_tilt_offset : hint_range(0.0, 0.5) = 0.1;

group_uniforms textures;
/** Groom geometry texture. RGB stores the strand tangent encoded from [-1, 1] into [0, 1]; A stores normalized root-to-tip position. */
uniform sampler2D coords_texture : filter_nearest;
/** Groom attribute texture. R stores coverage/occupancy, G stores strand depth, and B stores a deterministic per-strand seed used for variation/debugging. */
uniform sampler2D attributes_texture : filter_nearest;
/** Conditioned 128x128x64 R16F longitudinal kernel LUT. R stores log2(Q); HairMarschnerLUTAdapter binds the packaged texture automatically. */
uniform sampler3D cinematic_longitudinal_lut : filter_linear, repeat_disable;
group_uniforms;

group_uniforms Cinematic;
/** Fiber index of refraction used by the Cinematic Fresnel, refraction, and attenuation terms. Unlike Fast Marschner, this value remains authorable. */
uniform float ior : hint_range(1.0, 2.0) = 1.55;
/** Beta domain encoded along the longitudinal LUT's Z axis. The packaged LUT uses (0.05, 64.0); only change this when supplying a matching custom LUT. */
uniform vec2 cinematic_longitudinal_beta_range = vec2(0.05, 64.0);
/** Analytic-to-LUT transition thresholds for narrow longitudinal lobes. The packaged contract uses analytic evaluation through 0.05 and blends to LUT evaluation by 0.10. */
uniform vec2 cinematic_longitudinal_low_beta_blend = vec2(0.05, 0.10);
group_uniforms;

group_uniforms Debug;
/** Renders the full card geometry at full alpha. Use this to inspect card placement and UVs; disable it for final hair rendering. */
uniform bool show_hair_cards = false;
/** Replaces the authored hair color with deterministic per-strand hash colors so seed distribution and strand grouping are easy to inspect. */
uniform bool show_hashed_strands = false;
/** Per-lobe debug multiplier: X = R reflection, Y = TT transmission, Z = TRT internal-reflection/transmission. Keep at (1,1,1) for normal rendering. */
uniform vec3 lobe_scales = vec3(1.0);
group_uniforms;

group_uniforms Preview;
/** Presentation-only exposure multiplier used by visual comparison/validation scenes. Leave at 1.0 for normal rendering. */
uniform float comparison_exposure_gain : hint_range(0.25, 8.0) = 1.0;
group_uniforms;

group_uniforms Validation;
/** Applies Godot's area-light specular multiplier to the Cinematic Marschner contribution. Keep enabled for normal rendering; disable only for controlled validation comparisons. */
uniform bool use_area_light_multipliers = true;
group_uniforms;

#define R 0
#define TT 1
#define TRT 2

varying vec3 vertex_world;
varying vec3 absorption_coefficient;
varying vec2 beta_reparam;
varying mat3 inv_tangent_matrix;
varying vec3 omega_o;

#define HAIR_COVERAGE_ALPHA_TO_COVERAGE
#include "./hair_marschner_common.gdshaderinc"
#include "./hair_card_common.gdshaderinc"
#include "./hair_marschner_cinematic_body.gdshaderinc"