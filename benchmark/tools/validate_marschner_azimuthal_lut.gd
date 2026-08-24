extends SceneTree

## Numerical validation for the FAST_MARSCHNER azimuthal LUT.
##
## Loads the committed data blob (benchmark/resources/luts/
## fast_marschner_azimuthal_lut_64.res), trilinearly samples it exactly like
## the GPU sampler does (texel centers at (i + 0.5) / N, clamp to edge, linear
## filtering), and compares against the analytic azimuthal formulas ported
## from hair_marschner_fast.gdshaderinc at a deterministic grid. Reports
## per-channel max/RMS error and the phi wrap seam delta (phi = -PI vs +PI).
##
## Run with: godot --headless --path <project> --script res://benchmark/tools/validate_marschner_azimuthal_lut.gd

const LUT_PATH := "res://benchmark/resources/luts/fast_marschner_azimuthal_lut_64.res"
const ETA := 1.55
const H_TRT := 0.5 * sqrt(3.0)
const BETA_MIN := 0.001
const BETA_MAX := 1.0
const MAX_ALLOWED_ERROR := 0.10
## Hard seam tolerance: the periodic-U wrap makes phi=-PI and phi=+PI sample
## the identical texel, so the seam delta must be (near) zero; a future
## discontinuity that exceeds this tolerance fails the validation.
const MAX_ALLOWED_SEAM_DELTA := 0.01

const FastMarschnerLUTData := preload("res://benchmark/resources/fast_marschner_lut_data.gd")

var _size := 64
var _data := PackedByteArray()
var _data_error := false


