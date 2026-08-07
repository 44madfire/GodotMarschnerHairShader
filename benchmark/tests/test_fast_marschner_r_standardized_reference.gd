extends SceneTree

## Direct CPU equivalence, seam/branch-contract, z-identity, sign-mapping, and
## Q-reconstruction tests for the standardized R kernel reference.
##
## The baseline is an INDEPENDENT port of the shipping baseline R lobe
## (benchmark/reference/hair.gdshaderinc under the shipping defines
## USE_ENERGY_CONSERVING_LONGITUDINAL_SCATTERING_FUNCTION +
## USE_NON_SEPARABLE_LONGITUDINAL_WIDTHS_AND_TILT_ANGLES +
## USE_APPROXIMATE_NON_SEPARABLE_LONGITUDINAL_TILT_ANGLES): its own Bessel
## approximation and its own constants, so a shared bug inside the Reference
## helpers cannot make the equivalence pass vacuously.

const Reference := preload("res://benchmark/reference/fast_marschner_r_standardized_kernel_reference.gd")

## Independent baseline constants. Equal to the Reference's by contract, but
## declared here so the baseline never reads Reference state.
const COSINE_EPSILON := 1e-12
const BETA_EPSILON := 1e-8
const INV_SQRT_TAU := 0.3989422804014327

const THETA_I_DEGREES := [-75, -60, -30, 0, 30, 60, 75]
const BETA_M_VALUES := [0.02, 0.1, 0.3, 0.8, 1.5, 4.0]
const CUTICLE_VALUES := [0.0, 0.03, 0.087, 0.15]
const PHI_SAMPLES := 32
const RELATIVE_GATE := 1e-8
const ABSOLUTE_GATE := 1e-8

