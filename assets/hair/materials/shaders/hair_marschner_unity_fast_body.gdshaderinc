// Unity HDRP Standard-style production Fast body.
// The top-level wrapper owns every uniform/varying declaration so Godot 4.7
// exposes the complete material interface through get_shader_uniform_list().

vec3 unity_gaussian(vec3 theta_h_minus_alpha, vec3 beta_squared) {
	vec3 b = max(beta_squared, vec3(1e-5));
	return exp(-(theta_h_minus_alpha * theta_h_minus_alpha) / (2.0 * b)) * inversesqrt(TAU * b);
}

float unity_absorption_denominator(float radial_roughness) {
	float b = radial_roughness;
	return (((((0.245 * b) + 5.574) * b - 10.73) * b + 2.532) * b - 0.215) * b + 5.969;
}

vec3 unity_absorption_coefficient(vec3 base_color, float radial_roughness) {
	if (absorption_mode == 1) {
		return max(absorption, vec3(0.0));
	}
	if (absorption_mode == 2) {
		const vec3 lambda_nm = vec3(650.0, 540.0, 450.0);
		vec3 melanin = max(eumelanin, 0.0) * 6.6e11 * pow(lambda_nm, vec3(-3.33))
			+ max(pheomelanin, 0.0) * 2.9e14 * pow(lambda_nm, vec3(-4.75));
		return max(melanin * max(melanin_absorption_scale, 0.0), vec3(0.0));
	}
	vec3 safe_color = max(base_color, vec3(1e-3));
	vec3 x = log(safe_color) / max(unity_absorption_denominator(radial_roughness), 1e-4);
	return x * x;
}

vec3 sample_unity_azimuthal(float phi, float cos_theta_d, float radial_roughness) {
	ivec3 dims = textureSize(unity_azimuthal_lut, 0);
	vec3 half_texel = 0.5 / vec3(max(dims, ivec3(2)));
	vec3 uvw = vec3(
		(phi + TAU) / (2.0 * TAU),
		cos_theta_d,
		radial_roughness);
	uvw = clamp(uvw, half_texel, vec3(1.0) - half_texel);
	return max(texture(unity_azimuthal_lut, uvw).rgb, vec3(0.0));
}

vec3 unity_standard_bsdf(vec3 omega_i, vec3 omega_o_local) {
	float sin_theta_i = clamp(omega_i.x, -1.0, 1.0);
	float sin_theta_o = clamp(omega_o_local.x, -1.0, 1.0);
	float cos_theta_i = max(length(omega_i.yz), 1e-6);
	float cos_theta_o = max(length(omega_o_local.yz), 1e-6);
	float theta_i = asin(clamp(sin_theta_i, -0.999999, 0.999999));
	float theta_o = asin(clamp(sin_theta_o, -0.999999, 0.999999));
	float theta_h = 0.5 * (theta_i + theta_o);

	// HDRP GetHairAngleWorld convention: projected unsigned relative azimuth.
	float cos_phi = clamp(dot(omega_i.yz, omega_o_local.yz) / max(cos_theta_i * cos_theta_o, 1e-5), -1.0, 1.0);
	float phi = acos(cos_phi);

	float cos_theta = clamp(cos_theta_o * cos_theta_i + sin_theta_o * sin_theta_i, -1.0, 1.0);
	float cos_theta_d = sqrt(max(0.0, 0.5 + 0.5 * cos_theta));
	vec3 m = unity_gaussian(vec3(theta_h) - unity_alpha, unity_beta_variance);
	vec3 n = sample_unity_azimuthal(phi, cos_theta_d, unity_radial_roughness);

	// R: Unity half-angle Schlick Fresnel; no absorption on the surface path.
	float r_half_cos = sqrt(max(0.0, 0.5 + 0.5 * clamp(dot(omega_i, omega_o_local), -1.0, 1.0)));
	float a_r = hair_fresnel_ior(r_half_cos, ior);

	// TT/TRT: Unity's fixed-h attenuation approximation. The modified-index fit
	// is specific to human-hair eta=1.55, which the runtime LUT adapter pins.
	float eta_prime = 1.19 / max(cos_theta_d, 1e-5) + 0.36 * cos_theta_d;
	float cos_theta_t = sqrt(max(0.0, 1.0 - sin_theta_o * sin_theta_o / max(ior * ior, 1e-6)));

	float h_tt = 0.0;
	float cos_gamma_o_tt = 1.0;
	float f_tt = hair_fresnel_ior(cos_theta_o * cos_gamma_o_tt, ior);
	float sin_gamma_t_tt = h_tt / max(eta_prime, 1e-5);
	float cos_gamma_t_tt = sqrt(max(0.0, 1.0 - sin_gamma_t_tt * sin_gamma_t_tt));
	vec3 tr_tt = exp(-max(sigma_a, vec3(0.0)) * (2.0 * cos_gamma_t_tt / max(cos_theta_t, 1e-4)));
	vec3 a_tt = (1.0 - f_tt) * (1.0 - f_tt) * tr_tt;

	float h_trt = 0.86602540378;
	float cos_gamma_o_trt = sqrt(1.0 - h_trt * h_trt);
	float f_trt = hair_fresnel_ior(cos_theta_o * cos_gamma_o_trt, ior);
	float sin_gamma_t_trt = h_trt / max(eta_prime, 1e-5);
	float cos_gamma_t_trt = sqrt(max(0.0, 1.0 - sin_gamma_t_trt * sin_gamma_t_trt));
	vec3 tr_trt = exp(-max(sigma_a, vec3(0.0)) * (2.0 * cos_gamma_t_trt / max(cos_theta_t, 1e-4)));
	vec3 a_trt = (1.0 - f_trt) * (1.0 - f_trt) * f_trt * tr_trt * tr_trt;

	vec3 result = vec3(0.0);
	result += vec3(m.x * n.x * a_r * lobe_scales.x);
	result += m.y * n.y * a_tt * lobe_scales.y;
	result += m.z * n.z * a_trt * lobe_scales.z;
	return max(result, vec3(0.0));
}

