// Production Cinematic Marschner body.
// The top-level wrapper owns every uniform/varying declaration so Godot 4.7
// exposes the complete material interface through get_shader_uniform_list().
// Only the expensive longitudinal kernel is preintegrated; baseline azimuthal
// geometry and attenuation remain analytic for clean attribution.

float cinematic_logistic_distribution(float cos_phi, float s_inv) {
	float cphi = clamp(cos_phi, -1.0, 1.0);
	float phi = sqrt(max(0.0, 1.0 - cphi)) * (1.5707288 + cphi * (-0.2121144 + cphi * 0.0742610));
	float e = exp(-phi * s_inv);
	float b = exp(-2.0 * sqrt(TAU) * s_inv);
	float c = 1.0 + e;
	return min(1.0, s_inv * e * (1.0 + b) / max((1.0 - b) * c * c, 1e-8));
}

vec3 cinematic_cross_section_offset(float cos_phi_half, float sin_phi_half, float eta_prime_inv) {
	vec3 h;
	h[R] = -sin_phi_half;
	h[TT] = sign(sin_phi_half) * cos_phi_half * inversesqrt(max(1.0 + eta_prime_inv * (1.0 - 2.0 * eta_prime_inv * abs(sin_phi_half)), 1e-6));
	h[TRT] = 0.91;
	return clamp(h, vec3(-1.0), vec3(1.0));
}

float cinematic_azimuthal_angular_offset(int mode, float cos_phi, float sin_phi, float eta_prime_inv, float h) {
	float gamma = (2.126 * h * eta_prime_inv + PI) * float(mode);
	float a = 1.0 - 2.0 * h * h;
	float b = 2.0 * h * sqrt(max(0.0, 1.0 - h * h));
	float c = cos(gamma);
	float s = sin(gamma);
	return cos_phi * (c * a + s * b) + sin_phi * (s * a - c * b);
}

vec3 cinematic_azimuthal_attenuation(int mode, float cos_theta_t, float cos_theta_d, vec3 sigma_a, float eta_prime_inv, float h) {
	float f = hair_fresnel_ior(cos_theta_d * sqrt(max(0.0, 1.0 - h * h)), ior);
	vec3 transmittance = exp(-max(sigma_a, vec3(0.0)) / max(cos_theta_t, 1e-4)
		* 4.0 * (1.0 - eta_prime_inv * eta_prime_inv * h * h) * float(mode));
	float one_minus_f = 1.0 - f;
	return one_minus_f * one_minus_f * pow(f, float(mode - 1)) * transmittance;
}

float cinematic_asymptotic_q(float theta_cone, float theta_o, float beta_eff) {
	float beta = max(beta_eff, 1e-8);
	float delta = theta_o - theta_cone;
	return inversesqrt(TAU) * exp((cos(delta) - 1.0) / (beta * beta));
}

float cinematic_sample_m(float sin_cone, float theta_o, float beta_eff) {
	float beta = max(beta_eff, 1e-8);
	float blend_low = cinematic_longitudinal_low_beta_blend.x;
	float blend_high = cinematic_longitudinal_low_beta_blend.y;
	float theta_cone = asin(clamp(sin_cone, -0.999999, 0.999999));
	float q_asym = cinematic_asymptotic_q(theta_cone, theta_o, beta);
	if (beta <= blend_low) {
		float cos_o = max(cos(theta_o), 1e-5);
		float cos_cone = max(cos(theta_cone), 1e-5);
		return q_asym / max(beta * sqrt(cos_cone * cos_o) * cos_o, 1e-8);
	}

	ivec3 dims = max(textureSize(cinematic_longitudinal_lut, 0), ivec3(2));
	vec3 half_texel = 0.5 / vec3(dims);
	float beta_min = max(cinematic_longitudinal_beta_range.x, 1e-6);
	float beta_max = max(cinematic_longitudinal_beta_range.y, beta_min + 1e-6);
	float beta_sample = clamp(beta, beta_min, beta_max);
	float log_min = log2(beta_min);
	float log_span = max(log2(beta_max) - log_min, 1e-6);

	// The LUT is uniform in physical angle rather than sin(theta), preserving
	// resolution at grazing. R stores log2(Q), so hardware trilinear filtering
	// interpolates the smooth log-kernel instead of the sharp linear peak.
	float u = clamp(0.5 + theta_cone / PI, half_texel.x, 1.0 - half_texel.x);
	float v = clamp(0.5 + theta_o / PI, half_texel.y, 1.0 - half_texel.y);
	float w = clamp((log2(beta_sample) - log_min) / log_span, half_texel.z, 1.0 - half_texel.z);
	float log2_q_lut = max(texture(cinematic_longitudinal_lut, vec3(u, v, w)).r, -120.0);
	float q_lut = exp2(log2_q_lut);
	float q_value = q_lut;
	if (beta < blend_high) {
		float t = smoothstep(blend_low, blend_high, beta);
		q_value = mix(q_asym, q_lut, t);
	}

	// Reconstruct M using the same regularized angular coordinates used by the
	// texture sample. Narrower beta values use the analytic asymptotic path.
	float theta_cone_eval = (u - 0.5) * PI;
	float theta_o_eval = (v - 0.5) * PI;
	float cos_cone_eval = max(cos(theta_cone_eval), 1e-5);
	float cos_o_eval = max(cos(theta_o_eval), 1e-5);
	return q_value / max(beta_sample * sqrt(cos_cone_eval * cos_o_eval) * cos_o_eval, 1e-8);
}

