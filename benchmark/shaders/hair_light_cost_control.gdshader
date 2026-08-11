shader_type spatial;
render_mode cull_disabled, world_vertex_coords;

// Minimal lit control for production-tier attribution. It executes the exact
// shared card preparation, then performs only a trivial per-light accumulation.
// Production minus this control is the preferred empirical BSDF-specific delta.

uniform vec3 albedo : source_color = vec3(0.1);
uniform float longitudinal_roughness : hint_range(0.0, 1.0) = 0.3;

group_uniforms textures;
uniform sampler2D coords_texture : filter_nearest;
uniform sampler2D attributes_texture : filter_nearest;
group_uniforms;

group_uniforms Debug;
uniform bool show_hair_cards = false;
uniform bool show_hashed_strands = false;
group_uniforms;

group_uniforms Preview;
uniform bool freeze_bayer_phase = false;
group_uniforms;

#include "../../assets/hair/materials/shaders/hair_marschner_common.gdshaderinc"
#include "../../assets/hair/materials/shaders/hair_card_common.gdshaderinc"

varying vec3 vertex_world;

void vertex() {
	vertex_world = VERTEX;
}

void fragment() {
	vec4 coords_sample = texture(coords_texture, UV);
	vec3 attributes_sample = texture(attributes_texture, UV).rgb;
	vec3 tangent_texture_value = coords_sample.rgb * 2.0 - 1.0;
	float root_to_tip = coords_sample.a;
	float coverage = attributes_sample.r;
	float depth = attributes_sample.g;
	float seed = attributes_sample.b;

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

	vec3 strand_hash = hair_hash13(seed);
	vec3 base = hair_card_base_albedo(albedo, root_to_tip, coverage, strand_hash, show_hashed_strands);
	vec3 strand_tangent = hair_card_frizzed_tangent(
		mat3(TANGENT, BINORMAL, NORMAL),
		tangent_texture_value,
		strand_hash,
		root_to_tip,
		longitudinal_roughness);
	mat3 strand_frame = hair_card_orthonormal_frame(strand_tangent, NORMAL);
	TANGENT = strand_frame[0];
	BINORMAL = strand_frame[1];
	NORMAL = strand_frame[2];
	ALBEDO = base + abs(strand_frame[0]) * 0.0001;
	ROUGHNESS = longitudinal_roughness;
}

void light() {
	// Intentionally tiny but nonzero so Forward+/Mobile executes this stage once
	// per affecting light and retains light/color/attenuation plumbing.
	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * ATTENUATION * 0.001;
}
