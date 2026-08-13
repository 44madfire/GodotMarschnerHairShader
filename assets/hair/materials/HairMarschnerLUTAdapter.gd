extends RefCounted
class_name HairMarschnerLUTAdapter

## Runtime binder for the explicit production Marschner tiers.
##
## Production LUTs are directly serialized ImageTexture3D resources. Their
## semantic contract is owned by the shader slot/code below; runtime validation
## checks the texture structure before binding. The legacy raw-data helpers are
## retained only so the development storage benchmarks can reproduce the old
## PackedByteArray -> ImageTexture3D path.

const DEFAULT_UNITY_LUT_PATH: String = "res://assets/hair/luts/unity_azimuthal_64.res"
const DEFAULT_CINEMATIC_LUT_PATH: String = "res://assets/hair/luts/cinematic_longitudinal_kernel_128x128x64.res"

const LEGACY_UNITY_DATA_PATH: String = "res://benchmark/resources/luts/unity_azimuthal_64.res"
const LEGACY_CINEMATIC_DATA_PATH: String = "res://benchmark/resources/luts/cinematic_longitudinal_kernel_128x128x64.res"

const UNITY_CONTRACT: String = "unity_hdrp_azimuthal_n_v1"
const UNITY_SIZE: Vector3i = Vector3i(64, 64, 64)
const UNITY_FORMAT: int = Image.FORMAT_RGBAH
const UNITY_ETA: float = 1.55
const UNITY_CHANNELS: String = "R=N_R,G=N_TT,B=N_TRT,A=1"

const CINEMATIC_CONTRACT: String = "deon_physical_longitudinal_log2q_v2"
const CINEMATIC_SIZE: Vector3i = Vector3i(128, 128, 64)
const CINEMATIC_FORMAT: int = Image.FORMAT_RH
const CINEMATIC_BETA_RANGE: Vector2 = Vector2(0.05, 64.0)
const CINEMATIC_LOW_BETA_BLEND: Vector2 = Vector2(0.05, 0.10)
const CINEMATIC_CHANNELS: String = "R=log2(Q)"


func load_default_unity_texture() -> ImageTexture3D:
	return _load_direct_texture_checked(DEFAULT_UNITY_LUT_PATH, UNITY_SIZE, UNITY_FORMAT) as ImageTexture3D


func load_default_cinematic_texture() -> ImageTexture3D:
	return _load_direct_texture_checked(DEFAULT_CINEMATIC_LUT_PATH, CINEMATIC_SIZE, CINEMATIC_FORMAT) as ImageTexture3D


## Legacy benchmark API. New production code should use load_default_*_texture().
func load_default_unity_data() -> Resource:
	return _load_legacy_checked(LEGACY_UNITY_DATA_PATH, UNITY_CONTRACT)


## Legacy benchmark API. New production code should use load_default_*_texture().
func load_default_cinematic_data() -> Resource:
	return _load_legacy_checked(LEGACY_CINEMATIC_DATA_PATH, CINEMATIC_CONTRACT)


func validate_unity_texture(texture: Texture3D, require_rid: bool = true) -> PackedStringArray:
	return _texture_validation_errors(texture, UNITY_SIZE, UNITY_FORMAT, "Fast Marschner", require_rid)


func validate_cinematic_texture(texture: Texture3D, require_rid: bool = true) -> PackedStringArray:
	return _texture_validation_errors(texture, CINEMATIC_SIZE, CINEMATIC_FORMAT, "Cinematic Marschner", require_rid)


func bind_unity_fast(material: ShaderMaterial, data: Resource = null) -> bool:
	if material == null:
		return false
	var texture: Texture3D = _unity_texture_from_input(data)
	if texture == null:
		return false
	var errors: PackedStringArray = validate_unity_texture(texture, true)
	if not errors.is_empty():
		return false

	material.set_shader_parameter(&"unity_azimuthal_lut", texture)
	material.set_shader_parameter(&"unity_azimuthal_lut_eta", UNITY_ETA)
	# Unity Standard's modified-index fit is a 1.55 human-hair approximation;
	# do not allow a mathematically inconsistent arbitrary-IOR/LUT combination.
	material.set_shader_parameter(&"ior", UNITY_ETA)
	return true


func bind_cinematic(material: ShaderMaterial, data: Resource = null) -> bool:
	if material == null:
		return false
	var texture: Texture3D = _cinematic_texture_from_input(data)
	if texture == null:
		return false
	var errors: PackedStringArray = validate_cinematic_texture(texture, true)
	if not errors.is_empty():
		return false

	material.set_shader_parameter(&"cinematic_longitudinal_lut", texture)
	material.set_shader_parameter(&"cinematic_longitudinal_beta_range", CINEMATIC_BETA_RANGE)
	material.set_shader_parameter(&"cinematic_longitudinal_low_beta_blend", CINEMATIC_LOW_BETA_BLEND)
	return true


