// Tier 2 fast Marschner helpers. This include intentionally contains only the
// analytic (LUT-free) fast Marschner slice used by hair_marschner_fast.gdshader,
// plus the opt-in Stage-B preintegrated (LUT-backed) local dual-scattering
// slice (FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED). The Stage-A analytic
// fallback fm_dual_scattering() stays intact and is the default.
//
// Longitudinal scattering is selected by the single numeric compile-time
// selector FM_LONGITUDINAL_MODE below. Mode 0 (shipping default,
// Unity-standard) is a normalized variance-form Gaussian evaluated at
// theta_h = 0.5*(theta_i + theta_o) in theta space:
//
//   Lobe centers (theta_h):  R = +alpha,  TT = -0.5*alpha,  TRT = -1.5*alpha
//   Lobe variances:          R = beta^2,  TT = (0.5*beta)^2, TRT = (2.0*beta)^2
//
// The mode-0 lobe centers follow the baseline-compatible cuticle-tilt
// convention (FM_CUTICLE_TILT_CONVENTION below): a positive artist-facing
// cuticle_tilt_offset denotes an outward cuticle tilt.
//
// Mode 1 (diagnostic, never the default) is a baseline-compatible separable
// sin(theta_o)-space Gaussian around the cone rotations vec3(-2, 1, 3)*alpha
// with standard deviations vec3(1.5, 0.75, 3.0)*beta_M. It is a separable
// diagnostic approximation of the baseline cone-tilt contract, NOT the full
// non-separable d'Eon 2014 baseline (no non-separable widths/tilts, no
// derived compensation, no LUT redesign).
//
// R-only longitudinal override (FM_R_LONGITUDINAL_MODE, default 0): mode 1 is
// a cheap NON-separable R diagnostic that overrides ONLY m_p[FM_R] after the
// shared fm_longitudinal_scattering call in both the analytic and LUT BSDFs.
// It approximates the baseline R cone in sin(theta_o) space with
// z_r = cos_phi_half, beta_r = sqrt(2)*z_r*beta_m (positive floor), and
// sin_theta_cone_r = clamp(-sin_theta_i + 2*z_r*cuticle_tilt_value, -1, 1);
// because z_r depends on the relative azimuth, the width and tilt are
// non-separable. This is a cheap diagnostic, NOT the full non-separable
// d'Eon 2014 baseline (no full widths/tilts, no derived compensation), and
// mode 0 remains the shipping default. TT/TRT are never touched.
//
// Azimuthal scattering is the fixed-h logistic analytic approximation
// (FM_AZIMUTHAL_FIXED_H_ANALYTIC, the same Fresnel + Beer-Lambert with
// logistic distributions used by the high-tier include), selected by the
// numeric compile-time selector FM_AZIMUTHAL_MODE below. Mode 0 (shipping
// default) uses the fixed representative cross-section offsets h_TT = 0 and
// h_TRT = sqrt(3)/2 for the azimuthal angular offsets. Mode 1 (diagnostic,
// never the default) is an attribution-only baseline cross-section diagnostic
// for the ANALYTIC BSDF only: dynamic h_TT from the baseline formula
// sign(sin_phi_half) * cos_phi_half / sqrt(1 + eta_prime_inv * (1 -
// 2 * eta_prime_inv * abs(sin_phi_half))) and h_TRT = 0.91. Mode 1 never
// alters LUT sampling semantics (the LUT's azimuthal terms are baked at the
// fixed-h offsets, so the LUT path is untouched) and never alters attenuation
// (the Unity-style fixed-h family FM_ATTENUATION_MODE 0 /
// FM_ATTENUATION_UNITY_FIXED_H with h_TT = 0 and h_TRT = sqrt(3)/2 stays in
// every mode). The shipping branch uses the outgoing/view Snell convention;
// the named legacy diagnostic branch (FM_ATTENUATION_DEON_FIXED_H) retains
// the incoming/light convention for diagnosis. No LUT is required.

// --- Compile-time lobe configuration ---
// Comment out a lobe define to strip that lobe from the compiled shader
// variant. The runtime `lobe_scales` Debug uniform below provides per-lobe
// debug isolation without recompiling.
#define FM_LOBE_R
#define FM_LOBE_TT
#define FM_LOBE_TRT

// --- Compile-time model configuration ---
// Shipping defaults are defined below; the legacy/diagnostic branches are
// opt-in and must never be combined with their shipping counterpart (the
// code selects the legacy branch first, so defining one silently overrides
// the shipping default rather than mixing conventions).
// Longitudinal model: single numeric selector (no boolean/legacy macros).
// 0 = Unity-standard theta_h Gaussian (shipping default, current behavior
// unchanged); 1 = baseline-compatible separable sin(theta_o) Gaussian
// (diagnostic comparison mode; a separable approximation of the baseline
// cone-tilt contract, NOT the full non-separable baseline). Defined as a
// literal so the #if in fm_longitudinal_scattering never depends on nested
// macro expansion. The #ifndef guard honors a selector defined by a wrapper
// shader before including the body; the default applies when this include is
// used directly.
#ifndef FM_LONGITUDINAL_MODE
#define FM_LONGITUDINAL_MODE 0
#endif

// R longitudinal model: single numeric selector for the R lobe only, applied
// in both the analytic and LUT BSDF functions after the shared
// fm_longitudinal_scattering call. 0 = shipping default: the R lobe keeps the
// shared longitudinal path selected by FM_LONGITUDINAL_MODE (current behavior
// unchanged). 1 = diagnostic: overrides ONLY m_p[FM_R] with a cheap
// non-separable R approximation in sin(theta_o) space (z_r = cos_phi_half,
// beta_r = sqrt(2.0)*z_r*beta_m with a positive floor, and
// sin_theta_cone_r = clamp(-sin_theta_i + 2.0*z_r*cuticle_tilt_value, -1.0,
// 1.0)). This is a cheap diagnostic, NOT the full non-separable d'Eon 2014
// baseline (no full widths/tilts, no derived compensation), and 0 remains the
// shipping default. TT/TRT are never modified in either mode. The #ifndef
// guard honors a selector defined by a wrapper shader before including the
// body; the default applies when this include is used directly.
#ifndef FM_R_LONGITUDINAL_MODE
#define FM_R_LONGITUDINAL_MODE 0
#endif

// Standardized projected-R longitudinal LUT model: single numeric selector
// for the R lobe product only, applied in both the analytic and LUT BSDF
// result accumulations. 0 = shipping default: the R lobe keeps the analytic
// 0.25*cos_phi_half*M_R product (current behavior unchanged). 1 =
// diagnostic: the R product M_R*N_R is reconstructed from the committed
// standardized projected-R LUT
// (M_R*N_R = Q / (4*sqrt(2)*beta_m*cos(theta_o)
//                 * sqrt(cos(theta_cone)*cos(theta_o))), Q sampled from
// r_standardized_lut) instead of evaluating 0.25*cos_phi_half*M_R, avoiding
// the 0*infinity form as beta_r -> 0 (see
// fm_r_standardized_longitudinal_product below and the CPU reference in
// benchmark/reference/fast_marschner_r_standardized_kernel_reference.gd).
// The direct/asymptotic Q reference fallback covers q/beta outside the LUT
// support, the cone-pole outer two theta_cone texel bands, grazing
// footprints, and beta_r <= 1e-8. TT/TRT are never modified in either mode,
// and mode 0 remains the shipping default. The #ifndef guard honors a
// selector defined by a wrapper shader before including the body; the
// default applies when this include is used directly. Only wrappers that
// declare the r_standardized_lut / r_standardized_lut_log_decode uniforms
// may define mode 1 (the committed diagnostic wrapper
// hair_marschner_fast_r_standardized_lut.gdshader declares both).
#ifndef FM_R_STANDARDIZED_LUT_MODE
#define FM_R_STANDARDIZED_LUT_MODE 0
#endif

// Attenuation model: single numeric selector (no boolean/legacy macros).
// 0 = Unity-style fixed-h family (shipping default, current behavior
// unchanged); 1 = legacy diagnostic branch (the previous folded-constant
// d'Eon-style fixed-h family, incoming/light Snell convention). The two named
// constants below document the selector values; the selector itself is defined
// as the literal value (not as a macro alias) so the #if checks never depend
// on nested macro expansion. The #ifndef guard honors a selector defined by a
// wrapper shader before including the body; the default applies when this
// include is used directly.
#define FM_ATTENUATION_UNITY_FIXED_H 0
#define FM_ATTENUATION_DEON_FIXED_H 1
#ifndef FM_ATTENUATION_MODE
#define FM_ATTENUATION_MODE 0
#endif

