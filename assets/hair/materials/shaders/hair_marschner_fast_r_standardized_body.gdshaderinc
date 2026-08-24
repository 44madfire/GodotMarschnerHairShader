// Diagnostic body for the standardized projected-R LUT variant.
//
// The shipping fast body remains untouched. This body reuses every shipping
// helper with FM_R_STANDARDIZED_LUT_MODE=0, then replaces only the analytic R
// contribution at light time with the standardized-Q path below.
//
// Runtime policy:
//   * |q| > r_standardized_lut_zero_tail_abs -> Q = 0 (measured negligible)
//   * low beta -> fp32-safe asymptotic Q
//   * interior -> hardware trilinear LUT sample
//   * grazing footprint -> manual trilinear sample with nonphysical corners
//     discarded and surviving weights renormalized
//   * cone-pole / beta-above-domain -> retained direct reference diagnostic
//
// TT, TRT, absorption, multiple scattering, coverage and presentation remain
// shipping-equivalent.

#include "./hair_marschner_fast.gdshaderinc"

const float FM_R_SAFE_COSINE_EPSILON = 1e-8;
const float FM_R_SAFE_BETA_EPSILON = 1e-8;
const float FM_R_SAFE_INV_SQRT_TAU = 0.3989422804014327;
const float FM_R_SAFE_INV_LN_2 = 1.4426950408889634;
const float FM_R_SAFE_LOG_Q_FLOOR = -83.17794814081263;

float fm_r_safe_log_bessel_zero(float x) {
	float x_sq = x * x;
	float value = 0.564187 + 1.01298 / (x_sq + 2.32434);
	value *= 1.0 / sqrt(sqrt(x_sq * 0.25 + 1.0));
	value *= exp(-2.0 * abs(x)) * 0.5 + 0.5;
	return log(max(value, 1e-30)) + x;
}

// Retained only for unresolved pole/high-beta diagnostics. Low beta and
// grazing no longer use this expression.
float fm_r_safe_direct_q(float theta_o, float theta_cone, float beta_effective) {
	float beta = max(beta_effective, FM_R_SAFE_BETA_EPSILON);
	float sin_o = sin(theta_o);
	float cos_o = max(cos(theta_o), FM_R_SAFE_COSINE_EPSILON);
	float sin_cone = sin(theta_cone);
	float cos_cone = max(cos(theta_cone), FM_R_SAFE_COSINE_EPSILON);
	float variance_inverse = 1.0 / (beta * beta);
	float log_q = (sin_cone * sin_o - 1.0) * variance_inverse
		+ fm_r_safe_log_bessel_zero(cos_cone * cos_o * variance_inverse)
		+ log(variance_inverse) - log(cos_o)
		+ log(beta) + 0.5 * log(cos_cone) + 1.5 * log(cos_o);
	return exp(clamp(log_q, FM_R_SAFE_LOG_Q_FLOOR, 80.0));
}

float fm_r_safe_asymptotic_q(float theta_o, float theta_cone, float beta_effective) {
	float beta = max(beta_effective, FM_R_SAFE_BETA_EPSILON);
	float half_delta = 0.5 * (theta_o - theta_cone);
	return FM_R_SAFE_INV_SQRT_TAU
		* exp(-2.0 * sin(half_delta) * sin(half_delta) / (beta * beta));
}

