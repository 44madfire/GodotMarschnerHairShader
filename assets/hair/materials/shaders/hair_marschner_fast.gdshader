// Shipping fast Marschner selector wrapper (PR4 refactor).
//
// This file is intentionally small: it defines the shipping compile-time
// selectors and includes the shared body. All uniforms, varyings, and the
// vertex/fragment/light functions live in hair_marschner_fast_body.gdshaderinc;
// the numeric selectors themselves are guarded with #ifndef in
// hair_marschner_fast.gdshaderinc so a wrapper-defined value is honored and
// the include's defaults apply only when the common include is used directly.
//
// Shipping selectors (identical to the pre-refactor defaults):
//   FM_LONGITUDINAL_MODE 0        Unity-standard theta_h Gaussian longitudinal
//   FM_R_LONGITUDINAL_MODE 0      R lobe keeps the shared longitudinal path
//   FM_CUTICLE_TILT_CONVENTION 0  baseline-compatible cuticle tilt sign
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
#define FM_LONGITUDINAL_MODE 0
#define FM_R_LONGITUDINAL_MODE 0
#define FM_CUTICLE_TILT_CONVENTION 0

#include "./hair_marschner_fast_body.gdshaderinc"
