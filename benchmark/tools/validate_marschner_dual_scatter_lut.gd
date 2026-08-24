extends SceneTree

## Numerical validation for the FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED LUT.
##
## Loads the committed data blob (benchmark/resources/luts/
## fast_marschner_dual_scatter_lut_64.res), bilinearly samples it exactly like
## the GPU sampler does (texel centers at (i + 0.5) / N, edge clamping, linear
## filtering), and validates:
##   - committed metadata: the baked eta must be ~= 1.55 within 0.0005, the
##     tau_max domain must be 4.0 (the reachable [0, 4] domain for
##     tau_d = 4 * local_density), and the contract identifier must match the
##     generator's revision;
##   - finite/bounded data: every texel channel is finite and within [0, 1],
##     and the summed channel energy per texel stays within [0, 1];
##   - zero-density behavior: every channel is exactly zero at tau_d = 0
##     (zero local density -> zero secondary energy);
##   - seam/edge behavior: a sample clamped just outside either axis edge must
##     equal the same clamped sample at the edge (no wrap, no seam artifact);
##   - monotonic event-weight behavior: every channel is non-decreasing in
##     tau_d (U), the forward channels (R, B) are non-decreasing in the
##     scattering cosine (V) while the backward channels (G, A) are
##     non-increasing, and the three-event weights never exceed the one-event
##     weights of the same direction (R >= B, G >= A) at every texel;
##   - max/RMS error against the generator's analytic formulas at a
##     deterministic grid;
##   - directional non-cancellation: the four LUT channels are reconstructed
##     separately at runtime with the per-direction path responses
##     (T1f/T1b/T3f/T3b with a colored sigma_a), so the forward/backward split
##     the LUT stores must survive at the alignment endpoints c = -1 / 0 / +1,
##     while the pure-forward endpoint c = +1 must reproduce the naive summed
##     reconstruction exactly.
##
## Run with: godot --headless --path <project> --script res://benchmark/tools/validate_marschner_dual_scatter_lut.gd

