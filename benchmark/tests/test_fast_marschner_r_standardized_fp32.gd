extends SceneTree

## Regression test for the GPU-specific low-beta failure that the double-
## precision CPU reference cannot expose. The direct standardized-Q Bessel
## expression contains cancellation between O(1/beta^2) terms; this script
## explicitly rounds every material intermediate to IEEE float32 and compares
## it with the stable asymptotic Q limit used by the corrected diagnostic
## shader.

const Reference := preload("res://benchmark/reference/fast_marschner_r_standardized_kernel_reference.gd")
const BETAS := [0.02, 0.01, 0.005, 0.002, 0.001, 0.0005, 0.0002, 0.0001]
const THETA := 0.1
const ASYM_ONLY_MAX := 0.015
const BLEND_MAX := 0.03
const INV_SQRT_TAU := 0.3989422804014327

var _failures: PackedStringArray = []

func _initialize() -> void:
	call_deferred("_run")

func _f32(value: float) -> float:
	var packed := PackedFloat32Array([value])
	return float(packed[0])

func _f32_log_bessel_zero(x_value: float) -> float:
	var x := _f32(x_value)
	var x_sq := _f32(x * x)
	var denominator := _f32(x_sq + _f32(2.32434))
	var rational := _f32(_f32(1.01298) / denominator)
	var coefficient := _f32(_f32(0.564187) + rational)
	var root_arg := _f32(_f32(x_sq * _f32(0.25)) + _f32(1.0))
	var root := _f32(sqrt(_f32(sqrt(root_arg))))
	coefficient = _f32(coefficient * _f32(_f32(1.0) / root))
	var exp_term := _f32(exp(_f32(-2.0 * absf(x))))
	coefficient = _f32(coefficient * _f32(_f32(exp_term * _f32(0.5)) + _f32(0.5)))
	return _f32(_f32(log(maxf(coefficient, 1e-30))) + x)

func _f32_direct_q(theta_o_value: float, theta_cone_value: float, beta_value: float) -> float:
	var theta_o := _f32(theta_o_value)
	var theta_cone := _f32(theta_cone_value)
	var beta := _f32(maxf(beta_value, 1e-8))
	var sin_o := _f32(sin(theta_o))
	var cos_o := _f32(maxf(cos(theta_o), 1e-8))
	var sin_cone := _f32(sin(theta_cone))
	var cos_cone := _f32(maxf(cos(theta_cone), 1e-8))
	var beta_sq := _f32(beta * beta)
	var variance_inverse := _f32(_f32(1.0) / beta_sq)
	var first := _f32(_f32(_f32(sin_cone * sin_o) - _f32(1.0)) * variance_inverse)
	var bessel_arg := _f32(_f32(cos_cone * cos_o) * variance_inverse)
	var log_q := _f32(first + _f32_log_bessel_zero(bessel_arg))
	log_q = _f32(log_q + _f32(log(variance_inverse)))
	log_q = _f32(log_q - _f32(log(cos_o)))
	log_q = _f32(log_q + _f32(log(beta)))
	log_q = _f32(log_q + _f32(_f32(0.5) * _f32(log(cos_cone))))
	log_q = _f32(log_q + _f32(_f32(1.5) * _f32(log(cos_o))))
	return _f32(exp(clampf(log_q, -83.17794814081263, 80.0)))

func _run() -> void:
	var saw_material_instability := false
	for beta in BETAS:
		var fp32_direct := _f32_direct_q(THETA, THETA, beta)
		var direct64 := Reference.direct_q_value(THETA, THETA, beta)
		var asym := Reference.asymptotic_q_value(THETA, THETA, beta)
		var fp32_relative := absf(fp32_direct - asym) / maxf(asym, 1e-30)
		var direct64_relative := absf(direct64 - asym) / maxf(asym, 1e-30)
		var shader_policy := "asymptotic" if beta <= ASYM_ONLY_MAX else ("blend" if beta < BLEND_MAX else "lut_or_high_beta_direct")
		print("EVIDENCE standardized_fp32 beta=%s fp32_direct=%s direct64=%s asym=%s fp32_rel=%s direct64_rel=%s policy=%s" % [beta, fp32_direct, direct64, asym, fp32_relative, direct64_relative, shader_policy])
		if not is_finite(fp32_direct) or fp32_direct < 0.0:
			_fail("fp32 direct Q became non-finite/negative at beta=%s: %s" % [beta, fp32_direct])
		if beta <= ASYM_ONLY_MAX and shader_policy != "asymptotic":
			_fail("beta=%s must be in the asymptotic-only shader region" % beta)
		if beta <= 0.001 and fp32_relative > 0.05:
			saw_material_instability = true

	# The test intentionally proves that a direct fp32 branch would be unsafe;
	# if this ceases to be observed, either the expression changed or the test
	# stopped emulating the GPU path and should be reviewed.
	if not saw_material_instability:
		_fail("fp32 cancellation probe did not expose the expected low-beta instability")
	var peak := Reference.asymptotic_q_value(THETA, THETA, 1e-8)
	if absf(peak - INV_SQRT_TAU) > 1e-12:
		_fail("asymptotic aligned peak is not 1/sqrt(2*pi): %s" % peak)

	if _failures.is_empty():
		print("FAST_MARSCHNER_R_STANDARDIZED_FP32_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)

func _fail(message: String) -> void:
	_failures.append(message)
	push_error(message)
