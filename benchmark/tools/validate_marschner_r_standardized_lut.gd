extends SceneTree

## Validation for the standardized projected R-longitudinal Q LUT.
##
## This validator measures interpolation of Q, not a raw-M unit integral. The
## resource stores Q = beta_r * sqrt(cos(theta_cone) * cos(theta_o)) *
## cos(theta_o) * M_R, so Q-to-M_R*N_R reconstruction is checked separately.

const LUT_PATH := "res://benchmark/resources/luts/fast_marschner_r_standardized_lut_256x256x128.res"
const Data := preload("res://benchmark/resources/fast_marschner_r_standardized_lut_data.gd")
const Reference := preload("res://benchmark/reference/fast_marschner_r_standardized_kernel_reference.gd")
const CONTRACT_ID := "standardized_r_projected_q_v1"
const CHANNELS := "R=linear_Q,G=log2_Q,B=0,A=1"
const ACTIVE_FLOOR := 1e-6
const GATE_P95 := 0.08
const GATE_MAX := 0.25
const GATE_RMS := 0.05

var _failures: PackedStringArray = []


func _initialize() -> void:
	var lut = load(LUT_PATH)
	if lut == null:
		_fail("failed to load standardized LUT: %s" % LUT_PATH)
		_finish()
		return
	_check_metadata(lut)
	_check_data(lut)
	_check_interpolation(lut)
	_check_sampler_edges_and_fallback(lut)
	_check_direct_fallback_cases(lut)
	_check_q_reconstruction(lut)
	print("LUT_CONTRACT raw_m_unit_normalization_gate=false stored_quantity=Q")
	_finish()


func _check_metadata(lut) -> void:
	var errors: PackedStringArray = lut.validation_errors()
	if not errors.is_empty():
		_fail("resource validation errors: %s" % "; ".join(errors))
	if lut.contract != CONTRACT_ID:
		_fail("contract mismatch: %s" % lut.contract)
	if lut.channels != CHANNELS:
		_fail("channel mismatch: %s" % lut.channels)
	if lut.size_x == lut.size_y and lut.size_y == lut.size_z:
		_fail("standardized LUT must be non-cubic")
	if lut.raw_m_unit_normalization_claimed:
		_fail("raw-M unit normalization must not be claimed")
	print("LUT_METADATA size=%dx%dx%d q=[%s,%s] theta_cone=[%s,%s] beta=[%s,%s] contract=%s" % [
		lut.size_x, lut.size_y, lut.size_z, lut.q_min, lut.q_max,
		lut.theta_cone_min, lut.theta_cone_max, lut.beta_min, lut.beta_max, lut.contract])


func _check_data(lut) -> void:
	var finite := true
	var texel_count: int = lut.size_x * lut.size_y * lut.size_z
	for z in lut.size_z:
		for y in lut.size_y:
			for x in lut.size_x:
				var value: Vector4 = lut.texel(x, y, z)
				if not is_finite(value.x) or not is_finite(value.y) or not is_finite(value.z) or not is_finite(value.w) \
						or value.x < 0.0 or value.y < lut.log_value_floor or value.z != 0.0 or value.w != 1.0:
					finite = false
					_fail("out-of-contract texel (%d,%d,%d): %s" % [x, y, z, value])
	print("LUT_DATA texels=%d finite_and_in_contract=%s" % [texel_count, finite])


