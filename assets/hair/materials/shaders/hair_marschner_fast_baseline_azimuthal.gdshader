// Baseline-h azimuthal diagnostic wrapper (PR5).
//
// Diagnostic compile-time selector override: FM_AZIMUTHAL_MODE 1 selects the
// baseline cross-section diagnostic for the ANALYTIC BSDF only (see
// fm_azimuthal_baseline_h_tt in hair_marschner_fast.gdshaderinc): dynamic
// h_TT = sign(sin_phi_half) * cos_phi_half / sqrt(1 + eta_prime_inv * (1 -
// 2 * eta_prime_inv * abs(sin_phi_half))) and h_TRT = 0.91
// (FM_AZIMUTHAL_BASELINE_H_TRT), replacing the shipping fixed-h offsets
// h_TT = 0 / h_TRT = sqrt(3)/2 (FM_AZIMUTHAL_FIXED_H_ANALYTIC) in the
// azimuthal angular offsets only. The LUT path is untouched in this mode
// (its azimuthal terms are baked at the fixed-h offsets, so no LUT sampling
// semantics change) and attenuation always keeps the shipping fixed-h family
// (FM_ATTENUATION_MODE 0). The longitudinal model stays shipping
// (FM_LONGITUDINAL_MODE 0), R stays on the shared longitudinal path
// (FM_R_LONGITUDINAL_MODE 0), and the cuticle-tilt convention stays baseline
// (FM_CUTICLE_TILT_CONVENTION 0).
//
// No duplicated shader body: the shared body lives in
// hair_marschner_fast_body.gdshaderinc and is included below.
#define FM_LONGITUDINAL_MODE 0
#define FM_R_LONGITUDINAL_MODE 0
#define FM_CUTICLE_TILT_CONVENTION 0
#define FM_AZIMUTHAL_MODE 1

#include "./hair_marschner_fast_body.gdshaderinc"
