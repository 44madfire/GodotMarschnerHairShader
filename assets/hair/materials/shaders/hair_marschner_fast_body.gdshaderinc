// Interface uniforms are declared directly in each top-level wrapper. Godot
// 4.7 compiles declarations from includes but does not expose them reliably to
// ShaderMaterial's runtime uniform binding. This file owns the shared varyings,
// functions, and vertex/fragment/light implementation below.

#include "./hair_marschner_fast.gdshaderinc"

varying vec3 vertex_world;
varying vec3 sigma_a;
varying mat3 inv_tangent_matrix; // inverse TBN Matrix
// Light-invariant scattering setup, computed once per fragment (after alpha
// discard) instead of once per light. These varyings are written in
// fragment(), so they carry exact per-fragment values, not interpolated ones.
varying vec3 omega_o;          // strand-space view vector
varying vec3 view_yz;          // x = cos(theta_o), yz = normalized omega_o.yz (Karis)
varying float view_theta_o;    // theta_o = asin(omega_o.x), strand-space view elevation
varying vec3 lobe_alpha;       // theta_h lobe centers (R/TT/TRT cuticle tilts)
varying vec3 lobe_variance;    // theta_h per-lobe variances ((w*beta)^2, hoisted)
varying float lobe_cuticle_tilt; // cuticle_tilt_offset (radians): FM_LONGITUDINAL_MODE 1 cone rotation scalar
varying float lobe_beta_m;     // reparameterized longitudinal roughness beta_M: FM_LONGITUDINAL_MODE 1 width scalar
varying vec2 azimuthal_s_inv;  // TT/TRT logistic inverse azimuthal widths
varying vec2 logistic_b;       // TT/TRT logistic normalization exp(-2*sqrt(TAU)*s_inv)
varying float lut_azimuthal_width; // light-invariant LUT width axis (0..1)
varying float lut_azimuthal_compatible; // 1.0 = derived beta_N inside the LUT beta axis [0.001, 1.0], else analytic fallback
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

	float bayer_time = freeze_bayer_phase ? 0.0 : TIME;
	ivec2 id = ivec2(FRAGCOORD.xy + UV.xy*vec2(textureSize(attributes_texture, 0)*2) + bayer_time*500.0); // FIXME: uh oh! this code is ass!
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

	// --- Reparameterization ---
	// Source: "A Practical and Controllable Hair and Fur Model for Production Path Tracing" (Chiang et al., 2016)
	// ROUGHNESS, frizz, and sigma_a above use the raw artist-facing beta; the
	// reparameterized beta below feeds the per-lobe scattering widths, matching
	// the production baseline formula exactly (M = longitudinal, N = azimuthal),
	// including the per-seed mix(0.8, 1.2, seed) roughness variation and the
	// 1e-3 floor.
	beta = max(vec2(1e-3), mix(0.8, 1.2, seed)*vec2(
		0.726*beta.x + 0.812*beta.x*beta.x + 3.700*pow(beta.x, 20),
		0.265*beta.y + 1.194*beta.y*beta.y + 5.372*pow(beta.y, 22)));

	// --- Hoisted light-invariant scattering setup ---
	// Everything below depends only on the view, the strand basis, and the
	// material uniforms, so it is computed once per fragment (after discard)
	// instead of once per light. Values and clamp/order semantics match the
	// previous per-light computations exactly.
	omega_o = inv_tangent_matrix * VIEW;
	view_theta_o = asin(clamp(omega_o.x, -0.999999, 0.999999));

	// cos(theta_o) and the normalized omega_o.yz used by the Karis term. The
	// branch threshold (length squared > 1e-8) matches the previous code.
	float view_yz_length_squared = dot(omega_o.yz, omega_o.yz);
	float view_cos_theta = sqrt(view_yz_length_squared);
	vec2 view_yz_normalized = (view_yz_length_squared > 1e-8)
		? omega_o.yz * inversesqrt(view_yz_length_squared)
		: vec2(0.0, 1.0);
	view_yz = vec3(view_cos_theta, view_yz_normalized.x, view_yz_normalized.y);

	// Per-lobe theta_h centers under the shipping baseline cuticle-tilt
	// convention (FM_CUTICLE_TILT_CONVENTION = 0): a positive artist-facing
	// cuticle_tilt_offset denotes an outward tilt, so R = +alpha,
	// TT = -0.5*alpha, TRT = -1.5*alpha. The Unity diagnostic convention
	// (FM_CUTICLE_TILT_CONVENTION = 1) keeps the previous sign pattern.
#if FM_CUTICLE_TILT_CONVENTION == 1
	lobe_alpha = vec3(-1.0, 0.5, 1.5) * cuticle_tilt_offset;
#else
	lobe_alpha = vec3(1.0, -0.5, -1.5) * cuticle_tilt_offset;
