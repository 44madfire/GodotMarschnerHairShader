extends SceneTree

const LUT_PATH := "res://benchmark/resources/luts/marschner_cinematic_longitudinal_128x128x64.res"
const INV_LN_2 := 1.4426950408889634
const REL_EPS := 1e-8

func _initialize() -> void:
	if not ResourceLoader.exists(LUT_PATH):
		push_error("missing %s; run generate_marschner_cinematic_longitudinal_lut.gd first" % LUT_PATH)
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
	var p95 := float(report["off_grid"]["p95_relative_error"])
	var max_integral := float(report["integral"]["max_relative_error"])
	if p95 > 0.10 or max_integral > 0.05:
		push_error("cinematic LUT validation gates failed: p95=%g integral=%g" % [p95, max_integral])
		quit(1)
		return
	print("MARSCHNER_CINEMATIC_LONGITUDINAL_LUT_VALIDATION_OK")
	quit(0)

func _validate(lut: Resource) -> Dictionary:
	var relative_errors: Array[float] = []
	var abs_sq := 0.0
	var rel_sq := 0.0
	var sample_count := 0
	var max_rel := 0.0
	var worst := {}
	var betas := _logspace(float(lut.beta_min), float(lut.beta_max), 23)
	for bi in betas.size():
		var beta: float = betas[bi]
		for ci in 37:
			var sin_cone := -0.97 + (float(ci) + 0.37) / 37.0 * 1.94
			for oi in 41:
				var sin_o := -0.97 + (float(oi) + 0.61) / 41.0 * 1.94
				var direct_q := _direct_q(sin_cone, sin_o, beta)
				var sampled_q := float(lut.sample_q(sin_cone, sin_o, beta))
				var abs_error := absf(sampled_q - direct_q)
				var rel := abs_error / maxf(absf(direct_q), REL_EPS)
				# Very deep tails have negligible energy and produce meaningless huge relative ratios.
				if direct_q > 1e-6:
					relative_errors.append(rel)
					rel_sq += rel * rel
					if rel > max_rel:
						max_rel = rel
						worst = {"sin_cone": sin_cone, "sin_o": sin_o, "beta": beta, "direct_q": direct_q, "sampled_q": sampled_q}
				abs_sq += abs_error * abs_error
				sample_count += 1
	relative_errors.sort()
	var p95 := _percentile(relative_errors, 0.95)
	var p99 := _percentile(relative_errors, 0.99)

	var integral_cases := []
	var max_integral_rel := 0.0
	for beta in [0.03, 0.05, 0.1, 0.3, 1.0, 4.0, 12.0]:
		for sin_cone in [-0.9, -0.5, 0.0, 0.5, 0.9]:
			var direct_integral := 0.0
			var lut_integral := 0.0
			var steps := 2048
			var ds := 2.0 / float(steps)
			for i in steps:
				var sin_o := -1.0 + (float(i) + 0.5) * ds
				direct_integral += _direct_m(sin_cone, sin_o, beta) * ds
				lut_integral += _lut_m(lut, sin_cone, sin_o, beta) * ds
			var rel := absf(lut_integral - direct_integral) / maxf(absf(direct_integral), REL_EPS)
			max_integral_rel = maxf(max_integral_rel, rel)
			integral_cases.append({"sin_cone": sin_cone, "beta": beta, "direct": direct_integral, "lut": lut_integral, "relative_error": rel})

	return {
		"schema": "marschner_cinematic_longitudinal_lut_validation_v1",
		"lut": {"path": LUT_PATH, "dimensions": [lut.size_x, lut.size_y, lut.size_z], "beta_range": [lut.beta_min, lut.beta_max], "format": lut.format},
		"off_grid": {
			"sample_count": sample_count,
			"active_relative_count": relative_errors.size(),
			"rms_absolute_error": sqrt(abs_sq / float(maxi(sample_count, 1))),
			"rms_relative_error": sqrt(rel_sq / float(maxi(relative_errors.size(), 1))),
			"p95_relative_error": p95,
			"p99_relative_error": p99,
			"max_relative_error": max_rel,
			"worst": worst,
		},
		"integral": {"max_relative_error": max_integral_rel, "cases": integral_cases},
		"gates": {"p95_relative_error_max": 0.10, "integral_relative_error_max": 0.05},
	}

func _lut_m(lut: Resource, sin_cone: float, sin_o: float, beta: float) -> float:
	var q := float(lut.sample_q(sin_cone, sin_o, beta))
	var sc := float(lut.regularized_sin_cone(sin_cone))
	var so := float(lut.regularized_sin_o(sin_o))
	var cc := sqrt(maxf(1.0 - sc * sc, 1e-10))
	var co := sqrt(maxf(1.0 - so * so, 1e-10))
	var b := clampf(beta, float(lut.beta_min), float(lut.beta_max))
	return q / maxf(b * sqrt(cc * co) * co, 1e-10)

func _direct_q(sin_cone: float, sin_o: float, beta: float) -> float:
	var cc := sqrt(maxf(1.0 - sin_cone * sin_cone, 1e-16))
	var co := sqrt(maxf(1.0 - sin_o * sin_o, 1e-16))
	var m := _direct_m(sin_cone, sin_o, beta)
	return beta * sqrt(cc * co) * co * m

func _direct_m(sin_cone: float, sin_o: float, beta: float) -> float:
	var cc := sqrt(maxf(1.0 - sin_cone * sin_cone, 1e-16))
	var co := sqrt(maxf(1.0 - sin_o * sin_o, 1e-16))
	var v_inv := 1.0 / maxf(beta * beta, 1e-16)
	var log_m := (sin_cone * sin_o - 1.0) * v_inv + _log_bessel_zero(cc * co * v_inv) + log(v_inv) - log(co)
	return exp(clampf(log_m, -700.0, 80.0))

func _log_bessel_zero(x: float) -> float:
	var x_sq := x * x
	var value := (0.564187 + 1.01298 / (x_sq + 2.32434))
	value *= 1.0 / sqrt(sqrt(x_sq * 0.25 + 1.0))
	value *= exp(-2.0 * absf(x)) * 0.5 + 0.5
	return log(maxf(value, 1e-300)) + x

func _logspace(low: float, high: float, count: int) -> Array[float]:
	var result: Array[float] = []
	var a := log(low) * INV_LN_2
	var b := log(high) * INV_LN_2
	for i in count:
		result.append(pow(2.0, lerpf(a, b, float(i) / float(maxi(count - 1, 1)))))
	return result

func _percentile(values: Array[float], fraction: float) -> float:
	if values.is_empty():
		return 0.0
	var index := clampi(int(round(fraction * float(values.size() - 1))), 0, values.size() - 1)
	return values[index]