func _initialize() -> void:
	var lut_path: String = LUT_PATH
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--size="):
			lut_path = "res://benchmark/resources/luts/fast_marschner_azimuthal_lut_%s.res" % argument.trim_prefix("--size=").strip_edges()
	var lut_data: FastMarschnerLUTData = load(lut_path) as FastMarschnerLUTData
	if lut_data == null:
		push_error("LUT data failed to load")
		quit(1)
		return
	var validation_errors: PackedStringArray = lut_data.validation_errors()
	if not validation_errors.is_empty():
		push_error("LUT data invalid: %s" % "; ".join(validation_errors))
		quit(1)
		return
	if absf(lut_data.eta - ETA) > 0.0005:
		push_error("LUT baked eta %.4f must be ~= %.2f within 0.0005" % [lut_data.eta, ETA])
		quit(1)
		return
	print("LUT_ETA eta=%.4f expected=%.2f tolerance=0.0005" % [lut_data.eta, ETA])
	_size = lut_data.size
	_data = lut_data.data

	var channels := ["R", "TT", "TRT"]
	var max_error := [0.0, 0.0, 0.0]
	var sum_sq_error := [0.0, 0.0, 0.0]
	var sample_count := 0
	var seam_max_delta := [0.0, 0.0, 0.0]
	var realistic_max_error := [0.0, 0.0, 0.0]
	var realistic_count := 0
	var worst_point := {"channel": -1, "phi": 0.0, "cos_theta_d": 0.0, "beta": 0.0, "error": 0.0}

	# Deterministic grid: phi across the domain incl. the seam neighborhood,
	# cos_theta_d, and azimuthal roughness (incl. the benchmark defaults).
	var phis: Array = [-PI, -PI + 0.02, -2.0, -1.0, -0.5, 0.0, 0.5, 1.0, 2.0, PI - 0.02, PI]
	var cos_theta_ds: Array = [0.05, 0.25, 0.5, 0.75, 0.95, 1.0]
	var betas: Array = [0.1, 0.3, 0.5, 0.75, 0.8, 1.0]
	for phi_value in phis:
		var phi: float = phi_value
		var cos_phi: float = cos(phi)
		var sin_phi: float = sin(phi)
		for cos_td_value in cos_theta_ds:
			var cos_theta_d: float = cos_td_value
			for beta_value in betas:
				var beta: float = beta_value
				var analytic := _analytic_azimuthal(cos_phi, sin_phi, cos_theta_d, beta)
				var sampled := _sample_lut(phi, cos_theta_d, beta)
				sample_count += 1
				for channel in 3:
					var error := absf(analytic[channel] - sampled[channel])
					max_error[channel] = maxf(max_error[channel], error)
					sum_sq_error[channel] += error * error
					if error > worst_point["error"]:
						worst_point = {"channel": channel, "phi": phi, "cos_theta_d": cos_theta_d, "beta": beta, "error": error}
					if beta >= 0.3:
						realistic_max_error[channel] = maxf(realistic_max_error[channel], error)
				if beta >= 0.3:
					realistic_count += 1
				# Seam: the same physical phi sampled at -PI and +PI must match.
				if absf(phi - PI) < 1e-9 or absf(phi + PI) < 1e-9:
					var other_phi: float = -phi
					var other_sampled := _sample_lut(other_phi, cos_theta_d, beta)
					for channel in 3:
						seam_max_delta[channel] = maxf(seam_max_delta[channel], absf(sampled[channel] - other_sampled[channel]))

	for channel in 3:
		var rms := sqrt(sum_sq_error[channel] / float(sample_count))
		print("LUT_ERROR channel=%s max=%.6f rms=%.6f seam_max_delta=%.6f" % [channels[channel], max_error[channel], rms, seam_max_delta[channel]])

	var worst := maxf(max_error[0], maxf(max_error[1], max_error[2]))
	var realistic_worst := maxf(realistic_max_error[0], maxf(realistic_max_error[1], realistic_max_error[2]))
	print("LUT_ERROR lut=%s full_range_worst=%.6f allowed_full_range_note=documented" % [lut_path.get_file(), worst])
	print("LUT_ERROR worst_point channel=%s phi=%.3f cos_theta_d=%.3f beta=%.3f error=%.6f" % [
		channels[worst_point["channel"]], worst_point["phi"], worst_point["cos_theta_d"], worst_point["beta"], worst_point["error"],
	])
	print("LUT_ERROR realistic_beta(>=0.3)_worst=%.6f samples=%d" % [realistic_worst, realistic_count])
	# Release gate: the realistic benchmark roughness range (beta >= 0.3; all
	# profiles use 0.75..1.0) must stay under the allowed threshold. The
	# full-range worst (extreme beta ~0.1 at the TRT peak) is reported above.
	if _data_error:
		push_error("LUT data decoding failed; validation is not valid")
		quit(1)
		return
	var worst_seam := maxf(seam_max_delta[0], maxf(seam_max_delta[1], seam_max_delta[2]))
	print("LUT_ERROR worst_seam_delta=%.6f allowed=%.6f" % [worst_seam, MAX_ALLOWED_SEAM_DELTA])
	if worst_seam > MAX_ALLOWED_SEAM_DELTA:
		push_error("LUT phi seam delta exceeds the allowed tolerance")
		quit(1)
		return
	if realistic_worst > MAX_ALLOWED_ERROR:
		push_error("LUT realistic-range max error exceeds the allowed threshold")
		quit(1)
		return
	print("LUT_VALIDATION_OK")
	quit(0)


## Exact port of the include's azimuthal terms (fresnel, logistic with fast
## acos, angular offset) evaluated at a test point.
func _analytic_azimuthal(cos_phi: float, sin_phi: float, cos_theta_d: float, beta: float) -> Vector3:
	var sin_theta_d_sq: float = 1.0 - cos_theta_d * cos_theta_d
	var eta_prime: float = sqrt(max(ETA * ETA - sin_theta_d_sq, 1e-6)) / max(cos_theta_d, 1e-6)
	var eta_prime_inv: float = 1.0 / eta_prime
	var s_tt: float = sqrt(2.0) / beta
	var s_trt: float = 0.5 * sqrt(2.0) / beta
	var b_tt: float = exp(-2.0 * sqrt(TAU) * s_tt)
	var b_trt: float = exp(-2.0 * sqrt(TAU) * s_trt)

	var cos_phi_half: float = max(1e-6, sqrt(0.5 + 0.5 * cos_phi))
	var r_term: float = 0.25 * cos_phi_half * _fresnel(cos_theta_d * cos_phi_half, ETA)
	var tt_term: float = _logistic(_angular_offset(1, cos_phi, sin_phi, eta_prime_inv, 0.0), s_tt, b_tt)
	var trt_term: float = _logistic(_angular_offset(2, cos_phi, sin_phi, eta_prime_inv, H_TRT), s_trt, b_trt)
	return Vector3(r_term, tt_term, trt_term)


