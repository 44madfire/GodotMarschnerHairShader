shader_type spatial;
render_mode unshaded, cull_disabled, world_vertex_coords;

// Synthetic ALU sensitivity probe. This is a device-calibration workload, not
// an instruction-count estimate for any production tier. It uses the exact
// shared card preparation and then performs a fixed dependent arithmetic chain.

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

	vec3 v = strand_frame[0] * 0.37 + strand_frame[1] * 0.21 + strand_hash * 0.13 + vec3(UV, seed) * 0.17;
	for (int i = 0; i < 96; i++) {
		float fi = float(i) * 0.000173;
		v = v.yzx * vec3(1.013, 0.997, 1.021) + v.zxy * vec3(0.071, -0.063, 0.057) + vec3(fi);
		v = v * v * 0.241 + v * 0.619 - vec3(0.117, 0.093, 0.131);
		v = clamp(v, vec3(-2.0), vec3(2.0));
	}

	ALBEDO = base + abs(v) * 0.00001;
}
