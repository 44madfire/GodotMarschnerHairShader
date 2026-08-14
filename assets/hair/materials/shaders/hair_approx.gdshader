shader_type spatial;
render_mode cull_disabled, world_vertex_coords;

/** Base hair color used by the Approx tier for strand color, wrapped diffuse, and tinting the Kajiya–Kay highlights. */
uniform vec3 albedo : source_color = vec3(0.1);
/** Shared longitudinal roughness used for card frizz and the material roughness value. Kajiya–Kay highlight widths are controlled separately below. */
uniform float longitudinal_roughness : hint_range(0.0, 1.0) = 0.3;
/** Compatibility parameter retained across tiers. Approx / Kajiya–Kay lighting does not use azimuthal roughness directly. */
uniform float azimuthal_roughness : hint_range(0.0, 1.0) = 0.8;
/** Master scale for the Approx tier's Kajiya–Kay specular highlights. */
uniform float specular : hint_range(0.0, 1.0) = 1.0;
/** Compatibility parameter retained across tiers. Approx / Kajiya–Kay lighting does not use cuticle tilt directly. */
uniform float cuticle_tilt_offset : hint_range(0.0, 0.5) = 0.1;

group_uniforms textures;
/** Groom geometry texture. RGB stores the strand tangent encoded from [-1, 1] into [0, 1]; A stores normalized root-to-tip position. */
uniform sampler2D coords_texture : filter_nearest;
/** Groom attribute texture. R stores coverage/occupancy, G stores strand depth, and B stores a deterministic per-strand seed used for variation/debugging. */
uniform sampler2D attributes_texture : filter_nearest;
group_uniforms;

group_uniforms Wetness;
/** Optical wetness from 0 (dry) to 1 (saturated). This changes shading only; groom clumping/shape changes are intentionally handled outside the shader. */
uniform float wetness : hint_range(0.0, 1.0) = 0.0;
/** Roughness of the added water-film highlight. Lower values produce a tighter, brighter wet streak. */
uniform float wet_film_roughness : hint_range(0.015, 1.0) = 0.12;
/** Intensity of the untinted dielectric water-film reflection at full wetness. */
uniform float wet_film_specular_strength : hint_range(0.0, 4.0) = 1.25;
/** Multiplier applied to the Approx primary/secondary highlight roughness and material roughness at full wetness. */
uniform float wet_longitudinal_roughness_scale : hint_range(0.05, 1.0) = 0.45;
/** Marschner azimuthal endpoint retained for a consistent cross-tier wetness interface; Approx lighting does not use it directly. */
uniform float wet_azimuthal_roughness_scale : hint_range(0.05, 1.0) = 0.55;
/** Remaining wrapped diffuse/scatter intensity at full wetness. Lower values darken the body of the Approx hair response. */
uniform float wet_internal_scatter_scale : hint_range(0.0, 1.0) = 0.35;
/** Marschner TT/TRT endpoint retained for a consistent cross-tier wetness interface; Approx lighting has no physical transmission lobes. */
uniform float wet_transmission_scale : hint_range(0.0, 1.0) = 0.65;
/** Remaining Kajiya–Kay tangent-shift magnitude at full wetness. Lower values reduce separation between the two dry highlight lobes. */
uniform float wet_cuticle_shift_scale : hint_range(0.0, 1.0) = 0.5;
group_uniforms;

group_uniforms Debug;
/** Renders the full card geometry without coverage thinning. Use this to inspect card placement and UVs; disable it for final hair rendering. */
uniform bool show_hair_cards = false;
/** Replaces the authored hair color with deterministic per-strand hash colors so seed distribution and strand grouping are easy to inspect. */
uniform bool show_hashed_strands = false;
/** Per-lobe debug multiplier. X scales the primary lobe, Y scales the secondary lobe, and Z is retained for cross-tier parameter compatibility. */
uniform vec3 lobe_scales = vec3(1.0);
/** Enables the primary Kajiya–Kay lobe. Disable it to inspect the secondary lobe in isolation. */
uniform bool show_primary_lobe = true;
/** Enables the secondary Kajiya–Kay lobe. Disable it to inspect the primary lobe in isolation. */
uniform bool show_secondary_lobe = true;
group_uniforms;

group_uniforms KajiyaKay;
/** Tint applied to the primary Kajiya–Kay specular lobe. */
uniform vec3 primary_color : source_color = vec3(1.0);
/** Tint applied to the secondary Kajiya–Kay specular lobe. */
uniform vec3 secondary_color : source_color = vec3(0.45);
/** Signed tangent shift of the primary highlight. Positive values shift the effective tangent toward the surface normal. */
uniform float primary_shift : hint_range(-1.0, 1.0) = 0.0;
/** Signed tangent shift of the secondary highlight. Positive values shift the effective tangent toward the surface normal. */
uniform float secondary_shift : hint_range(-1.0, 1.0) = 0.12;
/** Width of the primary Kajiya–Kay highlight. Lower values are narrower/sharper; higher values are broader/softer. */
uniform float primary_roughness : hint_range(0.0, 1.0) = 0.3;
/** Width of the secondary Kajiya–Kay highlight. Lower values are narrower/sharper; higher values are broader/softer. */
uniform float secondary_roughness : hint_range(0.0, 1.0) = 0.55;
/** Intensity multiplier for the primary specular lobe before the common Specular control is applied. */
uniform float primary_strength : hint_range(0.0, 4.0) = 1.0;
/** Intensity multiplier for the secondary specular lobe before the common Specular control is applied. */
uniform float secondary_strength : hint_range(0.0, 4.0) = 0.35;
/** Amount of wrapped diffuse/scatter used by the inexpensive cylindrical lighting approximation. */
uniform float scatter : hint_range(0.0, 1.0) = 0.35;
group_uniforms;

group_uniforms Coverage;
/** Selects one of the 16 ordered-dither phases. Phase 0 is stable; HairCoverageController advances this once per rendered frame only for TAA temporal coverage. */
uniform int bayer_phase_index : hint_range(0, 15) = 0;
group_uniforms;

group_uniforms Preview;
/** Presentation-only exposure multiplier used by visual comparison/validation scenes. Leave at 1.0 for normal rendering. */
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