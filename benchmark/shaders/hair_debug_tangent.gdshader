shader_type spatial;
render_mode unshaded, cull_disabled, world_vertex_coords;

// Diagnostic-only strand tangent view. The discard and card data path are
// intentionally identical to the current hair shader; only the final color
// is replaced with the reconstructed tangent transformed from view space to
// world space and encoded as RGB.

uniform vec3 albedo : source_color = vec3(0.1);
uniform float longitudinal_roughness : hint_range(0.0, 1.0) = 0.3;
uniform float azimuthal_roughness : hint_range(0.0, 1.0) = 0.8;
uniform float specular : hint_range(0.0, 1.0) = 1.0;
uniform float cuticle_tilt_offset : hint_range(0.0, 0.5) = 0.1;

group_uniforms textures;
uniform sampler2D coords_texture : filter_nearest;
uniform sampler2D attributes_texture : filter_nearest;
group_uniforms;

group_uniforms Debug;
uniform bool show_hair_cards = false;
uniform bool show_hashed_strands = false;
group_uniforms;

#define M 0

varying vec3 vertex_world;
varying vec2 beta;


/** Returns a random vec3 in [0, 1) using the current PCG hash path. */
vec3 hash13(float p) {
	uvec3 v = uvec3(floatBitsToUint(p), 0u, 0u);

	v = v * 1664525u + 1013904223u;
	v.x += v.y*v.z; v.y += v.z*v.x; v.z += v.x*v.y;
	v ^= v >> 16u;
	v.x += v.y*v.z; v.y += v.z*v.x; v.z += v.x*v.y;

	return uintBitsToFloat((v & uvec3(0x007FFFFFu)) | uvec3(0x3F800000u)) - 1.0;
}


/** Current root-to-tip frizz bias approximation. */
float power(float x, float t) {
	return x / ((1.0/t - 2.0)*(1.0 - x) + 1.0);
}


void vertex() {
	vertex_world = VERTEX;
}


void fragment() {
	// Keep tangent/U and coverage/depth/seed channel assignments unchanged.
	vec3 tangent = texture(coords_texture, UV).rgb*2.0 - 1.0;
	float u = texture(coords_texture, UV).a;
	float coverage = texture(attributes_texture, UV).r;
	float depth = texture(attributes_texture, UV).g;
	float seed = texture(attributes_texture, UV).b;
	beta = vec2(longitudinal_roughness, azimuthal_roughness);

	// Keep the exact Bayer matrix, TIME-based hash coordinate, and distance /
	// depth bias used by the current hair card shader.
	const mat4 bayer4x4 = mat4(
		vec4(0.01,  8.0,  2.0, 10.0),
		vec4(12.0,  4.0, 14.0,  6.0),
		vec4( 3.0, 11.0,  1.0,  9.0),
		vec4(15.0,  7.0, 13.0,  5.0)) / 16.0;

	ivec2 id = ivec2(FRAGCOORD.xy + UV.xy*vec2(textureSize(attributes_texture, 0)*2) + TIME*500.0);
	float dist = length((CAMERA_POSITION_WORLD - vertex_world) / MODEL_MATRIX[0].xyz) / tan(PI/6.0) / PROJECTION_MATRIX[1][1];
	float bias = max((1.0 - clamp((dist - 1.0)*0.5, 0.0, 1.0))*(1.0 - depth*depth), 0.1);
	if (!show_hair_cards && pow(coverage, bias) < bayer4x4[id.x % 4][id.y % 4]) discard;

	// Reconstruct the current per-strand frizz/TBN. TANGENT is view-space in
	// this fragment stage, so transform it to world space before RGB encoding.
	vec3 hash = hash13(seed);
	float frizz = 0.5 * beta[M] * power(u, 1.0 - beta[M]);
	TANGENT = normalize(mat3(TANGENT, BINORMAL, NORMAL)*tangent + (hash*2.0 - 1.0)*frizz);
	NORMAL = normalize(NORMAL - TANGENT*dot(NORMAL, TANGENT));
	BINORMAL = cross(TANGENT, NORMAL);

	vec3 world_tangent = normalize((INV_VIEW_MATRIX * vec4(TANGENT, 0.0)).xyz);
	ALBEDO = world_tangent*0.5 + 0.5;
	EMISSION = ALBEDO;
	SPECULAR = 0.0;
	ROUGHNESS = 1.0;
}
