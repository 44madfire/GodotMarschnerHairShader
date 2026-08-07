// Standardized projected-R LUT diagnostic wrapper.
//
// This wrapper keeps the shipping fast shader untouched and swaps only the R
// longitudinal/azimuthal product through the fp32-safe standardized-Q body.
// Low beta uses the asymptotic Q limit and blends into the LUT; the direct
// rounded-Bessel reference is reserved for beta values above the blend where
// fp32 cancellation is no longer pathological. TT/TRT and all other Fast
// Marschner paths remain shipping-equivalent.
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
/** Standardized projected-R kernel LUT. The current committed diagnostic
 *  resource is 256x256x128 RGBAF, with R=linear Q and G=log2(Q). */
uniform sampler3D r_standardized_lut : filter_linear, repeat_disable;
/** false = linear-Q R channel; true = log2-Q G channel. Linear remains the
 *  default because the 512x128 CPU matrix measured lower aggregate error. */
uniform bool r_standardized_lut_log_decode = false;
/** Runtime LUT-domain contract. The controller should bind these from the
 *  resource metadata; defaults match standardized_r_projected_q_v1. */
uniform vec2 r_standardized_lut_q_range = vec2(-12.0, 12.0);
uniform vec2 r_standardized_lut_theta_cone_range = vec2(-1.5707963267948966, 1.5707963267948966);
uniform vec2 r_standardized_lut_beta_range = vec2(0.02, 9.0);
/** fp32-safe transition: beta<=0.015 is asymptotic only; beta>=0.03 uses the
 *  LUT/direct high-beta boundary policy, with a smooth blend between. */
uniform vec2 r_standardized_lut_low_beta_blend = vec2(0.015, 0.03);
group_uniforms;

#define FM_LONGITUDINAL_MODE 0
#define FM_R_LONGITUDINAL_MODE 0
#define FM_CUTICLE_TILT_CONVENTION 0
// Keep the old shared standardized implementation compiled out. The corrected
// diagnostic body below performs the R replacement after evaluating the
// unmodified shipping analytic BSDF.
#define FM_R_STANDARDIZED_LUT_MODE 0

#include "./hair_marschner_fast_r_standardized_body.gdshaderinc"
