// Tier 2 fast Marschner helpers. This include intentionally contains only the
// analytic (LUT-free) fast Marschner slice used by hair_marschner_fast.gdshader,
// plus the opt-in Stage-B preintegrated (LUT-backed) local dual-scattering
// slice (FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED). The Stage-A analytic
// fallback fm_dual_scattering() stays intact and is the default.
//
// Longitudinal scattering is a normalized Gaussian in sin(theta) space with the
// fixed Marschner (2003) lobe tilts/widths specified by the Tier 2 plan:
//
//   Cuticle tilt (alpha):    R = -alpha,  TT = +0.5*alpha,  TRT = +1.5*alpha
//   Longitudinal roughness:  R = beta,    TT = 0.5*beta,    TRT = 2.0*beta
//
// Azimuthal scattering is the analytic d'Eon et al. (2011) model already used
// by the high-tier include (Fresnel + Beer-Lambert attenuation with logistic
// distributions), evaluated with the fixed representative cross-section offsets
// from the Tier 2 plan: h_TT = 0 and h_TRT = sqrt(3)/2. No LUT is required.

// --- Compile-time lobe configuration ---
// Comment out a lobe define to strip that lobe from the compiled shader
// variant. The runtime `lobe_scales` Debug uniform below provides per-lobe
// debug isolation without recompiling.
#define FM_LOBE_R
#define FM_LOBE_TT
#define FM_LOBE_TRT

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
/** 64x64 RGBAF scalar one-/three-event attenuation/energy terms (see
 *  benchmark/tools/generate_marschner_dual_scatter_lut.gd and
 *  validate_marschner_dual_scatter_lut.gd). Axes: U = scalar optical depth
 *  tau = sigma * local path in [0, 16] (texel centers at (i + 0.5) / N),
 *  V = scattering cosine c (light/view alignment) in [-1, 1] -> 0.5 + 0.5*c.
 *  Channels: R = one-event forward, G = one-event backward, B = three-event
 *  forward, A = three-event backward. The stored terms are scalar: runtime
 *  sigma_a stays RGB and the LUT is sampled once per color channel at that
 *  channel's own optical depth, so no single hair color is baked in. Linear
 *  filtering with repeat disabled; both axes are half-texel clamped into the
 *  interior texel-center range so the clamped sample never wraps. */
uniform sampler2D dual_scatter_lut : filter_linear, repeat_disable;
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
 *  analytic d'Eon azimuthal model as the reference; the LUT is a separately
 *  selectable variant, never silently enabled. */
uniform bool use_azimuthal_lut = false;
/** 64^3 RGBAF azimuthal R/TT/TRT terms, axes U=phi, V=cos_theta_d,
 *  W=azimuthal_roughness (see benchmark/tools/generate_marschner_azimuthal_lut.gd
 *  and validate_marschner_azimuthal_lut.gd). Linear sampling with repeat
 *  enabled: the U/phi axis wraps continuously at the seam (sampled with
 *  fract() and texel centers over [-PI, PI]), while V and W are half-texel
 *  clamped so repeat never wraps those axes. */
uniform sampler3D azimuthal_lut : filter_linear, repeat_enable;
group_uniforms;


/** Schlick's bias approximation, guarded against a zero bias parameter. */
float power(float x, float t) {
	float safe_t = clamp(t, 1e-4, 1.0);
	float safe_x = clamp(x, 0.0, 1.0);
	return safe_x / ((1.0 / safe_t - 2.0) * (1.0 - safe_x) + 1.0);
}


