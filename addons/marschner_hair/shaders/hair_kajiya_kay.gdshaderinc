// Tier 1 Kajiya–Kay helpers. This include intentionally contains only the
// inexpensive two-lobe approximation used by hair_approx.gdshader. The
// KajiyaKay/Debug uniforms are declared in the consuming shaders so the
// editor's hover tooltips, which only scan the main shader file, can display
// their descriptions.


/** A normalize operation with a deterministic fallback for degenerate vectors. */
vec3 kk_safe_normalize(vec3 value, vec3 fallback) {
	float value_length_squared = dot(value, value);
	if (value_length_squared > 1e-8) {
		return value * inversesqrt(value_length_squared);
	}

	float fallback_length_squared = dot(fallback, fallback);
	if (fallback_length_squared > 1e-8) {
		return fallback * inversesqrt(fallback_length_squared);
	}
	return vec3(0.0, 1.0, 0.0);
}


/** Maps perceptual roughness to a bounded Kajiya–Kay longitudinal power. */
float kk_roughness_to_power(float roughness) {
	float safe_roughness = clamp(roughness, 1e-3, 1.0);
	return clamp(2.0 / (safe_roughness * safe_roughness) - 2.0, 1.0, 2048.0);
}


/** Shifts a strand tangent while retaining a stable tangent fallback. */
vec3 kk_shifted_tangent(vec3 tangent, vec3 normal, float shift) {
	return kk_safe_normalize(tangent + normal * shift, tangent);
}


/** Kajiya–Kay's azimuthally averaged longitudinal lobe. */
float kk_specular_lobe(vec3 tangent, vec3 light_direction, vec3 view_direction, float roughness) {
	// Opposing light and view vectors make L+V undefined. Falling back to the
	// strand direction keeps the result finite and produces no artificial spike.
	vec3 half_vector = kk_safe_normalize(light_direction + view_direction, tangent);
	float tangent_half = clamp(dot(tangent, half_vector), -1.0, 1.0);
	float transverse_half = sqrt(max(0.0, 1.0 - tangent_half * tangent_half));
	return pow(transverse_half, kk_roughness_to_power(roughness));
}


/** Cheap wrapped diffuse term for a cylindrical strand cross-section. */
float kk_wrapped_diffuse(vec3 tangent, vec3 light_direction, float scatter_amount) {
	float tangent_light = clamp(dot(tangent, light_direction), -1.0, 1.0);
	float transverse_light = sqrt(max(0.0, 1.0 - tangent_light * tangent_light));
	float safe_scatter = clamp(scatter_amount, 0.0, 1.0);
	return clamp((transverse_light + safe_scatter) / (1.0 + safe_scatter), 0.0, 1.0);
}
