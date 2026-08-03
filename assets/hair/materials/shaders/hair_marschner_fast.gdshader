shader_type spatial;
render_mode cull_disabled, world_vertex_coords;

/** The averaged reflectance/multiple-scattering color of the hair. */
uniform vec3 albedo : source_color = vec3(0.1);

/** Controls the highlight width (in radians) [i]along[/i] hair strands. */
uniform float longitudinal_roughness : hint_range(0.0, 1.0) = 0.3;

/** Controls the highlight width (in radians) [i]around[/i] hair strands. */
uniform float azimuthal_roughness : hint_range(0.0, 1.0) = 0.8;

/** Adjusts the single-scattering (highlight) strength of the hair. */
uniform float specular : hint_range(0.0, 1.0) = 1.0;

/** Adjusts the angled offset (in radians) of cuticle scales—a positive value denotes an outward tilt. */
uniform float cuticle_tilt_offset : hint_range(0.0, 0.5) = 0.1;

group_uniforms textures;
/** Texture containing tangent direction in RGB and root-to-tip U in A. */
uniform sampler2D coords_texture : filter_nearest;
/** Texture containing coverage in R, depth in G, and per-strand seed in B. */
uniform sampler2D attributes_texture : filter_nearest;
group_uniforms;

group_uniforms Debug;
uniform bool show_hair_cards = false;
uniform bool show_hashed_strands = false;
group_uniforms;

#include "./hair_marschner_fast.gdshaderinc"

varying vec3 vertex_world;
varying vec3 sigma_a;
varying mat3 inv_tangent_matrix; // inverse TBN Matrix
// Light-invariant scattering setup, computed once per fragment (after alpha
// discard) instead of once per light. These varyings are written in
// fragment(), so they carry exact per-fragment values, not interpolated ones.
varying vec3 omega_o;          // strand-space view vector
varying vec3 view_yz;          // x = cos(theta_o), yz = normalized omega_o.yz (Karis)
varying vec3 lobe_tilt_sin;    // sin of the per-lobe cuticle tilts (R/TT/TRT)
varying vec3 lobe_tilt_cos;    // cos of the per-lobe cuticle tilts (R/TT/TRT)
varying vec3 beta_m_inv;       // inverse longitudinal per-lobe widths
varying vec2 azimuthal_s_inv;  // TT/TRT logistic inverse azimuthal widths
varying vec2 logistic_b;       // TT/TRT logistic normalization exp(-2*sqrt(TAU)*s_inv)
varying float lut_azimuthal_width; // light-invariant LUT width axis (0..1)
varying float strand_depth;        // packed attributes depth (0 = deep, 1 = shallow; dual deepness proxy = 1 - depth)

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


void vertex() {
	vertex_world = VERTEX;
}