// Azimuthal model: single numeric selector (no boolean/legacy macros).
// 0 = fixed-h logistic analytic approximation (shipping default, current
// behavior unchanged: the azimuthal angular offsets use the fixed
// representative cross-section offsets FM_H_TT = 0 and FM_H_TRT = sqrt(3)/2);
// 1 = diagnostic baseline-h cross-section override for the ANALYTIC BSDF only
// (dynamic h_TT from the baseline cross-section formula
// sign(sin_phi_half) * cos_phi_half / sqrt(1 + eta_prime_inv * (1 -
// 2 * eta_prime_inv * abs(sin_phi_half))) and h_TRT =
// FM_AZIMUTHAL_BASELINE_H_TRT = 0.91). The baseline-h diagnostic never alters
// LUT sampling semantics (the LUT's R/TT/TRT azimuthal terms are baked at the
// fixed-h offsets, so fm_hair_bsdf_lut is untouched by the selector) and
// never alters attenuation (fm_att_fixed_h always uses the shipping fixed-h
// family FM_H_TT / FM_H_TRT via FM_ATTENUATION_MODE, which is independent).
// The two named constants below document the selector values; the selector
// itself is defined as the literal value (not as a macro alias) so the #if
// checks never depend on nested macro expansion. The #ifndef guard honors a
// selector defined by a wrapper shader before including the body; the default
// applies when this include is used directly.
#define FM_AZIMUTHAL_FIXED_H_ANALYTIC 0
#define FM_AZIMUTHAL_BASELINE_H_ANALYTIC 1
// Baseline representative TRT cross-section offset used by
// FM_AZIMUTHAL_MODE 1, matching the baseline reference include's
// USE_APPROXIMATE_TRT_CROSS_SECTION_OFFSET (0.91).
#define FM_AZIMUTHAL_BASELINE_H_TRT 0.91
#ifndef FM_AZIMUTHAL_MODE
#define FM_AZIMUTHAL_MODE 0
#endif

// --- Compile-time cuticle tilt convention ---
// Numeric selector naming the sign contract of the artist-facing
// cuticle_tilt_offset uniform, so the sign is never embedded without a
// contract. 0 = baseline-compatible (shipping default): a positive offset
// denotes an outward cuticle tilt, giving theta_h lobe centers
// R = +alpha, TT = -0.5*alpha, TRT = -1.5*alpha. 1 = Unity diagnostic mode:
// the previous sign pattern (R = -alpha, TT = +0.5*alpha, TRT = +1.5*alpha).
// Both the analytic and LUT BSDFs consume the same lobe_alpha varying, so the
// selector recompiles the sign consistently across variants.
#define FM_CUTICLE_TILT_BASELINE 0
#define FM_CUTICLE_TILT_UNITY 1
// The selector itself is defined as the literal value (not as a macro alias)
// so the #if in the shader never depends on nested macro expansion. The
// #ifndef guard honors a selector defined by a wrapper shader before including
// the body; the default applies when this include is used directly.
#ifndef FM_CUTICLE_TILT_CONVENTION
#define FM_CUTICLE_TILT_CONVENTION 0
#endif

// --- Fixed cross-section offsets (fixed-h attenuation family) ---
// Single source of truth for the fixed-h family: h_TT = 0 and h_TRT = sqrt(3)/2.
#define FM_H_TT 0.0
#define FM_H_TRT (0.5 * sqrt(3.0))

// --- Lobes (Modes) ---
#define FM_R   0 // (p=0) Paths where light reflects (R) off the front surface of the fiber.
#define FM_TT  1 // (p=1) Paths where light transmits (T) into the fiber, then transmits (T) out the back.
#define FM_TRT 2 // (p=2) Paths where light transmits in, reflects (R) off the back, then transmits out the front.

group_uniforms FastMarschner;
/** Absorption mode: 0 = albedo reparameterization (Chiang et al. 2016, the
 *  current high-tier default), 1 = direct absorption coefficient, 2 = melanin. */
uniform int absorption_mode : hint_range(0, 2) = 0;
/** Direct absorption coefficient (sigma_a) used by absorption_mode 1. */
uniform vec3 absorption : source_color = vec3(0.1);
/** Eumelanin concentration (0..1) used by absorption_mode 2. */
uniform float eumelanin : hint_range(0.0, 1.0) = 0.2;
/** Pheomelanin concentration (0..1) used by absorption_mode 2. */
uniform float pheomelanin : hint_range(0.0, 1.0) = 0.8;
/** Maps the physical melanin absorption coefficient (m^-1, sampled at
 *  650/540/450 nm) into the shader's per-fiber-radius unit system. */
uniform float melanin_absorption_scale : hint_range(0.0, 0.01) = 0.001;
/** Index of refraction of the hair fiber (human hair ~1.55). */
uniform float ior : hint_range(1.0, 2.0) = 1.55;
group_uniforms;

group_uniforms Debug;
// Keep the current high shader's debug parameter name and shape intact: the
// three components scale/isolate the R, TT, and TRT lobes.
uniform vec3 lobe_scales = vec3(1);
group_uniforms;

group_uniforms DualScatter;
/** Opt-in local dual-scattering slice (FAST_MARSCHNER_DUAL_SCATTER). Default
 *  false keeps the Karis multiple-scattering reference for the analytic and
 *  LUT variants. */
uniform bool use_dual_scatter = false;
/** Strength of the dual-scattering diffuse term (0 disables its contribution). */
uniform float dual_scatter_strength : hint_range(0.0, 2.0) = 0.5;
/** Density multiplier applied to the packed depth proxy. */
uniform float dual_scatter_density : hint_range(0.0, 1.0) = 0.5;
/** Opt-in Stage-B preintegrated (LUT-backed) dual-scattering slice
 *  (FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED). Requires use_dual_scatter=true
 *  (variant identity forces both); light() then samples the committed 2D LUT
 *  instead of the analytic Stage-A fallback. Default false keeps Stage A. */
uniform bool use_preintegrated_dual_scatter = false;
/** 64x64 RGBAF scalar density/event-proxy weights (see
 *  benchmark/tools/generate_marschner_dual_scatter_lut.gd and
 *  validate_marschner_dual_scatter_lut.gd). Axes: U = scalar density/event
 *  proxy tau_d = 4 * local_density in [0, tau_max] (the reachable domain;
 *  the committed resource carries tau_max = 4.0 as metadata, texel centers at
 *  (i + 0.5) / N), V = scattering cosine c (light/view alignment) in [-1, 1]
 *  -> 0.5 + 0.5*c. Channels are aggregate event weights: P1 = 1 - exp(-tau_d)
 *  (R/G, one event) and P3 = 1 - exp(-1.5 * tau_d) (B/A, three events), split
 *  forward/backward by the cosine and scaled by the F0 baked at
 *  dual_scatter_lut_eta (1.55). The runtime samples the LUT once at the
 *  scalar tau_d, then reconstructs the four directional channels separately
 *  with the per-direction path responses
 *  T1f = exp(-sigma_a), T1b = exp(-0.5 * sigma_a),
 *  T3f = exp(-1.5 * sigma_a), T3b = exp(-0.75 * sigma_a)
 *  (see fm_dual_scattering_preintegrated): the forward/backward split the LUT
 *  stores is preserved at runtime, never cancelled by a summed fetch. Linear
 *  filtering with repeat disabled; both axes are half-texel clamped into the
 *  interior texel-center range so the clamped sample never wraps. */
uniform sampler2D dual_scatter_lut : filter_linear, repeat_disable;
/** IOR baked into dual_scatter_lut (the F0 in the stored event weights);
 *  a runtime ior outside abs(ior - dual_scatter_lut_eta) <= 0.0005 evaluates
 *  the analytic Contract B fallback with the runtime F0 instead of sampling
 *  the LUT. */
uniform float dual_scatter_lut_eta : hint_range(1.0, 2.0) = 1.55;
/** tau_max metadata of dual_scatter_lut: the U-axis upper bound
 *  (tau_d = 4 * local_density; the committed resource is 4.0, the reachable
 *  domain). The adapter populates this from the resource metadata; the
 *  runtime maps tau_d into the texture domain with this value and never
 *  silently assumes a wider baked domain. */
uniform float dual_scatter_lut_tau_max : hint_range(0.01, 16.0) = 4.0;
group_uniforms;

group_uniforms Environment;
/** Opt-in fragment-stage environment response (FAST_MARSCHNER_ENVIRONMENT).
 *  Default false: analytic, LUT, and dual variants never evaluate it. The
 *  contribution is added via EMISSION in fragment() and is light-count
 *  invariant; it never touches light(). */
uniform bool use_environment = false;
/** 2D equirectangular environment stand-in (committed GradientTexture2D at
 *  res://benchmark/resources/textures/environment_gradient.tres: dark zenith,
 *  warm horizon, cool sky). Sampled with the standard equirect mapping
 *  u = 0.5 + atan(z, x) / TAU, v = 0.5 - asin(y) / PI. */
uniform sampler2D environment_texture : filter_linear, repeat_disable;
/** Strength of the environment EMISSION contribution. */
uniform float environment_strength : hint_range(0.0, 2.0) = 1.0;
group_uniforms;

group_uniforms LUT;
/** Opt-in azimuthal LUT path (FAST_MARSCHNER_LUT). Default false keeps the
 *  fixed-h logistic analytic approximation (FM_AZIMUTHAL_FIXED_H_ANALYTIC) as
 *  the reference; the LUT is a separately selectable variant, never silently
 *  enabled. */
uniform bool use_azimuthal_lut = false;
/** 64^3 RGBAF azimuthal R/TT/TRT terms, axes U=phi, V=cos_theta_d,
 *  W=azimuthal_roughness (see benchmark/tools/generate_marschner_azimuthal_lut.gd
 *  and validate_marschner_azimuthal_lut.gd). Linear sampling with repeat
 *  enabled: the U/phi axis wraps continuously at the seam (sampled with
 *  fract() and texel centers over [-PI, PI]), while V and W are half-texel
 *  clamped so repeat never wraps those axes. */
