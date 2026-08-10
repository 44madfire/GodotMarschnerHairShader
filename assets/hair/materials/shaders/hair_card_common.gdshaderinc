// Shared hair-card preparation used by every production lighting model.
//
// Keep sampler/uniform declarations in each top-level .gdshader wrapper so
// Godot 4.7 runtime uniform reflection remains reliable. This include only
// centralizes the deterministic card coverage, root shading, frizz, and frame
// reconstruction math that must remain identical across shader variants.

const mat4 HAIR_CARD_BAYER_4X4 = mat4(
	vec4(0.01, 8.0, 2.0, 10.0),
	vec4(12.0, 4.0, 14.0, 6.0),
	vec4(3.0, 11.0, 1.0, 9.0),
	vec4(15.0, 7.0, 13.0, 5.0)) / 16.0;


float hair_card_coverage_bias(
	vec3 camera_position_world,
	vec3 vertex_world_position,
	vec3 model_x_axis,
	float projection_y_scale,
	float depth
) {
	float dist = length((camera_position_world - vertex_world_position) / model_x_axis)
		/ tan(PI / 6.0) / projection_y_scale;
	return max((1.0 - clamp((dist - 1.0) * 0.5, 0.0, 1.0)) * (1.0 - depth * depth), 0.1);
}


bool hair_card_should_keep(
	float coverage,
	float depth,
	vec3 vertex_world_position,
	vec2 uv,
	vec2 fragcoord,
	ivec2 attributes_size,
	float bayer_time,
	bool show_cards,
	vec3 camera_position_world,
	vec3 model_x_axis,
	float projection_y_scale
) {
	if (show_cards) {
		return true;
	}
	ivec2 id = ivec2(fragcoord + uv * vec2(attributes_size * 2) + bayer_time * 500.0);
	float bias = hair_card_coverage_bias(
		camera_position_world,
		vertex_world_position,
		model_x_axis,
		projection_y_scale,
		depth);
	return pow(coverage, bias) >= HAIR_CARD_BAYER_4X4[id.x % 4][id.y % 4];
}


vec3 hair_card_base_albedo(
	vec3 base_color,
	float root_to_tip,
	float coverage,
	vec3 strand_hash,
	bool show_hashed_strands
) {
	return show_hashed_strands
		? strand_hash
		: base_color * smoothstep(-0.2, 0.2, root_to_tip * (1.0 - coverage));
}


float hair_card_frizz_amount(float longitudinal_roughness, float root_to_tip) {
	return 0.5 * longitudinal_roughness
		* hair_bias_power(root_to_tip, 1.0 - longitudinal_roughness);
}


vec3 hair_card_frizzed_tangent(
	mat3 surface_tbn,
	vec3 tangent_texture_value,
	vec3 strand_hash,
	float root_to_tip,
	float longitudinal_roughness
) {
	float frizz = hair_card_frizz_amount(longitudinal_roughness, root_to_tip);
	return normalize(
		surface_tbn * tangent_texture_value
		+ (strand_hash * 2.0 - 1.0) * frizz);
}


mat3 hair_card_orthonormal_frame(vec3 strand_tangent, vec3 surface_normal) {
	vec3 tangent = normalize(strand_tangent);
	vec3 normal = normalize(surface_normal - tangent * dot(surface_normal, tangent));
	vec3 binormal = cross(tangent, normal);
	return mat3(tangent, binormal, normal);
}
