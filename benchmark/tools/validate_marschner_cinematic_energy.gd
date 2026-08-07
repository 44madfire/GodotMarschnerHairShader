extends SceneTree

## Complete single-scattering parity check for the Cinematic longitudinal LUT.
## Direct and candidate paths share the same baseline non-separable geometry,
## analytic azimuthal distribution and attenuation. Only M differs:
##   direct    = analytic d'Eon-style log-Bessel approximation
##   candidate = physical-domain Q LUT + low-beta asymptotic transition

const LUT_PATH := "res://benchmark/resources/luts/marschner_cinematic_longitudinal_128x128x64.res"
const ETA := 1.55
const THETA_I_DEG := [-60.0, -30.0, 0.0, 30.0, 60.0]
const DEFAULT_GRID := 128
const DEFAULT_PHI_GRID := 96
const REL_EPS := 1e-10

var _grid := DEFAULT_GRID
var _phi_grid := DEFAULT_PHI_GRID
var _beta_m := 0.3
var _beta_n := 0.8
var _cuticle := 0.087
var _lut: Resource

func _initialize() -> void:
	if not _parse_args():
		quit(1)
		return
	if not ResourceLoader.exists(LUT_PATH):
		push_error("missing %s; generate the Cinematic LUT first" % LUT_PATH)
		quit(1)
		return
	_lut = load(LUT_PATH)
	var errors: PackedStringArray = _lut.validation_errors()
	if not errors.is_empty():
		push_error("LUT invalid: %s" % "; ".join(errors))
		quit(1)
		return
	var report := _integrate()
	print(JSON.stringify(report, "\t"))
	var worst_lobe := float(report["summary"]["worst_lobe_relative_error"])
	var worst_angle := float(report["summary"]["worst_per_theta_relative_error"])
	if worst_lobe > 0.05 or worst_angle > 0.05:
		push_error("Cinematic complete-energy gates failed: lobe=%g angle=%g" % [worst_lobe, worst_angle])
		quit(1)
		return
	print("MARSCHNER_CINEMATIC_COMPLETE_ENERGY_OK")
	quit(0)

func _parse_args() -> bool:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--grid="):
			_grid = int(arg.trim_prefix("--grid="))
		elif arg.begins_with("--phi-grid="):
			_phi_grid = int(arg.trim_prefix("--phi-grid="))
		elif arg.begins_with("--beta-m="):
			_beta_m = float(arg.trim_prefix("--beta-m="))
		elif arg.begins_with("--beta-n="):
			_beta_n = float(arg.trim_prefix("--beta-n="))
		elif arg.begins_with("--cuticle="):
			_cuticle = float(arg.trim_prefix("--cuticle="))
		elif arg == "--contract=report":
			pass
		else:
			push_error("unsupported argument: %s" % arg)
			return false
	return _grid >= 8 and _phi_grid >= 8 and _beta_m > 0.0 and _beta_n > 0.0