uniform sampler3D azimuthal_lut : filter_linear, repeat_enable;
/** IOR baked into azimuthal_lut; incompatible runtime IORs fall back to analytic. */
uniform float azimuthal_lut_eta : hint_range(1.0, 2.0) = 1.55;
group_uniforms;


/** Schlick's bias approximation, guarded against a zero bias parameter. */
float power(float x, float t) {
	float safe_t = clamp(t, 1e-4, 1.0);
	float safe_x = clamp(x, 0.0, 1.0);
	return safe_x / ((1.0 / safe_t - 2.0) * (1.0 - safe_x) + 1.0);
}


/** Normalized variance-form Gaussian with a positive variance floor. The
 *  internal floor (1e-3 squared, matching the shader's beta floor) keeps the
 *  helper finite for any external variance input, including callers that do
 *  not pre-floor their variances. */
vec3 fm_gaussian_variance(vec3 theta, vec3 variance) {
	vec3 safe_variance = max(variance, vec3(1e-6));
	return exp(-0.5 * theta * theta / safe_variance) * inversesqrt(TAU * safe_variance);
}


/** Schlick Fresnel approximation with a bounded incidence cosine. */
float fm_fresnel(float cos_theta, const float eta) {
	const float F0 = (1.0 - eta) * (1.0 - eta) / ((1.0 + eta) * (1.0 + eta));

	float p = 1.0 - clamp(cos_theta, 0.0, 1.0);
	float p_sq = p * p;
	return mix(p_sq * p_sq * p, 1.0, F0);
}


/** Logistic distribution normalized to [-pi..pi], matching the high-tier model.
 *  `b_pre` is the light-invariant normalization exp(-2*sqrt(TAU)*s_inv),
 *  precomputed once per fragment from the hoisted inverse azimuthal width. */
float fm_logistic(float cos_phi, float s_inv, float b_pre) {
	float safe_cos_phi = clamp(cos_phi, -1.0, 1.0);
	float phi = sqrt(max(0.0, 1.0 - safe_cos_phi)) * (1.5707288 + safe_cos_phi * (-0.2121144 + safe_cos_phi * 0.0742610)); // Approximate: acos(cos_phi)
	float exp_term = exp(-phi * s_inv);
	float c = 1.0 + exp_term;
	return min(1.0, s_inv * exp_term * (1.0 + b_pre) / ((1.0 - b_pre) * c * c));
}


/** Computes cos(phi - Phi(p,h)) where Phi(p,h) = 2*asin(h/eta')*p - 2*asin(h) - pi*p. */
float fm_azimuthal_angular_offset(int mode, float cos_phi, float sin_phi, float eta_prime_inv, float h) {
	float gamma = (2.126 * h * eta_prime_inv + PI) * float(mode); // Approximate: gamma_t = asin(h/eta') ~= 1.063*h*eta_prime_inv
	float A = 1.0 - 2.0 * h * h;
	float B = 2.0 * h * sqrt(1.0 - h * h);
	float C = cos(gamma);
	float S = sin(gamma);
	return cos_phi * (C * A + S * B) + sin_phi * (S * A - C * B);
}


#if FM_AZIMUTHAL_MODE == FM_AZIMUTHAL_BASELINE_H_ANALYTIC
/** Baseline cross-section formula for the TT azimuthal angular offset h_TT
 *  (FM_AZIMUTHAL_MODE 1 diagnostic, ANALYTIC BSDF only):
 *
 *    h_TT = sign(sin_phi_half) * cos_phi_half
 *           / sqrt(1 + eta_prime_inv * (1 - 2 * eta_prime_inv * abs(sin_phi_half)))
 *
 *  matching the baseline reference include's h_y formula
 *  (_baseline_cross_section_offsets in the CPU validator port). Only the
 *  analytic BSDF fm_hair_bsdf consumes it; the LUT path is untouched (its
 *  azimuthal terms are baked at the fixed-h offsets) and attenuation always
 *  keeps the shipping fixed-h family (FM_H_TT / FM_H_TRT) in every mode. */
float fm_azimuthal_baseline_h_tt(float cos_phi_half, float sin_phi_half, float eta_prime_inv) {
	return sign(sin_phi_half) * cos_phi_half
		/ sqrt(1.0 + eta_prime_inv * (1.0 - 2.0 * eta_prime_inv * abs(sin_phi_half)));
}
#endif


/** TT attenuation with the fixed h_TT = 0 and mode = 1 constants folded in:
 *  Fresnel input cos(theta_d), Beer-Lambert path factor 4.0, and
 *  (1 - F)^2 * transmittance. Legacy diagnostic branch used only by
 *  FM_ATTENUATION_MODE 1 (FM_ATTENUATION_DEON_FIXED_H); the shipping
 *  fm_att_unity_fixed_h() helper is the explicit equivalent. */
vec3 fm_tt_attenuation(float cos_theta_t, float cos_theta_d, vec3 sigma_a, float eta) {
	float f = fm_fresnel(cos_theta_d, eta);
	// Beer-Lambert law; the TT path length is 4.0 * (1 - eta'^-2 * 0^2) * 1.
	vec3 transmittance = exp(-max(sigma_a, vec3(0.0)) / max(cos_theta_t, 1e-4) * 4.0);
	return (1.0 - f) * (1.0 - f) * transmittance;
}


/** TRT attenuation with the fixed h_TRT = sqrt(3)/2 and mode = 2 constants
 *  folded in: Fresnel input cos(theta_d)*0.5 (sqrt(1 - h*h) = 0.5), Beer-Lambert
 *  path factor 8.0*(1.0 - 0.75*eta'^-2), and (1 - F)^2 * F * transmittance.
 *  Legacy diagnostic branch used only by FM_ATTENUATION_MODE 1
 *  (FM_ATTENUATION_DEON_FIXED_H); the shipping fm_att_unity_fixed_h() helper
 *  is the explicit equivalent. */
vec3 fm_trt_attenuation(float cos_theta_t, float cos_theta_d, vec3 sigma_a, float eta_prime_inv, float eta) {
	float f = fm_fresnel(cos_theta_d * 0.5, eta);
	// Beer-Lambert law; the TRT path length is 4.0 * (1 - eta'^-2 * 0.75) * 2.
	vec3 transmittance = exp(-max(sigma_a, vec3(0.0)) / max(cos_theta_t, 1e-4) * 8.0 * (1.0 - 0.75 * eta_prime_inv * eta_prime_inv));
	return (1.0 - f) * (1.0 - f) * f * transmittance;
}


/** Unity-style fixed-h attenuation for TT/TRT (FM_ATTENUATION_MODE 0, the
 *  shipping default). The fixed representative h values are explicit and the
 *  two internal TRT traversals are represented by a second transmittance
 *  factor. The outgoing longitudinal angle supplies cos_theta_o; the
 *  transmitted angle uses the documented Snell convention supplied by the
 *  caller. */
vec3 fm_att_unity_fixed_h(int mode, float cos_theta_o, float cos_theta_d, float cos_theta_t, float eta_prime, vec3 sigma_a, float eta) {
	float h = (mode == FM_TRT) ? FM_H_TRT : FM_H_TT;
	float h2 = h * h;
	float cos_gamma_o = sqrt(max(0.0, 1.0 - h2));
	float fresnel_cos = clamp(cos_theta_o * cos_gamma_o, 0.0, 1.0);
	float f = fm_fresnel(fresnel_cos, eta);
	float safe_eta_prime = max(eta_prime, 1e-4);
	float sin_gamma_t = clamp(h / safe_eta_prime, -0.999999, 0.999999);
	float cos_gamma_t = sqrt(max(0.0, 1.0 - sin_gamma_t * sin_gamma_t));
	vec3 transmittance = exp(-max(sigma_a, vec3(0.0))
		* (2.0 * cos_gamma_t / max(cos_theta_t, 1e-4)));
	float one_minus_f = 1.0 - f;
	if (mode == FM_TT) {
		return one_minus_f * one_minus_f * transmittance;
	}
	return one_minus_f * one_minus_f * f * transmittance * transmittance;
}


/** Legacy diagnostic attenuation (FM_ATTENUATION_MODE 1, never the default):
 *  the previous folded-constant d'Eon-style fixed-h family under an explicit
 *  name rather than silently mixing conventions. Only reachable through the
 *  diagnostic branch; fm_att_unity_fixed_h() is the shipping equivalent. */
vec3 fm_att_deon_fixed_h(int mode, float cos_theta_o, float cos_theta_d, float cos_theta_t, float eta_prime, vec3 sigma_a, float eta) {
	float legacy_eta_prime_inv = 1.0 / max(eta_prime, 1e-4);
	if (mode == FM_TT) {
		return fm_tt_attenuation(cos_theta_t, cos_theta_d, sigma_a, eta);
	}
	return fm_trt_attenuation(cos_theta_t, cos_theta_d, sigma_a, legacy_eta_prime_inv, eta);
}


/** Attenuation dispatcher (minimal wrapper): selects the configured
 *  FM_ATTENUATION_MODE without changing the call sites. Mode 0 (shipping
 *  default) = fm_att_unity_fixed_h; mode 1 (diagnostic) =
 *  fm_att_deon_fixed_h. The #if compares the literal selector so it never
 *  depends on nested macro expansion. */
