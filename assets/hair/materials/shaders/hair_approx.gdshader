shader_type spatial;
render_mode cull_disabled, world_vertex_coords;

/** The averaged hair color used by the diffuse/scatter approximation. */
uniform vec3 albedo : source_color = vec3(0.1);

/** Existing base controls retained so groom material assignments remain compatible. */
uniform float longitudinal_roughness : hint_range(0.0, 1.0) = 0.3;
uniform float azimuthal_roughness : hint_range(0.0, 1.0) = 0.8;
uniform float specular : hint_range(0.0, 1.0) = 1.0;
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

#include "./hair_kajiya_kay.gdshaderinc"

varying vec3 vertex_world;
varying vec2 beta;
varying vec3 strand_tangent;

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
	beta = vec2(longitudinal_roughness, azimuthal_roughness);

	// --- Alpha Hashing ---
	// This is intentionally the same Bayer matrix and coverage/depth bias as
	// the current shader so approximation changes only the lighting model.
	const mat4 bayer4x4 = mat4(
		vec4(0.01,  8.0,  2.0, 10.0),
		vec4(12.0,  4.0, 14.0,  6.0),
		vec4( 3.0, 11.0,  1.0,  9.0),
		vec4(15.0,  7.0, 13.0,  5.0)) / 16.0;

	ivec2 id = ivec2(FRAGCOORD.xy + UV.xy*vec2(textureSize(attributes_texture, 0)*2) + TIME*500.0); // FIXME: uh oh! this code is ass!
	float dist = length((CAMERA_POSITION_WORLD - vertex_world) / MODEL_MATRIX[0].xyz) / tan(PI/6.0) / PROJECTION_MATRIX[1][1];
	float bias = max((1.0 - clamp((dist - 1.0)*0.5, 0.0, 1.0))*(1.0 - depth*depth), 0.1);
	if (!show_hair_cards && pow(coverage, bias) < bayer4x4[id.x % 4][id.y % 4]) discard;

	// --- Built-ins ---
	vec3 hash = hash13(seed);
	// Keep the current darkening toward roots and the existing debug color.
	ALBEDO = show_hashed_strands ? hash : albedo * smoothstep(-0.2, 0.2, u*(1.0 - coverage));
	SPECULAR = specular;
	ROUGHNESS = beta[0];

	// --- Tangent (TBN) Matrix Calculation ---
	// This is the current per-strand frizz/TBN reconstruction used by the
	// high-quality shader, including its root-to-tip frizz progression.
	float frizz = 0.5 * beta[0] * power(u, 1.0 - beta[0]);
	TANGENT = normalize(mat3(TANGENT, BINORMAL, NORMAL)*tangent + (hash*2.0 - 1.0)*frizz);
	NORMAL = normalize(NORMAL - TANGENT*dot(NORMAL, TANGENT));
	BINORMAL = cross(TANGENT, NORMAL);
	strand_tangent = TANGENT;
}


void light() {
	vec3 light_direction = kk_safe_normalize(LIGHT, NORMAL);
	vec3 view_direction = kk_safe_normalize(VIEW, NORMAL);
	vec3 primary_tangent = kk_shifted_tangent(strand_tangent, NORMAL, primary_shift);
	vec3 secondary_tangent = kk_shifted_tangent(strand_tangent, NORMAL, secondary_shift);

	float primary_debug_scale = show_primary_lobe ? max(lobe_scales.x, 0.0) : 0.0;
	float secondary_debug_scale = show_secondary_lobe ? max(lobe_scales.y, 0.0) : 0.0;
	float primary_lobe = kk_specular_lobe(primary_tangent, light_direction, view_direction, primary_roughness);
	float secondary_lobe = kk_specular_lobe(secondary_tangent, light_direction, view_direction, secondary_roughness);

	// Cheap wrapped diffuse/scatter and both independently tinted lobes are
	// accumulated per light, preserving Forward+ light and shadow influence.
	float diffuse = kk_wrapped_diffuse(strand_tangent, light_direction, scatter);
	// Area lights contribute a diffuse multiplier. The LIGHT_AREA_* built-ins
	// are used directly (never assigned to typed locals): Godot 4.7 declares
	// them vec3 in the shader language but generates them as scalar floats in
	// the light stage, so only a construction in place keeps both the source
	// and the generated code compilable on the NVIDIA driver.
	DIFFUSE_LIGHT += ALBEDO * diffuse * LIGHT_COLOR * ATTENUATION
		* (LIGHT_IS_AREA ? vec3(LIGHT_AREA_DIFFUSE_MULTIPLIER) : vec3(1.0)) / PI;

	vec3 specular_light = ALBEDO * (
		primary_color * primary_lobe * primary_strength * primary_debug_scale
		+ secondary_color * secondary_lobe * secondary_strength * secondary_debug_scale
	);
	SPECULAR_LIGHT += specular_light * LIGHT_COLOR * ATTENUATION
		* (LIGHT_IS_AREA ? vec3(LIGHT_AREA_SPECULAR_MULTIPLIER) : vec3(1.0)) * specular;
}
