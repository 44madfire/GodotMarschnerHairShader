// Non-separable R longitudinal diagnostic wrapper (PR4).
//
// Diagnostic compile-time selector override: FM_R_LONGITUDINAL_MODE 1
// overrides ONLY m_p[FM_R] after the shared fm_longitudinal_scattering call in
// both the analytic and LUT BSDFs with the cheap non-separable R approximation
// in sin(theta_o) space (z_r = cos_phi_half, beta_r = sqrt(2.0)*z_r*beta_m,
// sin_theta_cone_r = clamp(-sin_theta_i + 2.0*z_r*cuticle_tilt_value, -1.0,
// 1.0); see fm_r_longitudinal_nonseparable in hair_marschner_fast.gdshaderinc).
// TT/TRT and the longitudinal model itself stay shipping
// (FM_LONGITUDINAL_MODE 0) and the cuticle-tilt convention stays baseline
// (FM_CUTICLE_TILT_CONVENTION 0).
//
// No duplicated shader body: the shared body lives in
// hair_marschner_fast_body.gdshaderinc and is included below.
#define FM_LONGITUDINAL_MODE 0
#define FM_R_LONGITUDINAL_MODE 1
#define FM_CUTICLE_TILT_CONVENTION 0

#include "./hair_marschner_fast_body.gdshaderinc"