float fm_r_safe_sample_q(float q, float theta_cone, float beta_r) {
	ivec3 lut_size = textureSize(r_standardized_lut, 0);
	vec3 half_texel = 0.5 / vec3(lut_size);
	float q_span = max(r_standardized_lut_q_range.y - r_standardized_lut_q_range.x, 1e-6);
	float cone_span = max(r_standardized_lut_theta_cone_range.y - r_standardized_lut_theta_cone_range.x, 1e-6);
	float beta_min = max(r_standardized_lut_beta_range.x, FM_R_SAFE_BETA_EPSILON);
	float beta_max = max(r_standardized_lut_beta_range.y, beta_min + 1e-6);
	float log2_beta_min = log(beta_min) * FM_R_SAFE_INV_LN_2;
	float log2_beta_span = max((log(beta_max) - log(beta_min)) * FM_R_SAFE_INV_LN_2, 1e-6);
	vec3 domain = vec3(
		(q - r_standardized_lut_q_range.x) / q_span,
		(theta_cone - r_standardized_lut_theta_cone_range.x) / cone_span,
		(log(max(beta_r, beta_min)) * FM_R_SAFE_INV_LN_2 - log2_beta_min) / log2_beta_span);
	vec3 uvw = clamp(domain, half_texel, vec3(1.0) - half_texel);
	vec4 encoded = texture(r_standardized_lut, uvw);
	return r_standardized_lut_log_decode ? pow(2.0, encoded.g) : max(encoded.r, 0.0);
}

bool fm_r_safe_is_pole_band(float theta_cone) {
	ivec3 lut_size = textureSize(r_standardized_lut, 0);
	float cone_half_step = 0.5 * (r_standardized_lut_theta_cone_range.y
		- r_standardized_lut_theta_cone_range.x) / float(lut_size.y);
	return abs(theta_cone) > r_standardized_lut_theta_cone_range.y - 2.0 * cone_half_step;
}

bool fm_r_safe_requires_boundary_renormalization(float q, float theta_cone, float beta_r) {
	if (q < r_standardized_lut_q_range.x || q > r_standardized_lut_q_range.y
			|| theta_cone < r_standardized_lut_theta_cone_range.x
			|| theta_cone > r_standardized_lut_theta_cone_range.y
			|| beta_r < r_standardized_lut_beta_range.x
			|| beta_r > r_standardized_lut_beta_range.y) {
		return false;
	}
	ivec3 lut_size = textureSize(r_standardized_lut, 0);
	float q_half_step = 0.5 * (r_standardized_lut_q_range.y - r_standardized_lut_q_range.x) / float(lut_size.x);
	float cone_half_step = 0.5 * (r_standardized_lut_theta_cone_range.y - r_standardized_lut_theta_cone_range.x) / float(lut_size.y);
	float beta_min = max(r_standardized_lut_beta_range.x, FM_R_SAFE_BETA_EPSILON);
	float beta_max = max(r_standardized_lut_beta_range.y, beta_min + 1e-6);
	float log2_half_step = 0.5 * (log(beta_max) - log(beta_min)) * FM_R_SAFE_INV_LN_2 / float(lut_size.z);
	float log2_beta = log(beta_r) * FM_R_SAFE_INV_LN_2;
	float beta_lo = max(beta_min, pow(2.0, log2_beta - log2_half_step));
	float beta_hi = min(beta_max, pow(2.0, log2_beta + log2_half_step));
	for (int q_side = 0; q_side < 2; q_side++) {
		float q_corner = q + (q_side == 0 ? -q_half_step : q_half_step);
		for (int cone_side = 0; cone_side < 2; cone_side++) {
			float cone_corner = theta_cone + (cone_side == 0 ? -cone_half_step : cone_half_step);
			float theta_o_lo = cone_corner + q_corner * beta_lo;
			float theta_o_hi = cone_corner + q_corner * beta_hi;
			if (abs(theta_o_lo) > 0.5 * PI || abs(theta_o_hi) > 0.5 * PI) {
				return true;
			}
		}
	}
	float grazing_margin = 1.25 * (q_half_step * beta_hi + cone_half_step + abs(q) * (beta_hi - beta_lo));
	return abs(theta_cone + q * beta_r) > 0.5 * PI - grazing_margin;
}

