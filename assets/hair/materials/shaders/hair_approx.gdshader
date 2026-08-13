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

group_uniforms Coverage;
/** Static phase 0 is the default. The runtime coverage controller advances this
 *  only for the TAA-temporal policy. */
uniform int bayer_phase_index : hint_range(0, 15) = 0;
group_uniforms;

group_uniforms Preview;
/** Presentation-only gain used by the standalone visual comparison. */
uniform float comparison_exposure_gain : hint_range(0.25, 8.0) = 1.0;
group_uniforms;

#include "./hair_marschner_common.gdshaderinc"
#include "./hair_card_common.gdshaderinc"
#include "./hair_kajiya_kay.gdshaderinc"

varying vec3 vertex_world;
varying vec2 beta;
varying vec3 strand_tangent;


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
	beta = vec2(longitudinal_roughness, azimuthal_roughness);

	if (!hair_card_should_keep_phase(
		coverage,
		depth,
		vertex_world,
		UV,
		FRAGCOORD.xy,
		textureSize(attributes_texture, 0),
		bayer_phase_index,
		show_hair_cards,
		CAMERA_POSITION_WORLD,
		MODEL_MATRIX[0].xyz,
		PROJECTION_MATRIX[1][1])) discard;

	vec3 hash = hair_hash13(seed);
	ALBEDO = hair_card_base_albedo(albedo, u, coverage, hash, show_hashed_strands);
	SPECULAR = specular;
	ROUGHNESS = beta[0];

	TANGENT = hair_card_frizzed_tangent(
		mat3(TANGENT, BINORMAL, NORMAL),
		tangent_texture_value,
		hash,
		u,
		beta[0]);
	mat3 strand_frame = hair_card_orthonormal_frame(TANGENT, NORMAL);
	TANGENT = strand_frame[0];
	BINORMAL = strand_frame[1];
	NORMAL = strand_frame[2];
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
	DIFFUSE_LIGHT += comparison_exposure_gain * ALBEDO * diffuse * LIGHT_COLOR * ATTENUATION
		* (LIGHT_IS_AREA ? vec3(LIGHT_AREA_DIFFUSE_MULTIPLIER) : vec3(1.0)) / PI;

	vec3 specular_light = ALBEDO * (
		primary_color * primary_lobe * primary_strength * primary_debug_scale
		+ secondary_color * secondary_lobe * secondary_strength * secondary_debug_scale
	);
	SPECULAR_LIGHT += comparison_exposure_gain * specular_light * LIGHT_COLOR * ATTENUATION
		* (LIGHT_IS_AREA ? vec3(LIGHT_AREA_SPECULAR_MULTIPLIER) : vec3(1.0)) * specular;
}