/** Normalized Gaussian in sin(theta) space with a bounded inverse width. */
vec3 fm_gaussian(vec3 theta, vec3 beta_inv) {
	return exp(-0.5 * theta * theta * beta_inv * beta_inv) * beta_inv * inversesqrt(TAU);
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
	float eta_prime_inv = exp(-phi * s_inv);
	float c = 1.0 + eta_prime_inv;
	return min(1.0, s_inv * eta_prime_inv * (1.0 + b_pre) / ((1.0 - b_pre) * c * c));
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


/** TT attenuation with the fixed h_TT = 0 and mode = 1 constants folded in:
 *  Fresnel input cos(theta_d), Beer-Lambert path factor 4.0, and
 *  (1 - F)^2 * transmittance. */
vec3 fm_tt_attenuation(float cos_theta_t, float cos_theta_d, vec3 sigma_a, float eta) {
	float f = fm_fresnel(cos_theta_d, eta);
	// Beer-Lambert law; the TT path length is 4.0 * (1 - eta'^-2 * 0^2) * 1.
	vec3 transmittance = exp(-max(sigma_a, vec3(0.0)) / max(cos_theta_t, 1e-4) * 4.0);
	return (1.0 - f) * (1.0 - f) * transmittance;
}


/** TRT attenuation with the fixed h_TRT = sqrt(3)/2 and mode = 2 constants
 *  folded in: Fresnel input cos(theta_d)*0.5 (sqrt(1 - h*h) = 0.5), Beer-Lambert
 *  path factor 8.0*(1.0 - 0.75*eta'^-2), and (1 - F)^2 * F * transmittance. */
vec3 fm_trt_attenuation(float cos_theta_t, float cos_theta_d, vec3 sigma_a, float eta_prime_inv, float eta) {
	float f = fm_fresnel(cos_theta_d * 0.5, eta);
	// Beer-Lambert law; the TRT path length is 4.0 * (1 - eta'^-2 * 0.75) * 2.
	vec3 transmittance = exp(-max(sigma_a, vec3(0.0)) / max(cos_theta_t, 1e-4) * 8.0 * (1.0 - 0.75 * eta_prime_inv * eta_prime_inv));
	return (1.0 - f) * (1.0 - f) * f * transmittance;
}


/** Gaussian longitudinal scattering for R, TT, and TRT with the Tier 2 plan's
 *  fixed per-lobe tilt and roughness defaults. The per-lobe tilt sin/cos and
 *  inverse widths are precomputed once per fragment and passed in instead of
 *  being recomputed per light. */
vec3 fm_longitudinal_scattering(float sin_theta_i, float cos_theta_i, float sin_theta_o, vec3 sin_alpha_m, vec3 cos_alpha_m, vec3 beta_m_inv) {
	vec3 sin_theta_cone = -cos_theta_i * sin_alpha_m - sin_theta_i * cos_alpha_m;
	return fm_gaussian(sin_theta_o - sin_theta_cone, beta_m_inv);
}


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
	vec3 backward_scatter = exp(-max(sigma_a, vec3(0.0)) * max(local_density, 1e-4) * 0.5)
		* (1.0 - abs(view_alignment)) * 0.5;

	return (forward_scatter + backward_scatter) * max(base_color, vec3(0.0)) * safe_strength
		* smoothstep(-0.5, 1.0, attenuation);
}


/** Upper bound of the preintegrated LUT's scalar optical-depth axis (tau).
 *  exp(-16) is below 1.2e-7, so the far end of the axis is effectively black
 *  and the runtime clamp at this bound keeps all lookups inside the domain. */
const float FM_DUAL_SCATTER_TAU_MAX = 16.0;


/** Stage-B preintegrated local dual scattering (opt-in, replaces the Karis
 *  diffuse term exactly like Stage A - never adds on top of it). The committed
 *  2D LUT stores scalar one-/three-event attenuation/energy terms over a
 *  scalar optical-depth/cosine domain (see the dual_scatter_lut uniform).
 *  The LUT stores aggregate local-scattering energy: zero local density produces
 *  zero secondary energy and increasing density saturates toward the available
 *  one-/three-event energy. Runtime sigma_a remains RGB and is applied as
 *  separate Beer-Lambert tinting for the one- and three-event path lengths, so
 *  the LUT never bakes a single hair color. Inputs are bounded (deepness,
 *  density, view alignment, and tau clamped to [0, FM_DUAL_SCATTER_TAU_MAX]),
 *  the LUT terms are bounded in [0, 1] with monotone energy growth in tau, and
 *  ATTENUATION enters only as the direct-light visibility ramp - it is never
 *  part of the LUT math. */