var _failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_direct_equivalence_sweep()
	_z_identity_sweep()
	_sign_mapping_test()
	_branch_threshold_test()
	_seam_and_grazing_test()
	_q_reconstruction_test()
	if _failures.is_empty():
		print("FAST_MARSCHNER_R_STANDARDIZED_REFERENCE_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


## Independent scalar port of log_bessel_zero from
## benchmark/reference/hair.gdshaderinc (the shader formula, not the
## Reference's copy).
func _baseline_log_bessel_zero(x: float) -> float:
	var x_sq := x * x
	var approx := (0.564187 + 1.01298 / (x_sq + 2.32434)) \
		* (1.0 / sqrt(sqrt(x_sq * 0.25 + 1.0))) \
		* (exp(-2.0 * absf(x)) * 0.5 + 0.5)
	return log(approx) + x


## Independent baseline R longitudinal term M_R (d'Eon 2011 energy-conserving
## form, exponent clamped like the shader's). Port of
## longitudinal_scattering()'s R component with the R reduction folded in:
## h[R] = -sin(phi/2), z_prime[R] = 0 (shipped quirk), alpha = -cuticle
## (artist-facing cuticle_tilt), beta_r = sqrt(2)*cos(phi/2)*beta_m.
func _baseline_m_r(theta_i: float, theta_o: float, theta_d: float,
		cos_phi_half: float, cuticle: float, beta_m: float) -> float:
	var sin_theta_i := sin(theta_i)
	var sin_theta_o := sin(theta_o)
	var cos_theta_o := maxf(cos(theta_o), COSINE_EPSILON)
	var cos_theta_d := cos(theta_d)
	var z_r := cos_theta_d * cos_phi_half
	var beta_r := sqrt(2.0) * cos_phi_half * beta_m
	var sin_cone := clampf(-sin_theta_i + 2.0 * z_r * cuticle, -1.0, 1.0)
	var theta_cone := asin(sin_cone)
	var variance_inverse := 1.0 / maxf(beta_r * beta_r, BETA_EPSILON * BETA_EPSILON)
	var cos_cone := maxf(cos(theta_cone), COSINE_EPSILON)
	var log_m := (sin_cone * sin_theta_o - 1.0) * variance_inverse \
		+ _baseline_log_bessel_zero(cos_cone * cos_theta_o * variance_inverse) \
		+ log(variance_inverse) - log(cos_theta_o)
	return exp(clampf(log_m, -120.0 * log(2.0), 80.0))


## Independent baseline full R product M_R * N_R with N_R = 0.25*cos(phi/2).
func _baseline_r_mn(theta_i: float, theta_o: float, theta_d: float,
		cos_phi_half: float, cuticle: float, beta_m: float) -> float:
	return 0.25 * cos_phi_half * _baseline_m_r(theta_i, theta_o, theta_d, cos_phi_half, cuticle, beta_m)


## Independent expected M_R * N_R for a declared branch, built from the
## baseline's own Bessel port and constants. The Reference's direct_r_mn must
## reproduce this value exactly when its branch dispatch picks the same branch.
func _expected_mn(beta_m: float, beta_r: float, theta_o: float,
		theta_cone: float, c_phi: float, branch: String) -> float:
	var beta_m_safe := maxf(beta_m, BETA_EPSILON)
	var cos_o := maxf(cos(theta_o), COSINE_EPSILON)
	var cos_cone := maxf(cos(theta_cone), COSINE_EPSILON)
	var q_value := 0.0
	if branch == "asymptotic":
		var beta := maxf(beta_r, BETA_EPSILON)
		var half_delta := 0.5 * (theta_o - theta_cone)
		q_value = INV_SQRT_TAU * exp(-2.0 * sin(half_delta) * sin(half_delta) / (beta * beta))
	else:
		var beta := maxf(beta_r, BETA_EPSILON)
		var sin_o := sin(theta_o)
		var sin_cone := sin(theta_cone)
		var variance_inverse := 1.0 / (beta * beta)
		var log_q := (sin_cone * sin_o - 1.0) * variance_inverse \
			+ _baseline_log_bessel_zero(cos_cone * cos_o * variance_inverse) \
			+ log(variance_inverse) - log(cos_o) \
			+ log(beta) + 0.5 * log(cos_cone) + 1.5 * log(cos_o)
		q_value = exp(clampf(log_q, -120.0 * log(2.0), 80.0))
	var denominator := 4.0 * sqrt(2.0) * beta_m_safe * cos_o * sqrt(cos_cone * cos_o)
	return maxf(q_value, 0.0) / maxf(denominator, 1e-30)


func _direct_equivalence_sweep() -> void:
	var max_relative := 0.0
	var max_absolute := 0.0
	var stable_count := 0
	for theta_i_degree in THETA_I_DEGREES:
		var theta_i := deg_to_rad(float(theta_i_degree))
		for theta_o_degree in range(-80, 81, 5):
			var theta_o := deg_to_rad(float(theta_o_degree))
			for phi_index in PHI_SAMPLES:
				var phi := -PI + (float(phi_index) + 0.5) * TAU / float(PHI_SAMPLES)
				var cos_phi_half := maxf(1e-6, sqrt(0.5 + 0.5 * cos(phi)))
				if cos_phi_half < 1e-4:
					continue
				var theta_d: float = 0.5 * (theta_o - theta_i)
				for beta_m in BETA_M_VALUES:
					for cuticle in CUTICLE_VALUES:
						var baseline := _baseline_r_mn(theta_i, theta_o, theta_d, cos_phi_half, cuticle, beta_m)
						var direct := Reference.direct_r_mn(theta_i, theta_o, theta_d, cos_phi_half, cuticle, beta_m)
						var absolute := absf(baseline - direct)
						var relative := absolute / maxf(absf(baseline), 1e-8)
						max_absolute = maxf(max_absolute, absolute)
						max_relative = maxf(max_relative, relative)
						stable_count += 1
						if absolute > ABSOLUTE_GATE or relative > RELATIVE_GATE:
							_fail("direct equivalence failed theta_i=%s theta_o=%s phi=%s beta_m=%s cuticle=%s abs=%s rel=%s" % [theta_i_degree, theta_o_degree, phi_index, beta_m, cuticle, absolute, relative])
	print("EVIDENCE standardized_direct_equivalence stable_samples=%s max_absolute=%s max_relative=%s" % [stable_count, max_absolute, max_relative])


## Verifies the full z identity with k^2: with h[R] = -sin(phi/2),
## k_sq = sin^2(theta_d) + cos^2(theta_d)*h^2 and
## z = sqrt(1 - k_sq) must equal z_r = max(cos(theta_d)*c_phi, 0).
func _z_identity_sweep() -> void:
	var max_absolute := 0.0
	var samples := 0
	for theta_i_degree in THETA_I_DEGREES:
		var theta_i := deg_to_rad(float(theta_i_degree))
		for theta_o_degree in range(-80, 81, 5):
			var theta_o := deg_to_rad(float(theta_o_degree))
			for phi_index in PHI_SAMPLES:
				var phi := -PI + (float(phi_index) + 0.5) * TAU / float(PHI_SAMPLES)
				var cos_phi_half := maxf(1e-6, sqrt(0.5 + 0.5 * cos(phi)))
				var sin_phi_half := sqrt(maxf(0.0, 1.0 - cos_phi_half * cos_phi_half))
				var theta_d: float = 0.5 * (theta_o - theta_i)
				var k_sq := sin(theta_d) * sin(theta_d) \
					+ cos(theta_d) * cos(theta_d) * sin_phi_half * sin_phi_half
				var z_k := sqrt(maxf(0.0, 1.0 - k_sq))
				var coordinates := Reference.derive_r_coordinates(theta_i, theta_o, theta_d, cos_phi_half, 0.087, 0.02)
				var z_r: float = coordinates["z_r"]
				var absolute := absf(z_k - z_r)
				max_absolute = maxf(max_absolute, absolute)
				samples += 1
				if absolute > 1e-8:
					_fail("z identity failed theta_i=%s theta_o=%s phi=%s z_k=%s z_r=%s abs=%s" % [theta_i_degree, theta_o_degree, phi_index, z_k, z_r, absolute])
	print("EVIDENCE standardized_z_identity samples=%s max_abs=%s" % [samples, max_absolute])


## Verifies the alpha = -cuticle sign mapping: the shipping baseline passes
## alpha = -cuticle_tilt_offset into longitudinal_scattering and with the
## shipped z_prime[R] = 0 quirk the approximate R tilt is
##   sin_theta_cone[R] = clamp(-sin(theta_i) + (2*0 - 2*z)*alpha, -1, 1)
##                     = clamp(-sin(theta_i) + 2*z*cuticle_tilt, -1, 1),
## so the reference's cuticle_tilt parameter must equal -alpha. Also asserts
## the wrong sign (alpha = +cuticle_tilt) does NOT match where unsaturated.
func _sign_mapping_test() -> void:
	var samples := 0
	var unsaturated := 0
	for theta_i_degree in THETA_I_DEGREES:
		var theta_i := deg_to_rad(float(theta_i_degree))
		for theta_o_degree in range(-80, 81, 10):
			var theta_o := deg_to_rad(float(theta_o_degree))
			for phi_index in 16:
				var phi := -PI + (float(phi_index) + 0.5) * TAU / 16.0
				var cos_phi_half := maxf(1e-6, sqrt(0.5 + 0.5 * cos(phi)))
				var theta_d: float = 0.5 * (theta_o - theta_i)
				var z_r := maxf(cos(theta_d) * cos_phi_half, 0.0)
				for cuticle in CUTICLE_VALUES:
					var coordinates := Reference.derive_r_coordinates(theta_i, theta_o, theta_d, cos_phi_half, cuticle, 0.02)
					var sin_cone: float = coordinates["sin_cone"]
					# Shader formula with alpha = -cuticle and z_prime[R] = 0.
					var sin_cone_shader := clampf(-sin(theta_i) - 2.0 * z_r * (-cuticle), -1.0, 1.0)
					samples += 1
					if absf(sin_cone - sin_cone_shader) > 1e-12:
						_fail("sign mapping failed theta_i=%s theta_o=%s phi=%s cuticle=%s sin_cone=%s shader=%s" % [theta_i_degree, theta_o_degree, phi_index, cuticle, sin_cone, sin_cone_shader])
					# Wrong sign (alpha = +cuticle) must differ where unsaturated.
					var sin_cone_wrong := clampf(-sin(theta_i) - 2.0 * z_r * cuticle, -1.0, 1.0)
					if cuticle != 0.0 and absf(sin_cone_shader) < 1.0 - 1e-6 and absf(sin_cone_wrong) < 1.0 - 1e-6:
						unsaturated += 1
						if absf(sin_cone - sin_cone_wrong) < 1e-9:
							_fail("sign mapping not exercised theta_i=%s theta_o=%s phi=%s cuticle=%s sin_cone=%s wrong=%s" % [theta_i_degree, theta_o_degree, phi_index, cuticle, sin_cone, sin_cone_wrong])
	print("EVIDENCE standardized_sign_mapping samples=%s unsaturated_checked=%s" % [samples, unsaturated])


## Branch contract below / at / above the beta_r threshold
## (BETA_NUMERIC_EPSILON = 1e-8) with delta = 0 and delta = 0.3, plus zero
## roughness (beta_m == 0), threshold-gap evidence, and the convergence of the
## two branches away from the threshold.
func _branch_threshold_test() -> void:
	var threshold := Reference.BETA_NUMERIC_EPSILON
	var c_phi := 0.5
	var cuticle := 0.087
	var theta_i := 0.1
	var theta_d := 0.05
	# theta_cone must come from the reference's own coordinate derivation so
	# delta = theta_o - theta_cone is the actual branch argument.
	var coordinates := Reference.derive_r_coordinates(theta_i, theta_i + 2.0 * theta_d, theta_d, c_phi, cuticle, 0.02)
	var theta_cone: float = coordinates["theta_cone"]
	# beta_m chosen so beta_r = sqrt(2)*c_phi*beta_m lands at 0.5x, 1x, 2x the
	# threshold, plus zero roughness and a mid-range direct-branch value.
	var beta_m_cases: Array[float] = [0.0, 0.5e-8, 1.4142135623730951e-8, 2.8284271247461903e-8, 1e-6, 0.02]
	for beta_m in beta_m_cases:
		var beta_r := sqrt(2.0) * c_phi * beta_m
		var branch := "asymptotic" if beta_r <= threshold else "direct"
		for delta: float in [0.0, 0.3]:
			var theta_o := theta_cone + delta
			var value := Reference.direct_r_mn(theta_i, theta_o, theta_d, c_phi, cuticle, beta_m)
			if not Reference.finite_nonnegative(value):
				_fail("branch result not finite/nonnegative beta_m=%s beta_r=%s branch=%s delta=%s value=%s" % [beta_m, beta_r, branch, delta, value])
			var expected := _expected_mn(beta_m, beta_r, theta_o, theta_cone, c_phi, branch)
			var absolute := absf(value - expected)
			var relative := absolute / maxf(absf(expected), 1e-8)
			if absolute > 1e-9 and relative > 1e-6:
				_fail("branch wiring failed beta_m=%s beta_r=%s branch=%s delta=%s value=%s expected=%s abs=%s rel=%s" % [beta_m, beta_r, branch, delta, value, expected, absolute, relative])
			print("EVIDENCE standardized_branch beta_m=%s beta_r=%s branch=%s delta=%s value=%s expected=%s" % [beta_m, beta_r, branch, delta, value, expected])
	# Threshold gap (delta = 0): the asymptotic branch at beta_r = eps/2 is the
	# exact Gaussian peak 1/sqrt(2*pi); the direct branch at beta_r = 2*eps
	# still carries the documented double-precision cancellation of two ~1e15
	# terms inside log Q (~13% at this beta), which is why the asymptotic
	# fallback exists. Assert boundedness, not equality, here.
	var q_direct_2eps := Reference.direct_q_value(theta_cone, theta_cone, 2.0 * threshold)
	var q_asymptotic_eps2 := Reference.asymptotic_q_value(theta_cone, theta_cone, 0.5 * threshold)
	print("EVIDENCE standardized_branch_threshold_gap delta=0 q_direct_2eps=%s q_asymptotic_eps2=%s ratio=%s" % [q_direct_2eps, q_asymptotic_eps2, q_direct_2eps / maxf(q_asymptotic_eps2, 1e-30)])
	if not Reference.finite_nonnegative(q_direct_2eps) or not Reference.finite_nonnegative(q_asymptotic_eps2):
		_fail("threshold q values not finite/nonnegative")
	if absf(q_asymptotic_eps2 - INV_SQRT_TAU) > 1e-12:
		_fail("asymptotic peak at threshold deviates from 1/sqrt(2*pi) q=%s" % q_asymptotic_eps2)
	if q_direct_2eps > 2.0 * INV_SQRT_TAU:
		_fail("direct branch at 2*eps unbounded near the Gaussian peak q=%s" % q_direct_2eps)
	# Convergence away from the threshold: once the cancellation error is
	# negligible (beta_r = 1e-4), the two branches agree to the irreducible
	# ~5e-6 bias of the rounded Bessel constant 0.564187 (which must stay
	# shader-parity).
	var q_direct := Reference.direct_q_value(theta_cone, theta_cone, 1e-4)
	var q_asymptotic := Reference.asymptotic_q_value(theta_cone, theta_cone, 1e-4)
	var convergence_ratio := q_direct / maxf(q_asymptotic, 1e-30)
	print("EVIDENCE standardized_branch_convergence beta_r=1e-4 ratio=%s" % convergence_ratio)
	if absf(convergence_ratio - 1.0) > 1e-4:
		_fail("direct/asymptotic convergence failed ratio=%s" % convergence_ratio)


## Exact c_phi == 0 seam (beta_r == 0, cuticle tilt drops out, asymptotic
## branch) and grazing inputs (theta_o / theta_i at +/-90 degrees) must stay
## finite and nonnegative; the exact seam must equal the independent
## asymptotic-branch expectation.
func _seam_and_grazing_test() -> void:
	var seam_count := 0
	var seam_finite := 0
	for c_phi in [1.0, 0.5, 0.1, 0.01, 0.001, 1e-6, 0.0]:
		for theta_i_degree in [-75.0, 0.0, 75.0]:
			for theta_o_degree in [-80.0, 0.0, 80.0]:
				for beta_m in [0.0, 0.02]:
					var theta_i := deg_to_rad(theta_i_degree)
					var theta_o := deg_to_rad(theta_o_degree)
					var theta_d: float = 0.5 * (theta_o - theta_i)
					var value := Reference.direct_r_mn(theta_i, theta_o, theta_d, c_phi, 0.087, beta_m)
					seam_count += 1
					if not Reference.finite_nonnegative(value):
						_fail("low-beta/seam result is not finite and nonnegative c_phi=%s theta_i=%s theta_o=%s beta_m=%s value=%s" % [c_phi, theta_i_degree, theta_o_degree, beta_m, value])
					else:
						seam_finite += 1
					if c_phi == 0.0:
						var coordinates := Reference.derive_r_coordinates(theta_i, theta_o, theta_d, c_phi, 0.087, beta_m)
						var theta_cone: float = coordinates["theta_cone"]
						var expected := _expected_mn(beta_m, 0.0, theta_o, theta_cone, c_phi, "asymptotic")
						var absolute := absf(value - expected)
						var relative := absolute / maxf(absf(expected), 1e-8)
						if absolute > 1e-9 and relative > 1e-6:
							_fail("exact seam branch mismatch theta_i=%s theta_o=%s beta_m=%s value=%s expected=%s abs=%s rel=%s" % [theta_i_degree, theta_o_degree, beta_m, value, expected, absolute, relative])
	print("EVIDENCE standardized_seam_finite=%d/%d" % [seam_finite, seam_count])

	var grazing_count := 0
	var grazing_finite := 0
	for theta_o_degree in [-90.0, 90.0]:
		for theta_i_degree in [-90.0, 0.0, 90.0]:
			for c_phi in [1.0, 0.5, 0.1, 0.001, 1e-6, 0.0]:
				for beta_m in [0.0, 0.02]:
					var theta_i := deg_to_rad(theta_i_degree)
					var theta_o := deg_to_rad(theta_o_degree)
					var theta_d: float = 0.5 * (theta_o - theta_i)
					var value := Reference.direct_r_mn(theta_i, theta_o, theta_d, c_phi, 0.087, beta_m)
					grazing_count += 1
					if not Reference.finite_nonnegative(value):
						_fail("grazing result is not finite and nonnegative theta_i=%s theta_o=%s c_phi=%s beta_m=%s value=%s" % [theta_i_degree, theta_o_degree, c_phi, beta_m, value])
					else:
						grazing_finite += 1
	print("EVIDENCE standardized_grazing_finite=%d/%d" % [grazing_finite, grazing_count])


## Independently tests the Q-to-M_R*N_R reconstruction: builds Q directly from
## the independent baseline M_R (Q = beta_r*sqrt(cos_cone*cos_o)*cos_o*M_R)
## and verifies direct_r_mn_from_q recovers 0.25*c_phi*M_R exactly.
func _q_reconstruction_test() -> void:
	var max_relative := 0.0
	var samples := 0
	for theta_i_degree in THETA_I_DEGREES:
		var theta_i := deg_to_rad(float(theta_i_degree))
		for theta_o_degree in range(-80, 81, 5):
			var theta_o := deg_to_rad(float(theta_o_degree))
			for phi_index in PHI_SAMPLES:
				var phi := -PI + (float(phi_index) + 0.5) * TAU / float(PHI_SAMPLES)
				var cos_phi_half := maxf(1e-6, sqrt(0.5 + 0.5 * cos(phi)))
				if cos_phi_half < 1e-4:
					continue
				var theta_d: float = 0.5 * (theta_o - theta_i)
				for beta_m: float in BETA_M_VALUES:
					for cuticle: float in CUTICLE_VALUES:
						var m_r := _baseline_m_r(theta_i, theta_o, theta_d, cos_phi_half, cuticle, beta_m)
						var sin_cone := clampf(-sin(theta_i) + 2.0 * maxf(cos(theta_d) * cos_phi_half, 0.0) * cuticle, -1.0, 1.0)
						var theta_cone := asin(sin_cone)
						var cos_o := maxf(cos(theta_o), COSINE_EPSILON)
						var cos_cone := maxf(cos(theta_cone), COSINE_EPSILON)
						var beta_r := sqrt(2.0) * cos_phi_half * beta_m
						var q_value := beta_r * sqrt(cos_cone * cos_o) * cos_o * m_r
						var reconstructed := Reference.direct_r_mn_from_q(q_value, theta_o, theta_cone, beta_m)
						var expected := 0.25 * cos_phi_half * m_r
						var relative := absf(reconstructed - expected) / maxf(absf(expected), 1e-30)
						max_relative = maxf(max_relative, relative)
						samples += 1
						if relative > 1e-9:
							_fail("Q reconstruction failed theta_i=%s theta_o=%s phi=%s beta_m=%s cuticle=%s reconstructed=%s expected=%s rel=%s" % [theta_i_degree, theta_o_degree, phi_index, beta_m, cuticle, reconstructed, expected, relative])
	print("EVIDENCE standardized_q_reconstruction samples=%s max_relative=%s" % [samples, max_relative])


func _fail(message: String) -> void:
	_failures.append(message)
	push_error(message)
