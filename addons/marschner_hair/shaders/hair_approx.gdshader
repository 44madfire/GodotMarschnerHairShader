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
uniform float wet_film_roughness : hint_range(0.015, 1.0) = 0.10;
/** Intensity of the untinted dielectric water-film reflection at full wetness. */
uniform float wet_film_specular_strength : hint_range(0.0, 4.0) = 2.0;
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

#include "./hair_common.gdshaderinc"
#include "./hair_card_common.gdshaderinc"
#include "./hair_kajiya_kay.gdshaderinc"

varying vec3 vertex_world;
varying vec2 beta;
varying vec3 strand_tangent;

#include "./hair_approx_body.gdshaderinc"