vec3 fm_dual_scattering_preintegrated(vec3 base_color, vec3 omega_i, vec2 omega_o_yz_normalized, vec3 sigma_a, float depth, float strength, float density, sampler2D lut_texture, float attenuation) {
	float safe_strength = max(strength, 0.0);
	// Deepness mapping matches Stage A: depth 0 (deep) -> deepness 1.
	float deepness = 1.0 - clamp(depth, 0.0, 1.0);
	float local_density = deepness * clamp(density, 0.0, 1.0);
	float view_alignment = clamp(dot(omega_i.yz, omega_o_yz_normalized), -1.0, 1.0);

	// Square LUT; the half-texel inset keeps clamped samples on texel centers
	// so the repeat-disabled sampler can never wrap either axis.
	float texel_scale = 1.0 / float(textureSize(lut_texture, 0).x);
	float half_texel = 0.5 * texel_scale;
	float v_domain = clamp(0.5 + 0.5 * view_alignment, 0.0, 1.0);
	float v_uv = mix(half_texel, 1.0 - half_texel, v_domain);

	// Scalar local-scattering optical depth: density controls how much secondary
	// energy is generated, while RGB sigma_a is applied separately below.
	float tau = clamp(local_density * 4.0, 0.0, FM_DUAL_SCATTER_TAU_MAX);
	float u_domain = clamp(tau * (1.0 / FM_DUAL_SCATTER_TAU_MAX), 0.0, 1.0);
	float u_uv = mix(half_texel, 1.0 - half_texel, u_domain);
	vec4 events = texture(lut_texture, vec2(u_uv, v_uv));
	vec3 one_event_transmittance = exp(-max(sigma_a, vec3(0.0)));
	vec3 three_event_transmittance = exp(-max(sigma_a, vec3(0.0)) * 1.5);
	vec3 energy = vec3(events.r + events.g) * one_event_transmittance
		+ vec3(events.b + events.a) * three_event_transmittance;

	return energy * max(base_color, vec3(0.0)) * safe_strength
		* smoothstep(-0.5, 1.0, attenuation);
}


/** Fast analytic Marschner BSDF: Gaussian longitudinal R/TT/TRT and the
 *  analytic d'Eon azimuthal model with the fixed cross-section offsets from
 *  the Tier 2 plan. All inputs are in strand space:
 *  [sin(theta), cos(theta)*cos(phi), cos(theta)*sin(phi)].
 *  The light-invariant view/tilt/width values are precomputed once per
 *  fragment in fragment() and passed in; only omega_i and the angle
 *  combinations below vary per light. */
