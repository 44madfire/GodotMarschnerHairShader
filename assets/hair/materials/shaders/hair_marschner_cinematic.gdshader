shader_type spatial;
render_mode cull_disabled, world_vertex_coords;

// Production Cinematic Marschner tier.
// The high-tier baseline's non-separable azimuth-dependent cone/width and
// analytic N/A behavior are preserved. Only the expensive d'Eon longitudinal
// kernel is replaced by a generic angle-domain log-Q 3D LUT sampled once for
// each of R/TT/TRT, with a narrow-beta analytic fallback/transition.
//
// Uniforms remain in this top-level wrapper because Godot 4.7 runtime uniform
// reflection is unreliable for interfaces declared solely through includes.

uniform vec3 albedo : source_color = vec3(0.1);
uniform float longitudinal_roughness : hint_range(0.0, 1.0) = 0.3;
uniform float azimuthal_roughness : hint_range(0.0, 1.0) = 0.8;
uniform float specular : hint_range(0.0, 1.0) = 1.0;
uniform float cuticle_tilt_offset : hint_range(0.0, 0.5) = 0.1;

group_uniforms textures;
uniform sampler2D coords_texture : filter_nearest;
uniform sampler2D attributes_texture : filter_nearest;
uniform sampler3D cinematic_longitudinal_lut : filter_linear, repeat_disable;
group_uniforms;

group_uniforms Cinematic;
uniform float ior : hint_range(1.0, 2.0) = 1.55;
uniform vec2 cinematic_longitudinal_beta_range = vec2(0.05, 64.0);
uniform vec2 cinematic_longitudinal_low_beta_blend = vec2(0.05, 0.10);
group_uniforms;

group_uniforms Debug;
uniform bool show_hair_cards = false;
uniform bool show_hashed_strands = false;
uniform vec3 lobe_scales = vec3(1.0);
group_uniforms;

group_uniforms Preview;
uniform bool freeze_bayer_phase = false;
uniform float comparison_exposure_gain : hint_range(0.25, 8.0) = 1.0;
group_uniforms;

group_uniforms Validation;
uniform bool use_area_light_multipliers = true;
group_uniforms;

#define R 0
#define TT 1
#define TRT 2

varying vec3 vertex_world;
varying vec3 absorption_coefficient;
varying vec2 beta_reparam;
varying mat3 inv_tangent_matrix;
varying vec3 omega_o;

#include "./hair_marschner_common.gdshaderinc"
#include "./hair_marschner_cinematic_body.gdshaderinc"
