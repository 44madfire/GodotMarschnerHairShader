extends SceneTree

## Validates the Unity Fast azimuthal resource against the contract Unity
## actually runs. Correctness is texel-center parity with HDRP's
## ComputeAzimuthalScattering generator, including RGBA16F quantization.
##
## Off-grid comparison to the continuous direct h integral is retained only as
## approximation-quality characterization. A 64^3 linearly filtered LUT cannot
## reproduce very narrow low-beta lobes pointwise; that discretization is part
## of Unity Standard itself and must not be used as a port-correctness gate.

const LUT_PATH: String = "res://benchmark/resources/luts/unity_azimuthal_64.res"
const DH: float = 0.1
const SQRT_PI_OVER_8: float = 0.6266570686577501
const REL_EPS: float = 1e-6
const ACTIVE_DIRECT_MIN: float = 1e-4
const TEXEL_P99_RELATIVE_GATE: float = 0.001
const TEXEL_MAX_ABSOLUTE_GATE: float = 0.01

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
	var report: Dictionary = _validate(lut)
	print(JSON.stringify(report, "\t"))
	var texel_p99: float = float(report["texel_center_parity"]["p99_relative_error"])
	var texel_max_abs: float = float(report["texel_center_parity"]["max_absolute_error"])
	if texel_p99 > TEXEL_P99_RELATIVE_GATE or texel_max_abs > TEXEL_MAX_ABSOLUTE_GATE:
		push_error("Unity azimuthal LUT generator parity failed: texel p99=%g (max %g), max_abs=%g (max %g)" % [texel_p99, TEXEL_P99_RELATIVE_GATE, texel_max_abs, TEXEL_MAX_ABSOLUTE_GATE])
		quit(1)
		return
	print("UNITY_HAIR_AZIMUTHAL_LUT_VALIDATION_OK")
	quit(0)

func _validate(lut: Resource) -> Dictionary:
	var texel_relative_errors: Array[float] = []
	var texel_rms_abs: float = 0.0
	var texel_component_count: int = 0
	var texel_max_abs: float = 0.0
	var texel_worst: Dictionary = {}

	# Representative exact texel centers. These verify the serialized RGBA16F
	# resource against the literal Unity compute-generator equations.
	for zi in 13:
		var z_index: int = clampi(int(floor((float(zi) + 0.5) / 13.0 * float(lut.size_z))), 0, int(lut.size_z) - 1)
		var beta_center: float = (float(z_index) + 0.5) / float(lut.size_z)
		for yi in 17:
			var y_index: int = clampi(int(floor((float(yi) + 0.5) / 17.0 * float(lut.size_y))), 0, int(lut.size_y) - 1)
			var cos_center: float = (float(y_index) + 0.5) / float(lut.size_y)
			for xi in 31:
				var x_index: int = clampi(int(floor((float(xi) + 0.5) / 31.0 * float(lut.size_x))), 0, int(lut.size_x) - 1)
				var phi_center: float = -TAU + (float(x_index) + 0.5) / float(lut.size_x) * (2.0 * TAU)
				var direct_center: Vector3 = _direct_n(phi_center, cos_center, beta_center)
				var sampled_center: Vector3 = lut.sample_n(phi_center, cos_center, beta_center)
				for channel in 3:
					var d_center: float = direct_center[channel]
					var s_center: float = sampled_center[channel]
					var abs_center: float = absf(s_center - d_center)
					var rel_center: float = abs_center / maxf(absf(d_center), REL_EPS)
					texel_rms_abs += abs_center * abs_center
					texel_component_count += 1
					if d_center > ACTIVE_DIRECT_MIN:
						texel_relative_errors.append(rel_center)
					if abs_center > texel_max_abs:
						texel_max_abs = abs_center
						texel_worst = {"x": x_index, "y": y_index, "z": z_index, "phi": phi_center, "cos_theta_d": cos_center, "beta": beta_center, "channel": channel, "direct": d_center, "sampled": s_center}

	texel_relative_errors.sort()

	var off_grid_relative_errors: Array[float] = []
	var interior_relative_errors: Array[float] = []
	var off_grid_rms_abs: float = 0.0
	var off_grid_rms_rel: float = 0.0
	var off_grid_component_count: int = 0
	var off_grid_worst_rel: float = 0.0
	var off_grid_worst: Dictionary = {}
	for zi in 13:
		var beta: float = 0.02 + (float(zi) + 0.37) / 13.0 * 0.96
		for yi in 17:
			var cos_td: float = 0.02 + (float(yi) + 0.53) / 17.0 * 0.96
			for xi in 31:
				var phi: float = -TAU + (float(xi) + 0.41) / 31.0 * (2.0 * TAU)
				var direct: Vector3 = _direct_n(phi, cos_td, beta)
				var sampled: Vector3 = lut.sample_n(phi, cos_td, beta)
				for channel in 3:
					var d: float = direct[channel]
					var s: float = sampled[channel]
					var abs_error: float = absf(s - d)
					var rel: float = abs_error / maxf(absf(d), REL_EPS)
					off_grid_rms_abs += abs_error * abs_error
					off_grid_component_count += 1
					if d > ACTIVE_DIRECT_MIN:
						off_grid_relative_errors.append(rel)
						off_grid_rms_rel += rel * rel
						if beta >= 0.2:
							interior_relative_errors.append(rel)
						if rel > off_grid_worst_rel:
							off_grid_worst_rel = rel
							off_grid_worst = {"phi": phi, "cos_theta_d": cos_td, "beta": beta, "channel": channel, "direct": d, "sampled": s}

	off_grid_relative_errors.sort()
	interior_relative_errors.sort()
	return {
		"schema": "unity_hair_azimuthal_lut_validation_v1",
		"lut": {"path": LUT_PATH, "dimensions": [lut.size_x, lut.size_y, lut.size_z], "format": lut.format, "eta": lut.eta},
		"source_contract": {
			"generator": "Unity HDRP ComputeAzimuthalScattering",
			"modified_refraction": "1.19/cosThetaD + 0.36*cosThetaD (eta=1.55 fit)",
			"inverse_trig": "Unity FastASin",
			"h_domain": "[-1,1)",
			"dh": DH,
		},
		"texel_center_parity": {
			"component_count": texel_component_count,
			"active_relative_count": texel_relative_errors.size(),
			"rms_absolute_error": sqrt(texel_rms_abs / float(maxi(texel_component_count, 1))),
			"p95_relative_error": _percentile(texel_relative_errors, 0.95),
			"p99_relative_error": _percentile(texel_relative_errors, 0.99),
			"max_absolute_error": texel_max_abs,
			"worst_absolute": texel_worst,
		},
		"off_grid": {
			"status": "characterization_only",
			"note": "Compares Unity's 64^3 linearly filtered approximation to the continuous direct h integral. Large low-beta pointwise relative error is expected and is not a Godot-port correctness failure.",
			"component_count": off_grid_component_count,
			"active_relative_count": off_grid_relative_errors.size(),
			"rms_absolute_error": sqrt(off_grid_rms_abs / float(maxi(off_grid_component_count, 1))),
			"rms_relative_error": sqrt(off_grid_rms_rel / float(maxi(off_grid_relative_errors.size(), 1))),
			"p95_relative_error": _percentile(off_grid_relative_errors, 0.95),
			"p99_relative_error": _percentile(off_grid_relative_errors, 0.99),
			"max_relative_error": off_grid_worst_rel,
			"worst": off_grid_worst,
		},
		"off_grid_beta_ge_0_2": {
			"status": "characterization_only",
			"active_relative_count": interior_relative_errors.size(),
			"p95_relative_error": _percentile(interior_relative_errors, 0.95),
			"p99_relative_error": _percentile(interior_relative_errors, 0.99),
		},
		"gate": {
			"oracle": "texel_center_parity_with_unity_compute_generator",
			"p99_relative_error_max": TEXEL_P99_RELATIVE_GATE,
			"max_absolute_error_max": TEXEL_MAX_ABSOLUTE_GATE,
		},
	}

