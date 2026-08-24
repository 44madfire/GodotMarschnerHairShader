extends SceneTree

## Offline generator for the FAST_MARSCHNER_ANALYTIC azimuthal LUT.
##
## Produces the committed RGBAF LUT data resource (default 64x64x64 at
## res://benchmark/resources/luts/fast_marschner_azimuthal_lut_64.res; the
## --size=N user argument reparameterizes the output path and size) with the
## three azimuthal lobe terms in RGB:
##   R   = 0.25 * cos(phi/2) * Fresnel(cos_theta_d * cos(phi/2); eta)
##   TT  = logistic(angular_offset(mode 1, h = 0);             s_tt,  b_tt)
##   TRT = logistic(angular_offset(mode 2, h = sqrt(3)/2);     s_trt, b_trt)
## The formulas are an exact GDScript port of hair_marschner_fast.gdshaderinc
## (fm_fresnel, fm_logistic with its fast-acos approximation, and
## fm_azimuthal_angular_offset), with the plan's fixed assumptions:
##   eta = 1.55, h_TT = 0, h_TRT = sqrt(3)/2.
##
## Axes (all in [0, 1] texture space, texel centers at (i + 0.5) / N):
##   U = phi      in [-PI, PI]   (relative azimuth; seam handled by the
##                                center layout and repeat-disabled sampling)
##   V = cos_theta_d in [0, 1]   (longitudinal difference angle)
##   W = azimuthal_roughness in [0.001, 1.0] (drives the TT/TRT logistic widths
##                                s_tt = sqrt(2)/beta, s_trt = 0.5*sqrt(2)/beta)
##
## Run with: godot --headless --path <project> --script res://benchmark/tools/generate_marschner_azimuthal_lut.gd

const LUT_SIZE := 64
const LUT_PATH := "res://benchmark/resources/luts/fast_marschner_azimuthal_lut_%d.res" % LUT_SIZE
## Preload shadow so parsing never depends on the global class cache.
const FastMarschnerLUTData := preload("res://benchmark/resources/fast_marschner_lut_data.gd")
const ETA := 1.55
const H_TRT := 0.5 * sqrt(3.0)
const BETA_MIN := 0.001
const BETA_MAX := 1.0