vec3 fm_att_fixed_h(int mode, float cos_theta_o, float cos_theta_d, float cos_theta_t, float eta_prime, vec3 sigma_a, float eta) {
#if FM_ATTENUATION_MODE == FM_ATTENUATION_DEON_FIXED_H
	return fm_att_deon_fixed_h(mode, cos_theta_o, cos_theta_d, cos_theta_t, eta_prime, sigma_a, eta);
#else
	return fm_att_unity_fixed_h(mode, cos_theta_o, cos_theta_d, cos_theta_t, eta_prime, sigma_a, eta);
#endif
}


/** Longitudinal scattering for R, TT, and TRT, selected by the numeric
 *  compile-time selector FM_LONGITUDINAL_MODE.
 *
 *  Mode 0 (shipping default, Unity-standard): normalized variance-form
 *  Gaussian in theta space evaluated at theta_h = 0.5*(theta_i + theta_o),
 *  with the per-lobe centers/variances hoisted from fragment(): centers
 *  vec3(1.0, -0.5, -1.5)*alpha under the shipping baseline cuticle-tilt
 *  convention (FM_CUTICLE_TILT_CONVENTION 0; the Unity diagnostic convention
 *  flips them to vec3(-1.0, 0.5, 1.5)*alpha) and variances
 *  vec3(1.0, 0.5, 2.0)^2 * beta_M^2, both with a positive variance floor
 *  inside fm_gaussian_variance.
 *
 *  Mode 1 (diagnostic, baseline-compatible): separable sin(theta_o)-space
 *  Gaussian around the cone rotations vec3(-2.0, 1.0, 3.0) *
 *  cuticle_tilt_offset, with sin_theta_cone = -cos(theta_i)*sin(rotation)
 *  - sin(theta_i)*cos(rotation) and standard deviations
 *  vec3(1.5, 0.75, 3.0) * beta_m converted to variances (positive floor
 *  inside fm_gaussian_variance). This is a separable diagnostic
 *  approximation of the baseline cone-tilt contract, NOT the full
 *  non-separable baseline (no d'Eon 2014 widths/tilts, no derived
 *  compensation). The additional scalars (cuticle tilt and beta_M) are
 *  passed from the shader call sites; mode 0 ignores them.
 *
 *  Both the analytic and LUT BSDF functions call this exact helper, so the
 *  two variants can never drift apart. */
vec3 fm_longitudinal_scattering(float theta_i, float theta_o, vec3 lobe_alpha, vec3 lobe_variance, float cuticle_tilt_value, float beta_m_value) {
#if FM_LONGITUDINAL_MODE == 1
	// Diagnostic branch (baseline-compatible): separable Gaussian in
	// sin(theta_o) space around the rotated cone
	// sin_theta_cone = -sin(theta_i + rotation), where
	// sin(theta_i + rotation) = sin(theta_i)*cos(rotation) + cos(theta_i)*sin(rotation).
	vec3 rotation = vec3(-2.0, 1.0, 3.0) * cuticle_tilt_value;
	vec3 sin_theta_cone = -vec3(cos(theta_i)) * sin(rotation) - vec3(sin(theta_i)) * cos(rotation);
	vec3 stddev = vec3(1.5, 0.75, 3.0) * max(beta_m_value, 0.0);
	return fm_gaussian_variance(sin(theta_o) - sin_theta_cone, stddev * stddev);
#else
	// Shipping branch (FM_LONGITUDINAL_MODE 0, Unity-standard): normalized
	// variance-form Gaussian in theta space.
	float theta_h = 0.5 * (theta_i + theta_o);
	return fm_gaussian_variance(theta_h - lobe_alpha, lobe_variance);
#endif
}


#if FM_R_LONGITUDINAL_MODE == 1
/** Cheap non-separable R longitudinal diagnostic (FM_R_LONGITUDINAL_MODE 1):
 *  overrides ONLY m_p[FM_R] after the shared fm_longitudinal_scattering call
 *  in both the analytic and LUT BSDFs. Non-separable because both the width
 *  and the cone tilt depend on the relative azimuth through z_r = cos_phi_half:
 *
 *    z_r = cos_phi_half
 *    beta_r = sqrt(2.0) * z_r * beta_m  (positive floor 1e-3, matching the
 *             shader's beta floor; fm_gaussian_variance re-floors the variance)
 *    sin_theta_cone_r = clamp(-sin_theta_i + 2.0 * z_r * cuticle_tilt_value,
 *                             -1.0, 1.0)
 *    result = fm_gaussian_variance(vec3(sin_theta_o - sin_theta_cone_r),
 *                                  vec3(beta_r * beta_r)).x
 *
 *  Cheap diagnostic approximation of the baseline R cone, NOT the full
 *  non-separable d'Eon 2014 baseline (no full widths/tilts, no derived
 *  compensation). TT/TRT and FM_R_LONGITUDINAL_MODE 0 (shipping default) are
 *  untouched. */
float fm_r_longitudinal_nonseparable(float sin_theta_i, float sin_theta_o, float cos_phi_half, float cuticle_tilt_value, float beta_m_value) {
	float z_r = cos_phi_half;
	float beta_r = max(sqrt(2.0) * z_r * max(beta_m_value, 0.0), 1e-3);
	float sin_theta_cone_r = clamp(-sin_theta_i + 2.0 * z_r * cuticle_tilt_value, -1.0, 1.0);
	return fm_gaussian_variance(vec3(sin_theta_o - sin_theta_cone_r), vec3(beta_r * beta_r)).x;
}
#endif


#if FM_R_STANDARDIZED_LUT_MODE == 1
// --- Standardized projected-R LUT constants ---
// CPU contract: benchmark/reference/fast_marschner_r_standardized_kernel_reference.gd
// and benchmark/resources/fast_marschner_r_standardized_lut_data.gd. Axes
// (texel centers at (i + 0.5) / N): X = q = (theta_o - theta_cone) / beta_r
// in [-12, 12], Y = theta_cone in [-PI/2, PI/2], Z = log2(beta_r) linear with
// beta_r in [0.02, 9]. Channels: R = linear Q, G = log2(Q) (floor -120),
// B = 0, A = 1. Q = beta_r * sqrt(cos(theta_cone) * cos(theta_o))
// * cos(theta_o) * M_R; the reconstruction below recovers M_R*N_R
// (N_R = 0.25*cos_phi_half) without ever evaluating the 0*infinity form.
const float FM_R_STD_Q_MIN = -12.0;
const float FM_R_STD_Q_MAX = 12.0;
const float FM_R_STD_BETA_MIN = 0.02;
const float FM_R_STD_BETA_MAX = 9.0;
const float FM_R_STD_LOG2_VALUE_FLOOR = -120.0;
const float FM_R_STD_COSINE_EPSILON = 1e-12;
const float FM_R_STD_BETA_NUMERIC_EPSILON = 1e-8;
const float FM_R_STD_INV_SQRT_TAU = 0.3989422804014327;
const float FM_R_STD_INV_LN_2 = 1.4426950408889634;
const float FM_R_STD_LOG_Q_CLAMP_FLOOR = -83.17794814081263; // -120 * log(2), the CPU's LOG2_VALUE_FLOOR * log(2)


/** Rounded-Bessel log approximation, matching the CPU reference
 *  log_bessel_zero(). The 1e-30 argument floor keeps log() finite in float32
 *  when the Bessel product underflows; the final clamp in fm_r_std_direct_q
 *  tames any residual -inf the same way the CPU's double-precision floor
 *  does. */
float fm_r_std_log_bessel_zero(float x) {
	float x_sq = x * x;
	float value = (0.564187 + 1.01298 / (x_sq + 2.32434));
	value *= 1.0 / sqrt(sqrt(x_sq * 0.25 + 1.0));
	value *= exp(-2.0 * abs(x)) * 0.5 + 0.5;
	return log(max(value, 1e-30)) + x;
}


/** Direct-branch log Q (theta_o, theta_cone, beta_r), matching the CPU's
 *  direct_log_q_value(): the d'Eon 2011 Bessel form of M_R scaled by
 *  beta_r * sqrt(cos_cone * cos_o) * cos_o, with beta floored at
 *  BETA_NUMERIC_EPSILON and the cosines floored at COSINE_EPSILON. */
float fm_r_std_direct_log_q(float theta_o, float theta_cone, float beta_effective) {
	float beta = max(beta_effective, FM_R_STD_BETA_NUMERIC_EPSILON);
	float sin_o = sin(theta_o);
	float cos_o = max(cos(theta_o), FM_R_STD_COSINE_EPSILON);
	float sin_cone = sin(theta_cone);
	float cos_cone = max(cos(theta_cone), FM_R_STD_COSINE_EPSILON);
	float variance_inverse = 1.0 / (beta * beta);
	return (sin_cone * sin_o - 1.0) * variance_inverse
		+ fm_r_std_log_bessel_zero(cos_cone * cos_o * variance_inverse)
		+ log(variance_inverse) - log(cos_o)
		+ log(beta) + 0.5 * log(cos_cone) + 1.5 * log(cos_o);
}


/** Direct-branch Q with the CPU's log clamp: exp(clamp(log_q,
 *  LOG2_VALUE_FLOOR * log(2), 80)). The clamp floor keeps the float32
 *  cancellation/underflow tails finite and bounded (never inf/NaN). */
float fm_r_std_direct_q(float theta_o, float theta_cone, float beta_effective) {
	return exp(clamp(fm_r_std_direct_log_q(theta_o, theta_cone, beta_effective), FM_R_STD_LOG_Q_CLAMP_FLOOR, 80.0));
}