func _check_interpolation(lut) -> void:
	var linear := _new_metrics()
	var logarithmic := _new_metrics()
	var q_values := _axis_values(lut.q_min, lut.q_max, 37, true)
	var cone_values := _axis_values(lut.theta_cone_min, lut.theta_cone_max, 31, true)
	var beta_values := _log_axis_values(lut.beta_min, lut.beta_max, 17)
	var slice_max := 0.0
	var supported_count := 0
	for beta in beta_values:
		slice_max = 0.0
		for cone in cone_values:
			for q in q_values:
				if not _physical_theta_o(q, cone, beta):
					continue
				if lut.requires_reference_fallback(q, cone, beta):
					continue
				slice_max = maxf(slice_max, lut.reference_q_value(q, cone, beta))
		for cone in cone_values:
			for q in q_values:
				if not _physical_theta_o(q, cone, beta):
					continue
				if lut.requires_reference_fallback(q, cone, beta):
					continue
				var direct: float = lut.reference_q_value(q, cone, beta)
				if direct <= ACTIVE_FLOOR * slice_max:
					continue
				supported_count += 1
				_update_metrics(linear, lut.sample_q(q, cone, beta, Data.DECODE_LINEAR), direct, q, cone, beta)
				_update_metrics(logarithmic, lut.sample_q(q, cone, beta, Data.DECODE_LOG), direct, q, cone, beta)
	var linear_p95 := _p95(linear)
	var log_p95 := _p95(logarithmic)
	_print_metrics("linear", linear, linear_p95)
	_print_metrics("log", logarithmic, log_p95)
	print("LUT_INTERPOLATION samples=%d gates=rms<=%s p95<=%s max<=%s" % [supported_count, GATE_RMS, GATE_P95, GATE_MAX])
	if linear["rms_relative"] > GATE_RMS or logarithmic["rms_relative"] > GATE_RMS:
		_fail("Q interpolation RMS gate exceeded")
	if linear_p95 > GATE_P95 or log_p95 > GATE_P95:
		_fail("Q interpolation p95 gate exceeded")
	if linear["max_relative"] > GATE_MAX or logarithmic["max_relative"] > GATE_MAX:
		_fail("Q interpolation max gate exceeded")


func _check_sampler_edges_and_fallback(lut) -> void:
	var ok := true
	for pair in [[lut.q_min - 1.0, lut.q_min], [lut.q_max + 1.0, lut.q_max]]:
		var outside: float = lut.sample_q(pair[0], 0.0, 1.0, Data.DECODE_LINEAR)
		var edge: float = lut.sample_q(pair[1], 0.0, 1.0, Data.DECODE_LINEAR)
		ok = ok and is_equal_approx(outside, edge)
	var beta_low: float = lut.sample_q(lut.q_min, 0.0, lut.beta_min * 0.5, Data.DECODE_LINEAR)
	var beta_low_edge: float = lut.sample_q(lut.q_min, 0.0, lut.beta_min, Data.DECODE_LINEAR)
	var beta_high: float = lut.sample_q(lut.q_min, 0.0, lut.beta_max * 2.0, Data.DECODE_LINEAR)
	var beta_high_edge: float = lut.sample_q(lut.q_min, 0.0, lut.beta_max, Data.DECODE_LINEAR)
	ok = ok and is_equal_approx(beta_low, beta_low_edge) and is_equal_approx(beta_high, beta_high_edge)
	var cone_out: float = lut.sample_q(0.0, lut.theta_cone_max + 1.0, 1.0, Data.DECODE_LINEAR)
	var cone_edge: float = lut.sample_q(0.0, lut.theta_cone_max, 1.0, Data.DECODE_LINEAR)
	ok = ok and is_equal_approx(cone_out, cone_edge)
	if not ok:
		_fail("clamp/no-wrap sampler edge contract failed")

	var fallback_cases := [
		[0.0, 0.0, lut.beta_min * 0.5],
		[lut.q_max + 1.0, 0.0, 1.0],
		[lut.q_min - 1.0, 0.2, 0.5],
		[0.0, 0.0, lut.beta_max * 1.5],
	]
	var fallback_ok := true
	for case in fallback_cases:
		var q: float = case[0]
		var cone: float = case[1]
		var beta: float = case[2]
		var expected: float = lut.reference_q_value(q, cone, beta)
		var actual: float = lut.sample_q_fallback(q, cone, beta, Data.DECODE_LINEAR, Data.FALLBACK_OUTSIDE)
		fallback_ok = fallback_ok and absf(actual - expected) <= 1e-10 * maxf(absf(expected), 1.0)
		var expected_log := pow(2.0, maxf(log(maxf(expected, 1e-300)) * Data.INV_LN_2, lut.log_value_floor))
		var actual_log: float = lut.sample_q_fallback(q, cone, beta, Data.DECODE_LOG, Data.FALLBACK_OUTSIDE)
		fallback_ok = fallback_ok and absf(actual_log - expected_log) <= 1e-10 * maxf(absf(expected_log), 1.0)
	var none: float = lut.sample_q_fallback(lut.q_max + 1.0, 0.0, 1.0, Data.DECODE_LINEAR, Data.FALLBACK_NONE)
	var clamped: float = lut.sample_q(lut.q_max + 1.0, 0.0, 1.0, Data.DECODE_LINEAR)
	fallback_ok = fallback_ok and is_equal_approx(none, clamped)
	print("LUT_SAMPLER edge_clamp=%s fallback_outside=%s" % [ok, fallback_ok])
	if not fallback_ok:
		_fail("direct/asymptotic fallback contract failed")