func _direct_n(phi: float, cos_theta_d: float, beta: float) -> Vector3:
	var eta_prime: float = _modified_refraction_index(cos_theta_d)
	var s: float = _logistic_scale_from_beta(beta)
	var result: Vector3 = Vector3.ZERO
	var h: float = -1.0
	while h < 1.0:
		var gamma_o: float = _fast_asin(clampf(h, -1.0, 1.0))
		var gamma_t: float = clampf(_fast_asin(h / maxf(eta_prime, 1e-6)), -1.0, 1.0)
		result.x += _azimuthal_scattering(phi, 0, s, gamma_o, gamma_t) * DH
		result.y += _azimuthal_scattering(phi, 1, s, gamma_o, gamma_t) * DH
		result.z += _azimuthal_scattering(phi, 2, s, gamma_o, gamma_t) * DH
		h += DH
	return result * 0.5

func _modified_refraction_index(cos_theta_d: float) -> float:
	var c: float = maxf(cos_theta_d, 1e-6)
	return 1.19 / c + 0.36 * c

func _fast_acos_pos(x_value: float) -> float:
	var x: float = absf(x_value)
	var result: float = (0.0468878 * x - 0.203471) * x + 1.570796
	return result * sqrt(maxf(0.0, 1.0 - x))

func _fast_acos(x: float) -> float:
	var result: float = _fast_acos_pos(x)
	return result if x >= 0.0 else PI - result

func _fast_asin(x: float) -> float:
	return 0.5 * PI - _fast_acos(clampf(x, -1.0, 1.0))

func _logistic_scale_from_beta(beta: float) -> float:
	return SQRT_PI_OVER_8 * ((0.265 * beta) + (1.194 * beta * beta) + (5.372 * pow(absf(beta), 22.0)))

func _logistic(x_value: float, s: float) -> float:
	var x: float = absf(x_value)
	var e: float = exp(-x / s)
	return e / (s * (1.0 + e) * (1.0 + e))

func _cdf(x: float, s: float) -> float:
	return 1.0 / (1.0 + exp(-x / s))

func _azimuthal_scattering(phi: float, p: int, s: float, gamma_o: float, gamma_t: float) -> float:
	var dphi: float = phi - (2.0 * float(p) * gamma_t - 2.0 * gamma_o + float(p) * PI)
	while dphi > PI:
		dphi -= TAU
	while dphi < -PI:
		dphi += TAU
	return _logistic(dphi, s) / maxf(_cdf(PI, s) - _cdf(-PI, s), 1e-8)

func _percentile(values: Array[float], fraction: float) -> float:
	if values.is_empty():
		return 0.0
	var index: int = clampi(int(round(fraction * float(values.size() - 1))), 0, values.size() - 1)
	return values[index]
