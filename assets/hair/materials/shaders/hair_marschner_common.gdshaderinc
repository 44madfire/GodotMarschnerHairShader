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
