// Standardized projected-R LUT diagnostic wrapper.
//
// This wrapper keeps the shipping fast shader untouched and swaps only the R
// longitudinal/azimuthal product through the standardized-Q diagnostic body.
// Low beta uses the fp32-safe asymptotic limit, negligible |q| tails are
// explicitly zeroed, and grazing LUT footprints use physical-corner
// renormalized trilinear interpolation. Direct Bessel remains only as a
// diagnostic fallback for unresolved cone-pole/high-beta cases.
shader_type spatial;
render_mode cull_disabled, world_vertex_coords;

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

group_uniforms Preview;
uniform bool freeze_bayer_phase = false;
uniform float comparison_exposure_gain : hint_range(0.25, 8.0) = 1.0;
group_uniforms;

group_uniforms Validation;
uniform bool use_area_light_multipliers = true;
group_uniforms;

group_uniforms RStandardizedLUT;
uniform sampler3D r_standardized_lut : filter_linear, repeat_disable;
uniform bool r_standardized_lut_log_decode = false;
uniform vec2 r_standardized_lut_q_range = vec2(-12.0, 12.0);
uniform vec2 r_standardized_lut_theta_cone_range = vec2(-1.5707963267948966, 1.5707963267948966);
uniform vec2 r_standardized_lut_beta_range = vec2(0.02, 9.0);
uniform vec2 r_standardized_lut_low_beta_blend = vec2(0.015, 0.03);
/** The 512x128 complete-R matrix measured the total reflected R energy beyond
 *  |q|=8 at <= ~2e-10 of the tested cases. Return Q=0 outside this threshold
 *  instead of evaluating the direct reference. */
uniform float r_standardized_lut_zero_tail_abs : hint_range(4.0, 12.0) = 8.0;
group_uniforms;

#define FM_LONGITUDINAL_MODE 0
#define FM_R_LONGITUDINAL_MODE 0
#define FM_CUTICLE_TILT_CONVENTION 0
#define FM_R_STANDARDIZED_LUT_MODE 0

#include "./hair_marschner_fast_r_standardized_body.gdshaderinc"