func _integrate() -> Dictionary:
	var lobe_direct := Vector3.ZERO
	var lobe_candidate := Vector3.ZERO
	var per_theta := []
	var dtheta := PI / float(_grid)
	var dphi := TAU / float(_phi_grid)
	var high_beta_samples := 0
	var low_beta_samples := 0
	var total_lobe_samples := 0

	for theta_i_deg in THETA_I_DEG:
		var theta_i := deg_to_rad(theta_i_deg)
		var sin_i := sin(theta_i)
		var cos_i := cos(theta_i)
		var cos_theta_t := sqrt(maxf(0.0, 1.0 - sin_i * sin_i / (ETA * ETA)))
		var theta_direct := Vector3.ZERO
		var theta_candidate := Vector3.ZERO
		for oi in _grid:
			var theta_o := -0.5 * PI + (float(oi) + 0.5) * dtheta
			var sin_o := sin(theta_o)
			var cos_o := cos(theta_o)
			var domega := cos_o * dtheta * dphi
			for pi_index in _phi_grid:
				var phi := -PI + (float(pi_index) + 0.5) * dphi
				var cos_phi := clampf(cos(phi), -0.9999, 0.9999)
				var sin_phi := clampf(sin(phi), -0.9999, 0.9999)
				var cphi := maxf(1e-6, sqrt(0.5 + 0.5 * cos_phi))
				var sphi := sqrt(maxf(0.0, 0.5 - 0.5 * cos_phi)) * signf(sin_phi)
				var cos_theta := clampf(cos_o * cos_i + sin_o * sin_i, -1.0, 1.0)
				var cos_d := sqrt(maxf(0.0, 0.5 + 0.5 * cos_theta))
				var sin_d := sqrt(maxf(0.0, 0.5 - 0.5 * cos_theta)) * signf(sin_o * cos_i - cos_o * sin_i)
				var eta_prime := sqrt(maxf(ETA * ETA - sin_d * sin_d, 1e-8)) / maxf(cos_d, 1e-6)
				var eta_inv := 1.0 / maxf(eta_prime, 1e-6)
				var h := _cross_section(cphi, sphi, eta_inv)
				var geometry := _longitudinal_geometry(sin_i, cos_d, sin_d, cphi, -_cuticle, _beta_m, h)
				var sin_cone: Vector3 = geometry["sin_cone"]
				var beta_eff: Vector3 = geometry["beta_eff"]
				var direct_m := Vector3(
					_direct_m(sin_cone.x, sin_o, beta_eff.x),
					_direct_m(sin_cone.y, sin_o, beta_eff.y),
					_direct_m(sin_cone.z, sin_o, beta_eff.z))
				var candidate_m := Vector3(
					_candidate_m(sin_cone.x, sin_o, beta_eff.x),
					_candidate_m(sin_cone.y, sin_o, beta_eff.y),
					_candidate_m(sin_cone.z, sin_o, beta_eff.z))
				for p in 3:
					if beta_eff[p] > float(_lut.beta_max):
						high_beta_samples += 1
					if beta_eff[p] < 0.03:
						low_beta_samples += 1
					total_lobe_samples += 1
				var weight := _azimuthal_weight(cos_theta_t, cos_d, cos_phi, sin_phi, cphi, eta_inv, h)
				var direct_lobes := direct_m * weight * domega
				var candidate_lobes := candidate_m * weight * domega
				lobe_direct += direct_lobes
				lobe_candidate += candidate_lobes
				theta_direct += direct_lobes
				theta_candidate += candidate_lobes
		var direct_total := theta_direct.x + theta_direct.y + theta_direct.z
		var candidate_total := theta_candidate.x + theta_candidate.y + theta_candidate.z
		per_theta.append({
			"theta_i_deg": theta_i_deg,
			"direct_total": direct_total,
			"candidate_total": candidate_total,
			"ratio": candidate_total / maxf(direct_total, REL_EPS),
			"relative_error": absf(candidate_total - direct_total) / maxf(absf(direct_total), REL_EPS),
		})

	var lobe_report := []
	var worst_lobe := 0.0
	var names := ["R", "TT", "TRT"]
	for p in 3:
		var direct_value := lobe_direct[p]
		var candidate_value := lobe_candidate[p]
		var rel := absf(candidate_value - direct_value) / maxf(absf(direct_value), REL_EPS)
		worst_lobe = maxf(worst_lobe, rel)
		lobe_report.append({
			"name": names[p],
			"direct": direct_value,
			"candidate": candidate_value,
			"ratio": candidate_value / maxf(direct_value, REL_EPS),
			"relative_error": rel,
		})
	var worst_angle := 0.0
	for row in per_theta:
		worst_angle = maxf(worst_angle, float(row["relative_error"]))
	return {
		"schema": "marschner_cinematic_complete_energy_v1",
		"configuration": {
			"grid": _grid,
			"phi_grid": _phi_grid,
			"theta_i_deg": THETA_I_DEG,
			"beta_m_effective": _beta_m,
			"beta_n_effective": _beta_n,
			"cuticle": _cuticle,
			"eta": ETA,
			"lut_dimensions": [_lut.size_x, _lut.size_y, _lut.size_z],
			"lut_beta_range": [_lut.beta_min, _lut.beta_max],
		},
		"lobes": lobe_report,
		"per_theta_i": per_theta,
		"branch_statistics": {
			"total_lobe_samples": total_lobe_samples,
			"low_beta_sample_share": float(low_beta_samples) / float(maxi(total_lobe_samples, 1)),
			"beta_above_lut_sample_share": float(high_beta_samples) / float(maxi(total_lobe_samples, 1)),
		},
		"summary": {
			"worst_lobe_relative_error": worst_lobe,
			"worst_per_theta_relative_error": worst_angle,
		},
		"gates": {
			"worst_lobe_relative_error_max": 0.05,
			"worst_per_theta_relative_error_max": 0.05,
		},
	}