/** Asymptotic (large variance-argument) Gaussian limit of Q, matching the
 *  CPU's asymptotic_q_value(): Q ~ 1/sqrt(2*pi) * exp(-2*sin(delta/2)^2 /
 *  beta^2), delta = theta_o - theta_cone. The exponent uses
 *  -2*sin(delta/2)^2 instead of cos(delta) - 1 to avoid catastrophic
 *  cancellation for tiny delta; beta is floored at BETA_NUMERIC_EPSILON so
 *  beta_r == 0 (and the exact c_phi == 0 seam) stays finite. */
float fm_r_std_asymptotic_q(float theta_o, float theta_cone, float beta_effective) {
	float beta = max(beta_effective, FM_R_STD_BETA_NUMERIC_EPSILON);
	float half_delta = 0.5 * (theta_o - theta_cone);
	return FM_R_STD_INV_SQRT_TAU * exp(-2.0 * sin(half_delta) * sin(half_delta) / (beta * beta));
}


/** Reference Q dispatcher matching the CPU branch contract: beta_r above
 *  BETA_NUMERIC_EPSILON uses the direct Bessel form, at or below it the
 *  asymptotic Gaussian limit. */
float fm_r_std_reference_q(float theta_o, float theta_cone, float beta_effective) {
	if (beta_effective > FM_R_STD_BETA_NUMERIC_EPSILON) {
		return fm_r_std_direct_q(theta_o, theta_cone, beta_effective);
	}
	return fm_r_std_asymptotic_q(theta_o, theta_cone, beta_effective);
}


/** True when the (q, theta_cone, beta_r) sample must use the direct/asymptotic
 *  reference instead of the clamped trilinear LUT read, matching the CPU's
 *  requires_reference_fallback() priority order:
 *    1. q/beta out of support (theta_cone is inside [-PI/2, PI/2] by
 *       construction: it comes from asin() of a clamped sine),
 *    2. cone-pole band: theta_cone inside the outer two Y-axis texel bands
 *       (reconstructing a pole-clamped cone with the exact cos(theta_cone)
 *       denominator would divide by the epsilon floor rather than the sampled
 *       edge cone),
 *    3. grazing footprint: any trilinear corner (or the grazing margin)
 *       straddles the physical outgoing-angle boundary |theta_o| <= PI/2.
 * The half-step extents are derived from the texture's own size. */
bool fm_r_std_requires_fallback(float q, float theta_cone, float beta_r, sampler3D lut_texture) {
	if (q < FM_R_STD_Q_MIN || q > FM_R_STD_Q_MAX
			|| beta_r < FM_R_STD_BETA_MIN || beta_r > FM_R_STD_BETA_MAX) {
		return true;
	}
	ivec3 lut_size = textureSize(lut_texture, 0);
	float q_half_step = 0.5 * (FM_R_STD_Q_MAX - FM_R_STD_Q_MIN) / float(lut_size.x);
	float cone_half_step = 0.5 * PI / float(lut_size.y);
	float log2_half_step = 0.5 * (log(FM_R_STD_BETA_MAX) - log(FM_R_STD_BETA_MIN)) * FM_R_STD_INV_LN_2 / float(lut_size.z);
	// Cone-pole band: the Y-axis texel centers stop short of the poles.
	if (abs(theta_cone) > PI * 0.5 - 2.0 * cone_half_step) {
		return true;
	}
	float beta_lo = max(FM_R_STD_BETA_MIN, pow(2.0, log(beta_r) * FM_R_STD_INV_LN_2 - log2_half_step));
	float beta_hi = min(FM_R_STD_BETA_MAX, pow(2.0, log(beta_r) * FM_R_STD_INV_LN_2 + log2_half_step));
	// Grazing footprint: the 8 trilinear corners (unrolled).
	float corner_1 = theta_cone - cone_half_step + (q - q_half_step) * beta_lo;
	float corner_2 = theta_cone - cone_half_step + (q + q_half_step) * beta_lo;
	float corner_3 = theta_cone + cone_half_step + (q - q_half_step) * beta_lo;
	float corner_4 = theta_cone + cone_half_step + (q + q_half_step) * beta_lo;
	float corner_5 = theta_cone - cone_half_step + (q - q_half_step) * beta_hi;
	float corner_6 = theta_cone - cone_half_step + (q + q_half_step) * beta_hi;
	float corner_7 = theta_cone + cone_half_step + (q - q_half_step) * beta_hi;
	float corner_8 = theta_cone + cone_half_step + (q + q_half_step) * beta_hi;
	if (abs(corner_1) > PI * 0.5 || abs(corner_2) > PI * 0.5 || abs(corner_3) > PI * 0.5
			|| abs(corner_4) > PI * 0.5 || abs(corner_5) > PI * 0.5 || abs(corner_6) > PI * 0.5
			|| abs(corner_7) > PI * 0.5 || abs(corner_8) > PI * 0.5) {
		return true;
	}
	// Grazing margin: the CPU's 1.25 * (q_half_step*beta_hi + cone_half_step
	// + abs(q)*(beta_hi - beta_lo)).
	float grazing_margin = 1.25 * (q_half_step * beta_hi + cone_half_step + abs(q) * (beta_hi - beta_lo));
	return abs(theta_cone + q * beta_r) > PI * 0.5 - grazing_margin;
}


/** Clamp/no-wrap trilinear Q sample from r_standardized_lut at (q,
 *  theta_cone, beta_r), matching the CPU's sample_q(): texel centers at
 *  (i + 0.5) / N on every axis, half-texel clamped into the interior
 *  texel-center range so the repeat-disabled sampler never wraps. log_decode
 *  reads the G channel (log2(Q)) and decodes Q = 2^G (trilinear
 *  interpolation in log2 space, matching the log2-beta axis); both decodes
 *  return linear Q. */
float fm_r_std_sample_q(float q, float theta_cone, float beta_r, sampler3D lut_texture, bool log_decode) {
	ivec3 lut_size = textureSize(lut_texture, 0);
	float half_x = 0.5 / float(lut_size.x);
	float half_y = 0.5 / float(lut_size.y);
	float half_z = 0.5 / float(lut_size.z);
	float log2_beta_min = log(FM_R_STD_BETA_MIN) * FM_R_STD_INV_LN_2;
	float log2_beta_span = (log(FM_R_STD_BETA_MAX) - log(FM_R_STD_BETA_MIN)) * FM_R_STD_INV_LN_2;
	vec3 uvw = vec3(
		clamp((q - FM_R_STD_Q_MIN) / (FM_R_STD_Q_MAX - FM_R_STD_Q_MIN), half_x, 1.0 - half_x),
		clamp((theta_cone - (-PI * 0.5)) / PI, half_y, 1.0 - half_y),
		clamp((log(beta_r) * FM_R_STD_INV_LN_2 - log2_beta_min) / log2_beta_span, half_z, 1.0 - half_z));
	vec4 sample_value = texture(lut_texture, uvw);
	if (log_decode) {
		return pow(2.0, sample_value.g);
	}
	return sample_value.r;
}


/** Reconstructs M_R*N_R from Q (the CPU's direct_r_mn_from_q()):
 *     M_R*N_R = Q / (4*sqrt(2)*beta_m*cos(theta_o)
 *                     * sqrt(cos(theta_cone)*cos(theta_o)))
 * The denominator floors mirror the CPU (beta_m at BETA_NUMERIC_EPSILON,
 * cosines at COSINE_EPSILON, and a 1e-30 absolute floor), so beta_m == 0 and
 * grazing never evaluate 0*infinity or divide by zero: Q stays bounded while
 * M_R diverges like 1/beta_r^2, and the product stays finite and
 * nonnegative. */
float fm_r_std_mn_from_q(float q_value, float theta_o, float theta_cone, float beta_m) {
	float beta_m_safe = max(beta_m, FM_R_STD_BETA_NUMERIC_EPSILON);
	float cos_o = max(cos(theta_o), FM_R_STD_COSINE_EPSILON);
	float cos_cone = max(cos(theta_cone), FM_R_STD_COSINE_EPSILON);
	float denominator = 4.0 * sqrt(2.0) * beta_m_safe * cos_o * sqrt(cos_cone * cos_o);
	return max(q_value, 0.0) / max(denominator, 1e-30);
}


/** Diagnostic standardized-R longitudinal product (FM_R_STANDARDIZED_LUT_MODE
 *  1): the full R product M_R*N_R for the analytic and LUT BSDFs, matching
 *  the CPU coordinate derivation (derive_r_coordinates + sample/fallback
 *  seam):
 *
 *    c_phi = clamp(cos_phi_half, 0, 1)
 *    z_r = max(cos(theta_d) * c_phi, 0)
 *    sin_theta_cone = clamp(-sin_theta_i + 2*z_r*cuticle_tilt_value, -1, 1)
 *    theta_cone = asin(sin_theta_cone)
 *    beta_r = sqrt(2) * c_phi * max(beta_m, 0)
 *    q = (theta_o - theta_cone) / max(beta_r, 1e-8)
 *
 *  Q comes from the clamped trilinear LUT read when inside the support
 *  (linear or log2 decode), and from the direct/asymptotic reference
 *  otherwise (q/beta outside support, cone-pole outer two theta_cone texel
 *  bands, grazing footprints, or beta_r <= 1e-8 -> asymptotic Gaussian
 *  limit, which is exactly the beta_r -> 0 resolution of the 0*infinity
 *  form). The caller multiplies the reconstructed product by the Fresnel
 *  term. */