// Returns (Q, surviving_weight). Q is linear even when the G/log channel is
// selected: log texels are renormalized in log space, then decoded.
vec2 fm_r_safe_sample_q_boundary_renormalized(float q, float theta_cone, float beta_r) {
	ivec3 lut_size = textureSize(r_standardized_lut, 0);
	float q_span = max(r_standardized_lut_q_range.y - r_standardized_lut_q_range.x, 1e-6);
	float cone_span = max(r_standardized_lut_theta_cone_range.y - r_standardized_lut_theta_cone_range.x, 1e-6);
	float beta_min = max(r_standardized_lut_beta_range.x, FM_R_SAFE_BETA_EPSILON);
	float beta_max = max(r_standardized_lut_beta_range.y, beta_min + 1e-6);
	float log2_beta_min = log(beta_min) * FM_R_SAFE_INV_LN_2;
	float log2_beta_span = max((log(beta_max) - log(beta_min)) * FM_R_SAFE_INV_LN_2, 1e-6);
	vec3 domain = vec3(
		(q - r_standardized_lut_q_range.x) / q_span,
		(theta_cone - r_standardized_lut_theta_cone_range.x) / cone_span,
		(log(beta_r) * FM_R_SAFE_INV_LN_2 - log2_beta_min) / log2_beta_span);
	vec3 p = clamp(domain * vec3(lut_size) - vec3(0.5), vec3(0.0), vec3(lut_size) - vec3(1.0));
	ivec3 i0 = ivec3(floor(p));
	ivec3 i1 = min(i0 + ivec3(1), lut_size - ivec3(1));
	vec3 t = p - vec3(i0);
	float accumulated = 0.0;
	float valid_weight = 0.0;
	for (int dz = 0; dz < 2; dz++) {
		int iz = dz == 0 ? i0.z : i1.z;
		float wz = dz == 0 ? 1.0 - t.z : t.z;
		float beta_corner = pow(2.0, log2_beta_min + (float(iz) + 0.5) / float(lut_size.z) * log2_beta_span);
		for (int dy = 0; dy < 2; dy++) {
			int iy = dy == 0 ? i0.y : i1.y;
			float wy = dy == 0 ? 1.0 - t.y : t.y;
			float cone_corner = r_standardized_lut_theta_cone_range.x
				+ (float(iy) + 0.5) / float(lut_size.y) * cone_span;
			for (int dx = 0; dx < 2; dx++) {
				int ix = dx == 0 ? i0.x : i1.x;
				float wx = dx == 0 ? 1.0 - t.x : t.x;
				float weight = wx * wy * wz;
				if (weight <= 0.0) {
					continue;
				}
				float q_corner = r_standardized_lut_q_range.x
					+ (float(ix) + 0.5) / float(lut_size.x) * q_span;
				float theta_o_corner = cone_corner + q_corner * beta_corner;
				if (theta_o_corner < -0.5 * PI || theta_o_corner > 0.5 * PI) {
					continue;
				}
				vec4 encoded = texelFetch(r_standardized_lut, ivec3(ix, iy, iz), 0);
				float encoded_q = r_standardized_lut_log_decode ? encoded.g : max(encoded.r, 0.0);
				accumulated += encoded_q * weight;
				valid_weight += weight;
			}
		}
	}
	if (valid_weight <= 1e-8) {
		return vec2(0.0);
	}
	float value = accumulated / valid_weight;
	if (r_standardized_lut_log_decode) {
		value = pow(2.0, value);
	}
	return vec2(max(value, 0.0), valid_weight);
}

float fm_r_safe_mn_from_q(float q_value, float theta_o, float theta_cone, float beta_m) {
	float beta_m_safe = max(beta_m, FM_R_SAFE_BETA_EPSILON);
	float cos_o = max(cos(theta_o), FM_R_SAFE_COSINE_EPSILON);
	float cos_cone = max(cos(theta_cone), FM_R_SAFE_COSINE_EPSILON);
	float denominator = 4.0 * sqrt(2.0) * beta_m_safe * cos_o * sqrt(cos_cone * cos_o);
	return max(q_value, 0.0) / max(denominator, 1e-20);
}

