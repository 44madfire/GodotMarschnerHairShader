extends SceneTree

## Numerical validation for the FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED LUT.
##
## Loads the committed data blob (benchmark/resources/luts/
## fast_marschner_dual_scatter_lut_64.res), bilinearly samples it exactly like
## the GPU sampler does (texel centers at (i + 0.5) / N, edge clamping, linear
## filtering), and validates:
##   - finite/bounded data: every texel channel is finite and within [0, 1],
##     and the summed channel energy per texel stays within [0, 1];
##   - seam/edge behavior: a sample clamped just outside either axis edge must
##     equal the same clamped sample at the edge (no wrap, no seam artifact);
##   - monotonic scattering energy: every channel is non-decreasing in tau
##     (U), the forward channels (R, B) are non-decreasing in the scattering
##     cosine (V) while the backward channels (G, A) are non-increasing, and
##     the three-event terms never exceed the one-event terms of the same
##     direction (R >= B, G >= A);
##   - max/RMS error against the generator's analytic formulas at a
##     deterministic grid.
##
## Run with: godot --headless --path <project> --script res://benchmark/tools/validate_marschner_dual_scatter_lut.gd

const LUT_PATH := "res://benchmark/resources/luts/fast_marschner_dual_scatter_lut_64.res"
const TAU_MAX := 16.0
const ONE_EVENT_PATH := 1.0
const THREE_EVENT_PATH := 1.5
## Bilinear interpolation error of the smooth exp() channels is a fraction of a
## percent at 64 texels; any channel error above this threshold fails.
const MAX_ALLOWED_ERROR := 0.02
## Monotonicity is checked with a small tolerance for float32 texel round-trip
## noise at the (near-)zero far end of the tau axis.
const MONOTONE_TOLERANCE := 5e-4
const MAX_ALLOWED_ENERGY := 1.0

const FastMarschnerDualLUTData := preload("res://benchmark/resources/fast_marschner_dual_lut_data.gd")

var _size := 64
var _data := PackedByteArray()
var _eta := 1.55
var _data_error := false