vec3 fm_hair_bsdf(vec3 omega_i, vec3 omega_o, float view_cos_theta, vec3 sin_alpha_m, vec3 cos_alpha_m, vec3 beta_m_inv, vec2 azimuthal_s_inv, vec2 logistic_b, vec3 sigma_a, float eta) {
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

	// sin(theta_i) = eta * sin(theta_t) (Snell's law, longitudinal inclination)
	float cos_theta_t = sqrt(max(0.0, 1.0 - sin_theta_i * sin_theta_i / (eta * eta)));

	// 'Effective' index of refraction and its reciprocal, both bounded.
	float eta_prime = sqrt(max(eta * eta - sin_theta_d * sin_theta_d, 1e-6)) / max(cos_theta_d, 1e-6);
	float eta_prime_inv = 1.0 / eta_prime;

	// Fixed representative cross-section offsets for fast attenuation (Tier 2
	// plan): h_TT = 0 and h_TRT = sqrt(3)/2. h_R is unused because the R lobe's
	// attenuation is the plain Fresnel term below.
	vec3 h = vec3(0.0, 0.0, 0.5 * sqrt(3.0));

	vec3 m_p = fm_longitudinal_scattering(sin_theta_i, cos_theta_i, sin_theta_o, sin_alpha_m, cos_alpha_m, beta_m_inv);

	vec3 result = vec3(0.0);
#ifdef FM_LOBE_R
	// R is a special case with a simple cosine azimuthal lobe and Fresnel
	// attenuation; it carries no absorption color.
	result += vec3((0.25 * cos_phi_half) * fm_fresnel(cos_theta_d * cos_phi_half, eta) * m_p[FM_R] * lobe_scales[FM_R]);
#endif
#ifdef FM_LOBE_TT
	result += fm_logistic(fm_azimuthal_angular_offset(FM_TT, cos_phi, sin_phi, eta_prime_inv, h[FM_TT]), azimuthal_s_inv.x, logistic_b.x)
		* fm_tt_attenuation(cos_theta_t, cos_theta_d, sigma_a, eta)
		* vec3(m_p[FM_TT] * lobe_scales[FM_TT]);
#endif
#ifdef FM_LOBE_TRT
	result += fm_logistic(fm_azimuthal_angular_offset(FM_TRT, cos_phi, sin_phi, eta_prime_inv, h[FM_TRT]), azimuthal_s_inv.y, logistic_b.y)
		* fm_trt_attenuation(cos_theta_t, cos_theta_d, sigma_a, eta_prime_inv, eta)
		* vec3(m_p[FM_TRT] * lobe_scales[FM_TRT]);
#endif
	return result;
}


/** LUT-backed fast Marschner BSDF: the azimuthal R/TT/TRT terms are sampled
 *  per light from the committed 3D LUT (u = normalized relative azimuth phi,
 *  v = cos_theta_d, w = hoisted azimuthal width); the Beer-Lambert
 *  attenuation, longitudinal Gaussian terms, and per-lobe scales stay
 *  analytic and match fm_hair_bsdf exactly. The LUT R channel includes the
 *  azimuthal Fresnel factor. The sample is light-dependent; only the width
 *  axis (lut_width) is light-invariant and hoisted to fragment(). */
vec3 fm_hair_bsdf_lut(vec3 omega_i, vec3 omega_o, float view_cos_theta, vec3 sin_alpha_m, vec3 cos_alpha_m, vec3 beta_m_inv, vec2 azimuthal_s_inv, vec2 logistic_b, vec3 sigma_a, float eta, float lut_width, sampler3D lut_texture) {
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

	// Snell and effective index, matching the analytic attenuation inputs.
	float cos_theta_t = sqrt(max(0.0, 1.0 - sin_theta_i * sin_theta_i / (eta * eta)));
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

	vec3 m_p = fm_longitudinal_scattering(sin_theta_i, cos_theta_i, sin_theta_o, sin_alpha_m, cos_alpha_m, beta_m_inv);

	vec3 result = vec3(0.0);
#ifdef FM_LOBE_R
	// LUT R channel already includes 0.25*cos(phi/2)*Fresnel(cos_theta_d*cos(phi/2)).
	result += azimuthal.r * m_p[FM_R] * lobe_scales[FM_R];
#endif
#ifdef FM_LOBE_TT
	result += azimuthal.g * fm_tt_attenuation(cos_theta_t, cos_theta_d, sigma_a, eta) * m_p[FM_TT] * lobe_scales[FM_TT];
#endif
#ifdef FM_LOBE_TRT
	result += azimuthal.b * fm_trt_attenuation(cos_theta_t, cos_theta_d, sigma_a, eta_prime_inv, eta) * m_p[FM_TRT] * lobe_scales[FM_TRT];
#endif
	return result;
}