float fm_r_standardized_longitudinal_product(float sin_theta_i, float sin_theta_o, float cos_theta_d, float cos_phi_half, float cuticle_tilt_value, float beta_m_value, sampler3D lut_texture, bool log_decode) {
	float c_phi = clamp(cos_phi_half, 0.0, 1.0);
	float z_r = max(cos_theta_d * c_phi, 0.0);
	float sin_cone = clamp(-sin_theta_i + 2.0 * z_r * cuticle_tilt_value, -1.0, 1.0);
	float theta_cone = asin(sin_cone);
	float theta_o = asin(clamp(sin_theta_o, -0.999999, 0.999999));
	float beta_r = sqrt(2.0) * c_phi * max(beta_m_value, 0.0);
	float beta_safe = max(beta_r, FM_R_STD_BETA_NUMERIC_EPSILON);
	float q = (theta_o - theta_cone) / beta_safe;
	float q_value;
	if (beta_r <= FM_R_STD_BETA_NUMERIC_EPSILON) {
		q_value = fm_r_std_asymptotic_q(theta_o, theta_cone, beta_r);
	} else if (fm_r_std_requires_fallback(q, theta_cone, beta_r, lut_texture)) {
		q_value = fm_r_std_reference_q(theta_o, theta_cone, beta_r);
	} else {
		q_value = fm_r_std_sample_q(q, theta_cone, beta_r, lut_texture, log_decode);
	}
	return fm_r_std_mn_from_q(q_value, theta_o, theta_cone, beta_m_value);
}
#endif


/** Chiang et al. (2016) albedo-to-absorption reparameterization, matching the
 *  current high-tier shader's default path. Clamped for near-black albedo. */
vec3 fm_sigma_a_from_albedo(vec3 base_color, float beta_n) {
	vec3 safe_albedo = clamp(base_color, vec3(1e-4), vec3(1.0));
	float c = 5.969 + beta_n * (-0.215 + beta_n * (2.532 + beta_n * (-10.73 + beta_n * (5.574 + beta_n * 0.245))));
	vec3 sigma = log(safe_albedo) / max(c, 1e-4);
	return sigma * sigma;
}


/** Melanin absorption from the Chiang et al. (2016) power laws, sampled at
 *  representative R/G/B wavelengths (650/540/450 nm). Concentrations are
 *  artist-facing 0..1 values; `scale` maps the m^-1 result into shader units. */
vec3 fm_sigma_a_from_melanin(float eumelanin_amount, float pheomelanin_amount, float scale) {
	const vec3 lambda_nm = vec3(650.0, 540.0, 450.0);
	vec3 sigma = max(eumelanin_amount, 0.0) * 6.6e11 * pow(lambda_nm, vec3(-3.33))
		+ max(pheomelanin_amount, 0.0) * 2.9e14 * pow(lambda_nm, vec3(-4.75));
	return max(sigma * max(scale, 0.0), vec3(0.0));
}


/** Selects the absorption coefficient for the configured absorption_mode. */
vec3 fm_absorption_coefficient(vec3 base_color, float beta_n) {
	if (absorption_mode == 1) {
		return max(absorption, vec3(0.0));
	}
	if (absorption_mode == 2) {
		return fm_sigma_a_from_melanin(eumelanin, pheomelanin, melanin_absorption_scale);
	}
	return fm_sigma_a_from_albedo(base_color, beta_n);
}


/** Karis (2016) Stage-A fake multiple scattering, preserved from the current
 *  high-tier shader's light() term with guards against degenerate inputs
 *  (black albedo, zero luminance, and view directions along the strand axis).
 *  The normalized omega_o.yz is precomputed once per fragment and passed in.
 *  Not physically based. */
vec3 fm_karis_multiple_scattering(vec3 base_color, vec3 omega_i, vec2 omega_o_yz_normalized, float attenuation) {
	float luminance = max(dot(base_color, vec3(0.299, 0.587, 0.114)), 1e-4);
	vec3 multiple_scattering = 0.25 * sqrt(max(base_color, vec3(0.0)))
		* (dot(omega_i.yz, omega_o_yz_normalized) + 1.0)
		* pow(max(base_color / luminance, vec3(1e-4)), vec3(attenuation));
	return multiple_scattering * smoothstep(-0.5, 1.0, attenuation);
}


/** Local dual-scattering slice (Zinke-style approximation, direct light only):
 *  the packed attributes depth channel (strand_depth varying) acts as a local
 *  density/visibility proxy. Depth polarity follows the source contract
 *  (attributes_texture.g: 0 = deep, 1 = shallow), so the slice maps it
 *  monotonically to a deepness proxy (1 - depth): DEEP strands receive the
 *  greater/equal local density response. The forward-scattered term is
 *  attenuated by that density through sigma_a (Beer-Lambert), the
 *  backward-scattered term peaks when light and view oppose, and both are
 *  tinted by the base color. In the dual variant this REPLACES the Karis
 *  diffuse term (never adds on top of it); strength/density come from the
 *  profile and a zero strength yields no diffuse contribution, preserving the
 *  Karis appearance when the feature is disabled. */
vec3 fm_dual_scattering(vec3 base_color, vec3 omega_i, vec2 omega_o_yz_normalized, vec3 sigma_a, float depth, float strength, float density, float attenuation) {
	float safe_strength = max(strength, 0.0);
	// Deepness mapping: 1 - depth, so depth 0 (deep) -> deepness 1.
	float deepness = 1.0 - clamp(depth, 0.0, 1.0);
	float local_density = deepness * clamp(density, 0.0, 1.0);
	float view_alignment = clamp(dot(omega_i.yz, omega_o_yz_normalized), -1.0, 1.0);

	// Forward-scattered transmitted component: Beer-Lambert attenuation through
	// the local density, strongest when the light and view directions agree.
	vec3 forward_scatter = exp(-max(sigma_a, vec3(0.0)) * max(local_density, 1e-4))
		* (view_alignment + 1.0) * 0.5;

	// Backward-scattered component: peaks for opposing light/view directions.
	// Do not use abs() here: that would also suppress the physically important
	// opposing-direction lobe at view_alignment = -1.
	vec3 backward_scatter = exp(-max(sigma_a, vec3(0.0)) * max(local_density, 1e-4) * 0.5)
		* (1.0 - view_alignment) * 0.5;

	return (forward_scatter + backward_scatter) * max(base_color, vec3(0.0)) * safe_strength
		* smoothstep(-0.5, 1.0, attenuation);
}


/** Documented default/fallback of the preintegrated LUT's scalar
 *  density/event-proxy axis upper bound (tau_d = 4 * local_density). The
 *  reachable domain is [0, 4] (local_density is clamped to [0, 1]); the
 *  committed resource stores tau_max = 4.0 as metadata and the adapter binds
 *  it into dual_scatter_lut_tau_max, so the runtime uses the resource's own
 *  domain and never silently claims the wider legacy 16-wide axis. */
const float FM_DUAL_SCATTER_TAU_MAX = 4.0;


/** Stage-B preintegrated local dual scattering (opt-in, replaces the Karis
 *  diffuse term exactly like Stage A - never adds on top of it). The committed
 *  2D LUT stores scalar density/event-proxy weights over the tau_d/cosine
 *  domain (see the dual_scatter_lut uniform): P1 = 1 - exp(-tau_d) and
 *  P3 = 1 - exp(-1.5 * tau_d), split forward/backward by the scattering
 *  cosine with the F0 baked at the LUT eta (dual_scatter_lut_eta, 1.55). Zero
 *  local density produces zero secondary energy and increasing density
 *  saturates toward the available one-/three-event energy. The LUT is sampled
 *  once at the scalar tau_d; runtime sigma_a stays RGB and is applied as the
 *  four per-direction path responses
 *  T1f = exp(-sigma_a * local_path), T1b = exp(-sigma_a * local_path * 0.5),
 *  T3f = exp(-sigma_a * local_path * 1.5), T3b = exp(-sigma_a * local_path * 0.75)
 *  with local_path = 1.0 (the unit one-event forward path; density enters the
 *  event weights through tau_d, never through this RGB absorption), so the
 *  LUT never bakes a hair color, there is no double absorption, and the
 *  forward/backward split stored in the four channels is preserved at
 *  runtime (the previous R+G / B+A summation cancelled it). Outside the
 *  baked-IOR tolerance (abs(ior - dual_scatter_lut_eta) <= 0.0005) the same
 *  Contract B formula is evaluated analytically with the runtime eta/F0 and
 *  the exact same four-path reconstruction and event weights instead of
 *  sampling the LUT; the Stage-A slice fm_dual_scattering() is a separate
 *  variant and is never used as this parity fallback. Inputs are bounded
 *  (deepness, density, view alignment, and tau_d clamped to
 *  [0, dual_scatter_lut_tau_max], the resource's tau_max metadata), the
 *  stored weights are bounded in [0, 1] with monotone growth in tau_d, and
 *  ATTENUATION enters only as the direct-light visibility ramp - it is never
 *  part of the LUT math. */