## Direct tests for the two fallback classes that must NOT be treated as
## q/beta out-of-support:
##   1. an outer theta_cone texel band (the cone-pole seam: the outer two
##      Y-axis texel bands route to the direct reference),
##   2. a physical grazing footprint (theta_o inside [-PI/2, PI/2] but the
##      trilinear footprint/margin straddles the outgoing-angle boundary).
## Both must report requires_reference_fallback == true, and both decoders of
## sample_q_fallback must return the direct reference Q -- DECODE_LOG decodes
## the floored log2 value back, so it returns linear Q equal to
## reference_q_value within float round-trip error.
func _check_direct_fallback_cases(lut) -> void:
	var cone_half_step: float = 0.5 * (lut.theta_cone_max - lut.theta_cone_min) / float(lut.size_y)
	# Pole band: |theta_cone| > theta_cone_max - 2 * cone_half_step. A value
	# one half-step inside the last texel band keeps theta_o physical
	# (theta_o = theta_cone <= theta_cone_max <= PI/2 with q = 0).
	var pole_case := [0.0, lut.theta_cone_max - cone_half_step, 1.0]
	# Grazing footprint: theta_o = cone + q * beta = 1.45 rad (physical,
	# |theta_o| <= PI/2) but within the 1.25x grazing margin of the boundary,
	# with every trilinear corner still inside [-PI/2, PI/2] (verified: the
	# corner loop does not trigger; only the margin check does).
	var grazing_case := [1.5, -0.05, 1.0]
	var ok := true
	for direct_case in [pole_case, grazing_case]:
		var q: float = direct_case[0]
		var cone: float = direct_case[1]
		var beta: float = direct_case[2]
		if not lut.requires_reference_fallback(q, cone, beta):
			ok = false
			_fail("direct fallback case (q=%s cone=%s beta=%s) must require the reference fallback" % [q, cone, beta])
			continue
		var expected: float = lut.reference_q_value(q, cone, beta)
		if not is_finite(expected) or expected < 0.0:
			ok = false
			_fail("reference Q non-finite/negative for (q=%s cone=%s beta=%s): %s" % [q, cone, beta, expected])
			continue
		var expected_log := pow(2.0, maxf(log(maxf(expected, 1e-300)) * Data.INV_LN_2, lut.log_value_floor))
		var linear: float = lut.sample_q_fallback(q, cone, beta, Data.DECODE_LINEAR, Data.FALLBACK_OUTSIDE)
		var log_decoded: float = lut.sample_q_fallback(q, cone, beta, Data.DECODE_LOG, Data.FALLBACK_OUTSIDE)
		if absf(linear - expected) > 1e-10 * maxf(absf(expected), 1.0):
			ok = false
			_fail("linear fallback mismatch for (q=%s cone=%s beta=%s): got %s want %s" % [q, cone, beta, linear, expected])
		if absf(log_decoded - expected_log) > 1e-10 * maxf(absf(expected_log), 1.0):
			ok = false
			_fail("log fallback mismatch for (q=%s cone=%s beta=%s): got %s want %s" % [q, cone, beta, log_decoded, expected_log])
		if absf(log_decoded - expected) > 1e-9 * maxf(absf(expected), 1.0):
			ok = false
			_fail("log decoder must return linear Q for (q=%s cone=%s beta=%s): got %s want %s" % [q, cone, beta, log_decoded, expected])
	print("LUT_FALLBACK_DIRECT pole_band_cone=%s grazing_q_cone_beta=[%s,%s,%s] requires_reference_fallback=true linear_and_log_match_reference=%s" % [
		pole_case[1], grazing_case[0], grazing_case[1], grazing_case[2], ok])
	if not ok:
		_fail("direct fallback seam tests failed (cone-pole band or grazing footprint)")