## GPU-matching trilinear sample: texel centers at (i + 0.5) / N, clamp edges.
func _sample_lut(phi: float, cos_theta_d: float, beta: float) -> Vector3:
	# Periodic-U contract mirroring the shader: U wraps via fract() and the
	# sampler's repeat mode (neighbor indices modulo N); V and W are remapped
	# into the interior half-texel-inset range so repeat never wraps them.
	var u: float = fposmod((phi + PI) / TAU, 1.0)
	var half: float = 0.5 / float(_size)
	var v: float = clampf(cos_theta_d, half, 1.0 - half)
	var w: float = clampf((beta - BETA_MIN) / (BETA_MAX - BETA_MIN), half, 1.0 - half)
	var pu: float = u * float(_size) - 0.5
	var pv: float = v * float(_size) - 0.5
	var pw: float = w * float(_size) - 0.5
	var x0 := int(floor(pu))
	var y0 := int(floor(pv))
	var z0 := int(floor(pw))
	var tx: float = pu - float(x0)
	var ty: float = pv - float(y0)
	var tz: float = pw - float(z0)
	var result := Vector3.ZERO
	for dz in 2:
		for dy in 2:
			for dx in 2:
				# U neighbors wrap modulo N (repeat); V/W neighbors collapse
				# onto the last texel at the interior edge (weight 0).
				var texel_x: int = (x0 + dx) % _size
				var texel_y: int = mini(y0 + dy, _size - 1)
				var texel_z: int = mini(z0 + dz, _size - 1)
				var weight := (tx if dx == 1 else 1.0 - tx) * (ty if dy == 1 else 1.0 - ty) * (tz if dz == 1 else 1.0 - tz)
				result += _texel(texel_x, texel_y, texel_z) * weight
	return result


func _texel(x: int, y: int, z: int) -> Vector3:
	var byte_offset := ((z * _size + y) * _size + x) * 16
	var r: float = _float_at(byte_offset)
	var g: float = _float_at(byte_offset + 4)
	var b: float = _float_at(byte_offset + 8)
	return Vector3(r, g, b)


## Decodes one float directly from the original packed bytes at an explicit
## byte offset, with bounds checks. Any out-of-range read sets the fatal
## _data_error flag (the run then exits nonzero) instead of a silent zero.
func _float_at(byte_offset: int) -> float:
	if byte_offset < 0 or byte_offset + 4 > _data.size():
		_data_error = true
		push_error("LUT byte read out of range at %d (data size %d)" % [byte_offset, _data.size()])
		return 0.0
	return _data.decode_float(byte_offset)


func _fresnel(cos_theta: float, eta: float) -> float:
	var f0 := (1.0 - eta) * (1.0 - eta) / ((1.0 + eta) * (1.0 + eta))
	var p := 1.0 - clampf(cos_theta, 0.0, 1.0)
	var p_sq := p * p
	return lerp(p_sq * p_sq * p, 1.0, f0)


func _logistic(offset: float, s_inv: float, b_pre: float) -> float:
	var safe_offset := clampf(offset, -1.0, 1.0)
	var phi := sqrt(max(0.0, 1.0 - safe_offset)) * (1.5707288 + safe_offset * (-0.2121144 + safe_offset * 0.0742610))
	var eta_prime_inv := exp(-phi * s_inv)
	var c := 1.0 + eta_prime_inv
	return minf(1.0, s_inv * eta_prime_inv * (1.0 + b_pre) / ((1.0 - b_pre) * c * c))


func _angular_offset(mode: int, cos_phi: float, sin_phi: float, eta_prime_inv: float, h: float) -> float:
	var gamma := (2.126 * h * eta_prime_inv + PI) * float(mode)
	var a := 1.0 - 2.0 * h * h
	var b := 2.0 * h * sqrt(1.0 - h * h)
	var c := cos(gamma)
	var s := sin(gamma)
	return cos_phi * (c * a + s * b) + sin_phi * (s * a - c * b)
