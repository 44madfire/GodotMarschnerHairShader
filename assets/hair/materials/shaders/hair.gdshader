shader_type spatial;
render_mode cull_disabled, world_vertex_coords;

// If defined, uses the perceptual roughness reparameterization expression described in
// "A Practical and Controllable Hair and Fur Model for Production Path Tracing" (Chiang et al., 2016)
#define USE_ROUGHNESS_REPARAMETERIZTION

/** The averaged multiple-scattering color of the hair. */
uniform vec3 albedo : source_color = vec3(0.1);

/** Controls the highlight width (in radians) [i]along[/i] hair strands. Effectively controls the overall [i]shininess[/i] of the hair. */
uniform float longitudinal_roughness : hint_range(0.0, 1.0) = 0.3;

/** Controls the highlight width (in radians) [i]around[/i] hair strands. Effectively controls the overall [i]softness[/i] of the hair. */
uniform float azimuthal_roughness : hint_range(0.0, 1.0) = 0.8;

/** Adjusts the single-scattering (highlight) strength of the hair. */
uniform float specular : hint_range(0.0, 1.0) = 1.0;

/** Adjusts the angled offset (in radians) of cuticle scales—a positive value denotes an outward tilt. Increasing causes the highlights of lobes to separate. */
uniform float cuticle_tilt_offset : hint_range(0.0, 0.5) = 0.1;

group_uniforms textures;
/** Texture containing geometric data for hair orientation and parameterization. Channels are packed as follows:
 * [code]RGB[/code]  ([b]Tangent[/b]): The local [b]tangent[/b] direction in tangent space. Note that data is packed in [0..1], but represents [-1..1] vector values.
 * [code]A[/code]  ([b]U Coordinate[/b]): A normalized parameter (in [0..1]) varying along root to tip of the hair strands. Can be used for color gradients that vary along strand.
 */
uniform sampler2D coords_texture : filter_nearest;

/** Texture containing physical attributes for lighting. Channels are packed as follows:
 * [code]R[/code]  ([b]Coverage[/b]): The pixel occupancy (i.e., alpha) of the strand.
 * [code]G[/code]  ([b]Depth[/b]): A per-strand factor (in [0..1]) denoting occluded/deep strands to shallow strands. Can be used to vary the transmittance of light hitting a strand through the hair volume to simulate global scattering.
 * For more information, see "Dual Scattering Approximation for Fast Multiple Scattering in Hair" (Zinke et al., 2008).
 * [code]B[/code]  ([b]Seed[/b]): A per-strand random value (in [0..1]). Can be used to vary roughness and tangent direction, preventing the hair from looking uniformly plastic.
 */
uniform sampler2D attributes_texture : filter_nearest;
group_uniforms;

group_uniforms Debug;
uniform bool show_hair_cards = false;
uniform bool show_hashed_strands = false;
group_uniforms;

#include "./hair_marschner_common.gdshaderinc"
#include "./hair_card_common.gdshaderinc"
#include "./hair.gdshaderinc"

varying vec3 vertex_world;
varying vec3 absorbtion_coefficient;
varying vec2 beta;
varying mat3 inv_tangent_matrix; // inverse TBN Matrix


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

	// Reference keeps its original TIME-driven Bayer phase; production preview
	// variants may freeze the phase with their explicit preview uniform.
	if (!hair_card_should_keep(
		coverage,
		depth,
		vertex_world,
		UV,
		FRAGCOORD.xy,
		textureSize(attributes_texture, 0),
		TIME,
		show_hair_cards,
		CAMERA_POSITION_WORLD,
		MODEL_MATRIX[0].xyz,
		PROJECTION_MATRIX[1][1])) discard;

	vec3 hash = hair_hash13(seed);
	ALBEDO = hair_card_base_albedo(albedo, u, coverage, hash, show_hashed_strands);
	SPECULAR = specular;
	ROUGHNESS = beta[M];

	TANGENT = hair_card_frizzed_tangent(
		mat3(TANGENT, BINORMAL, NORMAL),
		tangent_texture_value,
		hash,
		u,
		beta[M]);
	mat3 strand_frame = hair_card_orthonormal_frame(TANGENT, NORMAL);
	TANGENT = strand_frame[0];
	BINORMAL = strand_frame[1];
	NORMAL = strand_frame[2];
	inv_tangent_matrix = transpose(strand_frame);

	// --- Reparameterization ---
	// Source: "A Practical and Controllable Hair and Fur Model for Production Path Tracing" (Chiang et al., 2016)
	// Note: All of theses can be precomputed on the CPU, but I shall leave them here for easier access...

	// Calculate absorbtion coefficient from the user-defined albedo
	absorbtion_coefficient = log(albedo) / (5.969 + beta[N]*(-0.215 + beta[N]*(2.532 + beta[N]*(-10.73 + beta[N]*(5.574 + beta[N]*0.245)))));
	absorbtion_coefficient *= absorbtion_coefficient;

#ifdef USE_ROUGHNESS_REPARAMETERIZTION
	beta = max(vec2(1e-3), mix(0.8, 1.2, seed)*vec2(
		0.726*beta[M] + 0.812*beta[M]*beta[M] + 3.700*pow(beta[M], 20),
		0.265*beta[N] + 1.194*beta[N]*beta[N] + 5.372*pow(beta[N], 22)));
#endif
}


void light() {
	// Called for every pixel for every light affecting the material.
	// Uncomment to replace the default light processing function with this one.

	// Project light and view in (hair) tangent space
	vec3 omega_i = inv_tangent_matrix * LIGHT; // [sin(θ_i),  cos(θ_i)*cos(φ_i), cos(θ_i)*sin(φ_i)]
	vec3 omega_o = inv_tangent_matrix * VIEW;  // [sin(θ_o),  cos(θ_o)*cos(φ_o), cos(θ_o)*sin(φ_o)]

	vec3 single_scattering = hair_BSDF(omega_i, omega_o, -cuticle_tilt_offset, beta, absorbtion_coefficient);
	SPECULAR_LIGHT += single_scattering * LIGHT_COLOR * ATTENUATION * specular;

	// Fake multiple scattering approximation. Not physically-based.
	// Source: "Physically Based Hair Shading in Unreal" (Karis, 2016)
	float luminance = dot(ALBEDO, vec3(0.299, 0.587, 0.114));
	vec3 multiple_scattering = 0.25 * sqrt(ALBEDO)*(dot(omega_i.yz, normalize(omega_o.yz)) + 1.0) * pow(ALBEDO / luminance, vec3(ATTENUATION));
	DIFFUSE_LIGHT += multiple_scattering * smoothstep(-0.5, 1.0, ATTENUATION) * LIGHT_COLOR / PI;
}