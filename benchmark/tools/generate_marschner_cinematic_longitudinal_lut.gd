extends SceneTree

## Generates the production Cinematic d'Eon-style longitudinal kernel.
##
## The 128x128x64 R16F volume stays 2 MiB, but uses a better-conditioned
## representation than the original candidate:
##   X = theta_cone in [-PI/2, PI/2]
##   Y = theta_o in [-PI/2, PI/2]
##   Z = log2(beta_eff) in [0.05, 64]
##   R = log2(Q)
## where Q = beta * sqrt(cos_cone*cos_o) * cos_o * M.
##
## Uniform angle sampling preserves grazing resolution. Interpolating log2(Q)
## preserves narrow longitudinal peak shape without increasing the texture size.

const Data := preload("res://benchmark/resources/hair_marschner_cinematic_longitudinal_lut_data.gd")
const DEFAULT_X: int = 128
const DEFAULT_Y: int = 128
const DEFAULT_Z: int = 64
const BETA_MIN: float = 0.05
const BETA_MAX: float = 64.0
const LOG2_Q_FLOOR: float = -120.0
const INV_LN_2: float = 1.4426950408889634

func _initialize() -> void:
	var sx: int = DEFAULT_X
	var sy: int = DEFAULT_Y
	var sz: int = DEFAULT_Z
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--size="):
			var dims: Array = _parse_size(arg.trim_prefix("--size="))
			if dims.is_empty():
				push_error("--size must be WxHxD with dimensions >= 8")
				quit(1)
				return
			sx = int(dims[0])
			sy = int(dims[1])
			sz = int(dims[2])
	var out_path: String = "res://benchmark/resources/luts/cinematic_longitudinal_kernel_%dx%dx%d.res" % [sx, sy, sz]
	var all_bytes: PackedByteArray = PackedByteArray()
	var log_beta_min: float = log(BETA_MIN) * INV_LN_2
	var log_beta_span: float = (log(BETA_MAX) - log(BETA_MIN)) * INV_LN_2
	var min_log2_q: float = INF
	var max_log2_q: float = -INF
	for z in sz:
		var beta: float = pow(2.0, log_beta_min + (float(z) + 0.5) / float(sz) * log_beta_span)
		var slice_floats: PackedFloat32Array = PackedFloat32Array()
		slice_floats.resize(sx * sy)
		var index: int = 0
		for y in sy:
			var theta_o: float = -0.5 * PI + (float(y) + 0.5) / float(sy) * PI
			var sin_o: float = sin(theta_o)
			var cos_o: float = maxf(cos(theta_o), 1e-16)
			for x in sx:
				var theta_cone: float = -0.5 * PI + (float(x) + 0.5) / float(sx) * PI
				var sin_cone: float = sin(theta_cone)
				var cos_cone: float = maxf(cos(theta_cone), 1e-16)
				var log2_q: float = _conditioned_log2_q(sin_o, cos_o, sin_cone, cos_cone, beta)
				slice_floats[index] = log2_q
				index += 1
				min_log2_q = minf(min_log2_q, log2_q)
				max_log2_q = maxf(max_log2_q, log2_q)
		var image: Image = Image.create_from_data(sx, sy, false, Image.FORMAT_RF, slice_floats.to_byte_array())
		image.convert(Image.FORMAT_RH)
		all_bytes.append_array(image.get_data())

	var resource = Data.new()
	resource.size_x = sx
	resource.size_y = sy
	resource.size_z = sz
	resource.format = Image.FORMAT_RH
	resource.beta_min = BETA_MIN
	resource.beta_max = BETA_MAX
	resource.contract = "deon_physical_longitudinal_log2q_v2"
	resource.channels = "R=log2(Q)"
	resource.notes = "%dx%dx%d R16F angle-domain conditioned d'Eon longitudinal kernel. X=theta_cone, Y=theta_o, Z=log2(beta_eff), R=log2(Q), beta=[%.4f,%.4f]." % [sx, sy, sz, BETA_MIN, BETA_MAX]
	resource.data = all_bytes
	var errors: PackedStringArray = resource.validation_errors()
	if not errors.is_empty():
		push_error("generated resource invalid: %s" % "; ".join(errors))
		quit(1)
		return
	var save_error: Error = ResourceSaver.save(resource, out_path)
	if save_error != OK:
		push_error("ResourceSaver.save failed: %s" % save_error)
		quit(1)
		return
	var loaded: Resource = load(out_path)
	if loaded == null:
		push_error("round-trip load failed")
		quit(1)
		return
	var loaded_errors: PackedStringArray = loaded.call(&"validation_errors")
	if not loaded_errors.is_empty():
		push_error("round-trip validation failed: %s" % "; ".join(loaded_errors))
		quit(1)
		return
	print("MARSCHNER_CINEMATIC_LONGITUDINAL_LUT_GENERATED path=%s size=%dx%dx%d format=R16F bytes=%d log2Q=[%s,%s]" % [out_path, sx, sy, sz, all_bytes.size(), String.num_scientific(min_log2_q), String.num_scientific(max_log2_q)])
	print("MARSCHNER_CINEMATIC_LONGITUDINAL_LUT_GENERATION_OK")
	quit(0)

func _conditioned_log2_q(sin_o: float, cos_o: float, sin_cone: float, cos_cone: float, beta: float) -> float:
	var v_inv: float = 1.0 / maxf(beta * beta, 1e-16)
	var bessel_x: float = cos_cone * cos_o * v_inv
	var log_m: float = (sin_cone * sin_o - 1.0) * v_inv + _log_bessel_zero(bessel_x) + log(v_inv) - log(maxf(cos_o, 1e-16))
	var log_q: float = log_m + log(beta) + 0.5 * log(maxf(cos_cone * cos_o, 1e-32)) + log(maxf(cos_o, 1e-16))
	return clampf(log_q * INV_LN_2, LOG2_Q_FLOOR, 15.0)

func _log_bessel_zero(x: float) -> float:
	var x_sq: float = x * x
	var value: float = (0.564187 + 1.01298 / (x_sq + 2.32434))
	value *= 1.0 / sqrt(sqrt(x_sq * 0.25 + 1.0))
	value *= exp(-2.0 * absf(x)) * 0.5 + 0.5
	return log(maxf(value, 1e-300)) + x

func _parse_size(text: String) -> Array:
	var parts: PackedStringArray = text.to_lower().split("x")
	if parts.size() != 3:
		return []
	var out: Array = []
	for p in parts:
		if not p.is_valid_int():
			return []
		var value: int = int(p)
		if value < 8 or value > 512:
			return []
		out.append(value)
	return out