func _initialize() -> void:
	var lut_path: String = LUT_PATH
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--size="):
			lut_path = "res://benchmark/resources/luts/fast_marschner_dual_scatter_lut_%s.res" % argument.trim_prefix("--size=").strip_edges()
	var lut_data: FastMarschnerDualLUTData = load(lut_path) as FastMarschnerDualLUTData
	if lut_data == null:
		push_error("LUT data failed to load")
		quit(1)
		return
	var validation_errors: PackedStringArray = lut_data.validation_errors()
	if not validation_errors.is_empty():
		push_error("LUT data invalid: %s" % "; ".join(validation_errors))
		quit(1)
		return
	_size = lut_data.size
	_data = lut_data.data
	_eta = lut_data.eta

	# 1) Finite / bounded data over the full texel grid.
	var finite_ok := true
	var max_energy := 0.0
	for y in _size:
		for x in _size:
			var texel := _texel(x, y)
			for channel in 4:
				var value := _channel(texel, channel)
				if is_nan(value) or is_inf(value) or value < 0.0 or value > 1.0:
					finite_ok = false
					push_error("LUT texel (%d, %d) channel %d out of bounds: %s" % [x, y, channel, value])
			var energy := texel.x + texel.y + texel.z + texel.w
			max_energy = maxf(max_energy, energy)
			if energy < 0.0 or energy > MAX_ALLOWED_ENERGY:
				finite_ok = false
				push_error("LUT texel (%d, %d) energy %.6f outside [0, %.1f]" % [x, y, energy, MAX_ALLOWED_ENERGY])
	print("LUT_DATA finite_and_bounded=%s max_texel_energy=%.6f" % [finite_ok, max_energy])
	if not finite_ok:
		push_error("LUT contains non-finite or out-of-range data")
		quit(1)
		return

	# 2) Monotonic attenuation/energy behavior over the texel grid.
	var monotone_ok := _check_monotonicity()

	# 3) Seam/edge behavior: sampling just outside either axis domain must
	# clamp to the edge sample (the shader half-texel clamps both axes into the
	# interior texel-center range and the sampler is repeat-disabled, so an
	# out-of-domain coordinate wraps nowhere and equals the edge texel exactly).
	var edge_ok := true
	var edge_probes: Array = [
		[Vector2(0.0, 0.0), Vector2(-1.0, 0.0)],
		[Vector2(16.0, 0.0), Vector2(17.0, 0.0)],
		[Vector2(4.0, -1.0), Vector2(4.0, -2.0)],
		[Vector2(4.0, 1.0), Vector2(4.0, 2.0)],
	]
	for probe in edge_probes:
		var inside: Vector2 = probe[0]
		var outside: Vector2 = probe[1]
		if not _approx_equal(_sample_lut(inside.x, inside.y), _sample_lut(outside.x, outside.y)):
			edge_ok = false
			push_error("LUT edge clamp mismatch at tau=%.3f cosine=%.3f (outside probe tau=%.3f cosine=%.3f)" % [inside.x, inside.y, outside.x, outside.y])
	print("LUT_EDGE clamp_continuity=%s" % edge_ok)
	if not edge_ok:
		push_error("LUT edge clamping is not continuous (seam/edge behavior failed)")
		quit(1)
		return

	# 4) Max/RMS error against the generator's analytic formulas at a
	# deterministic grid (including exact domain endpoints). Endpoint texels are
	# generated at tau=0/TAU_MAX and c=-1/+1, so zero-density behavior is tested
	# directly rather than hidden by a half-texel floor.
	var channel_names := ["one_fwd", "one_bwd", "three_fwd", "three_bwd"]
	var max_error := [0.0, 0.0, 0.0, 0.0]
	var sum_sq_error := [0.0, 0.0, 0.0, 0.0]
	var gated_max_error := [0.0, 0.0, 0.0, 0.0]
	var sample_count := 0
	var gated_count := 0
	var worst_point := {"channel": -1, "tau": 0.0, "cosine": 0.0, "error": 0.0}
	var taus: Array = [0.0, 0.125, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 12.0, 16.0]
	var cosines: Array = [-1.0, -0.9, -0.75, -0.5, 0.0, 0.5, 0.75, 0.9, 1.0]
	for tau_value in taus:
		var tau: float = tau_value
		for cosine_value in cosines:
			var cosine: float = cosine_value
			var analytic := _analytic_terms(tau, cosine)
			var sampled := _sample_lut(tau, cosine)
			sample_count += 1
			var in_gate := tau >= 0.25 and absf(cosine) <= 0.9
			if in_gate:
				gated_count += 1
			for channel in 4:
				var error := absf(_channel(analytic, channel) - _channel(sampled, channel))
				max_error[channel] = maxf(max_error[channel], error)
				sum_sq_error[channel] += error * error
				if in_gate:
					gated_max_error[channel] = maxf(gated_max_error[channel], error)
				if error > worst_point["error"]:
					worst_point = {"channel": channel, "tau": tau, "cosine": cosine, "error": error}
	for channel in 4:
		var rms := sqrt(sum_sq_error[channel] / float(sample_count))
		print("LUT_ERROR channel=%s max=%.6f rms=%.6f gated_max=%.6f" % [channel_names[channel], max_error[channel], rms, gated_max_error[channel]])
	var worst := maxf(max_error[0], maxf(max_error[1], maxf(max_error[2], max_error[3])))
	var gated_worst := maxf(gated_max_error[0], maxf(gated_max_error[1], maxf(gated_max_error[2], gated_max_error[3])))
	print("LUT_ERROR lut=%s full_range_worst=%.6f" % [lut_path.get_file(), worst])
	print("LUT_ERROR gate=tau>=0.25,|cosine|<=0.9 gated_worst=%.6f allowed=%.6f samples=%d" % [gated_worst, MAX_ALLOWED_ERROR, gated_count])
	print("LUT_ERROR worst_point channel=%s tau=%.3f cosine=%.3f error=%.6f" % [
		channel_names[worst_point["channel"]], worst_point["tau"], worst_point["cosine"], worst_point["error"],
	])
	if _data_error:
		push_error("LUT data decoding failed; validation is not valid")
		quit(1)
		return
	if not monotone_ok:
		push_error("LUT monotonic attenuation/energy behavior failed")
		quit(1)
		return
	if gated_worst > MAX_ALLOWED_ERROR:
		push_error("LUT interior-range max error exceeds the allowed threshold")
		quit(1)
		return
	print("DUAL_SCATTER_LUT_VALIDATION_OK")
	quit(0)


