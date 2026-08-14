shader_type spatial;
render_mode cull_disabled, world_vertex_coords, alpha_to_coverage;

#define USE_ROUGHNESS_REPARAMETERIZTION

/** Base hair color. Used for visible strand color, absorption reparameterization, and the multiple-scattering approximation. */
uniform vec3 albedo : source_color = vec3(0.1);
/** Perceptual roughness [i]along[/i] the fiber. Lower values produce tighter longitudinal highlights; higher values broaden and soften them. */
uniform float longitudinal_roughness : hint_range(0.0, 1.0) = 0.3;
/** Perceptual roughness [i]around[/i] the fiber. Lower values produce tighter azimuthal scattering; higher values broaden and soften it. */
uniform float azimuthal_roughness : hint_range(0.0, 1.0) = 0.8;
/** Master scale for the single-scattering/specular contribution. */
uniform float specular : hint_range(0.0, 1.0) = 1.0;
/** Cuticle scale tilt in radians. Increasing this separates the R, TT, and TRT longitudinal highlight lobes. */
uniform float cuticle_tilt_offset : hint_range(0.0, 0.5) = 0.1;

group_uniforms textures;
/** Groom geometry texture. RGB stores the strand tangent encoded from [-1, 1] into [0, 1]; A stores normalized root-to-tip position. */
uniform sampler2D coords_texture : filter_nearest;
/** Groom attribute texture. R stores coverage/occupancy, G stores strand depth, and B stores a deterministic per-strand seed used for variation/debugging. */
uniform sampler2D attributes_texture : filter_nearest;
group_uniforms;

group_uniforms Debug;
/** Renders the full card geometry at full alpha. Use this to inspect card placement and UVs; disable it for final hair rendering. */
uniform bool show_hair_cards = false;
/** Replaces the authored hair color with deterministic per-strand hash colors so seed distribution and strand grouping are easy to inspect. */
uniform bool show_hashed_strands = false;
/** Per-lobe debug multiplier: X = R reflection, Y = TT transmission, Z = TRT internal-reflection/transmission. Keep at (1,1,1) for normal rendering. */
uniform vec3 lobe_scales = vec3(1.0);
group_uniforms;

#include "./hair_marschner_common.gdshaderinc"
#include "./hair_card_common.gdshaderinc"
#include "./hair.gdshaderinc"

varying vec3 vertex_world;
varying vec3 absorbtion_coefficient;
varying vec2 beta;
varying mat3 inv_tangent_matrix;

void vertex() {
	vertex_world = VERTEX;
}

void fragment() {
	vec4 coords_sample = texture(coords_texture, UV);
	vec3 attributes_sample = texture(attributes_texture, UV).rgb;
	vec3 tangent_texture_value = coords_sample.rgb * 2.0 - 1.0;
	float u = coords_sample.a;
	float coverage = attributes_sample.r;
	float depth = attributes_sample.g;
	float seed = attributes_sample.b;
	beta = vec2(longitudinal_roughness, azimuthal_roughness);

	ALPHA = show_hair_cards ? 1.0 : hair_card_adjusted_coverage(
		coverage,
		depth,
		vertex_world,
		CAMERA_POSITION_WORLD,
		MODEL_MATRIX[0].xyz,
		PROJECTION_MATRIX[1][1]);

	vec3 hash = hair_hash13(seed);
	ALBEDO = hair_card_base_albedo(albedo, u, coverage, hash, show_hashed_strands);
	SPECULAR = specular;
	ROUGHNESS = beta[M];
	TANGENT = hair_card_frizzed_tangent(mat3(TANGENT, BINORMAL, NORMAL), tangent_texture_value, hash, u, beta[M]);
	mat3 strand_frame = hair_card_orthonormal_frame(TANGENT, NORMAL);
	TANGENT = strand_frame[0];
	BINORMAL = strand_frame[1];
	NORMAL = strand_frame[2];
	inv_tangent_matrix = transpose(strand_frame);

	absorbtion_coefficient = log(albedo) / (5.969 + beta[N]*(-0.215 + beta[N]*(2.532 + beta[N]*(-10.73 + beta[N]*(5.574 + beta[N]*0.245)))));
	absorbtion_coefficient *= absorbtion_coefficient;
#ifdef USE_ROUGHNESS_REPARAMETERIZTION
	beta = max(vec2(1e-3), mix(0.8, 1.2, seed)*vec2(
		0.726*beta[M] + 0.812*beta[M]*beta[M] + 3.700*pow(beta[M], 20),
		0.265*beta[N] + 1.194*beta[N]*beta[N] + 5.372*pow(beta[N], 22)));
#endif
}

void light() {
	vec3 omega_i = inv_tangent_matrix * LIGHT;
	vec3 omega_o = inv_tangent_matrix * VIEW;
	vec3 single_scattering = hair_BSDF(omega_i, omega_o, -cuticle_tilt_offset, beta, absorbtion_coefficient);
	SPECULAR_LIGHT += single_scattering * LIGHT_COLOR * ATTENUATION * specular;
	float luminance = dot(ALBEDO, vec3(0.299, 0.587, 0.114));
	vec3 multiple_scattering = 0.25 * sqrt(ALBEDO)*(dot(omega_i.yz, normalize(omega_o.yz)) + 1.0) * pow(ALBEDO / luminance, vec3(ATTENUATION));
	DIFFUSE_LIGHT += multiple_scattering * smoothstep(-0.5, 1.0, ATTENUATION) * LIGHT_COLOR / PI;
}