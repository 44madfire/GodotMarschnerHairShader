extends SceneTree

## Offline generator for the Tier 2 standardized R-longitudinal kernel LUT
## (Phase 2a).
##
## Produces the committed non-cubic RGBAF 3D LUT data resource (default
## 128x128x64 at res://benchmark/resources/luts/
## fast_marschner_r_standardized_lut_128x128x64.res) holding the standardized
## projected quantity
##   Q = beta_r * sqrt(cos(theta_cone) * cos(theta_o)) * cos(theta_o) * M_R
## from benchmark/reference/fast_marschner_r_standardized_kernel_reference.gd
## (the direct Bessel form; the asymptotic Gaussian limit only matters below
## the LUT's beta floor and is handled by the sampler's fallback seam).
##
## Axes (all in [0, 1] texture space, texel centers at (i + 0.5) / N):
##   X = q = (theta_o - theta_cone) / beta_r  in [-12, 12]
##   Y = theta_cone                           in [-PI/2, PI/2]
##   Z = log2(beta_r) linearly mapped between log2(beta_min) and
##       log2(beta_max), beta in [0.02, 9]
##
## Channels: R = linear Q, G = log2(Q) (encode_log2 floor -120), B = 0, A = 1.
## Metadata states the axis ranges, resolution, contract, channels, fallback
## policy, and that no raw-M unit-normalization claim is made. The saved
## resource is verified on reload (resource type, byte payload, metadata,
## every texel against the reference at its texel center, and the sampler
## seam) before the run exits 0.
##
## --size=WxHxD optionally reparameterizes the output path and size; the
## resolution must stay non-cubic (a plain or cubic size is rejected and the
## default resource is left fixed), matching the replacement-plan contract.
##
## Run with (Windows Godot 4.7, UNC project path):
##   /mnt/c/Tools/Godot/godot.exe --headless --path "//wsl.localhost/Ubuntu/home/jeffreymwang/godot-hair-shader" --script res://benchmark/tools/generate_marschner_r_standardized_lut.gd

const SIZE_X := 256
const SIZE_Y := 256
const SIZE_Z := 128
const LUT_PATH := "res://benchmark/resources/luts/fast_marschner_r_standardized_lut_256x256x128.res"
## Preload shadows so parsing never depends on the global class cache.
const FastMarschnerRStandardizedLUTData := preload("res://benchmark/resources/fast_marschner_r_standardized_lut_data.gd")
const Reference := preload("res://benchmark/reference/fast_marschner_r_standardized_kernel_reference.gd")
const INV_LN_2 := 1.4426950408889634
const Q_MIN := -12.0
const Q_MAX := 12.0
const BETA_MIN := 0.02
const BETA_MAX := 9.0
const LOG_VALUE_FLOOR := -120.0
const CONTRACT_ID := "standardized_r_projected_q_v1"
const CHANNELS := "R=linear_Q,G=log2_Q,B=0,A=1"
const FALLBACK_POLICY := "clamp/no-wrap trilinear inside physical interpolation support; direct/asymptotic reference fallback for beta/q outside support, grazing footprints, or cone-pole samples"


