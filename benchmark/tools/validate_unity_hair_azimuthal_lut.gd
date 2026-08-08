extends SceneTree

const LUT_PATH := "res://benchmark/resources/luts/unity_azimuthal_64.res"
const DH := 0.1
const SQRT_PI_OVER_8 := 0.6266570686577501
const REL_EPS := 1e-6

func _initialize() -> void:
	if not ResourceLoader.exists(LUT_PATH):
		push_error("missing %s; run generate_unity_hair_azimuthal_lut.gd first" % LUT_PATH)
		quit(1)
		return
	var lut: Resource = load(LUT_PATH)
	var errors: PackedStringArray = lut.validation_errors()
	if not errors.is_empty():
		push_error("LUT invalid: %s" % "; ".join(errors))
		quit(1)
		return
	var report := _validate(lut)
	print(JSON.stringify(report, "\t"))
	if float(report["off_grid"]["p95_relative_error"]) > 0.20:
		push_error("Unity azimuthal LUT p95 interpolation error exceeded 20%%")
		quit(1)
		return
	print("UNITY_HAIR_AZIMUTHAL_LUT_VALIDATION_OK")
	quit(0)

func _validate(lut: Resource) -> Dictionary:
	var relative_errors: Array[float] = []
	var rms_abs := 0.0
	var rms_rel := 0.0
	var component_count := 0
	var worst_rel := 0.0
	var worst := {}
	for zi in 13:
		var beta := 0.02 + (float(zi) + 0.37) / 13.0 * 0.96
		for yi in 17:
			var cos_td := 0.02 + (float(yi) + 0.53) / 17.0 * 0.96
			for xi in 31:
				var phi := -TAU + (float(xi) + 0.41) / 31.0 * (2.0 * TAU)
				var direct := _direct_n(phi, cos_td, beta, float(lut.eta))
				var sampled: Vector3 = lut.sample_n(phi, cos_td, beta)
				for channel in 3:
					var d := direct[channel]
					var s := sampled[channel]
					var abs_error := absf(s - d)
					var rel := abs_error / maxf(absf(d), REL_EPS)
					rms_abs += abs_error * abs_error
					if d > 1e-4:
						relative_errors.append(rel)
						rms_rel += rel * rel
						if rel > worst_rel:
							worst_rel = rel
							worst = {"phi": phi, "cos_theta_d": cos_td, "beta": beta, "channel": channel, "direct": d, "sampled": s}
					component_count += 1
	relative_errors.sort()
	return {
		"schema": "unity_hair_azimuthal_lut_validation_v1",
		"lut": {"path": LUT_PATH, "dimensions": [lut.size_x, lut.size_y, lut.size_z], "format": lut.format, "eta": lut.eta},
		"off_grid": {
			"component_count": component_count,
			"active_relative_count": relative_errors.size(),
			"rms_absolute_error": sqrt(rms_abs / float(maxi(component_count, 1))),
			"rms_relative_error": sqrt(rms_rel / float(maxi(relative_errors.size(), 1))),
			"p95_relative_error": _percentile(relative_errors, 0.95),
			"p99_relative_error": _percentile(relative_errors, 0.99),
			"max_relative_error": worst_rel,
			"worst": worst,
		},
		"gate": {"p95_relative_error_max": 0.20},
	}

func _direct_n(phi: float, cos_theta_d: float, beta: float, eta: float) -> Vector3:
	var sin_theta_d_sq := maxf(0.0, 1.0 - cos_theta_d * cos_theta_d)
	var eta_prime := sqrt(maxf(eta * eta - sin_theta_d_sq, 1e-8)) / maxf(cos_theta_d, 1e-6)
	var s := _logistic_scale_from_beta(beta)
	var result := Vector3.ZERO
	var h := -1.0
	while h <= 1.000001:
		var gamma_o := asin(clampf(h, -1.0, 1.0))
		var gamma_t := asin(clampf(h / maxf(eta_prime, 1e-6), -1.0, 1.0))
		result.x += _azimuthal_scattering(phi, 0, s, gamma_o, gamma_t) * DH
		result.y += _azimuthal_scattering(phi, 1, s, gamma_o, gamma_t) * DH
		result.z += _azimuthal_scattering(phi, 2, s, gamma_o, gamma_t) * DH
		h += DH
	return result * 0.5

func _logistic_scale_from_beta(beta: float) -> float:
	return maxf(SQRT_PI_OVER_8 * ((0.265 * beta) + (1.194 * beta * beta) + (5.372 * pow(absf(beta), 22.0))), 1e-5)

func _logistic(x: float, s: float) -> float:
	x = absf(x)
	var e := exp(-x / s)
	return e / (s * (1.0 + e) * (1.0 + e))

func _cdf(x: float, s: float) -> float:
	return 1.0 / (1.0 + exp(-x / s))

func _azimuthal_scattering(phi: float, p: int, s: float, gamma_o: float, gamma_t: float) -> float:
	var dphi := phi - (2.0 * float(p) * gamma_t - 2.0 * gamma_o + float(p) * PI)
	while dphi > PI:
		dphi -= TAU
	while dphi < -PI:
		dphi += TAU
	return _logistic(dphi, s) / maxf(_cdf(PI, s) - _cdf(-PI, s), 1e-8)

func _percentile(values: Array[float], fraction: float) -> float:
	if values.is_empty():
		return 0.0
	var index := clampi(int(round(fraction * float(values.size() - 1))), 0, values.size() - 1)
	return values[index]
