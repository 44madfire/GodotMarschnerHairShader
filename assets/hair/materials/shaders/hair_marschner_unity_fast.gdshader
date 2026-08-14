shader_type spatial;
render_mode cull_disabled, world_vertex_coords;

// Production Fast Marschner tier: a coherent Unity HDRP Standard-style model.
// M = separable Unity Gaussian, N = Unity preintegrated RGB azimuthal LUT,
// A = Unity fixed-h analytic Fresnel/Beer attenuation. This shader intentionally
// omits the baseline's non-separable d'Eon longitudinal cone/width machinery.
//
// Uniforms remain in this top-level wrapper (rather than only in the body
// include) because Godot 4.7 runtime uniform reflection is unreliable for
// interfaces declared solely through nested shader includes.

/** Base hair color. Used for visible strand color and multiple scattering; absorption mode 0 also derives the fiber absorption coefficient from this color. */
uniform vec3 albedo : source_color = vec3(0.1);
/** Perceptual roughness along the fiber. Lower values produce tighter R/TT/TRT longitudinal highlights; higher values broaden them and increase shared card frizz. */
uniform float longitudinal_roughness : hint_range(0.0, 1.0) = 0.3;
/** Perceptual roughness around the fiber. Controls the radial/azimuthal axis of the preintegrated Unity LUT; lower values are sharper and higher values are softer. */
uniform float azimuthal_roughness : hint_range(0.0, 1.0) = 0.8;
/** Master scale for the Fast Marschner single-scattering/specular contribution. */
uniform float specular : hint_range(0.0, 1.0) = 1.0;
/** Cuticle scale tilt in radians. Shifts the Fast R, TT, and TRT longitudinal lobes by their Unity-style offsets. */
uniform float cuticle_tilt_offset : hint_range(0.0, 0.5) = 0.1;

group_uniforms textures;
/** Groom geometry texture. RGB stores the strand tangent encoded from [-1, 1] into [0, 1]; A stores normalized root-to-tip position. */
uniform sampler2D coords_texture : filter_nearest;
/** Groom attribute texture. R stores coverage/occupancy, G stores strand depth, and B stores a deterministic per-strand seed used for variation/debugging. */
uniform sampler2D attributes_texture : filter_nearest;
/** Preintegrated 64x64x64 RGBA16F Unity-style azimuthal LUT. RGB stores the R, TT, and TRT azimuthal terms. HairMarschnerLUTAdapter binds the packaged texture automatically. */
uniform sampler3D unity_azimuthal_lut : filter_linear, repeat_disable;
group_uniforms;

group_uniforms Hair;
/** Effective fiber index of refraction used by the Fast model. The packaged LUT and modified-refraction fit are calibrated at 1.55, so HairMarschnerLUTAdapter pins this value during normal binding. */
uniform float ior : hint_range(1.0, 2.0) = 1.55;
/** Contract metadata recording the eta/IOR used to generate the Unity azimuthal LUT. Keep this synchronized with the LUT; the packaged asset uses 1.55. */
uniform float unity_azimuthal_lut_eta : hint_range(1.0, 2.0) = 1.55;
/** Selects the absorption model: 0 = derive absorption from Albedo, 1 = use the direct Absorption coefficient, 2 = derive absorption from Eumelanin/Pheomelanin. */
uniform int absorption_mode : hint_range(0, 2) = 0;
/** Direct RGB absorption coefficient used when Absorption Mode is 1. Larger values absorb more light inside the fiber. */
uniform vec3 absorption : source_color = vec3(0.1);
/** Relative eumelanin amount used when Absorption Mode is 2. Increasing it generally darkens/browns the modeled pigment absorption. */
uniform float eumelanin : hint_range(0.0, 1.0) = 0.2;
/** Relative pheomelanin amount used when Absorption Mode is 2. Increasing it raises the modeled reddish/yellow pigment contribution. */
uniform float pheomelanin : hint_range(0.0, 1.0) = 0.8;
/** Scale applied to the melanin absorption fit in mode 2. The small default is calibrated to the current Fast Marschner implementation. */
uniform float melanin_absorption_scale : hint_range(0.0, 0.01) = 0.001;
group_uniforms;

group_uniforms Wetness;
/** Optical wetness from 0 (dry) to 1 (saturated). This changes scattering only; groom clumping/shape changes are intentionally handled outside the shader. */
uniform float wetness : hint_range(0.0, 1.0) = 0.0;
/** Roughness of the added water-film highlight. Lower values produce a tighter, brighter wet streak. */
uniform float wet_film_roughness : hint_range(0.015, 1.0) = 0.10;
/** Intensity of the untinted dielectric water-film reflection at full wetness. */
uniform float wet_film_specular_strength : hint_range(0.0, 4.0) = 2.0;
/** Multiplier applied to longitudinal roughness at full wetness. Values below 1 sharpen the underlying fiber highlights. */
uniform float wet_longitudinal_roughness_scale : hint_range(0.05, 1.0) = 0.45;
/** Multiplier applied to azimuthal roughness at full wetness. Values below 1 sharpen the underlying fiber response. */
uniform float wet_azimuthal_roughness_scale : hint_range(0.05, 1.0) = 0.55;
/** Remaining multiple-scattering intensity at full wetness. Lower values make the hair body darker and denser. */
uniform float wet_internal_scatter_scale : hint_range(0.0, 1.0) = 0.35;
/** Remaining TT/TRT internal transmission at full wetness. R reflection is left intact and the water-film lobe is added separately. */
uniform float wet_transmission_scale : hint_range(0.0, 1.0) = 0.65;
/** Remaining cuticle-driven lobe shift at full wetness. Lower values make the coated surface behave optically smoother. */
uniform float wet_cuticle_shift_scale : hint_range(0.0, 1.0) = 0.5;
group_uniforms;

group_uniforms Debug;
/** Renders the full card geometry without coverage thinning. Use this to inspect card placement and UVs; disable it for final hair rendering. */
uniform bool show_hair_cards = false;
/** Replaces the authored hair color with deterministic per-strand hash colors so seed distribution and strand grouping are easy to inspect. */
uniform bool show_hashed_strands = false;
/** Per-lobe debug multiplier: X = R reflection, Y = TT transmission, Z = TRT internal-reflection/transmission. Keep at (1,1,1) for normal rendering. */
uniform vec3 lobe_scales = vec3(1.0);
group_uniforms;

group_uniforms Coverage;
/** Selects one of the 16 ordered-dither phases. Phase 0 is stable; HairCoverageController advances this once per rendered frame only for TAA temporal coverage. */
uniform int bayer_phase_index : hint_range(0, 15) = 0;
group_uniforms;

group_uniforms Preview;
/** Presentation-only exposure multiplier used by visual comparison/validation scenes. Leave at 1.0 for normal rendering. */
uniform float comparison_exposure_gain : hint_range(0.25, 8.0) = 1.0;
group_uniforms;

group_uniforms Validation;
/** Applies Godot's area-light specular multiplier to the Fast Marschner contribution. Keep enabled for normal rendering; disable only for controlled validation comparisons. */
uniform bool use_area_light_multipliers = true;
group_uniforms;

varying vec3 vertex_world;
varying vec3 sigma_a;
varying mat3 inv_tangent_matrix;
varying vec3 omega_o;
varying vec3 unity_alpha;
varying vec3 unity_beta_variance;
varying float unity_radial_roughness;
varying float strand_depth;

#include "./hair_marschner_common.gdshaderinc"
#include "./hair_card_common.gdshaderinc"
#include "./hair_marschner_unity_fast_body.gdshaderinc"
