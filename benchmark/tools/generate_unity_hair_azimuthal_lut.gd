extends SceneTree

## Offline port of Unity HDRP's preintegrated roughened azimuthal distribution.
## The LUT contains distribution N only; attenuation A is evaluated analytically.
## Runtime coordinates match PreIntegratedAzimuthalScattering.hlsl exactly:
## X=(phi+2PI)/(4PI), Y=cos(theta_d), Z=perceptual radial roughness.
## Generation mirrors HDRP's ComputeAzimuthalScattering kernel: 64^3 texel-center
## coordinates, the eta=1.55 Karis modified-refraction fit, FastASin, h in
## [-1,1) with DH=0.1, and RGBA16F storage.

const Data := preload("res://benchmark/resources/unity_hair_azimuthal_lut_data.gd")
const SIZE: int = 64
const ETA: float = 1.55
const DH: float = 0.1
const SQRT_PI_OVER_8: float = 0.6266570686577501

func _initialize() -> void:
	var size: int = SIZE
	for arg_value in OS.get_cmdline_user_args():
		var arg: String = String(arg_value)
		if arg.begins_with("--size="):
			size = int(arg.trim_prefix("--size="))
	if size < 8 or size > 256:
		push_error("--size must be in [8,256]")
		quit(1)
		return

	var out_path: String = "res://benchmark/resources/luts/unity_azimuthal_%d.res" % size
	var all_bytes: PackedByteArray = PackedByteArray()
	var min_n: float = INF
	var max_n: float = 0.0
	for z in size:
		var beta: float = (float(z) + 0.5) / float(size)
		var s: float = _logistic_scale_from_beta(beta)
		var slice_floats: PackedFloat32Array = PackedFloat32Array()
		slice_floats.resize(size * size * 4)
		var index: int = 0
		for y in size:
			var cos_theta_d: float = (float(y) + 0.5) / float(size)
			var eta_prime: float = _modified_refraction_index(cos_theta_d)
			for x in size:
				var phi: float = -TAU + (float(x) + 0.5) / float(size) * (2.0 * TAU)
				var n: Vector3 = Vector3.ZERO
				var h: float = -1.0
				while h < 1.0:
					var gamma_o: float = _fast_asin(clampf(h, -1.0, 1.0))
					var gamma_t: float = clampf(_fast_asin(h / maxf(eta_prime, 1e-6)), -1.0, 1.0)
					n.x += _azimuthal_scattering(phi, 0, s, gamma_o, gamma_t) * DH
					n.y += _azimuthal_scattering(phi, 1, s, gamma_o, gamma_t) * DH
					n.z += _azimuthal_scattering(phi, 2, s, gamma_o, gamma_t) * DH
					h += DH
				n *= 0.5
				n = Vector3(maxf(n.x, 0.0), maxf(n.y, 0.0), maxf(n.z, 0.0))
				slice_floats[index] = n.x
				slice_floats[index + 1] = n.y
				slice_floats[index + 2] = n.z
				slice_floats[index + 3] = 1.0
				index += 4
				min_n = minf(min_n, minf(n.x, minf(n.y, n.z)))
				max_n = maxf(max_n, maxf(n.x, maxf(n.y, n.z)))
		var image: Image = Image.create_from_data(size, size, false, Image.FORMAT_RGBAF, slice_floats.to_byte_array())
		image.convert(Image.FORMAT_RGBAH)
		all_bytes.append_array(image.get_data())

	var resource = Data.new()
	resource.size_x = size
	resource.size_y = size
	resource.size_z = size
	resource.format = Image.FORMAT_RGBAH
	resource.eta = ETA
	resource.contract = "unity_hdrp_azimuthal_n_v1"
	resource.channels = "R=N_R,G=N_TT,B=N_TRT,A=1"
	resource.notes = "%d^3 RGBA16F Unity HDRP ComputeAzimuthalScattering port. X=phi[-2PI,2PI], Y=cosThetaD, Z=perceptual radial roughness; Karis modified eta for human hair 1.55; FastASin; h=[-1,1), DH=0.1." % size
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
	if loaded == null or not loaded.validation_errors().is_empty():
		push_error("round-trip validation failed")
		quit(1)
		return
	print("UNITY_HAIR_AZIMUTHAL_LUT_GENERATED path=%s size=%d bytes=%d N=[%s,%s]" % [out_path, size, all_bytes.size(), String.num_scientific(min_n), String.num_scientific(max_n)])
	print("UNITY_HAIR_AZIMUTHAL_LUT_GENERATION_OK")
	quit(0)

func _modified_refraction_index(cos_theta_d: float) -> float:
	var c: float = maxf(cos_theta_d, 1e-6)
	return 1.19 / c + 0.36 * c

func _fast_acos_pos(x_value: float) -> float:
	var x: float = absf(x_value)
	var result: float = (0.0468878 * x - 0.203471) * x + 1.570796
	return result * sqrt(maxf(0.0, 1.0 - x))

func _fast_acos(x: float) -> float:
	var result: float = _fast_acos_pos(x)
	return result if x >= 0.0 else PI - result

func _fast_asin(x: float) -> float:
	return 0.5 * PI - _fast_acos(clampf(x, -1.0, 1.0))

func _logistic_scale_from_beta(beta: float) -> float:
	return SQRT_PI_OVER_8 * ((0.265 * beta) + (1.194 * beta * beta) + (5.372 * pow(absf(beta), 22.0)))

func _logistic(x_value: float, s: float) -> float:
	var x: float = absf(x_value)
	var e: float = exp(-x / s)
	return e / (s * (1.0 + e) * (1.0 + e))

func _logistic_cdf(x: float, s: float) -> float:
	return 1.0 / (1.0 + exp(-x / s))

func _trimmed_logistic(x: float, s: float) -> float:
	return _logistic(x, s) / maxf(_logistic_cdf(PI, s) - _logistic_cdf(-PI, s), 1e-8)

func _azimuthal_direction(p: int, gamma_o: float, gamma_t: float) -> float:
	return 2.0 * float(p) * gamma_t - 2.0 * gamma_o + float(p) * PI

func _azimuthal_scattering(phi: float, p: int, s: float, gamma_o: float, gamma_t: float) -> float:
	var dphi: float = phi - _azimuthal_direction(p, gamma_o, gamma_t)
	while dphi > PI:
		dphi -= TAU
	while dphi < -PI:
		dphi += TAU
	return _trimmed_logistic(dphi, s)