vec3 cinematic_longitudinal(float sin_theta_i, float sin_theta_o, float cos_theta_d, float sin_theta_d, float cos_phi_half, float alpha_internal, float beta_m, vec3 h) {
	vec3 k_sq = vec3(sin_theta_d * sin_theta_d) + vec3(cos_theta_d * cos_theta_d) * h * h;
	k_sq = clamp(k_sq, vec3(0.0), vec3(0.999999));
	vec3 z = sqrt(vec3(1.0) - k_sq);
	vec3 z_prime = sqrt(max(vec3(ior * ior) - k_sq, vec3(1e-6))) * vec3(0.0, 1.0, 2.0);
	vec3 beta_eff = vec3(max(beta_m, 1e-6));
	beta_eff[R] *= sqrt(2.0) * cos_phi_half;
	beta_eff[TT] *= (z[TT] + 0.5 * z_prime[TT]) / max(cos_theta_d, 1e-5);
	beta_eff[TRT] *= 2.0 * sqrt(max(ior * ior - sin_theta_d * sin_theta_d, 1e-6)) / max(cos_theta_d, 1e-5) - 1.0;
	beta_eff = max(beta_eff, vec3(1e-8));

	// Preserve the analytic baseline's azimuth-dependent effective cone/width
	// before sampling one generic scalar longitudinal volume for all three paths.
	vec3 sin_cone = clamp(-vec3(sin_theta_i) + (2.0 * z_prime - 2.0 * z) * alpha_internal, vec3(-1.0), vec3(1.0));
	float theta_o = asin(clamp(sin_theta_o, -0.999999, 0.999999));
	return vec3(
		cinematic_sample_m(sin_cone[R], theta_o, beta_eff[R]),
		cinematic_sample_m(sin_cone[TT], theta_o, beta_eff[TT]),
		cinematic_sample_m(sin_cone[TRT], theta_o, beta_eff[TRT]));
}