func _initialize() -> void:
	var size_x := SIZE_X
	var size_y := SIZE_Y
	var size_z := SIZE_Z
	var lut_path := LUT_PATH
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--size="):
			var parsed := _parse_size(argument.trim_prefix("--size=").strip_edges())
			if parsed.is_empty():
				push_error("--size must be a non-cubic WxHxD triple (e.g. --size=256x256x128); plain or cubic sizes are rejected and the default resource is left fixed")
				quit(1)
				return
			size_x = parsed[0]
			size_y = parsed[1]
			size_z = parsed[2]
			lut_path = "res://benchmark/resources/luts/fast_marschner_r_standardized_lut_%dx%dx%d.res" % [size_x, size_y, size_z]
	var texel_count := size_x * size_y * size_z
	var floats := PackedFloat32Array()
	floats.resize(texel_count * 4)
	var float_index := 0
	var log2_beta_min := log(BETA_MIN) * INV_LN_2
	var log2_beta_span := (log(BETA_MAX) - log(BETA_MIN)) * INV_LN_2
	var min_linear := INF
	var max_linear := 0.0
	var min_log2 := INF
	var max_log2 := -INF
	for z in size_z:
		var log2_beta: float = log2_beta_min + (float(z) + 0.5) / float(size_z) * log2_beta_span
		var beta := pow(2.0, log2_beta)
		for y in size_y:
			var theta_cone := -PI * 0.5 + (float(y) + 0.5) / float(size_y) * PI
			for x in size_x:
				var q: float = Q_MIN + (float(x) + 0.5) / float(size_x) * (Q_MAX - Q_MIN)
				var theta_o := theta_cone + q * beta
				var q_value: float = Reference.direct_q_value(theta_o, theta_cone, beta) if beta > Reference.BETA_NUMERIC_EPSILON else Reference.asymptotic_q_value(theta_o, theta_cone, beta)
				var log2_q := maxf(log(maxf(q_value, 1e-300)) * INV_LN_2, LOG_VALUE_FLOOR)
				floats[float_index] = q_value
				floats[float_index + 1] = log2_q
				floats[float_index + 2] = 0.0
				floats[float_index + 3] = 1.0
				float_index += 4
				min_linear = minf(min_linear, q_value)
				max_linear = maxf(max_linear, q_value)
				min_log2 = minf(min_log2, log2_q)
				max_log2 = maxf(max_log2, log2_q)

	var bytes := floats.to_byte_array()
	# Godot 4.7's ResourceSaver cannot self-contain an ImageTexture3D (stub
	# .res / data-less .tres), so the committed artifact is the raw RGBAF data
	# in a FastMarschnerRStandardizedLUTData resource; the Phase 2b adapter
	# constructs the ImageTexture3D at runtime.
	var lut_data: FastMarschnerRStandardizedLUTData = FastMarschnerRStandardizedLUTData.new()
	lut_data.size_x = size_x
	lut_data.size_y = size_y
	lut_data.size_z = size_z
	lut_data.format = Image.FORMAT_RGBAF
	lut_data.q_min = Q_MIN
	lut_data.q_max = Q_MAX
	lut_data.theta_cone_min = -PI * 0.5
	lut_data.theta_cone_max = PI * 0.5
	lut_data.beta_min = BETA_MIN
	lut_data.beta_max = BETA_MAX
	lut_data.log_value_floor = LOG_VALUE_FLOOR
	lut_data.contract = CONTRACT_ID
	lut_data.channels = CHANNELS
	lut_data.fallback_policy = FALLBACK_POLICY
	lut_data.raw_m_unit_normalization_claimed = false
	lut_data.notes = "%dx%dx%d RGBAF standardized projected R-longitudinal kernel Q=beta_r*sqrt(cos(theta_cone)*cos(theta_o))*cos(theta_o)*M_R (contract %s). Axes (texel centers at (i+0.5)/N): X=q=(theta_o-theta_cone)/beta_r in [-12, 12], Y=theta_cone in [-PI/2, PI/2], Z=log2(beta_r) linear in [log2(0.02), log2(9)]. Channels: R=linear Q, G=log2(Q) floored at %s, B=0, A=1. Fallback policy: %s. The stored Q makes NO raw-M unit-normalization claim; the direct kernel's projected integral is not universally 1." % [size_x, size_y, size_z, CONTRACT_ID, LOG_VALUE_FLOOR, FALLBACK_POLICY]
	lut_data.data = bytes
	var save_error: Error = ResourceSaver.save(lut_data, lut_path)
	if save_error != OK:
		push_error("ResourceSaver.save failed: %s" % save_error)
		quit(1)
		return
	var reloaded: FastMarschnerRStandardizedLUTData = load(lut_path) as FastMarschnerRStandardizedLUTData
	if reloaded == null or not (reloaded is FastMarschnerRStandardizedLUTData):
		push_error("LUT round-trip verification failed: resource type mismatch")
		quit(1)
		return
	var bytes_ok := reloaded.data.size() == bytes.size() and reloaded.data == bytes
	if not bytes_ok:
		push_error("LUT round-trip verification failed: byte payload mismatch (%d vs %d)" % [reloaded.data.size(), bytes.size()])
		quit(1)
		return
	var reload_validation: PackedStringArray = reloaded.validation_errors()
	var metadata_ok := reload_validation.is_empty() \
		and reloaded.size_x == size_x and reloaded.size_y == size_y and reloaded.size_z == size_z \
		and reloaded.contract == CONTRACT_ID and reloaded.channels == CHANNELS \
		and reloaded.format == Image.FORMAT_RGBAF \
		and absf(reloaded.q_min - Q_MIN) <= 1e-12 and absf(reloaded.q_max - Q_MAX) <= 1e-12 \
		and absf(reloaded.theta_cone_min - (-PI * 0.5)) <= 1e-12 and absf(reloaded.theta_cone_max - (PI * 0.5)) <= 1e-12 \
		and absf(reloaded.beta_min - BETA_MIN) <= 1e-12 and absf(reloaded.beta_max - BETA_MAX) <= 1e-12 \
		and absf(reloaded.log_value_floor - LOG_VALUE_FLOOR) <= 1e-12 \
		and reloaded.fallback_policy == FALLBACK_POLICY \
		and not reloaded.raw_m_unit_normalization_claimed
	if not metadata_ok:
		push_error("LUT round-trip verification failed: metadata mismatch (%s)" % "; ".join(reload_validation))
		quit(1)
		return
	# Texel-domain verification over the full grid: every texel finite and in
	# contract (R >= 0, G >= log floor, B == 0, A == 1), and both R and G match
	# the reference at the texel center (tolerances cover the float32 storage
	# rounding of the float64 reference values).
	var texels_ok := true
	var texel_count_actual := 0
	for z in size_z:
		var log2_beta: float = log2_beta_min + (float(z) + 0.5) / float(size_z) * log2_beta_span
		var beta := pow(2.0, log2_beta)
		for y in size_y:
			var theta_cone := -PI * 0.5 + (float(y) + 0.5) / float(size_y) * PI
			for x in size_x:
				var q: float = Q_MIN + (float(x) + 0.5) / float(size_x) * (Q_MAX - Q_MIN)
				var theta_o := theta_cone + q * beta
				var reference_q: float = Reference.direct_q_value(theta_o, theta_cone, beta) if beta > Reference.BETA_NUMERIC_EPSILON else Reference.asymptotic_q_value(theta_o, theta_cone, beta)
				var reference_log2 := maxf(log(maxf(reference_q, 1e-300)) * INV_LN_2, LOG_VALUE_FLOOR)
				var byte_offset := ((z * size_y + y) * size_x + x) * 16
				var r: float = reloaded.data.decode_float(byte_offset)
				var g: float = reloaded.data.decode_float(byte_offset + 4)
				var b: float = reloaded.data.decode_float(byte_offset + 8)
				var a: float = reloaded.data.decode_float(byte_offset + 12)
				texel_count_actual += 1
				if not is_finite(r) or not is_finite(g) or not is_finite(b) or not is_finite(a) \
						or r < 0.0 or g < LOG_VALUE_FLOOR or b != 0.0 or a != 1.0:
					texels_ok = false
					push_error("LUT texel (%d, %d, %d) out of contract: R=%s G=%.6f B=%.6f A=%.6f" % [x, y, z, String.num_scientific(r), g, b, a])
				elif absf(r - reference_q) > 1e-5 * maxf(reference_q, 1e-30) \
						or absf(g - reference_log2) > 1e-4 * maxf(absf(reference_log2), 1.0):
					texels_ok = false
					push_error("LUT texel (%d, %d, %d) does not match the reference: R=%s ref=%s G=%.6f refG=%.6f" % [x, y, z, String.num_scientific(r), String.num_scientific(reference_q), g, reference_log2])
	if not texels_ok:
		push_error("LUT texel-domain verification failed")
		quit(1)
		return
	var sampler_ok := _verify_sampler(reloaded)
	if not sampler_ok:
		push_error("LUT sampler seam verification failed")
		quit(1)
		return
	print("LUT_GENERATED path=%s size=%dx%dx%d format=RGBAF bytes=%d" % [lut_path, size_x, size_y, size_z, bytes.size()])
	print("LUT_DOMAIN q=[%.6f, %.6f] theta_cone=[%.6f, %.6f] beta=[%.6f, %.6f]" % [Q_MIN, Q_MAX, -PI * 0.5, PI * 0.5, BETA_MIN, BETA_MAX])
	print("LUT_VALUE_RANGE linear_min=%s linear_max=%s log2_min=%.6f log2_max=%.6f" % [String.num_scientific(min_linear), String.num_scientific(max_linear), min_log2, max_log2])
	print("LUT_CONTRACT contract=%s channels=%s fallback=%s raw_m_unit_normalization_claimed=false" % [CONTRACT_ID, CHANNELS, FALLBACK_POLICY])
	print("LUT_VERIFY texels=%d bytes_ok=%s metadata_ok=%s texels_ok=%s sampler_ok=%s" % [texel_count_actual, bytes_ok, metadata_ok, texels_ok, sampler_ok])
	print("LUT_SAMPLE q=0.000000 theta_cone=0.000000 beta=1.000000 linear=%s log2=%.6f fallback_outside_linear=%s" % [
		String.num_scientific(reloaded.sample_q(0.0, 0.0, 1.0, FastMarschnerRStandardizedLUTData.DECODE_LINEAR)),
		reloaded.sample_q(0.0, 0.0, 1.0, FastMarschnerRStandardizedLUTData.DECODE_LOG),
		String.num_scientific(reloaded.sample_q_fallback(0.0, 0.0, 1.0, FastMarschnerRStandardizedLUTData.DECODE_LINEAR, FastMarschnerRStandardizedLUTData.FALLBACK_OUTSIDE))])
	print("FAST_MARSCHNER_R_STANDARDIZED_LUT_GENERATION_OK")
	quit(0)


