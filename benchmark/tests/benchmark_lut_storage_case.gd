extends SceneTree

## Measures one LUT storage path in a fresh Godot process.
##
## Modes:
##   raw    = load custom raw-data Resource, validate contract, reconstruct Texture3D
##   direct = load directly serialized ImageTexture3D and validate structural metadata
##
## Process startup is intentionally outside the timed region. The Python runner
## launches one process per sample to avoid ResourceLoader and adapter cache hits.

const LUT_ADAPTER := preload("res://benchmark/resources/hair_marschner_legacy_lut_adapter.gd")

const FAST_RAW_PATH: String = "res://benchmark/resources/luts/unity_azimuthal_64.res"
const CINEMATIC_RAW_PATH: String = "res://benchmark/resources/luts/cinematic_longitudinal_kernel_128x128x64.res"
const FAST_DIRECT_PATH: String = "user://marschner_lut_storage_fast_direct.res"
const CINEMATIC_DIRECT_PATH: String = "user://marschner_lut_storage_cinematic_direct.res"


func _initialize() -> void:
	var kind: String = ""
	var mode: String = ""
	for arg_value in OS.get_cmdline_user_args():
		var arg: String = String(arg_value)
		if arg.begins_with("--kind="):
			kind = arg.trim_prefix("--kind=")
		elif arg.begins_with("--mode="):
			mode = arg.trim_prefix("--mode=")

	if kind != "fast" and kind != "cinematic":
		push_error("--kind must be fast or cinematic")
		quit(2)
		return
	if mode != "raw" and mode != "direct":
		push_error("--mode must be raw or direct")
		quit(2)
		return

	var result: Dictionary = _measure_raw(kind) if mode == "raw" else _measure_direct(kind)
	if not bool(result.get("ok", false)):
		push_error("LUT storage benchmark case failed: %s" % String(result.get("error", "unknown error")))
		print("LUT_STORAGE_BENCHMARK_RESULT " + JSON.stringify(result))
		quit(1)
		return

	print("LUT_STORAGE_BENCHMARK_RESULT " + JSON.stringify(result))
	quit(0)


func _measure_raw(kind: String) -> Dictionary:
	var path: String = _raw_path(kind)
	var result: Dictionary = _base_result(kind, "raw", path)
	if not ResourceLoader.exists(path):
		result["error"] = "missing raw LUT resource"
		return result

	var start_us: int = Time.get_ticks_usec()
	var raw: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	var loaded_us: int = Time.get_ticks_usec()
	if raw == null:
		result["error"] = "failed to load raw LUT resource"
		return result

	if raw.has_method(&"validation_errors"):
		var errors_value: Variant = raw.call(&"validation_errors")
		if errors_value is PackedStringArray:
			var errors: PackedStringArray = errors_value
			if not errors.is_empty():
				result["error"] = "raw LUT validation failed: %s" % "; ".join(errors)
				return result
	var validated_us: int = Time.get_ticks_usec()

	var adapter: RefCounted = LUT_ADAPTER.new()
	var texture: Texture3D = adapter.call(&"texture3d_from_resource", raw) as Texture3D
	var ready_us: int = Time.get_ticks_usec()
	if texture == null or not texture.get_rid().is_valid():
		result["error"] = "raw LUT failed to reconstruct a usable Texture3D"
		return result

	result["ok"] = true
	result["resource_load_us"] = loaded_us - start_us
	result["validation_us"] = validated_us - loaded_us
	result["texture_build_us"] = ready_us - validated_us
	result["ready_us"] = ready_us - start_us
	result["size_x"] = texture.get_width()
	result["size_y"] = texture.get_height()
	result["size_z"] = texture.get_depth()
	result["format"] = texture.get_format()
	result["contract"] = String(raw.get(&"contract"))
	return result


func _measure_direct(kind: String) -> Dictionary:
	var path: String = _direct_path(kind)
	var result: Dictionary = _base_result(kind, "direct", path)
	if not ResourceLoader.exists(path):
		result["error"] = "missing prepared direct ImageTexture3D resource"
		return result

	var start_us: int = Time.get_ticks_usec()
	var loaded_resource: Resource = ResourceLoader.load(path, "ImageTexture3D", ResourceLoader.CACHE_MODE_IGNORE)
	var loaded_us: int = Time.get_ticks_usec()
	var texture: ImageTexture3D = loaded_resource as ImageTexture3D
	if texture == null:
		result["error"] = "direct resource did not load as ImageTexture3D"
		return result

	var expected: Dictionary = _expected_metadata(kind)
	if texture.get_width() != int(expected["size_x"]) or texture.get_height() != int(expected["size_y"]) or texture.get_depth() != int(expected["size_z"]):
		result["error"] = "direct ImageTexture3D dimensions do not match production LUT"
		return result
	if texture.get_format() != int(expected["format"]):
		result["error"] = "direct ImageTexture3D format does not match production LUT"
		return result
	var validated_us: int = Time.get_ticks_usec()

	var rid_valid: bool = texture.get_rid().is_valid()
	var ready_us: int = Time.get_ticks_usec()
	if not rid_valid:
		result["error"] = "direct ImageTexture3D has no valid RID"
		return result

	result["ok"] = true
	result["resource_load_us"] = loaded_us - start_us
	result["validation_us"] = validated_us - loaded_us
	result["texture_build_us"] = ready_us - validated_us
	result["ready_us"] = ready_us - start_us
	result["size_x"] = texture.get_width()
	result["size_y"] = texture.get_height()
	result["size_z"] = texture.get_depth()
	result["format"] = texture.get_format()
	result["contract"] = String(expected["contract"])
	return result


func _base_result(kind: String, mode: String, path: String) -> Dictionary:
	return {
		"schema": "marschner_lut_storage_case_v1",
		"ok": false,
		"kind": kind,
		"mode": mode,
		"path": path,
		"godot_version": Engine.get_version_info().get("string", "unknown"),
		"os": OS.get_name(),
	}


func _raw_path(kind: String) -> String:
	return FAST_RAW_PATH if kind == "fast" else CINEMATIC_RAW_PATH


func _direct_path(kind: String) -> String:
	return FAST_DIRECT_PATH if kind == "fast" else CINEMATIC_DIRECT_PATH


func _expected_metadata(kind: String) -> Dictionary:
	if kind == "fast":
		return {
			"size_x": 64,
			"size_y": 64,
			"size_z": 64,
			"format": Image.FORMAT_RGBAH,
			"contract": "unity_hdrp_azimuthal_n_v1",
		}
	return {
		"size_x": 128,
		"size_y": 128,
		"size_z": 64,
		"format": Image.FORMAT_RH,
		"contract": "deon_physical_longitudinal_log2q_v2",
	}
