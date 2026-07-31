// Tier 1 Kajiya–Kay helpers. This include intentionally contains only the
// inexpensive two-lobe approximation used by hair_approx.gdshader.

group_uniforms KajiyaKay;
/** Independent tint for the primary Kajiya–Kay specular lobe. */
uniform vec3 primary_color : source_color = vec3(1.0);
/** Independent tint for the secondary Kajiya–Kay specular lobe. */
uniform vec3 secondary_color : source_color = vec3(0.45);
/** Tangent shift for the primary lobe. */
uniform float primary_shift : hint_range(-1.0, 1.0) = 0.0;
/** Tangent shift for the secondary lobe. */
uniform float secondary_shift : hint_range(-1.0, 1.0) = 0.12;
/** Roughness converted to a bounded Kajiya–Kay exponent. */
uniform float primary_roughness : hint_range(0.0, 1.0) = 0.3;
/** Roughness converted to a bounded Kajiya–Kay exponent. */
uniform float secondary_roughness : hint_range(0.0, 1.0) = 0.55;
/** Strength of the primary lobe. */
uniform float primary_strength : hint_range(0.0, 4.0) = 1.0;
/** Strength of the secondary lobe. */
uniform float secondary_strength : hint_range(0.0, 4.0) = 0.35;
/** Wrapped diffuse/scatter amount. */
uniform float scatter : hint_range(0.0, 1.0) = 0.35;
group_uniforms;

group_uniforms Debug;
// Keep the current high shader's debug parameter name and shape intact. The
// first two components isolate the primary and secondary Tier 1 lobes.
uniform vec3 lobe_scales = vec3(1.0);
uniform bool show_primary_lobe = true;
uniform bool show_secondary_lobe = true;
group_uniforms;


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


/** Schlick's bias approximation, guarded against a zero bias parameter. */
float power(float x, float t) {
	float safe_t = clamp(t, 1e-4, 1.0);
	float safe_x = clamp(x, 0.0, 1.0);
	return safe_x / ((1.0 / safe_t - 2.0) * (1.0 - safe_x) + 1.0);
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
