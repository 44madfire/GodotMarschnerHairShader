extends SceneTree

## Prepares direct ImageTexture3D counterparts for the production LUT resources.
##
## The benchmark compares the current raw-data Resource representation against
## Godot 4.7's directly serialized ImageTexture3D representation. Direct files
## are written under user:// so benchmark artifacts never modify the project.

const LUT_ADAPTER := preload("res://assets/hair/materials/HairMarschnerLUTAdapter.gd")

const FAST_RAW_PATH: String = "res://benchmark/resources/luts/unity_azimuthal_64.res"
const CINEMATIC_RAW_PATH: String = "res://benchmark/resources/luts/cinematic_longitudinal_kernel_128x128x64.res"
const FAST_DIRECT_PATH: String = "user://marschner_lut_storage_fast_direct.res"
const CINEMATIC_DIRECT_PATH: String = "user://marschner_lut_storage_cinematic_direct.res"


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.has("--cleanup"):
		quit(_cleanup())
		return

	var result: Dictionary = {
		"schema": "marschner_lut_storage_prep_v1",
		"fast": _prepare_one("fast", FAST_RAW_PATH, FAST_DIRECT_PATH),
		"cinematic": _prepare_one("cinematic", CINEMATIC_RAW_PATH, CINEMATIC_DIRECT_PATH),
	}
	if not bool(result.fast.get("ok", false)) or not bool(result.cinematic.get("ok", false)):
		push_error("LUT storage benchmark preparation failed")
		print("LUT_STORAGE_PREP_RESULT " + JSON.stringify(result))
		quit(1)
		return

	print("LUT_STORAGE_PREP_RESULT " + JSON.stringify(result))
	print("LUT_STORAGE_PREP_OK")
	quit(0)


func _prepare_one(kind: String, raw_path: String, direct_path: String) -> Dictionary:
	var out: Dictionary = {
		"ok": false,
		"kind": kind,
		"raw_path": raw_path,
		"direct_path": direct_path,
	}
	if not ResourceLoader.exists(raw_path):
		out["error"] = "missing raw LUT resource"
		return out

	var raw: Resource = ResourceLoader.load(raw_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if raw == null:
		out["error"] = "failed to load raw LUT resource"
		return out
	if raw.has_method(&"validation_errors"):
		var errors_value: Variant = raw.call(&"validation_errors")
		if errors_value is PackedStringArray:
			var errors: PackedStringArray = errors_value
			if not errors.is_empty():
				out["error"] = "raw LUT validation failed: %s" % "; ".join(errors)
				return out

	var adapter: RefCounted = LUT_ADAPTER.new()
	var texture: Texture3D = adapter.call(&"texture3d_from_resource", raw) as Texture3D
	if texture == null:
		out["error"] = "adapter failed to reconstruct Texture3D"
		return out

	var save_error: Error = ResourceSaver.save(texture, direct_path)
	if save_error != OK:
		out["error"] = "failed to save direct ImageTexture3D: %s" % error_string(save_error)
		return out

	var direct_resource: Resource = ResourceLoader.load(direct_path, "ImageTexture3D", ResourceLoader.CACHE_MODE_IGNORE)
	var direct: ImageTexture3D = direct_resource as ImageTexture3D
	if direct == null:
		out["error"] = "direct resource did not reload as ImageTexture3D"
		return out

	var sx: int = int(raw.get(&"size_x"))
	var sy: int = int(raw.get(&"size_y"))
	var sz: int = int(raw.get(&"size_z"))
	var format: int = int(raw.get(&"format"))
	if direct.get_width() != sx or direct.get_height() != sy or direct.get_depth() != sz:
		out["error"] = "direct resource dimensions differ from raw metadata"
		return out
	if direct.get_format() != format:
		out["error"] = "direct resource format differs from raw metadata"
		return out

	var raw_bytes_value: Variant = raw.get(&"data")
	if not (raw_bytes_value is PackedByteArray):
		out["error"] = "raw LUT data is not a PackedByteArray"
		return out
	var raw_bytes: PackedByteArray = raw_bytes_value
	var direct_bytes: PackedByteArray = _flatten_texture(direct)
	if direct_bytes != raw_bytes:
		out["error"] = "direct resource texel payload differs from raw LUT data"
		return out

	out["ok"] = true
	out["size_x"] = sx
	out["size_y"] = sy
	out["size_z"] = sz
	out["format"] = format
	out["contract"] = String(raw.get(&"contract"))
	out["payload_bytes"] = raw_bytes.size()
	out["raw_res_bytes"] = _file_size(raw_path)
	out["direct_res_bytes"] = _file_size(direct_path)
	return out


func _flatten_texture(texture: ImageTexture3D) -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray()
	var slices: Array[Image] = texture.get_data()
	for image in slices:
		if image == null:
			return PackedByteArray()
		bytes.append_array(image.get_data())
	return bytes


func _file_size(path: String) -> int:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return -1
	return file.get_length()


func _cleanup() -> int:
	var failed: bool = false
	for path in [FAST_DIRECT_PATH, CINEMATIC_DIRECT_PATH]:
		if FileAccess.file_exists(path):
			var error: Error = DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
			if error != OK:
				push_error("failed to remove %s: %s" % [path, error_string(error)])
				failed = true
	if failed:
		return 1
	print("LUT_STORAGE_PREP_CLEANUP_OK")
	return 0