## Texel-grid monotonicity checks with a float32-noise tolerance:
## non-decreasing in tau for all channels; R/B non-decreasing and G/A
## non-increasing in the scattering cosine; three-event never above the
## one-event term of the same direction.
func _check_monotonicity() -> bool:
	var ok := true
	for y in _size:
		var previous := _texel(0, y)
		for x in range(1, _size):
			var current := _texel(x, y)
			for channel in 4:
				if _channel(current, channel) < _channel(previous, channel) - MONOTONE_TOLERANCE:
					ok = false
					push_error("LUT channel %d not non-increasing in tau at (%d, %d): %s -> %s" % [channel, x, y, _channel(previous, channel), _channel(current, channel)])
			previous = current
		if _channel(previous, 0) < _channel(previous, 2) - MONOTONE_TOLERANCE:
			ok = false
			push_error("LUT three-event forward exceeds one-event forward at (last, %d)" % y)
		if _channel(previous, 1) < _channel(previous, 3) - MONOTONE_TOLERANCE:
			ok = false
			push_error("LUT three-event backward exceeds one-event backward at (last, %d)" % y)
	for x in _size:
		var previous := _texel(x, 0)
		for y in range(1, _size):
			var current := _texel(x, y)
			if _channel(current, 0) < _channel(previous, 0) - MONOTONE_TOLERANCE:
				ok = false
				push_error("LUT one-event forward not non-decreasing in cosine at (%d, %d)" % [x, y])
			if _channel(current, 1) > _channel(previous, 1) + MONOTONE_TOLERANCE:
				ok = false
				push_error("LUT one-event backward not non-increasing in cosine at (%d, %d)" % [x, y])
			if _channel(current, 2) < _channel(previous, 2) - MONOTONE_TOLERANCE:
				ok = false
				push_error("LUT three-event forward not non-decreasing in cosine at (%d, %d)" % [x, y])
			if _channel(current, 3) > _channel(previous, 3) + MONOTONE_TOLERANCE:
				ok = false
				push_error("LUT three-event backward not non-increasing in cosine at (%d, %d)" % [x, y])
			previous = current
		if _channel(previous, 0) < _channel(previous, 2) - MONOTONE_TOLERANCE:
			ok = false
			push_error("LUT three-event forward exceeds one-event forward at (%d, last)" % x)
		if _channel(previous, 1) < _channel(previous, 3) - MONOTONE_TOLERANCE:
			ok = false
			push_error("LUT three-event backward exceeds one-event backward at (%d, last)" % x)
	print("LUT_MONOTONE ok=%s" % ok)
	return ok


## The generator's analytic channel formulas, evaluated at a test point.
func _analytic_terms(tau: float, cosine: float) -> Vector4:
	var f0 := (1.0 - _eta) * (1.0 - _eta) / ((1.0 + _eta) * (1.0 + _eta))
	var one_event_fresnel := (1.0 - f0) * (1.0 - f0)
	var three_event_fresnel := one_event_fresnel * f0
	var forward_lobe := 0.5 * (1.0 + cosine)
	var backward_lobe := 0.5 * (1.0 - cosine)
	var one_event_energy := 1.0 - exp(-ONE_EVENT_PATH * tau)
	var three_event_energy := 1.0 - exp(-THREE_EVENT_PATH * tau)
	return Vector4(
		forward_lobe * one_event_fresnel * one_event_energy,
		backward_lobe * one_event_fresnel * one_event_energy,
		forward_lobe * three_event_fresnel * three_event_energy,
		backward_lobe * three_event_fresnel * three_event_energy
	)


## GPU-matching bilinear sample: texel centers at (i + 0.5) / N, clamped edges
## (the shader half-texel clamps both axes into the interior texel-center range
## and the sampler uses repeat-disabled linear filtering, so the GPU never
## wraps; neighbor indices clamp to the edge texel with zero weight).
func _sample_lut(tau: float, cosine: float) -> Vector4:
	var half: float = 0.5 / float(_size)
	var u: float = lerpf(half, 1.0 - half, clampf(tau / TAU_MAX, 0.0, 1.0))
	var v: float = lerpf(half, 1.0 - half, clampf(0.5 + 0.5 * cosine, 0.0, 1.0))
	var pu: float = u * float(_size) - 0.5
	var pv: float = v * float(_size) - 0.5
	var x0 := int(floor(pu))
	var y0 := int(floor(pv))
	var tx: float = pu - float(x0)
	var ty: float = pv - float(y0)
	var result := Vector4.ZERO
	for dy in 2:
		for dx in 2:
			var texel_x: int = clampi(x0 + dx, 0, _size - 1)
			var texel_y: int = clampi(y0 + dy, 0, _size - 1)
			var weight := (tx if dx == 1 else 1.0 - tx) * (ty if dy == 1 else 1.0 - ty)
			result += _texel(texel_x, texel_y) * weight
	return result


func _texel(x: int, y: int) -> Vector4:
	var byte_offset := (y * _size + x) * 16
	var r: float = _float_at(byte_offset)
	var g: float = _float_at(byte_offset + 4)
	var b: float = _float_at(byte_offset + 8)
	var a: float = _float_at(byte_offset + 12)
	return Vector4(r, g, b, a)


func _channel(value: Vector4, channel: int) -> float:
	match channel:
		0:
			return value.x
		1:
			return value.y
		2:
			return value.z
		_:
			return value.w


func _approx_equal(a: Vector4, b: Vector4) -> bool:
	return absf(a.x - b.x) < 1e-6 and absf(a.y - b.y) < 1e-6 \
		and absf(a.z - b.z) < 1e-6 and absf(a.w - b.w) < 1e-6


## Decodes one float directly from the original packed bytes at an explicit
## byte offset, with bounds checks. Any out-of-range read sets the fatal
## _data_error flag (the run then exits nonzero) instead of a silent zero.
func _float_at(byte_offset: int) -> float:
	if byte_offset < 0 or byte_offset + 4 > _data.size():
		_data_error = true
		push_error("LUT byte read out of range at %d (data size %d)" % [byte_offset, _data.size()])
		return 0.0
	return _data.decode_float(byte_offset)
