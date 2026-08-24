extends RefCounted

## Legacy development-benchmark LUT helpers.
##
## These reproduce the former PackedByteArray -> ImageTexture3D reconstruction
## path used by the LUT storage benchmark and the direct-LUT materialization
## tools. Production binding uses the packaged addon adapter
## (res://addons/marschner_hair/hair_marschner_lut_adapter.gd), which loads the
## directly serialized ImageTexture3D resources under
## res://addons/marschner_hair/luts/. This script intentionally declares no
## class_name: it is benchmark validation only and is always preloaded by path.

const LEGACY_UNITY_DATA_PATH: String = "res://benchmark/resources/luts/unity_azimuthal_64.res"
const LEGACY_CINEMATIC_DATA_PATH: String = "res://benchmark/resources/luts/cinematic_longitudinal_kernel_128x128x64.res"

const UNITY_CONTRACT: String = "unity_hdrp_azimuthal_n_v1"
const CINEMATIC_CONTRACT: String = "deon_physical_longitudinal_log2q_v2"


## Legacy benchmark API. New production code should use the addon adapter's
## load_default_unity_texture().
func load_default_unity_data() -> Resource:
	return _load_legacy_checked(LEGACY_UNITY_DATA_PATH, UNITY_CONTRACT)


## Legacy benchmark API. New production code should use the addon adapter's
## load_default_cinematic_texture().
func load_default_cinematic_data() -> Resource:
	return _load_legacy_checked(LEGACY_CINEMATIC_DATA_PATH, CINEMATIC_CONTRACT)


## Legacy development-benchmark compatibility only. Production binding never
## enters this raw-data reconstruction path when the packaged direct LUTs are
## present.
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
