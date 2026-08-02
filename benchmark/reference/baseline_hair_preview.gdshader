// Preview-only variant of baseline_hair.gdshader: identical rendering
// code and material interface, plus the opt-in freeze_bayer_phase uniform
// used by interactive previews. Timed benchmarks keep using the original
// baseline shader so its bytes and behavior never change.
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

group_uniforms Preview;
/** Freezes the Bayer phase for deterministic interactive previews. Default false
 *  preserves the production TIME-driven behavior for benchmark runs. */
uniform bool freeze_bayer_phase = false;
group_uniforms;

#include "./hair.gdshaderinc"

varying vec3 vertex_world;
varying vec3 absorbtion_coefficient;
varying vec2 beta;
varying mat3 inv_tangent_matrix; // inverse TBN Matrix

/** Returns a random vec3 in [0, 1) using PCG hash. */
// Source: https://www.shadertoy.com/view/XlGcRh
vec3 hash13(float p) {
	uvec3 v = uvec3(floatBitsToUint(p), 0u, 0u);

	v = v * 1664525u + 1013904223u; // pcg3d
	v.x += v.y*v.z; v.y += v.z*v.x; v.z += v.x*v.y;
	v ^= v >> 16u;
	v.x += v.y*v.z; v.y += v.z*v.x; v.z += v.x*v.y;

	return uintBitsToFloat((v & uvec3(0x007FFFFFu)) | uvec3(0x3F800000u)) - 1.0;
}


/** Schlick's Bias Approximation */
// Source: https://blog.demofox.org/2012/09/24/bias-and-gain-are-your-friend/
float power(float x, float t) {
	return x / ((1.0/t - 2.0)*(1.0 - x) + 1.0);
}


void vertex() {
	vertex_world = VERTEX;
}


void fragment() {
	// Called for every pixel the material is visible on.
	vec3 tangent = texture(coords_texture, UV).rgb*2.0 - 1.0;
	float u = texture(coords_texture, UV).a;            // 0->1 from base of strand to tip.
	float coverage = texture(attributes_texture, UV).r; // Alpha
	float depth = texture(attributes_texture, UV).g;    // 0->1 from deep hair to shallow hair
	float seed = texture(attributes_texture, UV).b;
	beta = vec2(longitudinal_roughness, azimuthal_roughness);

	// --- Alpha Hashing ---
	// We'll use a simpler alpha hash implementation which uses a Bayer matrix for dithering.
	const mat4 bayer4x4 = mat4(
		vec4(0.01,  8.0,  2.0, 10.0),
		vec4(12.0,  4.0, 14.0,  6.0),
		vec4( 3.0, 11.0,  1.0,  9.0),
		vec4(15.0,  7.0, 13.0,  5.0)) / 16.0;

	float bayer_time = freeze_bayer_phase ? 0.0 : TIME;
	ivec2 id = ivec2(FRAGCOORD.xy + UV.xy*vec2(textureSize(attributes_texture, 0)*2) + bayer_time*500.0); // FIXME: uh oh! this code is ass!
	float dist = length((CAMERA_POSITION_WORLD - vertex_world) / MODEL_MATRIX[0].xyz) / tan(PI/6.0) / PROJECTION_MATRIX[1][1];
	float bias = max((1.0 - clamp((dist - 1.0)*0.5, 0.0, 1.0))*(1.0 - depth*depth), 0.1);
	// Note: if standard alpha blending is used (as opposed to alpha hashing), the output of the BSDF
	//       would need to be multiplied by the coverage value.
	if (!show_hair_cards && pow(coverage, bias) < bayer4x4[id.x % 4][id.y % 4]) discard;

	// --- Built-ins ---
	vec3 hash = hash13(seed);
	// Darken strands towards the roots to simulate self shadowing.
	ALBEDO = show_hashed_strands ? hash : albedo * smoothstep(-0.2, 0.2, u*(1.0 - coverage));
	SPECULAR = specular;
	ROUGHNESS = beta[M];

	// --- Tangent (TBN) Matrix Calculation ---
	// We define a 'frizziness' factor that depends on roughness as well as how far along
	// the strand we are (assuming hair further along the strand is more 'damaged').
	// FIXME: Probably better to expose this as a uniform...
	float frizz = 0.5 * beta[M] * power(u, 1.0 - beta[M]);

	// Purturb the tangent in a per-strand random direction to simulate hair frizz.
	TANGENT = normalize(mat3(TANGENT, BINORMAL, NORMAL)*tangent + (hash*2.0 - 1.0)*frizz);
	NORMAL = normalize(NORMAL - TANGENT*dot(NORMAL, TANGENT));
	BINORMAL = cross(TANGENT, NORMAL);

	inv_tangent_matrix = transpose(mat3(TANGENT, BINORMAL, NORMAL));

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