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
#define FM_LONGITUDINAL_MODE 0
#define FM_R_LONGITUDINAL_MODE 0
#define FM_CUTICLE_TILT_CONVENTION 0

#include "./hair_marschner_fast_body.gdshaderinc"