func _cross_section(cphi: float, sphi: float, eta_inv: float) -> Vector3:
	var h_r := -sphi
	var h_tt := signf(sphi) * cphi / sqrt(maxf(1.0 + eta_inv * (1.0 - 2.0 * eta_inv * absf(sphi)), 1e-6))
	return Vector3(clampf(h_r, -1.0, 1.0), clampf(h_tt, -1.0, 1.0), 0.91)

func _longitudinal_geometry(sin_i: float, cos_d: float, sin_d: float, cphi: float, alpha_internal: float, beta_m: float, h: Vector3) -> Dictionary:
	var k_sq := Vector3.ONE * (sin_d * sin_d) + Vector3.ONE * (cos_d * cos_d) * h * h
	k_sq = Vector3(clampf(k_sq.x, 0.0, 0.999999), clampf(k_sq.y, 0.0, 0.999999), clampf(k_sq.z, 0.0, 0.999999))
	var z := Vector3(sqrt(1.0 - k_sq.x), sqrt(1.0 - k_sq.y), sqrt(1.0 - k_sq.z))
	var z_prime_base := Vector3(
		sqrt(maxf(ETA * ETA - k_sq.x, 1e-6)),
		sqrt(maxf(ETA * ETA - k_sq.y, 1e-6)),
		sqrt(maxf(ETA * ETA - k_sq.z, 1e-6)))
	var z_prime := z_prime_base * Vector3(0.0, 1.0, 2.0)
	var beta_eff := Vector3.ONE * beta_m
	beta_eff.x *= sqrt(2.0) * cphi
	beta_eff.y *= (z.y + 0.5 * z_prime.y) / maxf(cos_d, 1e-5)
	beta_eff.z *= 2.0 * sqrt(maxf(ETA * ETA - sin_d * sin_d, 1e-6)) / maxf(cos_d, 1e-5) - 1.0
	beta_eff = Vector3(maxf(beta_eff.x, 1e-8), maxf(beta_eff.y, 1e-8), maxf(beta_eff.z, 1e-8))
	var sin_cone := -Vector3.ONE * sin_i + (2.0 * z_prime - 2.0 * z) * alpha_internal
	sin_cone = Vector3(clampf(sin_cone.x, -1.0, 1.0), clampf(sin_cone.y, -1.0, 1.0), clampf(sin_cone.z, -1.0, 1.0))
	return {"sin_cone": sin_cone, "beta_eff": beta_eff}

func _candidate_m(sin_cone: float, sin_o: float, beta: float) -> float:
	var q_asym := _asym_q(sin_cone, sin_o, beta)
	if beta <= 0.015:
		return _m_from_q(q_asym, sin_cone, sin_o, beta)
	var q_lut := float(_lut.sample_q(sin_cone, sin_o, beta))
	var q := q_lut
	if beta < 0.03:
		q = lerpf(q_asym, q_lut, smoothstep(0.015, 0.03, beta))
	var sc := float(_lut.regularized_sin_cone(sin_cone))
	var so := float(_lut.regularized_sin_o(sin_o))
	return _m_from_q(q, sc, so, clampf(beta, float(_lut.beta_min), float(_lut.beta_max)))

func _m_from_q(q: float, sin_cone: float, sin_o: float, beta: float) -> float:
	var cc := sqrt(maxf(1.0 - sin_cone * sin_cone, 1e-10))
	var co := sqrt(maxf(1.0 - sin_o * sin_o, 1e-10))
	return maxf(q, 0.0) / maxf(beta * sqrt(cc * co) * co, 1e-10)

