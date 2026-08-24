extends RefCounted

## CPU reference for the standardized projected R-longitudinal kernel.
##
## Stored quantity: Q = beta_r * sqrt(cos(theta_cone) * cos(theta_o))
## * cos(theta_o) * M_R (the d'Eon 2011 energy-conserving longitudinal kernel
## M_R scaled by the projected-cosine factors). The full R product
##     M_R * N_R = Q / (4 * sqrt(2) * beta_m * cos(theta_o)
##                      * sqrt(cos(theta_cone) * cos(theta_o)))
## (N_R = 0.25 * cos(phi/2), the R cosine lobe of the baseline azimuthal
## scattering) is reconstructed directly from Q, so beta_R -> 0 never
## evaluates the 0 * infinity form: Q stays bounded while M_R diverges like
## 1/beta_r^2.
##
## Branch contract (beta_r = sqrt(2) * c_phi * beta_m):
##   beta_r >  BETA_NUMERIC_EPSILON -> direct Bessel form (direct_q_value)
##   beta_r <= BETA_NUMERIC_EPSILON -> asymptotic Gaussian limit
##                                     (asymptotic_q_value)
## The asymptotic exponent is written as -2*sin(delta/2)^2 with
## delta = theta_o - theta_cone instead of the algebraically identical
## cos(delta) - 1, which suffers catastrophic cancellation for tiny delta.
##
## Accuracy note: inside the direct branch, log Q is the difference of two
## ~variance_inverse-sized terms (the quadratic term and the Bessel linear
## term), so double-precision cancellation makes the direct form's relative
## error ~1e-16*variance_inverse. It decays from ~13% just above the branch
## threshold (beta_r ~ 2e-8) to ~5e-6 by beta_r ~ 1e-4 (the latter floor is
## the rounded Bessel constant 0.564187, kept for shader parity). The
## asymptotic branch has no such cancellation and is the accurate form in the
## low-beta fallback regime; the seam contract only requires it to stay
## finite, nonnegative, and bounded.
##
## Edge behavior (all outputs remain finite and nonnegative):
## - beta_m == 0 (zero roughness): beta_r = 0 forces the asymptotic branch.
##   The exact model's R lobe degenerates to a Dirac distribution; the
##   reference returns the finite floored-broadened value (Q peaks at
##   1/sqrt(2*pi), then the 1/beta_m numeric floor in the N_R reconstruction),
##   never inf/NaN.
## - c_phi == 0 (exact azimuthal seam, cos(phi/2) == 0): z_r = 0 so the
##   cuticle tilt drops out (theta_cone = -theta_i) and beta_r = 0 forces the
##   asymptotic branch; the reconstruction returns the c_phi -> 0+ limit of
##   M_R * N_R, resolving the 0 * infinity form of the naive product.
## - Grazing (cos(theta_o) -> 0): cos values floor at COSINE_EPSILON, which
##   keeps both the log terms and the reconstruction denominator finite; the
##   output grows large (the exact kernel is unbounded at cos_o = 0) but never
##   overflows to inf.

const Q_MIN := -12.0
const Q_MAX := 12.0
const BETA_LUT_MIN := 0.02
const BETA_LUT_MAX := 9.0
const LOG2_VALUE_FLOOR := -120.0
const COSINE_EPSILON := 1e-12
const BETA_NUMERIC_EPSILON := 1e-8
const INV_SQRT_TAU := 0.3989422804014327


static func log_bessel_zero(x: float) -> float:
	var x_sq := x * x
	var value := (0.564187 + 1.01298 / (x_sq + 2.32434))
	value *= 1.0 / sqrt(sqrt(x_sq * 0.25 + 1.0))
	value *= exp(-2.0 * absf(x)) * 0.5 + 0.5
	return log(maxf(value, 1e-300)) + x


static func direct_log_m(theta_o: float, theta_cone: float, beta_effective: float) -> float:
	var beta := maxf(beta_effective, BETA_NUMERIC_EPSILON)
	var sin_o := sin(theta_o)
	var cos_o := maxf(cos(theta_o), COSINE_EPSILON)
	var sin_cone := sin(theta_cone)
	var cos_cone := maxf(cos(theta_cone), COSINE_EPSILON)
	var variance_inverse := 1.0 / (beta * beta)
	return (sin_cone * sin_o - 1.0) * variance_inverse \
		+ log_bessel_zero(cos_cone * cos_o * variance_inverse) \
		+ log(variance_inverse) - log(cos_o)