float fm_r_safe_standardized_mn(float sin_theta_i, float sin_theta_o, float cos_theta_d,
		float cos_phi_half, float cuticle_tilt_value, float beta_m_value) {
	float c_phi = clamp(cos_phi_half, 0.0, 1.0);
	float z_r = max(cos_theta_d * c_phi, 0.0);
	float sin_cone = clamp(-sin_theta_i + 2.0 * z_r * cuticle_tilt_value, -1.0, 1.0);
	float theta_cone = asin(sin_cone);
	float theta_o = asin(clamp(sin_theta_o, -0.999999, 0.999999));
	float beta_r = sqrt(2.0) * c_phi * max(beta_m_value, 0.0);
	float beta_safe = max(beta_r, FM_R_SAFE_BETA_EPSILON);
	float q = (theta_o - theta_cone) / beta_safe;
	float zero_tail = max(r_standardized_lut_zero_tail_abs, 0.0);

	// The measured complete-R energy outside |q|=8 was <= O(1e-10) in the
	// 512x128 matrix. Early-out before exp/log/texture work.
	if (zero_tail > 0.0 && abs(q) > zero_tail) {
		return 0.0;
	}

	float blend_low = min(r_standardized_lut_low_beta_blend.x, r_standardized_lut_low_beta_blend.y);
	float blend_high = max(r_standardized_lut_low_beta_blend.x, r_standardized_lut_low_beta_blend.y);
	float q_asym = fm_r_safe_asymptotic_q(theta_o, theta_cone, beta_safe);
	float q_value = q_asym;

	if (beta_r > blend_low) {
		bool outside_resource = q < r_standardized_lut_q_range.x || q > r_standardized_lut_q_range.y
			|| theta_cone < r_standardized_lut_theta_cone_range.x
			|| theta_cone > r_standardized_lut_theta_cone_range.y;
		bool beta_above = beta_r > r_standardized_lut_beta_range.y;
		bool pole = !outside_resource && !beta_above && fm_r_safe_is_pole_band(theta_cone);

		if (outside_resource || beta_above || pole) {
			if (beta_r >= blend_high) {
				q_value = fm_r_safe_direct_q(theta_o, theta_cone, beta_r);
			}
		} else {
			float sample_beta = max(beta_r, r_standardized_lut_beta_range.x);
			float q_lut;
			if (fm_r_safe_requires_boundary_renormalization(q, theta_cone, sample_beta)) {
				vec2 boundary_sample = fm_r_safe_sample_q_boundary_renormalized(q, theta_cone, sample_beta);
				q_lut = boundary_sample.y > 1e-8 ? boundary_sample.x : q_asym;
			} else {
				q_lut = fm_r_safe_sample_q(q, theta_cone, sample_beta);
			}
			float lut_weight = smoothstep(blend_low, blend_high, beta_r);
			q_value = mix(q_asym, q_lut, lut_weight);
		}
	}
	return fm_r_safe_mn_from_q(q_value, theta_o, theta_cone, beta_m_value);
}

// Reuse the complete shipping analytic BSDF for TT/TRT and subtract only its
// R term before adding the standardized projected-Q R term.
vec3 fm_hair_bsdf_r_standardized_safe(vec3 omega_i, vec3 omega_o, float view_cos_theta,
		float view_theta_o, vec3 lobe_alpha, vec3 lobe_variance, vec2 azimuthal_s_inv,
		vec2 logistic_b, vec3 sigma_a_value, float eta, float cuticle_tilt_value,
		float beta_m_value) {
	vec3 result = fm_hair_bsdf(omega_i, omega_o, view_cos_theta, view_theta_o,
		lobe_alpha, lobe_variance, azimuthal_s_inv, logistic_b, sigma_a_value,
		eta, cuticle_tilt_value, beta_m_value);
#ifdef FM_LOBE_R
	float sin_theta_i = omega_i.x;
	float sin_theta_o = omega_o.x;
	float cos_theta_i = length(omega_i.yz);
	float cos_theta_o = view_cos_theta;
	float cos_phi = clamp((omega_i.y * omega_o.y + omega_i.z * omega_o.z)
		/ max(cos_theta_i * cos_theta_o, 1e-6), -0.9999, 0.9999);
	float cos_phi_half = sqrt(max(0.0, 0.5 + 0.5 * cos_phi));
	float cos_theta = clamp(cos_theta_o * cos_theta_i + sin_theta_o * sin_theta_i, -1.0, 1.0);
	float cos_theta_d = sqrt(0.5 + 0.5 * cos_theta);
	vec3 m_p = fm_longitudinal_scattering(asin(clamp(sin_theta_i, -0.999999, 0.999999)),
		view_theta_o, lobe_alpha, lobe_variance, cuticle_tilt_value, beta_m_value);
	float fresnel = fm_fresnel(cos_theta_d * cos_phi_half, eta);
	float shipping_r = 0.25 * max(cos_phi_half, 1e-6) * fresnel * m_p[FM_R] * lobe_scales[FM_R];
	float corrected_r = fm_r_safe_standardized_mn(sin_theta_i, sin_theta_o, cos_theta_d,
		cos_phi_half, cuticle_tilt_value, beta_m_value) * fresnel * lobe_scales[FM_R];
	result += vec3(corrected_r - shipping_r);
#endif
	return result;
}

