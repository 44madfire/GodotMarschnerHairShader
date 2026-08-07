// Standardized projected-R LUT diagnostic wrapper (Phase 4).
//
// Diagnostic compile-time selector override: FM_R_STANDARDIZED_LUT_MODE 1
// replaces ONLY the R lobe's longitudinal product in both the analytic and
// LUT BSDFs with the reconstruction
//     M_R * N_R = Q / (4 * sqrt(2) * beta_m * cos(theta_o)
//                       * sqrt(cos(theta_cone) * cos(theta_o)))
// where Q = beta_r * sqrt(cos(theta_cone) * cos(theta_o)) * cos(theta_o)
// * M_R is sampled from the committed standardized projected-R 3D LUT
// (r_standardized_lut, axes q/theta_cone/log2(beta_r), see
// benchmark/tools/generate_marschner_r_standardized_lut.gd and
// benchmark/reference/fast_marschner_r_standardized_kernel_reference.gd).
// Reconstructing M_R*N_R from Q avoids the 0*infinity form of the shipping
// 0.25*cos_phi_half*M_R product as beta_r -> 0. The direct/asymptotic
// reference fallback covers q/beta outside the LUT support, the cone-pole
// outer two theta_cone texel bands, grazing footprints, and beta_r <= 1e-8.
//
// Everything else stays shipping: FM_LONGITUDINAL_MODE 0 (Unity-standard
// longitudinal), FM_R_LONGITUDINAL_MODE 0 (no non-separable R override),
// FM_CUTICLE_TILT_CONVENTION 0 (baseline cuticle-tilt sign), and TT/TRT are
// never touched. The diagnostic wrapper declares the two additional
// standardized-R uniforms below; shipping wrappers keep
// FM_R_STANDARDIZED_LUT_MODE 0 (the include default) and never reference
// them.
//
// No duplicated shader body: the shared body lives in
// hair_marschner_fast_body.gdshaderinc and is included below.
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
/** Committed 256x256x128 RGBAF standardized projected-R kernel LUT
 *  (axes q in [-12, 12], theta_cone in [-PI/2, PI/2], log2(beta_r) linear
 *  with beta_r in [0.02, 9]; R = linear Q, G = log2(Q), B = 0, A = 1; see
 *  benchmark/tools/generate_marschner_r_standardized_lut.gd). Linear
 *  filtering with repeat disabled; every axis is half-texel clamped into the
 *  interior texel-center range so the clamped sample never wraps. */
uniform sampler3D r_standardized_lut : filter_linear, repeat_disable;
/** Decode selector for r_standardized_lut: false reads the R channel
 *  (linear Q), true reads the G channel and decodes Q = 2^G (trilinear
 *  interpolation in log2 space, matching the log2-beta axis). Both decodes
 *  return linear Q. */
uniform bool r_standardized_lut_log_decode = false;
group_uniforms;
#define FM_LONGITUDINAL_MODE 0
#define FM_R_LONGITUDINAL_MODE 0
#define FM_CUTICLE_TILT_CONVENTION 0
#define FM_R_STANDARDIZED_LUT_MODE 1

#include "./hair_marschner_fast_body.gdshaderinc"