void fragment() {
	// Preserve the card contract: tangent/U, coverage/depth/seed, and the
	// current per-strand root-to-tip behavior all come from the same textures.
	vec3 tangent = texture(coords_texture, UV).rgb*2.0 - 1.0;
	float u = texture(coords_texture, UV).a;            // 0->1 from base of strand to tip.
	float coverage = texture(attributes_texture, UV).r; // Alpha
	float depth = texture(attributes_texture, UV).g;    // 0->1 from deep hair to shallow hair
	float seed = texture(attributes_texture, UV).b;
	vec2 beta = vec2(longitudinal_roughness, azimuthal_roughness);

	// --- Alpha Hashing ---
	// This is intentionally the same Bayer matrix and coverage/depth bias as
	// the current shader so the fast tier changes only the lighting model.
	const mat4 bayer4x4 = mat4(
		vec4(0.01,  8.0,  2.0, 10.0),
		vec4(12.0,  4.0, 14.0,  6.0),
		vec4( 3.0, 11.0,  1.0,  9.0),
		vec4(15.0,  7.0, 13.0,  5.0)) / 16.0;

	ivec2 id = ivec2(FRAGCOORD.xy + UV.xy*vec2(textureSize(attributes_texture, 0)*2) + TIME*500.0); // FIXME: uh oh! this code is ass!
	float dist = length((CAMERA_POSITION_WORLD - vertex_world) / MODEL_MATRIX[0].xyz) / tan(PI/6.0) / PROJECTION_MATRIX[1][1];
	float bias = max((1.0 - clamp((dist - 1.0)*0.5, 0.0, 1.0))*(1.0 - depth*depth), 0.1);
	if (!show_hair_cards && pow(coverage, bias) < bayer4x4[id.x % 4][id.y % 4]) discard;

	// Carry the packed depth channel into light() as the dual-scatter
	// density/visibility proxy.
	strand_depth = depth;

	// --- Built-ins ---
	vec3 hash = hash13(seed);
	// Keep the current darkening toward roots and the existing debug color.
	ALBEDO = show_hashed_strands ? hash : albedo * smoothstep(-0.2, 0.2, u*(1.0 - coverage));
	SPECULAR = specular;
	ROUGHNESS = beta.x;

	// --- Tangent (TBN) Matrix Calculation ---
	// This is the current per-strand frizz/TBN reconstruction used by the
	// high-quality shader, including its root-to-tip frizz progression.
	float frizz = 0.5 * beta.x * power(u, 1.0 - beta.x);
	TANGENT = normalize(mat3(TANGENT, BINORMAL, NORMAL)*tangent + (hash*2.0 - 1.0)*frizz);
	NORMAL = normalize(NORMAL - TANGENT*dot(NORMAL, TANGENT));
	BINORMAL = cross(TANGENT, NORMAL);
	inv_tangent_matrix = transpose(mat3(TANGENT, BINORMAL, NORMAL));

	// --- Absorption ---
	// Convert the artist-facing color/absorption/melanin inputs into the
	// canonical per-fiber sigma_a used by the Beer-Lambert attenuation.
	sigma_a = fm_absorption_coefficient(albedo, beta.y);

	// --- Hoisted light-invariant scattering setup ---
	// Everything below depends only on the view, the strand basis, and the
	// material uniforms, so it is computed once per fragment (after discard)
	// instead of once per light. Values and clamp/order semantics match the
	// previous per-light computations exactly.
	omega_o = inv_tangent_matrix * VIEW;

	// cos(theta_o) and the normalized omega_o.yz used by the Karis term. The
	// branch threshold (length squared > 1e-8) matches the previous code.
	float view_yz_length_squared = dot(omega_o.yz, omega_o.yz);
	float view_cos_theta = sqrt(view_yz_length_squared);
	vec2 view_yz_normalized = (view_yz_length_squared > 1e-8)
		? omega_o.yz * inversesqrt(view_yz_length_squared)
		: vec2(0.0, 1.0);
	view_yz = vec3(view_cos_theta, view_yz_normalized.x, view_yz_normalized.y);

	// Per-lobe cuticle tilt sin/cos: R = -alpha, TT = +0.5*alpha, TRT = +1.5*alpha.
	vec3 alpha_m = vec3(-1.0, 0.5, 1.5) * cuticle_tilt_offset;
	lobe_tilt_sin = sin(alpha_m);
	lobe_tilt_cos = cos(alpha_m);

	// Bounded roughness feeding the inverse longitudinal per-lobe widths
	// (R = beta, TT = 0.5*beta, TRT = 2.0*beta) and the TT/TRT logistic inverse
	// azimuthal widths. The clamps mirror the previous per-light math.
	vec2 beta_safe = clamp(beta, vec2(1e-3), vec2(1.0));
	beta_m_inv = 1.0 / (vec3(1.0, 0.5, 2.0) * max(beta_safe.x, 1e-3));
	azimuthal_s_inv = vec2(sqrt(2.0) / beta_safe.y, 0.5 * sqrt(2.0) / beta_safe.y);

	// Logistic normalization exp(-2*sqrt(TAU)*s_inv), light-invariant per lobe.
	logistic_b = exp(-2.0 * sqrt(TAU) * azimuthal_s_inv);

	// LUT width axis, matching the generator's beta axis [0.001, 1.0].
	lut_azimuthal_width = clamp((beta_safe.y - 0.001) * (1.0 / 0.999), 0.0, 1.0);

	// --- Environment (FAST_MARSCHNER_ENVIRONMENT, fragment-stage only) ---
	// One representative direction per fragment: the reflected view vector in
	// CAMERA space (this local stand-in is not world-space IBL; the equirect
	// mapping is applied to the camera-space direction), sampled from the
	// equirectangular environment and added via EMISSION so the term is
	// light-count invariant. TT (transmission) is skipped for the local slice;
	// R/TRT-compatible coloring uses the existing albedo and absorption
	// (sigma_a attenuates the TRT-like tint). Never writes light(), and the
	// sample is skipped in shadow passes where EMISSION is unused.
	if (use_environment && !IN_SHADOW_PASS) {
		vec3 env_dir = reflect(-VIEW, NORMAL);
		if (dot(env_dir, env_dir) < 1e-6) {
			env_dir = vec3(0.0, 1.0, 0.0);
		} else {
			env_dir = normalize(env_dir);
		}
		vec2 env_uv = vec2(
			0.5 + atan(env_dir.z, env_dir.x) / TAU,
			clamp(0.5 - asin(clamp(env_dir.y, -1.0, 1.0)) / PI, 0.0, 1.0));
		vec3 env_sample = texture(environment_texture, env_uv).rgb;
		vec3 r_tint = max(ALBEDO, vec3(0.0));
		vec3 trt_tint = max(ALBEDO, vec3(0.0)) * exp(-max(sigma_a, vec3(0.0)) * 0.5);
		EMISSION += (r_tint + trt_tint) * env_sample * max(environment_strength, 0.0);
	}
}


