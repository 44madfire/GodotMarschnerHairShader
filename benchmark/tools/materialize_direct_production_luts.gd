extends SceneTree

## Materializes the validated benchmark raw LUTs as the direct ImageTexture3D
## resources consumed by production. The raw generators remain the numerical
## source of truth; this step changes serialization only.

const LUT_ADAPTER := preload("res://addons/marschner_hair/hair_marschner_lut_adapter.gd")
const LEGACY_ADAPTER := preload("res://benchmark/resources/hair_marschner_legacy_lut_adapter.gd")

func _initialize() -> void:
	var adapter: RefCounted = LUT_ADAPTER.new()
	var legacy_adapter: RefCounted = LEGACY_ADAPTER.new()
	var result := {
		"schema": "marschner_direct_lut_materialization_v1",
		"fast": _materialize_one(adapter, legacy_adapter, "fast", legacy_adapter.call(&"load_default_unity_data") as Resource, LUT_ADAPTER.DEFAULT_UNITY_LUT_PATH, true),
		"cinematic": _materialize_one(adapter, legacy_adapter, "cinematic", legacy_adapter.call(&"load_default_cinematic_data") as Resource, LUT_ADAPTER.DEFAULT_CINEMATIC_LUT_PATH, false),
	}
	print("DIRECT_LUT_MATERIALIZATION_RESULT " + JSON.stringify(result))
	if not bool(result.fast.get("ok", false)) or not bool(result.cinematic.get("ok", false)):
		push_error("Direct production LUT materialization failed. Generate the benchmark raw LUTs first if they are missing.")
		quit(1)
		return
	print("DIRECT_LUT_MATERIALIZATION_OK")
	quit(0)

func _materialize_one(adapter: RefCounted, legacy_adapter: RefCounted, kind: String, raw: Resource, out_path: String, is_fast: bool) -> Dictionary:
	var out := {"ok": false, "kind": kind, "path": out_path}
	if raw == null:
		out["error"] = "validated raw source LUT is missing"
		return out
	if raw.has_method(&"validation_errors"):
		var raw_errors_value: Variant = raw.call(&"validation_errors")
		if raw_errors_value is PackedStringArray:
			var raw_errors: PackedStringArray = raw_errors_value
			if not raw_errors.is_empty():
				out["error"] = "raw LUT invalid: %s" % "; ".join(raw_errors)
				return out
	var texture: Texture3D = legacy_adapter.call(&"texture3d_from_resource", raw) as Texture3D
	if texture == null:
		out["error"] = "raw LUT could not be reconstructed"
		return out
	var structural_errors: PackedStringArray = adapter.call(&"validate_unity_texture", texture, false) if is_fast else adapter.call(&"validate_cinematic_texture", texture, false)
	if not structural_errors.is_empty():
		out["error"] = "reconstructed texture invalid: %s" % "; ".join(structural_errors)
		return out
	var save_error := ResourceSaver.save(texture, out_path)
	if save_error != OK:
		out["error"] = "ResourceSaver.save failed: %s" % error_string(save_error)
		return out
	var loaded_resource: Resource = ResourceLoader.load(out_path, "ImageTexture3D", ResourceLoader.CACHE_MODE_IGNORE)
	var loaded: ImageTexture3D = loaded_resource as ImageTexture3D
	if loaded == null:
		out["error"] = "saved LUT did not reload as ImageTexture3D"
		return out
	structural_errors = adapter.call(&"validate_unity_texture", loaded, false) if is_fast else adapter.call(&"validate_cinematic_texture", loaded, false)
	if not structural_errors.is_empty():
		out["error"] = "reloaded texture invalid: %s" % "; ".join(structural_errors)
		return out
	var raw_bytes_value: Variant = raw.get(&"data")
	if not (raw_bytes_value is PackedByteArray):
		out["error"] = "raw source has no PackedByteArray payload"
		return out
	var raw_bytes: PackedByteArray = raw_bytes_value
	var direct_bytes := _flatten_texture(loaded)
	if direct_bytes != raw_bytes:
		out["error"] = "direct ImageTexture3D payload differs from raw source"
		return out
	out["ok"] = true
	out["contract"] = String(raw.get(&"contract"))
	out["size_x"] = loaded.get_width()
	out["size_y"] = loaded.get_height()
	out["size_z"] = loaded.get_depth()
	out["format"] = loaded.get_format()
	out["payload_bytes"] = direct_bytes.size()
	out["resource_bytes"] = _file_size(out_path)
	return out

func _flatten_texture(texture: ImageTexture3D) -> PackedByteArray:
	var bytes := PackedByteArray()
	for image in texture.get_data():
		if image == null:
			return PackedByteArray()
		bytes.append_array(image.get_data())
	return bytes

func _file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_length() if file != null else -1
