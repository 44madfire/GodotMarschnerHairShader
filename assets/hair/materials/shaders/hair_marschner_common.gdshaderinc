// Shared helpers for the production Marschner tiers.
// Keep this include free of uniforms/varyings so top-level wrappers expose
// their complete material interface to Godot's runtime uniform reflection.

vec3 hair_hash13(float p) {
	uvec3 v = uvec3(floatBitsToUint(p), 0u, 0u);
	v = v * 1664525u + 1013904223u;
	v.x += v.y*v.z; v.y += v.z*v.x; v.z += v.x*v.y;
	v ^= v >> 16u;
	v.x += v.y*v.z; v.y += v.z*v.x; v.z += v.x*v.y;
	return uintBitsToFloat((v & uvec3(0x007FFFFFu)) | uvec3(0x3F800000u)) - 1.0;
}

float hair_bias_power(float x, float t) {
	float safe_t = clamp(t, 1e-4, 1.0);
	float safe_x = clamp(x, 0.0, 1.0);
	return safe_x / ((1.0 / safe_t - 2.0) * (1.0 - safe_x) + 1.0);
}

float hair_fresnel_ior(float cos_theta, float eta) {
	float f0 = (1.0 - eta) * (1.0 - eta) / ((1.0 + eta) * (1.0 + eta));
	float p = 1.0 - clamp(cos_theta, 0.0, 1.0);
	float p2 = p * p;
	return mix(p2 * p2 * p, 1.0, f0);
}

// Optical wetness helpers. Wetness deliberately does not alter groom geometry;
// strand clumping/shape changes belong to the groom/deformation pipeline.
float hair_wet_effective_roughness(float dry_roughness, float saturated_scale, float wetness_amount) {
	float wet = clamp(wetness_amount, 0.0, 1.0);
	return max(1e-3, dry_roughness * mix(1.0, max(saturated_scale, 1e-3), wet));
}

float hair_wet_effective_cuticle_tilt(float dry_tilt, float saturated_scale, float wetness_amount) {
	return dry_tilt * mix(1.0, clamp(saturated_scale, 0.0, 1.0), clamp(wetness_amount, 0.0, 1.0));
}

float hair_wet_transport_multiplier(float saturated_scale, float wetness_amount) {
	return mix(1.0, clamp(saturated_scale, 0.0, 1.0), clamp(wetness_amount, 0.0, 1.0));
}

float hair_wet_roughness_to_power(float roughness) {
	float r = clamp(roughness, 0.015, 1.0);
	return clamp(2.0 / (r * r) - 2.0, 1.0, 8192.0);
}

// Cheap dielectric water-film lobe. It is intentionally separate from the
// underlying fiber IOR/LUT contract: Fast Marschner remains pinned to eta=1.55.
// The film uses water's approximate visible-light IOR (1.333), stays untinted,
// and forms a strand-aligned longitudinal highlight.
float hair_wet_film_specular(
		vec3 strand_tangent,
		vec3 light_direction,
		vec3 view_direction,
		float wetness_amount,
		float film_roughness,
		float film_strength) {
	float wet = clamp(wetness_amount, 0.0, 1.0);
	if (wet <= 0.0 || film_strength <= 0.0) {
		return 0.0;
	}

	vec3 t = normalize(strand_tangent);
	vec3 l = normalize(light_direction);
	vec3 v = normalize(view_direction);
	vec3 hv = l + v;
	float hv_len2 = dot(hv, hv);
	if (hv_len2 <= 1e-8) {
		return 0.0;
	}
	vec3 h = hv * inversesqrt(hv_len2);
	float tangent_half = clamp(dot(t, h), -1.0, 1.0);
	float transverse_half = sqrt(max(0.0, 1.0 - tangent_half * tangent_half));
	float longitudinal_lobe = pow(transverse_half, hair_wet_roughness_to_power(film_roughness));
	float view_half = clamp(dot(v, h), 0.0, 1.0);
	float water_fresnel = hair_fresnel_ior(view_half, 1.333);
	return wet * max(film_strength, 0.0) * water_fresnel * longitudinal_lobe;
}