vec3 unity_karis_multiple_scattering(vec3 base_color, vec3 omega_i, vec2 view_yz, float attenuation) {
	float luminance = max(dot(base_color, vec3(0.299, 0.587, 0.114)), 1e-4);
	return 0.25 * sqrt(max(base_color, vec3(0.0)))
		* (dot(omega_i.yz, view_yz) + 1.0)
		* pow(max(base_color / luminance, vec3(1e-4)), vec3(attenuation))
		* smoothstep(-0.5, 1.0, attenuation);
}

void vertex() {
	vertex_world = VERTEX;
}

void fragment() {
	vec3 tangent = texture(coords_texture, UV).rgb * 2.0 - 1.0;
	float u = texture(coords_texture, UV).a;
	float coverage = texture(attributes_texture, UV).r;
	float depth = texture(attributes_texture, UV).g;
	float seed = texture(attributes_texture, UV).b;
	const mat4 bayer4x4 = mat4(
		vec4(0.01, 8.0, 2.0, 10.0), vec4(12.0, 4.0, 14.0, 6.0),
		vec4(3.0, 11.0, 1.0, 9.0), vec4(15.0, 7.0, 13.0, 5.0)) / 16.0;
	float bayer_time = freeze_bayer_phase ? 0.0 : TIME;
	ivec2 id = ivec2(FRAGCOORD.xy + UV.xy * vec2(textureSize(attributes_texture, 0) * 2) + bayer_time * 500.0);
	float dist = length((CAMERA_POSITION_WORLD - vertex_world) / MODEL_MATRIX[0].xyz) / tan(PI / 6.0) / PROJECTION_MATRIX[1][1];
	float bias = max((1.0 - clamp((dist - 1.0) * 0.5, 0.0, 1.0)) * (1.0 - depth * depth), 0.1);
	if (!show_hair_cards && pow(coverage, bias) < bayer4x4[id.x % 4][id.y % 4]) discard;
	strand_depth = depth;

	vec3 hash = hair_hash13(seed);
	ALBEDO = show_hashed_strands ? hash : albedo * smoothstep(-0.2, 0.2, u * (1.0 - coverage));
	SPECULAR = specular;
	ROUGHNESS = longitudinal_roughness;
	float frizz = 0.5 * longitudinal_roughness * hair_bias_power(u, 1.0 - longitudinal_roughness);
	TANGENT = normalize(mat3(TANGENT, BINORMAL, NORMAL) * tangent + (hash * 2.0 - 1.0) * frizz);
	NORMAL = normalize(NORMAL - TANGENT * dot(NORMAL, TANGENT));
	BINORMAL = cross(TANGENT, NORMAL);
	inv_tangent_matrix = transpose(mat3(TANGENT, BINORMAL, NORMAL));
	omega_o = inv_tangent_matrix * VIEW;

	// Literal Unity Standard longitudinal parameterization: separable theta_h
	// Gaussian with R/TT/TRT shifts (-1,+0.5,+1.5) and widths (1,0.5,2).
	float perceptual_l = max(longitudinal_roughness, 0.01);
	unity_alpha = vec3(-1.0, 0.5, 1.5) * cuticle_tilt_offset;
	vec3 roughness = vec3(perceptual_l, 0.5 * perceptual_l, 2.0 * perceptual_l);
	unity_beta_variance = roughness * roughness;
	unity_radial_roughness = clamp(azimuthal_roughness, 0.0, 0.99);
	sigma_a = unity_absorption_coefficient(albedo, unity_radial_roughness);
}

void light() {
	vec3 omega_i = inv_tangent_matrix * LIGHT;
	vec3 single_scattering = unity_standard_bsdf(omega_i, omega_o);
	vec3 area_specular_multiplier = (LIGHT_IS_AREA && use_area_light_multipliers) ? vec3(LIGHT_AREA_SPECULAR_MULTIPLIER) : vec3(1.0);
	SPECULAR_LIGHT += comparison_exposure_gain * single_scattering * LIGHT_COLOR * ATTENUATION * specular * area_specular_multiplier;
	float yz_len2 = dot(omega_o.yz, omega_o.yz);
	vec2 view_yz = yz_len2 > 1e-8 ? omega_o.yz * inversesqrt(yz_len2) : vec2(0.0, 1.0);
	vec3 multiple = unity_karis_multiple_scattering(ALBEDO, omega_i, view_yz, ATTENUATION);
	DIFFUSE_LIGHT += comparison_exposure_gain * multiple * LIGHT_COLOR / PI;
}