static func direct_log_q_value(theta_o: float, theta_cone: float, beta_effective: float) -> float:
	var beta := maxf(beta_effective, BETA_NUMERIC_EPSILON)
	var cos_o := maxf(cos(theta_o), COSINE_EPSILON)
	var cos_cone := maxf(cos(theta_cone), COSINE_EPSILON)
	return direct_log_m(theta_o, theta_cone, beta) \
		+ log(beta) + 0.5 * log(cos_cone) + 1.5 * log(cos_o)


static func direct_q_value(theta_o: float, theta_cone: float, beta_effective: float) -> float:
	return exp(clampf(direct_log_q_value(theta_o, theta_cone, beta_effective), LOG2_VALUE_FLOOR * log(2.0), 80.0))


## Asymptotic (large variance-argument) limit of the direct Q value:
##   Q ~ 1/sqrt(2*pi) * exp(-2*sin(delta/2)^2 / beta^2),
##   delta = theta_o - theta_cone.
## The exponent uses -2*sin(delta/2)^2 instead of the algebraically identical
## cos(delta) - 1 to avoid catastrophic cancellation for tiny delta (with the
## cos form, delta ~ 1e-8 loses most significant digits before the division).
## beta_effective is floored at BETA_NUMERIC_EPSILON, so beta_m == 0 and the
## exact c_phi == 0 seam (beta_r == 0) stay finite: the exponent is always
## <= 0 and exp() never overflows.
static func asymptotic_q_value(theta_o: float, theta_cone: float, beta_effective: float) -> float:
	var beta := maxf(beta_effective, BETA_NUMERIC_EPSILON)
	var half_delta := 0.5 * (theta_o - theta_cone)
	return INV_SQRT_TAU * exp(-2.0 * sin(half_delta) * sin(half_delta) / (beta * beta))


static func derive_r_coordinates(theta_i: float, theta_o: float, theta_d: float,
		cos_phi_half: float, cuticle_tilt: float, beta_m: float) -> Dictionary:
	var c_phi := clampf(cos_phi_half, 0.0, 1.0)
	var z_r := maxf(cos(theta_d) * c_phi, 0.0)
	var sin_cone := clampf(-sin(theta_i) + 2.0 * z_r * cuticle_tilt, -1.0, 1.0)
	var theta_cone := asin(sin_cone)
	var beta_r := sqrt(2.0) * c_phi * maxf(beta_m, 0.0)
	var beta_safe := maxf(beta_r, BETA_NUMERIC_EPSILON)
	return {
		"c_phi": c_phi,
		"z_r": z_r,
		"sin_cone": sin_cone,
		"theta_cone": theta_cone,
		"beta_r": beta_r,
		"beta_safe": beta_safe,
		"q": (theta_o - theta_cone) / beta_safe,
	}


static func direct_r_mn(theta_i: float, theta_o: float, theta_d: float,
		cos_phi_half: float, cuticle_tilt: float, beta_m: float) -> float:
	var coordinates := derive_r_coordinates(theta_i, theta_o, theta_d, cos_phi_half, cuticle_tilt, beta_m)
	var theta_cone: float = coordinates["theta_cone"]
	var beta_r: float = coordinates["beta_r"]
	var q_value := direct_q_value(theta_o, theta_cone, beta_r) if beta_r > BETA_NUMERIC_EPSILON \
		else asymptotic_q_value(theta_o, theta_cone, beta_r)
	return direct_r_mn_from_q(q_value, theta_o, theta_cone, beta_m)


static func direct_r_mn_from_q(q_value: float, theta_o: float, theta_cone: float, beta_m: float) -> float:
	var beta_m_safe := maxf(beta_m, BETA_NUMERIC_EPSILON)
	var cos_o := maxf(cos(theta_o), COSINE_EPSILON)
	var cos_cone := maxf(cos(theta_cone), COSINE_EPSILON)
	var denominator := 4.0 * sqrt(2.0) * beta_m_safe * cos_o * sqrt(cos_cone * cos_o)
	return maxf(q_value, 0.0) / maxf(denominator, 1e-30)


static func finite_nonnegative(value: float) -> bool:
	return is_finite(value) and value >= 0.0