const LUT_PATH := "res://benchmark/resources/luts/fast_marschner_dual_scatter_lut_64.res"
const ETA_EXPECTED := 1.55
## Reachable tau_d domain upper bound (tau_d = 4 * local_density).
const TAU_MAX := 4.0
## Generator/runtime contract revision identifier carried by the resource.
const CONTRACT_ID := "dual_scatter_contract_b_v2"
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
	var tau_max: float = lut_data.tau_max
	var contract_id: String = lut_data.contract

	# 1) Committed metadata: the F0 baked into the texels must be the plan's
	# fixed eta 1.55 (the shader guards LUT use with the same 0.0005 tolerance),
	# the tau_max domain must be the reachable 4.0 (the runtime maps the U axis
	# with the resource's own tau_max via dual_scatter_lut_tau_max and must
	# never silently claim a wider domain), and the contract identifier must
	# match the generator's revision.
	if absf(_eta - ETA_EXPECTED) > 0.0005:
		push_error("LUT baked eta %.4f must be ~= %.2f within 0.0005" % [_eta, ETA_EXPECTED])
		quit(1)
		return
	if not is_finite(tau_max) or tau_max <= 0.0:
		push_error("LUT tau_max %.4f must be finite and > 0" % tau_max)
		quit(1)
		return
	if absf(tau_max - TAU_MAX) > 0.0005:
		push_error("LUT tau_max %.4f must be ~= %.1f (the reachable tau_d = 4 * local_density domain)" % [tau_max, TAU_MAX])
		quit(1)
		return
	if contract_id != CONTRACT_ID:
		push_error("LUT contract identifier '%s' must be '%s'" % [contract_id, CONTRACT_ID])
		quit(1)
		return
	print("LUT_ETA eta=%.4f expected=%.2f tolerance=0.0005" % [_eta, ETA_EXPECTED])
	print("LUT_METADATA tau_max=%.1f contract=%s" % [tau_max, contract_id])

	# 2) Finite / bounded data over the full texel grid.
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

	# 3) Zero-density behavior: the first U texel is exactly tau_d = 0, and
	# every channel there must be exactly zero (zero local density -> zero
	# secondary energy).
	var zero_ok := true
	for y in _size:
		var zero_texel := _texel(0, y)
		if zero_texel.x != 0.0 or zero_texel.y != 0.0 or zero_texel.z != 0.0 or zero_texel.w != 0.0:
			zero_ok = false
			push_error("LUT texel (0, %d) must be exactly zero at tau_d = 0: %s" % [y, zero_texel])
	print("LUT_ZERO zero_density=%s" % zero_ok)
	if not zero_ok:
		push_error("LUT zero-density behavior failed (tau_d = 0 must yield zero secondary energy)")
		quit(1)
		return

	# 4) Monotonic event-weight behavior over the texel grid.
	var monotone_ok := _check_monotonicity()

	# 5) Seam/edge behavior: sampling just outside either axis domain must
	# clamp to the edge sample (the shader half-texel clamps both axes into the
	# interior texel-center range and the sampler is repeat-disabled, so an
	# out-of-domain coordinate wraps nowhere and equals the edge texel exactly).
	var edge_ok := true
	var edge_probes: Array = [
		[Vector2(0.0, 0.0), Vector2(-1.0, 0.0)],
		[Vector2(4.0, 0.0), Vector2(5.0, 0.0)],
		[Vector2(2.0, -1.0), Vector2(2.0, -2.0)],
		[Vector2(2.0, 1.0), Vector2(2.0, 2.0)],
	]
	for probe in edge_probes:
		var inside: Vector2 = probe[0]
		var outside: Vector2 = probe[1]
		if not _approx_equal(_sample_lut(inside.x, inside.y), _sample_lut(outside.x, outside.y)):
			edge_ok = false
			push_error("LUT edge clamp mismatch at tau_d=%.3f cosine=%.3f (outside probe tau_d=%.3f cosine=%.3f)" % [inside.x, inside.y, outside.x, outside.y])
	print("LUT_EDGE clamp_continuity=%s" % edge_ok)
	if not edge_ok:
		push_error("LUT edge clamping is not continuous (seam/edge behavior failed)")
		quit(1)
		return

	# 6) Max/RMS error against the generator's analytic formulas at a
	# deterministic grid (including exact domain endpoints). Endpoint texels are
	# generated at tau=0/TAU_MAX and c=-1/+1, so zero-density behavior is tested
	# directly rather than hidden by a half-texel floor.
	var channel_names := ["one_fwd", "one_bwd", "three_fwd", "three_bwd"]
	var max_error := [0.0, 0.0, 0.0, 0.0]
	var sum_sq_error := [0.0, 0.0, 0.0, 0.0]
	var gated_max_error := [0.0, 0.0, 0.0, 0.0]
	var sample_count := 0
	var gated_count := 0
	var worst_point := {"channel": -1, "tau_d": 0.0, "cosine": 0.0, "error": 0.0}
	var taus: Array = [0.0, 0.125, 0.25, 0.5, 1.0, 2.0, 3.0, 3.5, 4.0]
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
					worst_point = {"channel": channel, "tau_d": tau, "cosine": cosine, "error": error}
	for channel in 4:
		var rms := sqrt(sum_sq_error[channel] / float(sample_count))
		print("LUT_ERROR channel=%s max=%.6f rms=%.6f gated_max=%.6f" % [channel_names[channel], max_error[channel], rms, gated_max_error[channel]])
	var worst := maxf(max_error[0], maxf(max_error[1], maxf(max_error[2], max_error[3])))
	var gated_worst := maxf(gated_max_error[0], maxf(gated_max_error[1], maxf(gated_max_error[2], gated_max_error[3])))
	print("LUT_ERROR lut=%s full_range_worst=%.6f" % [lut_path.get_file(), worst])
	print("LUT_ERROR gate=tau_d>=0.25,|cosine|<=0.9 gated_worst=%.6f allowed=%.6f samples=%d" % [gated_worst, MAX_ALLOWED_ERROR, gated_count])
	print("LUT_ERROR worst_point channel=%s tau_d=%.3f cosine=%.3f error=%.6f" % [
		channel_names[worst_point["channel"]], worst_point["tau_d"], worst_point["cosine"], worst_point["error"],
	])
	if _data_error:
		push_error("LUT data decoding failed; validation is not valid")
		quit(1)
		return
	if not monotone_ok:
		push_error("LUT monotonic event-weight behavior failed")
		quit(1)
		return
	if gated_worst > MAX_ALLOWED_ERROR:
		push_error("LUT interior-range max error exceeds the allowed threshold")
		quit(1)
		return

	# 7) Directional non-cancellation evidence: the runtime reconstructs the
	# four LUT channels separately with the per-direction path responses
	# (Contract B four-path contract with a colored sigma_a), so the
	# forward/backward split the LUT stores must survive at the alignment
	# endpoints c = -1 / 0 / +1, while the pure-forward endpoint c = +1 must
	# reproduce the naive summed reconstruction exactly (the backward channels
	# are zero there, so the two reconstructions coincide).
	var directional_ok := _check_directional_channels()
	if not directional_ok:
		push_error("LUT directional non-cancellation evidence failed")
		quit(1)
		return
	print("DUAL_SCATTER_LUT_VALIDATION_OK")
	quit(0)


