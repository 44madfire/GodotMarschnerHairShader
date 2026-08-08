extends SceneTree

## Generates a generic d'Eon-style energy-conserving longitudinal kernel in a
## physical rectangular domain. The runtime derives each lobe's non-separable
## sin(theta_cone) and beta_eff analytically, then samples this single scalar LUT.
## Default storage is R16F: 128x128x64 is 2 MiB.

const Data := preload("res://benchmark/resources/hair_marschner_cinematic_longitudinal_lut_data.gd")
const DEFAULT_X := 128
const DEFAULT_Y := 128
const DEFAULT_Z := 64
const BETA_MIN := 0.015
const BETA_MAX := 64.0
const INV_LN_2 := 1.4426950408889634

func _initialize() -> void:
	var sx := DEFAULT_X
	var sy := DEFAULT_Y
	var sz := DEFAULT_Z
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--size="):
			var dims := _parse_size(arg.trim_prefix("--size="))
			if dims.is_empty():
				push_error("--size must be WxHxD with dimensions >= 8")
				quit(1)
				return
			sx = dims[0]
			sy = dims[1]
			sz = dims[2]
	var out_path := "res://benchmark/resources/luts/cinematic_longitudinal_kernel_%dx%dx%d.res" % [sx, sy, sz]
	var all_bytes := PackedByteArray()
	var log_beta_min := log(BETA_MIN) * INV_LN_2
	var log_beta_span := (log(BETA_MAX) - log(BETA_MIN)) * INV_LN_2
	var min_q := INF
	var max_q := 0.0
	for z in sz:
		var beta := pow(2.0, log_beta_min + (float(z) + 0.5) / float(sz) * log_beta_span)
		var slice_floats := PackedFloat32Array()
		slice_floats.resize(sx * sy)
		var index := 0
		for y in sy:
			var sin_o := -1.0 + 2.0 * (float(y) + 0.5) / float(sy)
			var cos_o := sqrt(maxf(1.0 - sin_o * sin_o, 1e-16))
			for x in sx:
				var sin_cone := -1.0 + 2.0 * (float(x) + 0.5) / float(sx)
				var cos_cone := sqrt(maxf(1.0 - sin_cone * sin_cone, 1e-16))
				var q := _conditioned_q(sin_o, cos_o, sin_cone, cos_cone, beta)
				slice_floats[index] = q
				index += 1
				min_q = minf(min_q, q)
				max_q = maxf(max_q, q)
		var image := Image.create_from_data(sx, sy, false, Image.FORMAT_RF, slice_floats.to_byte_array())
		image.convert(Image.FORMAT_RH)
		all_bytes.append_array(image.get_data())

	var resource: HairMarschnerCinematicLongitudinalLUTData = Data.new()
	resource.size_x = sx
	resource.size_y = sy
	resource.size_z = sz
	resource.format = Image.FORMAT_RH
	resource.beta_min = BETA_MIN
	resource.beta_max = BETA_MAX
	resource.contract = "deon_physical_longitudinal_q_v1"
	resource.channels = "R=Q"
	resource.notes = "%dx%dx%d R16F physical-domain conditioned d'Eon longitudinal kernel. X=sin(theta_cone), Y=sin(theta_o), Z=log2(beta_eff), beta=[%.4f,%.4f]." % [sx, sy, sz, BETA_MIN, BETA_MAX]
	resource.data = all_bytes
	var errors := resource.validation_errors()
	if not errors.is_empty():
		push_error("generated resource invalid: %s" % "; ".join(errors))
		quit(1)
		return
	var save_error := ResourceSaver.save(resource, out_path)
	if save_error != OK:
		push_error("ResourceSaver.save failed: %s" % save_error)
		quit(1)
		return
	var loaded: Resource = load(out_path)
	if loaded == null or not loaded.validation_errors().is_empty():
		push_error("round-trip validation failed")
		quit(1)
		return
	print("MARSCHNER_CINEMATIC_LONGITUDINAL_LUT_GENERATED path=%s size=%dx%dx%d format=R16F bytes=%d Q=[%s,%s]" % [out_path, sx, sy, sz, all_bytes.size(), String.num_scientific(min_q), String.num_scientific(max_q)])
	print("MARSCHNER_CINEMATIC_LONGITUDINAL_LUT_GENERATION_OK")
	quit(0)

func _conditioned_q(sin_o: float, cos_o: float, sin_cone: float, cos_cone: float, beta: float) -> float:
	var v_inv := 1.0 / maxf(beta * beta, 1e-16)
	var x := cos_cone * cos_o * v_inv
	var log_m := (sin_cone * sin_o - 1.0) * v_inv + _log_bessel_zero(x) + log(v_inv) - log(maxf(cos_o, 1e-16))
	var log_q := log_m + log(beta) + 0.5 * log(maxf(cos_cone * cos_o, 1e-32)) + log(maxf(cos_o, 1e-16))
	return exp(clampf(log_q, -120.0 * log(2.0), 80.0))

func _log_bessel_zero(x: float) -> float:
	var x_sq := x * x
	var value := (0.564187 + 1.01298 / (x_sq + 2.32434))
	value *= 1.0 / sqrt(sqrt(x_sq * 0.25 + 1.0))
	value *= exp(-2.0 * absf(x)) * 0.5 + 0.5
	return log(maxf(value, 1e-300)) + x

func _parse_size(text: String) -> Array:
	var parts := text.to_lower().split("x")
	if parts.size() != 3:
		return []
	var out := []
	for p in parts:
		if not p.is_valid_int():
			return []
		var value := int(p)
		if value < 8 or value > 512:
			return []
		out.append(value)
	return out
