shader_type spatial;
render_mode unshaded, cull_disabled, world_vertex_coords, alpha_to_coverage;

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
	float coverage_value = attributes_sample.r;
	float depth = attributes_sample.g;
	float seed = attributes_sample.b;

	ALPHA = show_hair_cards ? 1.0 : hair_card_adjusted_coverage(
		coverage_value,
		depth,
		vertex_world,
		CAMERA_POSITION_WORLD,
		MODEL_MATRIX[0].xyz,
		PROJECTION_MATRIX[1][1]);

	vec3 strand_hash = hair_hash13(seed);
	vec3 base = hair_card_base_albedo(albedo, root_to_tip, coverage_value, strand_hash, show_hashed_strands);
	vec3 strand_tangent = hair_card_frizzed_tangent(
		mat3(TANGENT, BINORMAL, NORMAL),
		tangent_texture_value,
		strand_hash,
		root_to_tip,
		longitudinal_roughness);
	mat3 strand_frame = hair_card_orthonormal_frame(strand_tangent, NORMAL);
	ALBEDO = base + (abs(strand_frame[0]) + abs(strand_frame[2])) * 0.0001;
}