vec3 fm_dual_scattering_preintegrated(vec3 base_color, vec3 omega_i, vec2 omega_o_yz_normalized, vec3 sigma_a, float depth, float strength, float density, sampler2D lut_texture, float eta, float lut_eta, float attenuation) {
	float safe_strength = max(strength, 0.0);
	// Deepness mapping matches Stage A: depth 0 (deep) -> deepness 1.
	float deepness = 1.0 - clamp(depth, 0.0, 1.0);
	float local_density = deepness * clamp(density, 0.0, 1.0);
	float view_alignment = clamp(dot(omega_i.yz, omega_o_yz_normalized), -1.0, 1.0);

	// Scalar density/event proxy: density controls how much secondary energy
	// is generated (tau_d = 4 * local_density). RGB sigma_a is never an axis
	// of this LUT; it is applied separately below.
	float lut_tau_max = max(dual_scatter_lut_tau_max, 1e-3);
	float tau_d = clamp(local_density * 4.0, 0.0, lut_tau_max);

	// Contract B four-path responses: local_path is the unit one-event
	// forward path (1.0 in the LUT's tau_d unit system). Backward paths are
	// half the forward paths (Stage-A convention) and three-event paths are
	// 1.5x the one-event paths, so each directional channel carries its own
	// Beer-Lambert response.
	const float local_path = 1.0;
	vec3 t1_forward = exp(-max(sigma_a, vec3(0.0)) * local_path);
	vec3 t1_backward = exp(-max(sigma_a, vec3(0.0)) * local_path * 0.5);
	vec3 t3_forward = exp(-max(sigma_a, vec3(0.0)) * local_path * 1.5);
	vec3 t3_backward = exp(-max(sigma_a, vec3(0.0)) * local_path * 0.75);

	vec3 energy = vec3(0.0);
	if (abs(eta - lut_eta) <= 0.0005) {
		// Square LUT; the half-texel inset keeps clamped samples on texel
		// centers so the repeat-disabled sampler can never wrap either axis.
		float texel_scale = 1.0 / float(textureSize(lut_texture, 0).x);
		float half_texel = 0.5 * texel_scale;
		float v_domain = clamp(0.5 + 0.5 * view_alignment, 0.0, 1.0);
		float v_uv = mix(half_texel, 1.0 - half_texel, v_domain);
		float u_domain = clamp(tau_d * (1.0 / lut_tau_max), 0.0, 1.0);
		float u_uv = mix(half_texel, 1.0 - half_texel, u_domain);
		vec4 events = texture(lut_texture, vec2(u_uv, v_uv));
		// Reconstruct the four directional channels separately; the
		// forward/backward split stored in the LUT survives at runtime.
		energy = vec3(events.r) * t1_forward + vec3(events.g) * t1_backward
			+ vec3(events.b) * t3_forward + vec3(events.a) * t3_backward;
	} else {
		// Analytic Contract B fallback for a runtime IOR outside the baked-LUT
		// tolerance: the same P1/P3 event weights and the exact same four-path
		// reconstruction with F0 evaluated at the runtime eta, at the same
		// scalar tau_d.
		float f0 = (1.0 - eta) * (1.0 - eta) / ((1.0 + eta) * (1.0 + eta));
		float one_event_fresnel = (1.0 - f0) * (1.0 - f0);
		float three_event_fresnel = one_event_fresnel * f0;
		float forward_lobe = 0.5 * (1.0 + view_alignment);
		float backward_lobe = 0.5 * (1.0 - view_alignment);
		float one_event_weight = 1.0 - exp(-tau_d);
		float three_event_weight = 1.0 - exp(-1.5 * tau_d);
		energy = forward_lobe * one_event_fresnel * one_event_weight * t1_forward
			+ backward_lobe * one_event_fresnel * one_event_weight * t1_backward
			+ forward_lobe * three_event_fresnel * three_event_weight * t3_forward
			+ backward_lobe * three_event_fresnel * three_event_weight * t3_backward;
	}

	return energy * max(base_color, vec3(0.0)) * safe_strength
		* smoothstep(-0.5, 1.0, attenuation);
}


/** Fast analytic Marschner BSDF: FM_LONGITUDINAL_MODE-selected Gaussian
 *  longitudinal R/TT/TRT and the fixed-h logistic analytic azimuthal model
 *  (FM_AZIMUTHAL_FIXED_H_ANALYTIC) with Unity-style fixed-h attenuation
 *  (FM_ATTENUATION_MODE 0 / FM_ATTENUATION_UNITY_FIXED_H). All
 *  inputs are in strand space:
 *  [sin(theta), cos(theta)*cos(phi), cos(theta)*sin(phi)].
 *  The light-invariant view/lobe values (view_cos_theta, view_theta_o,
 *  lobe_alpha, lobe_variance) are precomputed once per fragment in fragment()
 *  and passed in; only omega_i and the angle combinations below vary per
 *  light. cuticle_tilt_offset and beta_m are the extra scalars consumed by
 *  the FM_LONGITUDINAL_MODE 1 diagnostic branch (ignored in mode 0). */
vec3 fm_hair_bsdf(vec3 omega_i, vec3 omega_o, float view_cos_theta, float view_theta_o, vec3 lobe_alpha, vec3 lobe_variance, vec2 azimuthal_s_inv, vec2 logistic_b, vec3 sigma_a, float eta, float cuticle_tilt_value, float beta_m_value) {
	float sin_theta_i = omega_i.x;
	float sin_theta_o = omega_o.x;
	float cos_theta_i = length(omega_i.yz);
	float cos_theta_o = view_cos_theta;

	// phi = phi_o - phi_i (relative azimuth)
	float cos_phi = clamp((omega_i.y * omega_o.y + omega_i.z * omega_o.z) / max(cos_theta_i * cos_theta_o, 1e-6), -0.9999, 0.9999);
	float sin_phi = clamp((omega_i.y * omega_o.z - omega_i.z * omega_o.y) / max(cos_theta_i * cos_theta_o, 1e-6), -0.9999, 0.9999);
	float cos_phi_half = max(1e-6, sqrt(0.5 + 0.5 * cos_phi));

	// theta_d = (theta_o - theta_i) / 2 (longitudinal difference angle)
	float cos_theta = clamp(cos_theta_o * cos_theta_i + sin_theta_o * sin_theta_i, -1.0, 1.0);
	float cos_theta_d = sqrt(0.5 + 0.5 * cos_theta);
	float sin_theta_d = sqrt(0.5 - 0.5 * cos_theta) * sign(sin_theta_o * cos_theta_i - cos_theta_o * sin_theta_i);

	// Snell transmitted-angle convention: the Unity fixed-h branch (mode 0)
	// uses the outgoing/view longitudinal angle; the legacy diagnostic branch
	// (mode 1) retains the incoming/light convention for controlled diagnosis.
#if FM_ATTENUATION_MODE == FM_ATTENUATION_UNITY_FIXED_H
	float cos_theta_t = sqrt(max(0.0, 1.0 - sin_theta_o * sin_theta_o / (eta * eta)));
#else
	float cos_theta_t = sqrt(max(0.0, 1.0 - sin_theta_i * sin_theta_i / (eta * eta)));
#endif

	// 'Effective' index of refraction and its reciprocal, both bounded.
	float eta_prime = sqrt(max(eta * eta - sin_theta_d * sin_theta_d, 1e-6)) / max(cos_theta_d, 1e-6);
	float eta_prime_inv = 1.0 / eta_prime;

	// Fixed representative cross-section offsets for the azimuthal angular
	// offsets and the fixed-h attenuation family (Tier 2 plan): h_TT = 0 and
	// h_TRT = sqrt(3)/2. h_R is unused because the R lobe's attenuation is the
	// plain Fresnel term below. FM_AZIMUTHAL_MODE 1 (diagnostic, analytic BSDF
	// only) overrides the offsets with the baseline cross-section formula
	// (dynamic h_TT, h_TRT = 0.91); attenuation and the LUT path are never
	// affected, and mode 0 keeps the shipping math byte-identical.
#if FM_AZIMUTHAL_MODE == FM_AZIMUTHAL_BASELINE_H_ANALYTIC
	float sin_phi_half = sqrt(0.5 - 0.5 * cos_phi) * sign(sin_phi);
	vec3 h = vec3(0.0, fm_azimuthal_baseline_h_tt(cos_phi_half, sin_phi_half, eta_prime_inv), FM_AZIMUTHAL_BASELINE_H_TRT);
#else
	vec3 h = vec3(0.0, FM_H_TT, FM_H_TRT);
#endif

	vec3 m_p = fm_longitudinal_scattering(asin(clamp(sin_theta_i, -0.999999, 0.999999)), view_theta_o, lobe_alpha, lobe_variance, cuticle_tilt_value, beta_m_value);
#if FM_R_LONGITUDINAL_MODE == 1
	// Diagnostic override: cheap non-separable R only (see
	// fm_r_longitudinal_nonseparable). TT/TRT keep the shared path, and
	// mode 0 emits nothing here.
	m_p[FM_R] = fm_r_longitudinal_nonseparable(sin_theta_i, sin_theta_o, cos_phi_half, cuticle_tilt_value, beta_m_value);
#endif

	vec3 result = vec3(0.0);
#ifdef FM_LOBE_R
#if FM_R_STANDARDIZED_LUT_MODE == 1
	// Diagnostic standardized-R path: the reconstructed R product M_R*N_R
	// from the committed LUT times the analytic Fresnel, replacing the
	// shipping 0.25*cos_phi_half*M_R product (which evaluates 0*infinity as
	// beta_r -> 0). m_p[FM_R] is unused for R in this mode (its unit is M_R
	// alone, while the reconstruction returns the full product); TT/TRT keep
	// the shared m_p path below. Only reachable in the committed diagnostic
	// wrapper (FM_R_STANDARDIZED_LUT_MODE 1), which declares the LUT
	// uniforms.
	result += vec3(fm_r_standardized_longitudinal_product(sin_theta_i, sin_theta_o, cos_theta_d, cos_phi_half, cuticle_tilt_value, beta_m_value, r_standardized_lut, r_standardized_lut_log_decode)
		* fm_fresnel(cos_theta_d * cos_phi_half, eta) * lobe_scales[FM_R]);
#else
	// R is a special case with a simple cosine azimuthal lobe and Fresnel
	// attenuation; it carries no absorption color.
	result += vec3((0.25 * cos_phi_half) * fm_fresnel(cos_theta_d * cos_phi_half, eta) * m_p[FM_R] * lobe_scales[FM_R]);
#endif
#endif
#ifdef FM_LOBE_TT
	result += fm_logistic(fm_azimuthal_angular_offset(FM_TT, cos_phi, sin_phi, eta_prime_inv, h[FM_TT]), azimuthal_s_inv.x, logistic_b.x)
		* fm_att_fixed_h(FM_TT, cos_theta_o, cos_theta_d, cos_theta_t, eta_prime, sigma_a, eta)
		* vec3(m_p[FM_TT] * lobe_scales[FM_TT]);
#endif
#ifdef FM_LOBE_TRT
	result += fm_logistic(fm_azimuthal_angular_offset(FM_TRT, cos_phi, sin_phi, eta_prime_inv, h[FM_TRT]), azimuthal_s_inv.y, logistic_b.y)
		* fm_att_fixed_h(FM_TRT, cos_theta_o, cos_theta_d, cos_theta_t, eta_prime, sigma_a, eta)
		* vec3(m_p[FM_TRT] * lobe_scales[FM_TRT]);
#endif
	return result;
}