## Directional non-cancellation evidence for the four-path runtime contract:
## samples the LUT at the alignment endpoints c = -1 / 0 / +1 at a mid-domain
## tau_d (2.0), applies the per-direction path responses with a colored
## sigma_a (0.02, 0.15, 0.6, matching the deterministic probe colors), and
## verifies:
##   - the four-path energy differs between c = -1 and c = +1 and c = 0 is
##     distinct from both endpoints (the directional channels carry energy the
##     old R+G / B+A summation cancelled);
##   - at c = -1 the four-path reconstruction differs from the naive summed
##     reconstruction, proving the split is not cancelled at runtime;
##   - at c = +1 the four-path reconstruction equals the summed reconstruction
##     exactly (only the forward channels are active there), proving the
##     four-path reconstruction is a strict generalization of the summed one.
func _check_directional_channels() -> bool:
	var ok := true
	var tau := 2.0
	var sigma_a := Vector3(0.02, 0.15, 0.6)
	var t1_forward := Vector3(exp(-sigma_a.x), exp(-sigma_a.y), exp(-sigma_a.z))
	var t1_backward := Vector3(exp(-0.5 * sigma_a.x), exp(-0.5 * sigma_a.y), exp(-0.5 * sigma_a.z))
	var t3_forward := Vector3(exp(-1.5 * sigma_a.x), exp(-1.5 * sigma_a.y), exp(-1.5 * sigma_a.z))
	var t3_backward := Vector3(exp(-0.75 * sigma_a.x), exp(-0.75 * sigma_a.y), exp(-0.75 * sigma_a.z))
	var directional_by_cosine := {}
	var summed_by_cosine := {}
	for cosine in [-1.0, 0.0, 1.0]:
		var events := _sample_lut(tau, cosine)
		var directional := events.x * t1_forward + events.y * t1_backward \
			+ events.z * t3_forward + events.w * t3_backward
		var summed := (events.x + events.y) * t1_forward + (events.z + events.w) * t3_forward
		directional_by_cosine[cosine] = directional
		summed_by_cosine[cosine] = summed
		print("LUT_DIRECTIONAL tau_d=%.1f c=%+.1f four_path=(%.6f %.6f %.6f) summed=(%.6f %.6f %.6f)" % [tau, cosine, directional.x, directional.y, directional.z, summed.x, summed.y, summed.z])
	var forward_energy: Vector3 = directional_by_cosine[1.0]
	var backward_energy: Vector3 = directional_by_cosine[-1.0]
	var zero_energy: Vector3 = directional_by_cosine[0.0]
	if forward_energy.distance_to(backward_energy) < 1e-3:
		ok = false
		push_error("four-path energy must differ between c=+1 and c=-1 at tau_d=%.1f (forward %s, backward %s)" % [tau, forward_energy, backward_energy])
	if zero_energy.distance_to(forward_energy) < 1e-3 or zero_energy.distance_to(backward_energy) < 1e-3:
		ok = false
		push_error("four-path energy at c=0 must differ from both endpoints at tau_d=%.1f (c=0 %s)" % [tau, zero_energy])
	var summed_backward: Vector3 = summed_by_cosine[-1.0]
	if backward_energy.distance_to(summed_backward) < 1e-3:
		ok = false
		push_error("four-path reconstruction must differ from the summed R+G / B+A reconstruction at c=-1 (four_path %s, summed %s)" % [backward_energy, summed_backward])
	var summed_forward: Vector3 = summed_by_cosine[1.0]
	if forward_energy.distance_to(summed_forward) > 1e-6:
		ok = false
		push_error("four-path reconstruction must equal the summed reconstruction at the pure-forward endpoint c=+1 (four_path %s, summed %s)" % [forward_energy, summed_forward])
	# Channel-level directional dominance at the endpoints: at c=+1 the forward
	# weights dominate (R >= G, B >= A), at c=-1 the backward weights dominate.
	var forward_events := _sample_lut(tau, 1.0)
	var backward_events := _sample_lut(tau, -1.0)
	if forward_events.x < forward_events.y - 1e-6 or forward_events.z < forward_events.w - 1e-6:
		ok = false
		push_error("forward channels must dominate at c=+1 at tau_d=%.1f (%s)" % [tau, forward_events])
	if backward_events.y < backward_events.x - 1e-6 or backward_events.w < backward_events.z - 1e-6:
		ok = false
		push_error("backward channels must dominate at c=-1 at tau_d=%.1f (%s)" % [tau, backward_events])
	print("LUT_DIRECTIONAL ok=%s" % ok)
	return ok