func _initialize() -> void:
	var requested_size := 0
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--size="):
			requested_size = int(argument.trim_prefix("--size=").strip_edges())
	var lut_size: int = requested_size if requested_size > 0 else LUT_SIZE
	var lut_path: String = LUT_PATH
	if requested_size > 0 and requested_size != LUT_SIZE:
		lut_path = "res://benchmark/resources/luts/fast_marschner_azimuthal_lut_%d.res" % lut_size
	var texel_count := lut_size * lut_size * lut_size
	var floats := PackedFloat32Array()
	floats.resize(texel_count * 4)
	var float_index := 0
	for z in lut_size:
		var beta: float = BETA_MIN + (float(z) + 0.5) / float(lut_size) * (BETA_MAX - BETA_MIN)
		var s_tt: float = sqrt(2.0) / beta
		var s_trt: float = 0.5 * sqrt(2.0) / beta
		var b_tt: float = exp(-2.0 * sqrt(TAU) * s_tt)
		var b_trt: float = exp(-2.0 * sqrt(TAU) * s_trt)
		for y in lut_size:
			var cos_theta_d: float = (float(y) + 0.5) / float(lut_size)
			var sin_theta_d_sq: float = 1.0 - cos_theta_d * cos_theta_d
			var eta_prime: float = sqrt(max(ETA * ETA - sin_theta_d_sq, 1e-6)) / max(cos_theta_d, 1e-6)
			var eta_prime_inv: float = 1.0 / eta_prime
			for x in lut_size:
				var phi: float = -PI + (float(x) + 0.5) / float(lut_size) * TAU
				var cos_phi: float = cos(phi)
				var sin_phi: float = sin(phi)
				var cos_phi_half: float = max(1e-6, sqrt(0.5 + 0.5 * cos_phi))

				var r_term: float = 0.25 * cos_phi_half * _fresnel(cos_theta_d * cos_phi_half, ETA)
				var tt_offset: float = _angular_offset(1, cos_phi, sin_phi, eta_prime_inv, 0.0)
				var tt_term: float = _logistic(tt_offset, s_tt, b_tt)
				var trt_offset: float = _angular_offset(2, cos_phi, sin_phi, eta_prime_inv, H_TRT)
				var trt_term: float = _logistic(trt_offset, s_trt, b_trt)

				floats[float_index] = r_term
				floats[float_index + 1] = tt_term
				floats[float_index + 2] = trt_term
				floats[float_index + 3] = 1.0
				float_index += 4

	var bytes := floats.to_byte_array()
	# Godot 4.7's ResourceSaver cannot self-contain an ImageTexture3D (stub
	# .res / data-less .tres), so the committed artifact is the raw RGBAF data
	# in a FastMarschnerLUTData resource; the adapter constructs the
	# ImageTexture3D at runtime with the instance create() call.
	var lut_data: FastMarschnerLUTData = FastMarschnerLUTData.new()
	lut_data.size = lut_size
	lut_data.format = Image.FORMAT_RGBAF
	lut_data.eta = ETA
	lut_data.notes = "%d^3 RGBAF azimuthal R/TT/TRT terms for FAST_MARSCHNER (eta 1.55, h_TT 0, h_TRT sqrt(3)/2). U=phi, V=cos_theta_d, W=azimuthal_roughness; texel centers at (i+0.5)/N." % lut_size
	lut_data.data = bytes
	var save_error: Error = ResourceSaver.save(lut_data, lut_path)
	if save_error != OK:
		push_error("ResourceSaver.save failed: %s" % save_error)
		quit(1)
		return
	var reloaded: FastMarschnerLUTData = load(lut_path) as FastMarschnerLUTData
	if reloaded == null or reloaded.data.size() != bytes.size():
		push_error("LUT round-trip verification failed")
		quit(1)
		return
	print("LUT_GENERATED path=%s size=%dx%dx%d format=RGBAF bytes=%d" % [lut_path, lut_size, lut_size, lut_size, bytes.size()])
	print("LUT_SAMPLE z0(y0): R=%.6f TT=%.6f TRT=%.6f (phi=-PI+PI/%d, cos_td=1/%d, beta=0.017)" % [floats[0], floats[1], floats[2], lut_size * 2, lut_size])
	quit(0)


func _fresnel(cos_theta: float, eta: float) -> float:
	var f0 := (1.0 - eta) * (1.0 - eta) / ((1.0 + eta) * (1.0 + eta))
	var p := 1.0 - clampf(cos_theta, 0.0, 1.0)
	var p_sq := p * p
	return lerp(p_sq * p_sq * p, 1.0, f0)


## Exact port of fm_logistic: fast-acos approximation, exp, and normalization.
func _logistic(offset: float, s_inv: float, b_pre: float) -> float:
	var safe_offset := clampf(offset, -1.0, 1.0)
	var phi := sqrt(max(0.0, 1.0 - safe_offset)) * (1.5707288 + safe_offset * (-0.2121144 + safe_offset * 0.0742610))
	var eta_prime_inv := exp(-phi * s_inv)
	var c := 1.0 + eta_prime_inv
	return minf(1.0, s_inv * eta_prime_inv * (1.0 + b_pre) / ((1.0 - b_pre) * c * c))


## Exact port of fm_azimuthal_angular_offset (gamma approximated as in the shader).
func _angular_offset(mode: int, cos_phi: float, sin_phi: float, eta_prime_inv: float, h: float) -> float:
	var gamma := (2.126 * h * eta_prime_inv + PI) * float(mode)
	var a := 1.0 - 2.0 * h * h
	var b := 2.0 * h * sqrt(1.0 - h * h)
	var c := cos(gamma)
	var s := sin(gamma)
	return cos_phi * (c * a + s * b) + sin_phi * (s * a - c * b)