/** LUT-backed fast Marschner BSDF: the azimuthal R/TT/TRT terms are sampled
 *  per light from the committed 3D LUT (u = normalized relative azimuth phi,
 *  v = cos_theta_d, w = hoisted azimuthal width); the Unity-style fixed-h
 *  attenuation, the FM_LONGITUDINAL_MODE-selected longitudinal Gaussian terms
 *  (shared with fm_hair_bsdf through fm_longitudinal_scattering), and
 *  per-lobe scales stay analytic and match fm_hair_bsdf exactly. The LUT R
 *  channel includes the azimuthal Fresnel factor. The sample is
 *  light-dependent; only the width axis (lut_width) is light-invariant and
 *  hoisted to fragment(). Callers must only invoke this with a lut_width
 *  derived from a beta_N inside the generator's beta axis [0.001, 1.0];
 *  light() falls back to fm_hair_bsdf otherwise (lut_azimuthal_compatible)
 *  instead of clamping the roughness. FM_AZIMUTHAL_MODE never affects this
 *  path: its R/TT/TRT azimuthal terms are baked at the fixed-h offsets
 *  (h_TT = 0, h_TRT = sqrt(3)/2), so the baseline-h diagnostic
 *  (FM_AZIMUTHAL_MODE 1) applies to the analytic BSDF only and no LUT
 *  sampling semantics change in any mode. */
vec3 fm_hair_bsdf_lut(vec3 omega_i, vec3 omega_o, float view_cos_theta, float view_theta_o, vec3 lobe_alpha, vec3 lobe_variance, vec2 azimuthal_s_inv, vec2 logistic_b, vec3 sigma_a, float eta, float lut_width, sampler3D lut_texture, float cuticle_tilt_value, float beta_m_value) {
	float sin_theta_i = omega_i.x;
	float sin_theta_o = omega_o.x;
	float cos_theta_i = length(omega_i.yz);
	float cos_theta_o = view_cos_theta;

	// phi = phi_o - phi_i (relative azimuth), same clamp semantics as analytic.
	float cos_phi = clamp((omega_i.y * omega_o.y + omega_i.z * omega_o.z) / max(cos_theta_i * cos_theta_o, 1e-6), -0.9999, 0.9999);
	float sin_phi = clamp((omega_i.y * omega_o.z - omega_i.z * omega_o.y) / max(cos_theta_i * cos_theta_o, 1e-6), -0.9999, 0.9999);

	// theta_d = (theta_o - theta_i) / 2 (longitudinal difference angle).
	float cos_theta = clamp(cos_theta_o * cos_theta_i + sin_theta_o * sin_theta_i, -1.0, 1.0);
	float cos_theta_d = sqrt(0.5 + 0.5 * cos_theta);
	float sin_theta_d = sqrt(0.5 - 0.5 * cos_theta) * sign(sin_theta_o * cos_theta_i - cos_theta_o * sin_theta_i);

	// Snell and effective index, matching the analytic attenuation inputs:
	// mode 0 uses the outgoing/view convention, mode 1 the incoming/light one.
#if FM_ATTENUATION_MODE == FM_ATTENUATION_UNITY_FIXED_H
	float cos_theta_t = sqrt(max(0.0, 1.0 - sin_theta_o * sin_theta_o / (eta * eta)));
#else
	float cos_theta_t = sqrt(max(0.0, 1.0 - sin_theta_i * sin_theta_i / (eta * eta)));
#endif
	float eta_prime = sqrt(max(eta * eta - sin_theta_d * sin_theta_d, 1e-6)) / max(cos_theta_d, 1e-6);
	float eta_prime_inv = 1.0 / eta_prime;

	// Periodic-U contract: phi wraps continuously via fract() (the sampler's
	// repeat mode interpolates across the seam between the last and first
	// texels), while V/W are remapped into the interior texel-center range so
	// repeat cannot wrap those axes. The half-texel inset uses the texture's
	// own size rather than a hard-coded resolution.
	float phi = atan(sin_phi, cos_phi);
	float texel_scale = 1.0 / float(textureSize(lut_texture, 0).x);
	float half_texel = 0.5 * texel_scale;
	vec3 lut_uvw = vec3(
		fract((phi + PI) / TAU),
		clamp(cos_theta_d, half_texel, 1.0 - half_texel),
		clamp(lut_width, half_texel, 1.0 - half_texel));
	vec3 azimuthal = texture(lut_texture, lut_uvw).rgb;

	vec3 m_p = fm_longitudinal_scattering(asin(clamp(sin_theta_i, -0.999999, 0.999999)), view_theta_o, lobe_alpha, lobe_variance, cuticle_tilt_value, beta_m_value);
#if FM_R_LONGITUDINAL_MODE == 1
	// Diagnostic override: cheap non-separable R only, matching the analytic
	// BSDF exactly. cos_phi_half is derived from the existing local cos_phi
	// (the LUT R channel already carries the azimuthal R term; only the
	// longitudinal R factor changes). TT/TRT keep the shared path.
	float cos_phi_half = max(1e-6, sqrt(0.5 + 0.5 * cos_phi));
	m_p[FM_R] = fm_r_longitudinal_nonseparable(sin_theta_i, sin_theta_o, cos_phi_half, cuticle_tilt_value, beta_m_value);
#endif

	vec3 result = vec3(0.0);
#ifdef FM_LOBE_R
#if FM_R_STANDARDIZED_LUT_MODE == 1
	// Diagnostic standardized-R path (mirrors the analytic BSDF exactly): the
	// reconstructed R product M_R*N_R times the analytic Fresnel, replacing
	// azimuthal.r * m_p[FM_R] (the baked 0.25*cos_phi_half*Fresnel form).
	// The LUT R channel's baked 0.25*cos_phi_half*Fresnel factor is not
	// reused because dividing the reconstruction by 0.25*cos_phi_half would
	// reintroduce the 0*infinity form at the c_phi seam. The committed
	// diagnostic wrapper forces use_azimuthal_lut=false, so this branch is
	// the defensive consistency path; TT/TRT keep the LUT azimuthal terms
	// below.
	float cos_phi_half = max(1e-6, sqrt(0.5 + 0.5 * cos_phi));
	result += vec3(fm_r_standardized_longitudinal_product(sin_theta_i, sin_theta_o, cos_theta_d, cos_phi_half, cuticle_tilt_value, beta_m_value, r_standardized_lut, r_standardized_lut_log_decode)
		* fm_fresnel(cos_theta_d * cos_phi_half, eta) * lobe_scales[FM_R]);
#else
	// LUT R channel already includes 0.25*cos(phi/2)*Fresnel(cos_theta_d*cos(phi/2)).
	result += azimuthal.r * m_p[FM_R] * lobe_scales[FM_R];
#endif
#endif
#ifdef FM_LOBE_TT
	result += azimuthal.g * fm_att_fixed_h(FM_TT, cos_theta_o, cos_theta_d, cos_theta_t, eta_prime, sigma_a, eta) * m_p[FM_TT] * lobe_scales[FM_TT];
#endif
#ifdef FM_LOBE_TRT
	result += azimuthal.b * fm_att_fixed_h(FM_TRT, cos_theta_o, cos_theta_d, cos_theta_t, eta_prime, sigma_a, eta) * m_p[FM_TRT] * lobe_scales[FM_TRT];
#endif
	return result;
}
