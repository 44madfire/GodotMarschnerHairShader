extends RefCounted
class_name HairMarschnerTierLUTAdapter

const UNITY_LUT_PATH: String = "res://benchmark/resources/luts/unity_azimuthal_64.res"
const CINEMATIC_LUT_PATH: String = "res://benchmark/resources/luts/cinematic_longitudinal_kernel_128x128x64.res"
const UNITY_CONTRACT: String = "unity_hdrp_azimuthal_n_v1"
const CINEMATIC_CONTRACT: String = "deon_physical_longitudinal_q_v1"

var _texture_cache: Dictionary = {}

func load_unity_lut() -> Resource:
	if not ResourceLoader.exists(UNITY_LUT_PATH):
		return null
	var data: Resource = load(UNITY_LUT_PATH)
	if data == null or String(data.get(&"contract")) != UNITY_CONTRACT:
		return null
	if data.has_method(&"validation_errors"):
		var error_value: Variant = data.call(&"validation_errors")
		if error_value is PackedStringArray:
			var errors: PackedStringArray = error_value
			if not errors.is_empty():
				return null
	return data

func load_cinematic_lut() -> Resource:
	if not ResourceLoader.exists(CINEMATIC_LUT_PATH):
		return null
	var data: Resource = load(CINEMATIC_LUT_PATH)
	if data == null or String(data.get(&"contract")) != CINEMATIC_CONTRACT:
		return null
	if data.has_method(&"validation_errors"):
		var error_value: Variant = data.call(&"validation_errors")
		if error_value is PackedStringArray:
			var errors: PackedStringArray = error_value
			if not errors.is_empty():
				return null
	return data

func texture3d_from_resource(data: Resource) -> Texture3D:
	if data == null:
		return null
	var key: int = data.get_instance_id()
	if _texture_cache.has(key):
		return _texture_cache[key] as Texture3D
	var bytes_value: Variant = data.get(&"data")
	if not (bytes_value is PackedByteArray):
		return null
	var bytes: PackedByteArray = bytes_value
	var sx: int = int(data.get(&"size_x"))
	var sy: int = int(data.get(&"size_y"))
	var sz: int = int(data.get(&"size_z"))
	var format: int = int(data.get(&"format"))
	if sx <= 0 or sy <= 0 or sz <= 0:
		return null
	if bytes.size() % sz != 0:
		return null
	var slice_bytes: int = int(bytes.size() / sz)
	var slices: Array[Image] = []
	for z in sz:
		var image: Image = Image.create_from_data(sx, sy, false, format, bytes.slice(z * slice_bytes, (z + 1) * slice_bytes))
		if image == null:
			return null
		slices.append(image)
	var texture: ImageTexture3D = ImageTexture3D.new()
	texture.create(format, sx, sy, sz, false, slices)
	if not texture.get_rid().is_valid():
		return null
	if texture.get_width() != sx or texture.get_height() != sy or texture.get_depth() != sz:
		return null
	_texture_cache[key] = texture
	return texture

func bind_unity_fast(material: ShaderMaterial) -> bool:
	var data: Resource = load_unity_lut()
	if material == null or data == null:
		return false
	var texture: Texture3D = texture3d_from_resource(data)
	if texture == null:
		return false
	var eta: float = float(data.get(&"eta"))
	material.set_shader_parameter(&"unity_azimuthal_lut", texture)
	material.set_shader_parameter(&"unity_azimuthal_lut_eta", eta)
	# HDRP's Standard path uses the 1.55-specific ModifiedRefractionIndex fit
	# and sinThetaT mapping. Pin the project compatibility uniform to the LUT
	# eta rather than allowing a mathematically inconsistent hybrid.
	material.set_shader_parameter(&"ior", eta)
	return true

func bind_cinematic(material: ShaderMaterial) -> bool:
	var data: Resource = load_cinematic_lut()
	if material == null or data == null:
		return false
	var texture: Texture3D = texture3d_from_resource(data)
	if texture == null:
		return false
	material.set_shader_parameter(&"cinematic_longitudinal_lut", texture)
	material.set_shader_parameter(&"cinematic_longitudinal_beta_range", Vector2(float(data.get(&"beta_min")), float(data.get(&"beta_max"))))
	material.set_shader_parameter(&"cinematic_longitudinal_low_beta_blend", Vector2(0.015, 0.03))
	return true

func missing_resource_instructions() -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray()
	if not ResourceLoader.exists(UNITY_LUT_PATH):
		result.append("Generate Unity Fast LUT: godot --headless --path <project> --script res://benchmark/tools/generate_unity_hair_azimuthal_lut.gd")
	if not ResourceLoader.exists(CINEMATIC_LUT_PATH):
		result.append("Generate Cinematic LUT: godot --headless --path <project> --script res://benchmark/tools/generate_marschner_cinematic_longitudinal_lut.gd")
	return result