## Parses "--size=WxHxD" into [w, h, d] or returns an empty Array. Rejects
## non-numeric input, dimensions below 2, and cubic resolutions (the contract
## requires the LUT to stay non-cubic).
func _parse_size(argument: String) -> Array:
	var parts := argument.split("x")
	if parts.size() != 3:
		return []
	var dims := []
	for part in parts:
		var stripped := part.strip_edges()
		if not stripped.is_valid_int():
			return []
		var value := int(stripped)
		if value < 2:
			return []
		dims.append(value)
	if dims[0] == dims[1] and dims[1] == dims[2]:
		return []
	return dims


## Sampler seam checks on the reloaded resource: texel-center exactness for
## both decodes, edge-clamp/no-wrap continuity, and the direct/asymptotic
## fallback behavior.
func _verify_sampler(lut_data: FastMarschnerRStandardizedLUTData) -> bool:
	var ok := true
	var dec_linear := FastMarschnerRStandardizedLUTData.DECODE_LINEAR
	var dec_log := FastMarschnerRStandardizedLUTData.DECODE_LOG
	# Texel-center exactness: an interior texel center samples exactly the
	# stored texel for both decoders.
	var cx := lut_data.size_x / 2
	var cy := lut_data.size_y / 2
	var cz := lut_data.size_z / 2
	var q_c := lut_data.q_min + (float(cx) + 0.5) / float(lut_data.size_x) * (lut_data.q_max - lut_data.q_min)
	var cone_c := lut_data.theta_cone_min + (float(cy) + 0.5) / float(lut_data.size_y) * (lut_data.theta_cone_max - lut_data.theta_cone_min)
	var beta_c := pow(2.0, _log2_beta_min(lut_data) + (float(cz) + 0.5) / float(lut_data.size_z) * _log2_beta_span(lut_data))
	var texel_value := lut_data.texel(cx, cy, cz)
	var linear_sample := lut_data.sample_q(q_c, cone_c, beta_c, dec_linear)
	var log_sample := lut_data.sample_q(q_c, cone_c, beta_c, dec_log)
	if absf(linear_sample - texel_value.x) > 1e-9 * maxf(texel_value.x, 1.0) \
			or absf(log_sample - pow(2.0, texel_value.y)) > 1e-9 * maxf(pow(2.0, texel_value.y), 1.0):
		ok = false
		push_error("sampler texel-center exactness failed at (%d, %d, %d): linear=%s texel=%s log=%s" % [cx, cy, cz, String.num_scientific(linear_sample), String.num_scientific(texel_value.x), String.num_scientific(log_sample)])
	# Edge clamp / no wrap on X: q beyond the support clamps to the edge
	# texel centers, identical to sampling the edge coordinate.
	for pair in [[lut_data.q_max + 1.0, lut_data.q_max], [lut_data.q_min - 1.0, lut_data.q_min]]:
		var outside: float = pair[0]
		var inside: float = pair[1]
		var outside_sample := lut_data.sample_q(outside, 0.0, 1.0, dec_linear)
		var inside_sample := lut_data.sample_q(inside, 0.0, 1.0, dec_linear)
		if absf(outside_sample - inside_sample) > 1e-9 * maxf(outside_sample, 1.0):
			ok = false
			push_error("sampler edge clamp failed on X at q=%.3f (outside=%s inside=%s)" % [outside, String.num_scientific(outside_sample), String.num_scientific(inside_sample)])
	# Edge clamp on Z: beta below/above the support clamps to beta_min/beta_max.
	var beta_lo_out := lut_data.sample_q(0.0, 0.0, lut_data.beta_min * 0.5, dec_linear)
	var beta_lo_edge := lut_data.sample_q(0.0, 0.0, lut_data.beta_min, dec_linear)
	var beta_hi_out := lut_data.sample_q(0.0, 0.0, lut_data.beta_max * 2.0, dec_linear)
	var beta_hi_edge := lut_data.sample_q(0.0, 0.0, lut_data.beta_max, dec_linear)
	if absf(beta_lo_out - beta_lo_edge) > 1e-9 * maxf(beta_lo_out, 1.0) \
			or absf(beta_hi_out - beta_hi_edge) > 1e-9 * maxf(beta_hi_out, 1.0):
		ok = false
		push_error("sampler edge clamp failed on Z (beta below/above support)")
	# Edge clamp on Y: theta_cone beyond the support clamps to the PI/2 edge
	# (no wrap).
	var cone_hi_out := lut_data.sample_q(0.0, lut_data.theta_cone_max + 1.0, 1.0, dec_linear)
	var cone_hi_edge := lut_data.sample_q(0.0, lut_data.theta_cone_max, 1.0, dec_linear)
	if absf(cone_hi_out - cone_hi_edge) > 1e-9 * maxf(cone_hi_out, 1.0):
		ok = false
		push_error("sampler edge clamp failed on Y at theta_cone=%.3f (outside=%s inside=%s)" % [lut_data.theta_cone_max + 1.0, String.num_scientific(cone_hi_out), String.num_scientific(cone_hi_edge)])
	# Fallback: FALLBACK_OUTSIDE equals the direct reference outside the
	# support (both linear and log decodes); FALLBACK_ALWAYS equals the
	# reference at an interior point (within float32 storage); FALLBACK_NONE
	# equals the clamped LUT sample.
	var fallback_linear := lut_data.sample_q_fallback(0.0, 0.0, lut_data.beta_min * 0.5, dec_linear, FastMarschnerRStandardizedLUTData.FALLBACK_OUTSIDE)
	var reference_linear := lut_data.reference_q_value(0.0, 0.0, lut_data.beta_min * 0.5)
	if absf(fallback_linear - reference_linear) > 1e-12 * maxf(absf(reference_linear), 1.0):
		ok = false
		push_error("sampler fallback (linear, beta below support) mismatch: lut=%s ref=%s" % [String.num_scientific(fallback_linear), String.num_scientific(reference_linear)])
	var fallback_log := lut_data.sample_q_fallback(0.0, 0.0, lut_data.beta_min * 0.5, dec_log, FastMarschnerRStandardizedLUTData.FALLBACK_OUTSIDE)
	var reference_log := pow(2.0, maxf(log(maxf(reference_linear, 1e-300)) * INV_LN_2, LOG_VALUE_FLOOR))
	if absf(fallback_log - reference_log) > 1e-12 * maxf(absf(reference_log), 1.0):
		ok = false
		push_error("sampler fallback (decoded log, beta below support) mismatch: lut=%s ref=%s" % [String.num_scientific(fallback_log), String.num_scientific(reference_log)])
	var fallback_log_q_out := lut_data.sample_q_fallback(lut_data.q_max + 1.0, 0.0, 1.0, dec_log, FastMarschnerRStandardizedLUTData.FALLBACK_OUTSIDE)
	var reference_log_q_out := pow(2.0, maxf(log(maxf(lut_data.reference_q_value(lut_data.q_max + 1.0, 0.0, 1.0), 1e-300)) * INV_LN_2, LOG_VALUE_FLOOR))
	if absf(fallback_log_q_out - reference_log_q_out) > 1e-12 * maxf(absf(reference_log_q_out), 1.0):
		ok = false
		push_error("sampler fallback (decoded log, q outside support) mismatch")
	var fallback_q_out := lut_data.sample_q_fallback(lut_data.q_max + 1.0, 0.0, 1.0, dec_linear, FastMarschnerRStandardizedLUTData.FALLBACK_OUTSIDE)
	var reference_q_out := lut_data.reference_q_value(lut_data.q_max + 1.0, 0.0, 1.0)
	if absf(fallback_q_out - reference_q_out) > 1e-12 * maxf(absf(reference_q_out), 1.0):
		ok = false
		push_error("sampler fallback (q above support) mismatch: lut=%s ref=%s" % [String.num_scientific(fallback_q_out), String.num_scientific(reference_q_out)])
	var always_linear := lut_data.sample_q_fallback(0.5, 0.1, 0.5, dec_linear, FastMarschnerRStandardizedLUTData.FALLBACK_ALWAYS)
	var always_reference := lut_data.reference_q_value(0.5, 0.1, 0.5)
	if absf(always_linear - always_reference) > 1e-5 * maxf(absf(always_reference), 1e-30):
		ok = false
		push_error("sampler FALLBACK_ALWAYS mismatch at interior point: lut=%s ref=%s" % [String.num_scientific(always_linear), String.num_scientific(always_reference)])
	var none_linear := lut_data.sample_q_fallback(0.0, 0.0, lut_data.beta_min * 0.5, dec_linear, FastMarschnerRStandardizedLUTData.FALLBACK_NONE)
	var clamped_linear := lut_data.sample_q(0.0, 0.0, lut_data.beta_min * 0.5, dec_linear)
	if absf(none_linear - clamped_linear) > 1e-12 * maxf(absf(clamped_linear), 1.0):
		ok = false
		push_error("sampler FALLBACK_NONE mismatch: lut=%s clamp=%s" % [String.num_scientific(none_linear), String.num_scientific(clamped_linear)])
	return ok


func _log2_beta_min(lut_data: FastMarschnerRStandardizedLUTData) -> float:
	return log(lut_data.beta_min) * INV_LN_2


func _log2_beta_span(lut_data: FastMarschnerRStandardizedLUTData) -> float:
	return (log(lut_data.beta_max) - log(lut_data.beta_min)) * INV_LN_2