#endif

	// Derived roughness feeding the theta_h per-lobe variances
	// (R = beta, TT = 0.5*beta, TRT = 2.0*beta; squared with a positive floor)
	// and the TT/TRT logistic inverse azimuthal widths. Only the 1e-3 lower
	// floor is applied: the actual derived beta values drive the analytic
	// widths with no upper clamp. The azimuthal LUT path alone is restricted
	// to its baked beta domain [0.001, 1.0] via lut_azimuthal_compatible.
	vec2 beta_floored = max(beta, vec2(1e-3));
	lobe_variance = pow(vec3(1.0, 0.5, 2.0) * beta_floored.x, vec3(2.0));
	azimuthal_s_inv = vec2(sqrt(2.0) / beta_floored.y, 0.5 * sqrt(2.0) / beta_floored.y);

	// FM_LONGITUDINAL_MODE 1 diagnostic scalars: the cone rotation magnitude
	// (artist-facing cuticle tilt, radians) and the reparameterized
	// longitudinal roughness beta_M. Mode 0 (shipping default) never reads
	// them; they exist so the diagnostic branch needs no public uniform API.
	lobe_cuticle_tilt = cuticle_tilt_offset;
	lobe_beta_m = beta_floored.x;

	// Logistic normalization exp(-2*sqrt(TAU)*s_inv), light-invariant per lobe.
	logistic_b = exp(-2.0 * sqrt(TAU) * azimuthal_s_inv);

	// LUT width axis, matching the generator's beta axis [0.001, 1.0]. The
	// width derives from the actual beta_N without clamping; beta_N outside
	// the domain is flagged incompatible below so light() uses the analytic
	// azimuthal model instead of silently clamping the roughness into the LUT
	// domain.
	lut_azimuthal_compatible = (beta.y >= 0.001 && beta.y <= 1.0) ? 1.0 : 0.0;
	lut_azimuthal_width = (beta.y - 0.001) * (1.0 / 0.999);

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
		EMISSION += comparison_exposure_gain * (r_tint + trt_tint) * env_sample * max(environment_strength, 0.0);
	}
}


void light() {
	// omega_i is the only light-dependent strand-space vector; omega_o,
	// view_theta_o, and the per-lobe center/variance setup were hoisted into
	// fragment().
	vec3 omega_i = inv_tangent_matrix * LIGHT;

	vec3 single_scattering;
	// The LUT path also requires the derived beta_N to fall inside the baked
	// beta axis [0.001, 1.0] (lut_azimuthal_compatible); outside it the
	// analytic model is used rather than clamping the material roughness
	// into the LUT domain.
	bool azimuthal_lut_compatible = abs(ior - azimuthal_lut_eta) <= 0.0005;
	if (use_azimuthal_lut && azimuthal_lut_compatible && lut_azimuthal_compatible > 0.5) {
		single_scattering = fm_hair_bsdf_lut(omega_i, omega_o, view_yz.x, view_theta_o, lobe_alpha, lobe_variance, azimuthal_s_inv, logistic_b, sigma_a, ior, lut_azimuthal_width, azimuthal_lut, lobe_cuticle_tilt, lobe_beta_m);
	} else {
		// Analytic fallback is required when the runtime IOR differs from the
		// baked LUT IOR (which would mix incompatible Fresnel terms) or when
		// the derived beta_N lies outside the LUT's baked beta axis.
		single_scattering = fm_hair_bsdf(omega_i, omega_o, view_yz.x, view_theta_o, lobe_alpha, lobe_variance, azimuthal_s_inv, logistic_b, sigma_a, ior, lobe_cuticle_tilt, lobe_beta_m);
	}
	// Area lights scale the final direct-light accumulations. The built-ins are
	// applied in place with an explicit vec3() construction (never assigned to
	// typed locals): Godot 4.7 declares them vec3 in the shader language but
	// generates them as scalar floats in the light stage, so only this form
	// keeps both the source and the generated code compilable on the NVIDIA
	// driver. Non-area lights multiply by vec3(1.0), exactly as before.
	vec3 area_specular_multiplier = (LIGHT_IS_AREA && use_area_light_multipliers)
		? vec3(LIGHT_AREA_SPECULAR_MULTIPLIER)
		: vec3(1.0);
	SPECULAR_LIGHT += comparison_exposure_gain * single_scattering * LIGHT_COLOR * ATTENUATION * specular
		* area_specular_multiplier;

	// Multiple scattering: the dual variants replace the Karis approximation
	// (never add on top of it); analytic and LUT variants keep Karis as the
	// reference path. The Stage-B preintegrated slice (variant 9) samples the
	// committed 2D LUT only when the runtime IOR matches the baked
	// dual_scatter_lut_eta within 0.0005; otherwise it evaluates the analytic
	// Contract B formula with the runtime IOR/F0 (the Stage-A slice is a
	// separate variant and is never used for this parity fallback). Stage A
	// (variant 7) stays analytic. Area multipliers stay at this final
	// accumulation.
	vec3 multiple_scattering;
	if (use_dual_scatter) {
		if (use_preintegrated_dual_scatter) {
			multiple_scattering = fm_dual_scattering_preintegrated(ALBEDO, omega_i, view_yz.yz, sigma_a, strand_depth, dual_scatter_strength, dual_scatter_density, dual_scatter_lut, ior, dual_scatter_lut_eta, ATTENUATION);
		} else {
			multiple_scattering = fm_dual_scattering(ALBEDO, omega_i, view_yz.yz, sigma_a, strand_depth, dual_scatter_strength, dual_scatter_density, ATTENUATION);
		}
	} else {
		// Fake multiple scattering approximation (Karis, 2016), preserved from
		// the current high-tier shader. Not physically based.
		multiple_scattering = fm_karis_multiple_scattering(ALBEDO, omega_i, view_yz.yz, ATTENUATION);
	}
	vec3 area_diffuse_multiplier = (LIGHT_IS_AREA && use_area_light_multipliers)
		? vec3(LIGHT_AREA_DIFFUSE_MULTIPLIER)
		: vec3(1.0);
	DIFFUSE_LIGHT += comparison_exposure_gain * multiple_scattering * LIGHT_COLOR
		* area_diffuse_multiplier / PI;
}