vec3 cinematic_bsdf(vec3 omega_i, vec3 omega_o_local) {
	float sin_theta_i = omega_i.x;
	float sin_theta_o = omega_o_local.x;
	float cos_theta_i = max(length(omega_i.yz), 1e-6);
	float cos_theta_o = max(length(omega_o_local.yz), 1e-6);
	float denom = max(cos_theta_i * cos_theta_o, 1e-6);
	float cos_phi = clamp((omega_i.y * omega_o_local.y + omega_i.z * omega_o_local.z) / denom, -0.9999, 0.9999);
	float sin_phi = clamp((omega_i.y * omega_o_local.z - omega_i.z * omega_o_local.y) / denom, -0.9999, 0.9999);
	float cos_phi_half = max(1e-6, sqrt(0.5 + 0.5 * cos_phi));
	float sin_phi_half = sqrt(max(0.0, 0.5 - 0.5 * cos_phi)) * sign(sin_phi);
	float cos_theta = clamp(cos_theta_o * cos_theta_i + sin_theta_o * sin_theta_i, -1.0, 1.0);
	float cos_theta_d = sqrt(max(0.0, 0.5 + 0.5 * cos_theta));
	float sin_theta_d = sqrt(max(0.0, 0.5 - 0.5 * cos_theta)) * sign(sin_theta_o * cos_theta_i - cos_theta_o * sin_theta_i);
	float cos_theta_t = sqrt(max(0.0, 1.0 - sin_theta_i * sin_theta_i / max(ior * ior, 1e-6)));
	float eta_prime = sqrt(max(ior * ior - sin_theta_d * sin_theta_d, 1e-6)) / max(cos_theta_d, 1e-6);
	float eta_prime_inv = 1.0 / max(eta_prime, 1e-6);
	vec3 h = cinematic_cross_section_offset(cos_phi_half, sin_phi_half, eta_prime_inv);

	vec3 m = cinematic_longitudinal(sin_theta_i, sin_theta_o, cos_theta_d, sin_theta_d, cos_phi_half, -cuticle_tilt_offset, beta_reparam.x, h);
	vec3 result = vec3(0.0);
	float a_r = hair_fresnel_ior(cos_theta_d * cos_phi_half, ior);
	result += vec3(0.25 * cos_phi_half * a_r * m[R] * lobe_scales[R]);
	float n_tt = cinematic_logistic_distribution(cinematic_azimuthal_angular_offset(TT, cos_phi, sin_phi, eta_prime_inv, h[TT]), sqrt(2.0) / max(beta_reparam.y, 1e-6));
	vec3 a_tt = cinematic_azimuthal_attenuation(TT, cos_theta_t, cos_theta_d, absorption_coefficient, eta_prime_inv, h[TT]);
	result += n_tt * a_tt * m[TT] * lobe_scales[TT];
	float n_trt = cinematic_logistic_distribution(cinematic_azimuthal_angular_offset(TRT, cos_phi, sin_phi, eta_prime_inv, h[TRT]), 0.5 * sqrt(2.0) / max(beta_reparam.y, 1e-6));
	vec3 a_trt = cinematic_azimuthal_attenuation(TRT, cos_theta_t, cos_theta_d, absorption_coefficient, eta_prime_inv, h[TRT]);
	result += n_trt * a_trt * m[TRT] * lobe_scales[TRT];
	return max(result, vec3(0.0));
}

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
	vec2 beta_raw = vec2(longitudinal_roughness, azimuthal_roughness);
	float bayer_time = freeze_bayer_phase ? 0.0 : TIME;
	if (!hair_card_should_keep(
		coverage,
		depth,
		vertex_world,
		UV,
		FRAGCOORD.xy,
		textureSize(attributes_texture, 0),
		bayer_time,
		show_hair_cards,
		CAMERA_POSITION_WORLD,
		MODEL_MATRIX[0].xyz,
		PROJECTION_MATRIX[1][1])) discard;

	vec3 hash = hair_hash13(seed);
	ALBEDO = hair_card_base_albedo(albedo, u, coverage, hash, show_hashed_strands);
	SPECULAR = specular;
	ROUGHNESS = beta_raw.x;
	TANGENT = hair_card_frizzed_tangent(
		mat3(TANGENT, BINORMAL, NORMAL),
		tangent_texture_value,
		hash,
		u,
		beta_raw.x);
	mat3 strand_frame = hair_card_orthonormal_frame(TANGENT, NORMAL);
	TANGENT = strand_frame[0];
	BINORMAL = strand_frame[1];
	NORMAL = strand_frame[2];
	inv_tangent_matrix = transpose(strand_frame);
	omega_o = inv_tangent_matrix * VIEW;

	vec3 safe_albedo = max(albedo, vec3(1e-4));
	float c = 5.969 + beta_raw.y * (-0.215 + beta_raw.y * (2.532 + beta_raw.y * (-10.73 + beta_raw.y * (5.574 + beta_raw.y * 0.245))));
	absorption_coefficient = log(safe_albedo) / max(c, 1e-4);
	absorption_coefficient *= absorption_coefficient;
	beta_reparam = max(vec2(1e-3), mix(0.8, 1.2, seed) * vec2(
		0.726 * beta_raw.x + 0.812 * beta_raw.x * beta_raw.x + 3.700 * pow(beta_raw.x, 20.0),
		0.265 * beta_raw.y + 1.194 * beta_raw.y * beta_raw.y + 5.372 * pow(beta_raw.y, 22.0)));
}

void light() {
	vec3 omega_i = inv_tangent_matrix * LIGHT;
	vec3 single_scattering = cinematic_bsdf(omega_i, omega_o);
	vec3 area_specular_multiplier = (LIGHT_IS_AREA && use_area_light_multipliers) ? vec3(LIGHT_AREA_SPECULAR_MULTIPLIER) : vec3(1.0);
	SPECULAR_LIGHT += comparison_exposure_gain * single_scattering * LIGHT_COLOR * ATTENUATION * specular * area_specular_multiplier;

	float yz_len2 = dot(omega_o.yz, omega_o.yz);
	vec2 view_yz = yz_len2 > 1e-8 ? omega_o.yz * inversesqrt(yz_len2) : vec2(0.0, 1.0);
	float luminance = max(dot(ALBEDO, vec3(0.299, 0.587, 0.114)), 1e-4);
	vec3 multiple = 0.25 * sqrt(max(ALBEDO, vec3(0.0))) * (dot(omega_i.yz, view_yz) + 1.0)
		* pow(max(ALBEDO / luminance, vec3(1e-4)), vec3(ATTENUATION));
	DIFFUSE_LIGHT += comparison_exposure_gain * multiple * smoothstep(-0.5, 1.0, ATTENUATION) * LIGHT_COLOR / PI;
}