func _asym_q(sin_cone: float, sin_o: float, beta: float) -> float:
	var tc := asin(clampf(sin_cone, -0.999999, 0.999999))
	var to := asin(clampf(sin_o, -0.999999, 0.999999))
	var b := maxf(beta, 1e-8)
	return exp((cos(to - tc) - 1.0) / (b * b)) / sqrt(TAU)

func _direct_m(sin_cone: float, sin_o: float, beta: float) -> float:
	var cc := sqrt(maxf(1.0 - sin_cone * sin_cone, 1e-16))
	var co := sqrt(maxf(1.0 - sin_o * sin_o, 1e-16))
	var inv_v := 1.0 / maxf(beta * beta, 1e-16)
	var log_m := (sin_cone * sin_o - 1.0) * inv_v + _log_bessel_zero(cc * co * inv_v) + log(inv_v) - log(co)
	return exp(clampf(log_m, -700.0, 80.0))

func _log_bessel_zero(x: float) -> float:
	var x_sq := x * x
	var value := (0.564187 + 1.01298 / (x_sq + 2.32434)) / sqrt(sqrt(x_sq * 0.25 + 1.0))
	value *= exp(-2.0 * absf(x)) * 0.5 + 0.5
	return log(maxf(value, 1e-300)) + x

func _azimuthal_weight(cos_theta_t: float, cos_d: float, cos_phi: float, sin_phi: float, cphi: float, eta_inv: float, h: Vector3) -> Vector3:
	var result := Vector3.ZERO
	result.x = 0.25 * cphi * _fresnel(cos_d * cphi)
	var n_tt := _logistic(_angular_offset(1, cos_phi, sin_phi, eta_inv, h.y), sqrt(2.0) / maxf(_beta_n, 1e-6))
	var n_trt := _logistic(_angular_offset(2, cos_phi, sin_phi, eta_inv, h.z), 0.5 * sqrt(2.0) / maxf(_beta_n, 1e-6))
	result.y = n_tt * _attenuation(1, cos_theta_t, cos_d, eta_inv, h.y)
	result.z = n_trt * _attenuation(2, cos_theta_t, cos_d, eta_inv, h.z)
	return result

func _fresnel(cos_theta: float) -> float:
	var f0 := (1.0 - ETA) * (1.0 - ETA) / ((1.0 + ETA) * (1.0 + ETA))
	var p := 1.0 - clampf(cos_theta, 0.0, 1.0)
	return lerpf(p * p * p * p * p, 1.0, f0)

func _attenuation(mode: int, cos_theta_t: float, cos_d: float, eta_inv: float, h: float) -> float:
	var f := _fresnel(cos_d * sqrt(maxf(0.0, 1.0 - h * h)))
	var sigma := 0.2
	var tr := exp(-sigma / maxf(cos_theta_t, 1e-4) * 4.0 * (1.0 - eta_inv * eta_inv * h * h) * float(mode))
	return (1.0 - f) * (1.0 - f) * pow(f, float(mode - 1)) * tr

func _angular_offset(mode: int, cos_phi: float, sin_phi: float, eta_inv: float, h: float) -> float:
	var gamma := (2.126 * h * eta_inv + PI) * float(mode)
	var a := 1.0 - 2.0 * h * h
	var b := 2.0 * h * sqrt(maxf(0.0, 1.0 - h * h))
	return cos_phi * (cos(gamma) * a + sin(gamma) * b) + sin_phi * (sin(gamma) * a - cos(gamma) * b)

func _logistic(cos_value: float, s_inv: float) -> float:
	var c := clampf(cos_value, -1.0, 1.0)
	var phi := sqrt(maxf(0.0, 1.0 - c)) * (1.5707288 + c * (-0.2121144 + c * 0.0742610))
	var e := exp(-phi * s_inv)
	var b := exp(-2.0 * sqrt(TAU) * s_inv)
	return minf(1.0, s_inv * e * (1.0 + b) / maxf((1.0 - b) * (1.0 + e) * (1.0 + e), 1e-8))