func missing_default_resources() -> PackedStringArray:
	var result := PackedStringArray()
	if not ResourceLoader.exists(DEFAULT_UNITY_LUT_PATH):
		result.append("Missing direct Fast LUT %s. Run with a rendering context: godot --path <project> --script res://benchmark/tools/materialize_direct_production_luts.gd" % DEFAULT_UNITY_LUT_PATH)
	if not ResourceLoader.exists(DEFAULT_CINEMATIC_LUT_PATH):
		result.append("Missing direct Cinematic LUT %s. Run with a rendering context: godot --path <project> --script res://benchmark/tools/materialize_direct_production_luts.gd" % DEFAULT_CINEMATIC_LUT_PATH)
	return result


func contract_summary() -> Dictionary:
	return {
		"fast": {
			"contract": UNITY_CONTRACT,
			"size": UNITY_SIZE,
			"format": UNITY_FORMAT,
			"eta": UNITY_ETA,
			"channels": UNITY_CHANNELS,
		},
		"cinematic": {
			"contract": CINEMATIC_CONTRACT,
			"size": CINEMATIC_SIZE,
			"format": CINEMATIC_FORMAT,
			"beta_range": CINEMATIC_BETA_RANGE,
			"low_beta_blend": CINEMATIC_LOW_BETA_BLEND,
			"channels": CINEMATIC_CHANNELS,
		},
	}


func _load_direct_texture_checked(path: String, expected_size: Vector3i, expected_format: int) -> Texture3D:
	if not ResourceLoader.exists(path):
		return null
	var loaded: Resource = ResourceLoader.load(path, "ImageTexture3D", ResourceLoader.CACHE_MODE_REUSE)
	var texture: ImageTexture3D = loaded as ImageTexture3D
	if texture == null:
		return null
	var errors: PackedStringArray = _texture_validation_errors(texture, expected_size, expected_format, path, true)
	return texture if errors.is_empty() else null


func _texture_validation_errors(texture: Texture3D, expected_size: Vector3i, expected_format: int, label: String, require_rid: bool) -> PackedStringArray:
	var errors := PackedStringArray()
	if texture == null:
		errors.append("%s texture is null" % label)
		return errors
	if texture.get_width() != expected_size.x or texture.get_height() != expected_size.y or texture.get_depth() != expected_size.z:
		errors.append("%s dimensions are %dx%dx%d; expected %dx%dx%d" % [label, texture.get_width(), texture.get_height(), texture.get_depth(), expected_size.x, expected_size.y, expected_size.z])
	if texture.get_format() != expected_format:
		errors.append("%s format is %d; expected %d" % [label, texture.get_format(), expected_format])
	if require_rid and not texture.get_rid().is_valid():
		errors.append("%s texture RID is invalid" % label)
	return errors


func _unity_texture_from_input(data: Resource) -> Texture3D:
	if data == null:
		return load_default_unity_texture()
	if data is Texture3D:
		return data as Texture3D
	if not _legacy_resource_matches_contract(data, UNITY_CONTRACT):
		return null
	return texture3d_from_resource(data)


func _cinematic_texture_from_input(data: Resource) -> Texture3D:
	if data == null:
		return load_default_cinematic_texture()
	if data is Texture3D:
		return data as Texture3D
	if not _legacy_resource_matches_contract(data, CINEMATIC_CONTRACT):
		return null
	return texture3d_from_resource(data)


## Legacy development-benchmark compatibility only. Production binding never
## enters this raw-data reconstruction path when the default LUTs are present.
func texture3d_from_resource(data: Resource) -> Texture3D:
	if data == null:
		return null
	if data is Texture3D:
		return data as Texture3D

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
	var sx := int(sx_value)
	var sy := int(sy_value)
	var sz := int(sz_value)
	var format := int(format_value)
	if sx <= 0 or sy <= 0 or sz <= 0 or bytes.is_empty() or bytes.size() % sz != 0:
		return null

	var slice_bytes := int(bytes.size() / sz)
	var slices: Array[Image] = []
	for z in sz:
		var image := Image.create_from_data(sx, sy, false, format, bytes.slice(z * slice_bytes, (z + 1) * slice_bytes))
		if image == null:
			return null
		slices.append(image)

	var texture := ImageTexture3D.new()
	texture.create(format, sx, sy, sz, false, slices)
	if texture.get_width() != sx or texture.get_height() != sy or texture.get_depth() != sz:
		return null
	return texture


## Kept for callers written against the former cached reconstruction adapter.
func clear_cache() -> void:
	pass


func _load_legacy_checked(path: String, contract: String) -> Resource:
	if not ResourceLoader.exists(path):
		return null
	var data: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE)
	return data if _legacy_resource_matches_contract(data, contract) else null


func _legacy_resource_matches_contract(data: Resource, contract: String) -> bool:
	if data == null or String(data.get(&"contract")) != contract:
		return false
	if data.has_method(&"validation_errors"):
		var errors_value: Variant = data.call(&"validation_errors")
		if errors_value is PackedStringArray:
			var errors: PackedStringArray = errors_value
			if not errors.is_empty():
				return false
	return true
