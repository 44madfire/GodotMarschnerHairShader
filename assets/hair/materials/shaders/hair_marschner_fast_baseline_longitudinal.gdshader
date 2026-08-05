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
#define FM_LONGITUDINAL_MODE 1
#define FM_R_LONGITUDINAL_MODE 0
#define FM_CUTICLE_TILT_CONVENTION 0

#include "./hair_marschner_fast_body.gdshaderinc"