void light() {
	// omega_i is the only light-dependent strand-space vector; omega_o and the
	// per-lobe tilt/width setup were hoisted into fragment().
	vec3 omega_i = inv_tangent_matrix * LIGHT;

	vec3 single_scattering;
	if (use_azimuthal_lut) {
		single_scattering = fm_hair_bsdf_lut(omega_i, omega_o, view_yz.x, lobe_tilt_sin, lobe_tilt_cos, beta_m_inv, azimuthal_s_inv, logistic_b, sigma_a, ior, lut_azimuthal_width, azimuthal_lut);
	} else {
		// Analytic d'Eon azimuthal model: the reference path, unchanged.
		single_scattering = fm_hair_bsdf(omega_i, omega_o, view_yz.x, lobe_tilt_sin, lobe_tilt_cos, beta_m_inv, azimuthal_s_inv, logistic_b, sigma_a, ior);
	}
	// Area lights scale the final direct-light accumulations. The built-ins are
	// applied in place with an explicit vec3() construction (never assigned to
	// typed locals): Godot 4.7 declares them vec3 in the shader language but
	// generates them as scalar floats in the light stage, so only this form
	// keeps both the source and the generated code compilable on the NVIDIA
	// driver. Non-area lights multiply by vec3(1.0), exactly as before.
	SPECULAR_LIGHT += single_scattering * LIGHT_COLOR * ATTENUATION * specular
		* (LIGHT_IS_AREA ? vec3(LIGHT_AREA_SPECULAR_MULTIPLIER) : vec3(1.0));

	// Multiple scattering: the dual variants replace the Karis approximation
	// (never add on top of it); analytic and LUT variants keep Karis as the
	// reference path. The Stage-B preintegrated slice (variant 9) samples the
	// committed 2D LUT; Stage A (variant 7) stays analytic. Area multipliers
	// stay at this final accumulation.
	vec3 multiple_scattering;
	if (use_dual_scatter) {
		if (use_preintegrated_dual_scatter) {
			multiple_scattering = fm_dual_scattering_preintegrated(ALBEDO, omega_i, view_yz.yz, sigma_a, strand_depth, dual_scatter_strength, dual_scatter_density, dual_scatter_lut, ATTENUATION);
		} else {
			multiple_scattering = fm_dual_scattering(ALBEDO, omega_i, view_yz.yz, sigma_a, strand_depth, dual_scatter_strength, dual_scatter_density, ATTENUATION);
		}
	} else {
		// Fake multiple scattering approximation (Karis, 2016), preserved from
		// the current high-tier shader. Not physically based.
		multiple_scattering = fm_karis_multiple_scattering(ALBEDO, omega_i, view_yz.yz, ATTENUATION);
	}
	DIFFUSE_LIGHT += multiple_scattering * LIGHT_COLOR
		* (LIGHT_IS_AREA ? vec3(LIGHT_AREA_DIFFUSE_MULTIPLIER) : vec3(1.0)) / PI;
}
