// Approx (Kajiya–Kay) production body.
// The top-level wrapper owns every uniform/varying declaration so Godot 4.7
// exposes the complete material interface through get_shader_uniform_list().
// Coverage is selected at compile time: the normal wrapper discards below the
// ordered-dither threshold, while the alpha-to-coverage wrapper writes ALPHA.

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

#ifdef HAIR_COVERAGE_ALPHA_TO_COVERAGE
	ALPHA = show_hair_cards ? 1.0 : hair_card_adjusted_coverage(
		coverage,
		depth,
		vertex_world,
		CAMERA_POSITION_WORLD,
		MODEL_MATRIX[0].xyz,
		PROJECTION_MATRIX[1][1]);
#else
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
#endif

	vec3 hash = hair_hash13(seed);
	ALBEDO = hair_card_base_albedo(albedo, u, coverage, hash, show_hashed_strands);
	SPECULAR = specular;
	ROUGHNESS = hair_wet_effective_roughness(beta[0], wet_longitudinal_roughness_scale, wetness);

	// Wetness is optical only: preserve the dry roughness for tangent/frizz so
	// this shader never substitutes for groom clumping/deformation.
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
	float shift_scale = hair_wet_transport_multiplier(wet_cuticle_shift_scale, wetness);
	vec3 primary_tangent = kk_shifted_tangent(strand_tangent, NORMAL, primary_shift * shift_scale);
	vec3 secondary_tangent = kk_shifted_tangent(strand_tangent, NORMAL, secondary_shift * shift_scale);

	float primary_debug_scale = show_primary_lobe ? max(lobe_scales.x, 0.0) : 0.0;
	float secondary_debug_scale = show_secondary_lobe ? max(lobe_scales.y, 0.0) : 0.0;
	float wet_primary_roughness = hair_wet_effective_roughness(primary_roughness, wet_longitudinal_roughness_scale, wetness);
	float wet_secondary_roughness = hair_wet_effective_roughness(secondary_roughness, wet_longitudinal_roughness_scale, wetness);
	float primary_lobe = kk_specular_lobe(primary_tangent, light_direction, view_direction, wet_primary_roughness);
	float secondary_lobe = kk_specular_lobe(secondary_tangent, light_direction, view_direction, wet_secondary_roughness);

	float diffuse = kk_wrapped_diffuse(strand_tangent, light_direction, scatter)
		* hair_wet_transport_multiplier(wet_internal_scatter_scale, wetness);
	DIFFUSE_LIGHT += comparison_exposure_gain * ALBEDO * diffuse * LIGHT_COLOR * ATTENUATION
		* (LIGHT_IS_AREA ? vec3(LIGHT_AREA_DIFFUSE_MULTIPLIER) : vec3(1.0)) / PI;

	vec3 specular_light = ALBEDO * (
		primary_color * primary_lobe * primary_strength * primary_debug_scale
		+ secondary_color * secondary_lobe * secondary_strength * secondary_debug_scale
	);
	float wet_film = hair_wet_film_specular(strand_tangent, light_direction, view_direction, wetness, wet_film_roughness, wet_film_specular_strength);
	specular_light += vec3(wet_film);
	SPECULAR_LIGHT += comparison_exposure_gain * specular_light * LIGHT_COLOR * ATTENUATION
		* (LIGHT_IS_AREA ? vec3(LIGHT_AREA_SPECULAR_MULTIPLIER) : vec3(1.0)) * specular;
}
