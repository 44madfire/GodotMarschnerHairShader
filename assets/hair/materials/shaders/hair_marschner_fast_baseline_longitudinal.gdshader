// Baseline-compatible longitudinal diagnostic wrapper (PR4).
//
// Diagnostic compile-time selector override: FM_LONGITUDINAL_MODE 1 selects
// the separable sin(theta_o)-space Gaussian around the cone rotations
// vec3(-2.0, 1.0, 3.0)*cuticle_tilt_offset with standard deviations
// vec3(1.5, 0.75, 3.0)*beta_M (see fm_longitudinal_scattering in
// hair_marschner_fast.gdshaderinc). R stays on the shared longitudinal path
// (FM_R_LONGITUDINAL_MODE 0) and the cuticle-tilt convention stays baseline
// (FM_CUTICLE_TILT_CONVENTION 0).
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
#define FM_LONGITUDINAL_MODE 1
#define FM_R_LONGITUDINAL_MODE 0
#define FM_CUTICLE_TILT_CONVENTION 0

#include "./hair_marschner_fast_body.gdshaderinc"
