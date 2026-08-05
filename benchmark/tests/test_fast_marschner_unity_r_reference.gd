extends SceneTree

## Standalone CPU reference tests for the Unity HDRP R-lobe attribution model.
## This deliberately does not instantiate BenchmarkHarness or touch a shader.

const UNITY_H_STEP := 0.1
const UNITY_H_SAMPLES := 20
const UNITY_SQRT_PI_OVER_8 := 0.6266570686577501
const ETA := 1.55
const INTEGRATION_SAMPLES := 4096
const EXPECTED_N_R_ZERO_BETA_HALF := 0.24265561

var _failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for beta in [0.1, 0.5, 0.9]:
		var normalization := _integrate_phi(beta)
		print("EVIDENCE unity_r_n_normalization beta=%.3f value=%.8f" % [beta, normalization])
		if absf(normalization - 1.0) > 0.02:
			_fail("N_R normalization for beta %.3f is %.8f, expected approximately 1" % [beta, normalization])

	for phi in [0.1, 0.5, 1.0, 2.0]:
		var positive := _unity_r_azimuthal_direct(phi, 0.5)
		var negative := _unity_r_azimuthal_direct(-phi, 0.5)
		print("EVIDENCE unity_r_n_symmetry phi=%.3f positive=%.8f negative=%.8f" % [phi, positive, negative])
		if absf(positive - negative) > 1e-5:
			_fail("N_R symmetry failed at phi %.3f" % phi)

	var seam_left := _unity_r_azimuthal_direct(-PI - 0.3, 0.5)
	var seam_right := _unity_r_azimuthal_direct(PI - 0.3, 0.5)
	print("EVIDENCE unity_r_n_periodicity left=%.8f right=%.8f" % [seam_left, seam_right])
	if absf(seam_left - seam_right) > 1e-8:
		_fail("N_R periodicity failed at the phi seam")

	var sharp := _unity_r_azimuthal_direct(0.0, 0.1)
	var broad := _unity_r_azimuthal_direct(0.0, 0.9)
	print("EVIDENCE unity_r_n_roughness sharp=%.8f broad=%.8f" % [sharp, broad])
	if sharp <= broad:
		_fail("N_R roughness behavior did not broaden as beta increased")
	var pinned := _unity_r_azimuthal_direct(0.0, 0.5)
	print("EVIDENCE unity_r_n_pinned beta=0.5 value=%.8f expected=%.8f" % [pinned, EXPECTED_N_R_ZERO_BETA_HALF])
	if absf(pinned - EXPECTED_N_R_ZERO_BETA_HALF) > 1e-7:
		_fail("N_R pinned reference drifted: %.8f != %.8f" % [pinned, EXPECTED_N_R_ZERO_BETA_HALF])

	var response_a := _unity_r_response(0.25, 0.2, -0.1, 0.5, 0.75, 0.087, 1.55, Vector3(0.1, 0.2, 0.3))
	var response_b := _unity_r_response(0.25, 0.2, -0.1, 0.5, 0.75, 0.087, 1.55, Vector3(4.0, 8.0, 12.0))
	print("EVIDENCE unity_r_no_absorption response_a=%.8f response_b=%.8f" % [response_a, response_b])
	if absf(response_a - response_b) > 1e-12:
		_fail("R response changed with sigma_a; R must not use Beer-Lambert absorption")

	# The checked-in current regression is exercised by the required control
	# command, because this standalone test intentionally has no process-spawn
	# dependency. Keep the control command explicit in the evidence.
	print("EVIDENCE current_control=validate_fast_marschner_energy.gd --contract=regression --r-study=current")
	_finish()


func _unity_logistic_scale_from_beta(beta: float) -> float:
	return UNITY_SQRT_PI_OVER_8 * (0.265 * beta + 1.194 * beta * beta + 5.372 * pow(absf(beta), 22.0))


func _unity_logistic(x: float, s: float) -> float:
	var safe_s := maxf(s, 1e-6)
	var e := exp(-absf(x) / safe_s)
	return e / (safe_s * (1.0 + e) * (1.0 + e))


func _unity_logistic_cdf(x: float, s: float) -> float:
	return 1.0 / (1.0 + exp(-x / maxf(s, 1e-6)))


func _unity_trimmed_logistic(x: float, s: float) -> float:
	var safe_s := maxf(s, 1e-6)
	var normalization := _unity_logistic_cdf(PI, safe_s) - _unity_logistic_cdf(-PI, safe_s)
	return _unity_logistic(x, safe_s) / maxf(normalization, 1e-9)


func _wrap_pi(x: float) -> float:
	return fposmod(x + PI, TAU) - PI


func _unity_r_azimuthal_direct(phi: float, raw_radial_roughness: float) -> float:
	var beta := clampf(raw_radial_roughness, 1e-3, 0.99)
	var s := maxf(_unity_logistic_scale_from_beta(beta), 1e-6)
	var total := 0.0
	for sample_index in UNITY_H_SAMPLES:
		var h := -1.0 + float(sample_index) * UNITY_H_STEP
		var direction_r := -2.0 * asin(clampf(h, -1.0, 1.0))
		total += _unity_trimmed_logistic(_wrap_pi(phi - direction_r), s) * UNITY_H_STEP
	return 0.5 * total


func _integrate_phi(beta: float) -> float:
	var total := 0.0
	var step := TAU / float(INTEGRATION_SAMPLES)
	for index in INTEGRATION_SAMPLES:
		var phi := -PI + (float(index) + 0.5) * step
		total += _unity_r_azimuthal_direct(phi, beta) * step
	return total


func _unity_r_response(phi: float, theta_i: float, theta_o: float, beta_m: float, beta_n: float,
		cuticle: float, eta: float, sigma_a: Vector3) -> float:
	# sigma_a is intentionally accepted to make the no-absorption contract
	# explicit; Unity R is a surface reflection path and does not use it.
	var theta_h := 0.5 * (theta_i + theta_o)
	var variance := maxf(beta_m * beta_m, 1e-5)
	var m := exp(-0.5 * (theta_h + cuticle) * (theta_h + cuticle) / variance) / sqrt(TAU * variance)
	var n := _unity_r_azimuthal_direct(phi, beta_n)
	var omega_i := Vector3(sin(theta_i), cos(theta_i), 0.0)
	var omega_o := Vector3(sin(theta_o), cos(theta_o) * cos(phi), cos(theta_o) * sin(phi))
	var cos_half := sqrt(maxf(0.0, 0.5 + 0.5 * clampf(omega_i.dot(omega_o), -1.0, 1.0)))
	var f0 := (1.0 - eta) * (1.0 - eta) / ((1.0 + eta) * (1.0 + eta))
	var p := 1.0 - clampf(cos_half, 0.0, 1.0)
	var a: float = lerp(p * p * p * p * p, 1.0, f0)
	return m * n * a


func _fail(message: String) -> void:
	_failures.append(message)
	push_error(message)


func _finish() -> void:
	if _failures.is_empty():
		print("FAST_MARSCHNER_UNITY_R_REFERENCE_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)