varying vec3 vertex_world;
varying vec3 sigma_a;
varying mat3 inv_tangent_matrix;
varying vec3 omega_o;
varying vec3 view_yz;
varying float view_theta_o;
varying vec3 lobe_alpha;
varying vec3 lobe_variance;
varying float lobe_cuticle_tilt;
varying float lobe_beta_m;
varying vec2 azimuthal_s_inv;
varying vec2 logistic_b;
varying float lut_azimuthal_width;
varying float lut_azimuthal_compatible;
varying float strand_depth;

vec3 hash13(float p) {
	uvec3 v = uvec3(floatBitsToUint(p), 0u, 0u);
	v = v * 1664525u + 1013904223u;
	v.x += v.y*v.z; v.y += v.z*v.x; v.z += v.x*v.y;
	v ^= v >> 16u;
	v.x += v.y*v.z; v.y += v.z*v.x; v.z += v.x*v.y;
	return uintBitsToFloat((v & uvec3(0x007FFFFFu)) | uvec3(0x3F800000u)) - 1.0;
}

void vertex() {
	vertex_world = VERTEX;
}

void fragment() {
	vec3 tangent = texture(coords_texture, UV).rgb*2.0 - 1.0;
	float u = texture(coords_texture, UV).a;
	float coverage = texture(attributes_texture, UV).r;
	float depth = texture(attributes_texture, UV).g;
	float seed = texture(attributes_texture, UV).b;
	vec2 beta = vec2(longitudinal_roughness, azimuthal_roughness);

	const mat4 bayer4x4 = mat4(
		vec4(0.01,  8.0,  2.0, 10.0),
		vec4(12.0,  4.0, 14.0,  6.0),
		vec4( 3.0, 11.0,  1.0,  9.0),
		vec4(15.0,  7.0, 13.0,  5.0)) / 16.0;
	float bayer_time = freeze_bayer_phase ? 0.0 : TIME;
	ivec2 id = ivec2(FRAGCOORD.xy + UV.xy*vec2(textureSize(attributes_texture, 0)*2) + bayer_time*500.0);
	float dist = length((CAMERA_POSITION_WORLD - vertex_world) / MODEL_MATRIX[0].xyz) / tan(PI/6.0) / PROJECTION_MATRIX[1][1];
	float bias = max((1.0 - clamp((dist - 1.0)*0.5, 0.0, 1.0))*(1.0 - depth*depth), 0.1);
	if (!show_hair_cards && pow(coverage, bias) < bayer4x4[id.x % 4][id.y % 4]) discard;
	strand_depth = depth;

	vec3 hash = hash13(seed);
	ALBEDO = show_hashed_strands ? hash : albedo * smoothstep(-0.2, 0.2, u*(1.0 - coverage));
	SPECULAR = specular;
	ROUGHNESS = beta.x;

	float frizz = 0.5 * beta.x * power(u, 1.0 - beta.x);
	TANGENT = normalize(mat3(TANGENT, BINORMAL, NORMAL)*tangent + (hash*2.0 - 1.0)*frizz);
	NORMAL = normalize(NORMAL - TANGENT*dot(NORMAL, TANGENT));
	BINORMAL = cross(TANGENT, NORMAL);
	inv_tangent_matrix = transpose(mat3(TANGENT, BINORMAL, NORMAL));

	sigma_a = fm_absorption_coefficient(albedo, beta.y);
	beta = max(vec2(1e-3), mix(0.8, 1.2, seed)*vec2(
		0.726*beta.x + 0.812*beta.x*beta.x + 3.700*pow(beta.x, 20),
		0.265*beta.y + 1.194*beta.y*beta.y + 5.372*pow(beta.y, 22)));

	omega_o = inv_tangent_matrix * VIEW;
	view_theta_o = asin(clamp(omega_o.x, -0.999999, 0.999999));
	float view_yz_length_squared = dot(omega_o.yz, omega_o.yz);
	float view_cos_theta = sqrt(view_yz_length_squared);
	vec2 view_yz_normalized = (view_yz_length_squared > 1e-8)
		? omega_o.yz * inversesqrt(view_yz_length_squared)
		: vec2(0.0, 1.0);
	view_yz = vec3(view_cos_theta, view_yz_normalized.x, view_yz_normalized.y);

#if FM_CUTICLE_TILT_CONVENTION == 1
	lobe_alpha = vec3(-1.0, 0.5, 1.5) * cuticle_tilt_offset;
#else
	lobe_alpha = vec3(1.0, -0.5, -1.5) * cuticle_tilt_offset;
#endif
	vec2 beta_floored = max(beta, vec2(1e-3));
	lobe_variance = pow(vec3(1.0, 0.5, 2.0) * beta_floored.x, vec3(2.0));
	azimuthal_s_inv = vec2(sqrt(2.0) / beta_floored.y, 0.5 * sqrt(2.0) / beta_floored.y);
	lobe_cuticle_tilt = cuticle_tilt_offset;
	lobe_beta_m = beta_floored.x;
	logistic_b = exp(-2.0 * sqrt(TAU) * azimuthal_s_inv);
	lut_azimuthal_compatible = (beta.y >= 0.001 && beta.y <= 1.0) ? 1.0 : 0.0;
	lut_azimuthal_width = (beta.y - 0.001) * (1.0 / 0.999);

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
	vec3 omega_i = inv_tangent_matrix * LIGHT;
	vec3 single_scattering = fm_hair_bsdf_r_standardized_safe(omega_i, omega_o,
		view_yz.x, view_theta_o, lobe_alpha, lobe_variance, azimuthal_s_inv,
		logistic_b, sigma_a, ior, lobe_cuticle_tilt, lobe_beta_m);
	vec3 area_specular_multiplier = (LIGHT_IS_AREA && use_area_light_multipliers)
		? vec3(LIGHT_AREA_SPECULAR_MULTIPLIER)
		: vec3(1.0);
	SPECULAR_LIGHT += comparison_exposure_gain * single_scattering * LIGHT_COLOR * ATTENUATION * specular
		* area_specular_multiplier;

	vec3 multiple_scattering;
	if (use_dual_scatter) {
		if (use_preintegrated_dual_scatter) {
			multiple_scattering = fm_dual_scattering_preintegrated(ALBEDO, omega_i, view_yz.yz,
				sigma_a, strand_depth, dual_scatter_strength, dual_scatter_density,
				dual_scatter_lut, ior, dual_scatter_lut_eta, ATTENUATION);
		} else {
			multiple_scattering = fm_dual_scattering(ALBEDO, omega_i, view_yz.yz, sigma_a,
				strand_depth, dual_scatter_strength, dual_scatter_density, ATTENUATION);
		}
	} else {
		multiple_scattering = fm_karis_multiple_scattering(ALBEDO, omega_i, view_yz.yz, ATTENUATION);
	}
	vec3 area_diffuse_multiplier = (LIGHT_IS_AREA && use_area_light_multipliers)
		? vec3(LIGHT_AREA_DIFFUSE_MULTIPLIER)
		: vec3(1.0);
	DIFFUSE_LIGHT += comparison_exposure_gain * multiple_scattering * LIGHT_COLOR
		* area_diffuse_multiplier / PI;
}
