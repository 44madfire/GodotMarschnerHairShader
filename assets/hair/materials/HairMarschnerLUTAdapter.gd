extends RefCounted
class_name HairMarschnerLUTAdapter

## Runtime binder for the explicit production Marschner tiers.
## The LUT resources are generated offline and stored as raw data resources;
## Godot 4.7 cannot reliably self-contain ImageTexture3D data in .res files, so
## this adapter reconstructs and caches Texture3D instances at runtime.

const DEFAULT_UNITY_LUT_PATH: String = "res://benchmark/resources/luts/unity_azimuthal_64.res"
const DEFAULT_CINEMATIC_LUT_PATH: String = "res://benchmark/resources/luts/cinematic_longitudinal_kernel_128x128x64.res"
const UNITY_CONTRACT: String = "unity_hdrp_azimuthal_n_v1"
const CINEMATIC_CONTRACT: String = "deon_physical_longitudinal_q_v1"
const CINEMATIC_LOW_BETA_BLEND: Vector2 = Vector2(0.015, 0.03)

var _texture_cache: Dictionary = {}


func load_default_unity_data() -> Resource:
	return _load_checked(DEFAULT_UNITY_LUT_PATH, UNITY_CONTRACT)


func load_default_cinematic_data() -> Resource:
	return _load_checked(DEFAULT_CINEMATIC_LUT_PATH, CINEMATIC_CONTRACT)


func texture3d_from_resource(data: Resource) -> Texture3D:
	if data == null:
		return null
	var cache_key: int = data.get_instance_id()
	if _texture_cache.has(cache_key):
		return _texture_cache[cache_key] as Texture3D

	var bytes_value: Variant = data.get(&"data")
	var sx_value: Variant = data.get(&"size_x")
	var sy_value: Variant = data.get(&"size_y")
	var sz_value: Variant = data.get(&"size_z")
	var format_value: Variant = data.get(&"format")
	if not (bytes_value is PackedByteArray):
		return null
	if not (sx_value is int) or not (sy_value is int) or not (sz_value is int) or not (format_value is int):
		return null

	var bytes: PackedByteArray = bytes_value
	var sx: int = int(sx_value)
	var sy: int = int(sy_value)
	var sz: int = int(sz_value)
	var format: int = int(format_value)
	if sx <= 0 or sy <= 0 or sz <= 0 or bytes.is_empty() or bytes.size() % sz != 0:
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
	_texture_cache[cache_key] = texture
	return texture


func bind_unity_fast(material: ShaderMaterial, data: Resource = null) -> bool:
	if material == null:
		return false
	var lut_data: Resource = data if data != null else load_default_unity_data()
	if not _resource_matches_contract(lut_data, UNITY_CONTRACT):
		return false
	var texture: Texture3D = texture3d_from_resource(lut_data)
	if texture == null:
		return false
	var eta_value: Variant = lut_data.get(&"eta")
	if not (eta_value is float or eta_value is int):
		return false
	var eta: float = float(eta_value)
	material.set_shader_parameter(&"unity_azimuthal_lut", texture)
	material.set_shader_parameter(&"unity_azimuthal_lut_eta", eta)
	# Unity Standard's modified-index fit is a 1.55 human-hair approximation;
	# do not allow a mathematically inconsistent arbitrary-IOR/LUT combination.
	material.set_shader_parameter(&"ior", eta)
	return true


func bind_cinematic(material: ShaderMaterial, data: Resource = null) -> bool:
	if material == null:
		return false
	var lut_data: Resource = data if data != null else load_default_cinematic_data()
	if not _resource_matches_contract(lut_data, CINEMATIC_CONTRACT):
		return false
	var texture: Texture3D = texture3d_from_resource(lut_data)
	if texture == null:
		return false
	var beta_min_value: Variant = lut_data.get(&"beta_min")
	var beta_max_value: Variant = lut_data.get(&"beta_max")
	if not (beta_min_value is float or beta_min_value is int) or not (beta_max_value is float or beta_max_value is int):
		return false
	var beta_min: float = float(beta_min_value)
	var beta_max: float = float(beta_max_value)
	if beta_min <= 0.0 or beta_max <= beta_min:
		return false
	material.set_shader_parameter(&"cinematic_longitudinal_lut", texture)
	material.set_shader_parameter(&"cinematic_longitudinal_beta_range", Vector2(beta_min, beta_max))
	material.set_shader_parameter(&"cinematic_longitudinal_low_beta_blend", CINEMATIC_LOW_BETA_BLEND)
	return true


func missing_default_resources() -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray()
	if not ResourceLoader.exists(DEFAULT_UNITY_LUT_PATH):
		result.append("Generate Unity Fast LUT: godot --headless --path <project> --script res://benchmark/tools/generate_unity_hair_azimuthal_lut.gd")
	if not ResourceLoader.exists(DEFAULT_CINEMATIC_LUT_PATH):
		result.append("Generate Cinematic LUT: godot --headless --path <project> --script res://benchmark/tools/generate_marschner_cinematic_longitudinal_lut.gd")
	return result


func _load_checked(path: String, contract: String) -> Resource:
	if not ResourceLoader.exists(path):
		return null
	var data: Resource = load(path)
	return data if _resource_matches_contract(data, contract) else null


func _resource_matches_contract(data: Resource, contract: String) -> bool:
	if data == null or String(data.get(&"contract")) != contract:
		return false
	if data.has_method(&"validation_errors"):
		var errors: Variant = data.call(&"validation_errors")
		if errors is PackedStringArray:
			var typed_errors: PackedStringArray = errors
			if not typed_errors.is_empty():
				return false
	return true