func _check_q_reconstruction(lut) -> void:
	var max_relative := 0.0
	var count := 0
	for c_phi in [1.0, 0.5, 0.1]:
		for beta_r in [0.05, 0.2, 1.0, 4.0]:
			for cone in [-0.8, 0.0, 0.8]:
				for q in [-4.0, 0.0, 4.0]:
					if not _physical_theta_o(q, cone, beta_r):
						continue
					if lut.requires_reference_fallback(q, cone, beta_r):
						continue
					var theta_o: float = cone + q * beta_r
					var beta_m: float = beta_r / (sqrt(2.0) * c_phi)
					var direct_q: float = lut.reference_q_value(q, cone, beta_r)
					var sampled_q: float = lut.sample_q(q, cone, beta_r, Data.DECODE_LOG)
					var direct_mn: float = Reference.direct_r_mn_from_q(direct_q, theta_o, cone, beta_m)
					var sampled_mn: float = Reference.direct_r_mn_from_q(sampled_q, theta_o, cone, beta_m)
					var relative := absf(sampled_mn - direct_mn) / maxf(absf(direct_mn), 1e-30)
					max_relative = maxf(max_relative, relative)
					count += 1
	print("LUT_RECONSTRUCTION samples=%d max_relative=%s c_phi_seam=direct_fallback_only" % [count, max_relative])
	if max_relative > GATE_MAX:
		_fail("Q-to-M_R*N_R reconstruction gate exceeded")


func _axis_values(min_value: float, max_value: float, count: int, midpoint: bool) -> Array:
	var values := []
	for index in count:
		var fraction := (float(index) + (0.5 if midpoint else 0.0)) / float(count if midpoint else maxi(count - 1, 1))
		values.append(lerpf(min_value, max_value, fraction))
	return values


func _log_axis_values(min_value: float, max_value: float, count: int) -> Array:
	var values := []
	var log_min := log(min_value)
	var log_max := log(max_value)
	for index in count:
		values.append(exp(lerpf(log_min, log_max, float(index) / float(maxi(count - 1, 1)))))
	return values


func _physical_theta_o(q: float, theta_cone: float, beta_r: float) -> bool:
	return absf(theta_cone + q * beta_r) <= PI * 0.5


func _new_metrics() -> Dictionary:
	return {"count": 0, "sum_abs_sq": 0.0, "sum_relative_sq": 0.0, "max_relative": 0.0, "worst": [], "relative_values": PackedFloat64Array(), "rms_relative": 0.0}


func _update_metrics(metrics: Dictionary, actual: float, expected: float, q: float, cone: float, beta: float) -> void:
	var absolute := absf(actual - expected)
	var relative := absolute / maxf(absf(expected), 1e-30)
	metrics["count"] += 1
	metrics["sum_abs_sq"] += absolute * absolute
	metrics["sum_relative_sq"] += relative * relative
	var values: PackedFloat64Array = metrics["relative_values"]
	values.append(relative)
	metrics["relative_values"] = values
	if relative > metrics["max_relative"]:
		metrics["max_relative"] = relative
		metrics["worst"] = [q, cone, beta, actual, expected]


func _p95(metrics: Dictionary) -> float:
	var values: Array = Array(metrics["relative_values"])
	if values.is_empty():
		return 0.0
	values.sort()
	return values[clampi(int(ceil(0.95 * values.size())) - 1, 0, values.size() - 1)]


func _print_metrics(name: String, metrics: Dictionary, p95: float) -> void:
	var count: int = metrics["count"]
	metrics["rms_relative"] = sqrt(metrics["sum_relative_sq"] / float(maxi(count, 1)))
	var rms_abs := sqrt(metrics["sum_abs_sq"] / float(maxi(count, 1)))
	print("LUT_ERROR decoder=%s samples=%d rms_abs=%s rms_relative=%s p95_relative=%s max_relative=%s worst=%s" % [
		name, count, rms_abs, metrics["rms_relative"], p95, metrics["max_relative"], metrics["worst"]])


func _fail(message: String) -> void:
	_failures.append(message)
	push_error(message)


func _finish() -> void:
	if _failures.is_empty():
		print("FAST_MARSCHNER_R_STANDARDIZED_LUT_VALIDATION_OK")
		quit(0)
		return
	print("FAST_MARSCHNER_R_STANDARDIZED_LUT_VALIDATION_FAILED failures=%d" % _failures.size())
	quit(1)