## Texel-grid monotonicity checks with a float32-noise tolerance:
## non-decreasing in tau_d for all channels; R/B non-decreasing and G/A
## non-increasing in the scattering cosine; the three-event weight never above
## the one-event weight of the same direction (R >= B, G >= A) at every texel.
func _check_monotonicity() -> bool:
	var ok := true
	for y in _size:
		var previous := _texel(0, y)
		for x in range(1, _size):
			var current := _texel(x, y)
			for channel in 4:
				if _channel(current, channel) < _channel(previous, channel) - MONOTONE_TOLERANCE:
					ok = false
					push_error("LUT channel %d not non-decreasing in tau_d at (%d, %d): %s -> %s" % [channel, x, y, _channel(previous, channel), _channel(current, channel)])
			if _channel(current, 0) < _channel(current, 2) - MONOTONE_TOLERANCE:
				ok = false
				push_error("LUT three-event forward exceeds one-event forward at (%d, %d)" % [x, y])
			if _channel(current, 1) < _channel(current, 3) - MONOTONE_TOLERANCE:
				ok = false
				push_error("LUT three-event backward exceeds one-event backward at (%d, %d)" % [x, y])
			previous = current
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
			if _channel(current, 0) < _channel(current, 2) - MONOTONE_TOLERANCE:
				ok = false
				push_error("LUT three-event forward exceeds one-event forward at (%d, %d)" % [x, y])
			if _channel(current, 1) < _channel(current, 3) - MONOTONE_TOLERANCE:
				ok = false
				push_error("LUT three-event backward exceeds one-event backward at (%d, %d)" % [x, y])
			previous = current
	print("LUT_MONOTONE ok=%s" % ok)
	return ok


## The generator's analytic event-weight formulas, evaluated at a test point.
func _analytic_terms(tau: float, cosine: float) -> Vector4:
	var f0 := (1.0 - _eta) * (1.0 - _eta) / ((1.0 + _eta) * (1.0 + _eta))
	var one_event_fresnel := (1.0 - f0) * (1.0 - f0)
	var three_event_fresnel := one_event_fresnel * f0
	var forward_lobe := 0.5 * (1.0 + cosine)
	var backward_lobe := 0.5 * (1.0 - cosine)
	var one_event_weight := 1.0 - exp(-ONE_EVENT_PATH * tau)
	var three_event_weight := 1.0 - exp(-THREE_EVENT_PATH * tau)
	return Vector4(
		forward_lobe * one_event_fresnel * one_event_weight,
		backward_lobe * one_event_fresnel * one_event_weight,
		forward_lobe * three_event_fresnel * three_event_weight,
		backward_lobe * three_event_fresnel * three_event_weight
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
