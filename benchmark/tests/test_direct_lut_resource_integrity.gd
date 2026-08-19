extends SceneTree
const LUT_ADAPTER := preload("res://addons/marschner_hair/hair_marschner_lut_adapter.gd")
const LEGACY_ADAPTER := preload("res://benchmark/resources/hair_marschner_legacy_lut_adapter.gd")
func _initialize() -> void:
	var adapter: RefCounted = LUT_ADAPTER.new()
	var failures := PackedStringArray()
	_check_one(adapter, "fast", LUT_ADAPTER.DEFAULT_UNITY_LUT_PATH, LEGACY_ADAPTER.LEGACY_UNITY_DATA_PATH, true, failures)
	_check_one(adapter, "cinematic", LUT_ADAPTER.DEFAULT_CINEMATIC_LUT_PATH, LEGACY_ADAPTER.LEGACY_CINEMATIC_DATA_PATH, false, failures)
	if not failures.is_empty():
		for failure in failures: push_error(failure)
		print("DIRECT_LUT_RESOURCE_INTEGRITY_FAILED"); quit(1); return
	print("DIRECT_LUT_RESOURCE_INTEGRITY_OK"); quit(0)
func _check_one(adapter: RefCounted, kind: String, direct_path: String, raw_path: String, is_fast: bool, failures: PackedStringArray) -> void:
	if not ResourceLoader.exists(direct_path): failures.append("%s direct LUT missing: %s" % [kind, direct_path]); return
	var loaded_resource: Resource = ResourceLoader.load(direct_path, "ImageTexture3D", ResourceLoader.CACHE_MODE_IGNORE)
	var texture: ImageTexture3D = loaded_resource as ImageTexture3D
	if texture == null: failures.append("%s direct LUT did not load as ImageTexture3D" % kind); return
	var errors: PackedStringArray = adapter.call(&"validate_unity_texture", texture, false) if is_fast else adapter.call(&"validate_cinematic_texture", texture, false)
	if not errors.is_empty(): failures.append("%s structural validation failed: %s" % [kind, "; ".join(errors)]); return
	if not ResourceLoader.exists(raw_path): failures.append("%s raw comparison LUT missing: %s" % [kind, raw_path]); return
	var raw: Resource = ResourceLoader.load(raw_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if raw == null: failures.append("%s raw comparison LUT failed to load" % kind); return
	if raw.has_method(&"validation_errors"):
		var raw_errors: PackedStringArray = raw.call(&"validation_errors")
		if not raw_errors.is_empty(): failures.append("%s raw comparison LUT invalid: %s" % [kind, "; ".join(raw_errors)]); return
	var raw_bytes_value: Variant = raw.get(&"data")
	if not (raw_bytes_value is PackedByteArray): failures.append("%s raw comparison resource has no byte payload" % kind); return
	var raw_bytes: PackedByteArray = raw_bytes_value
	var direct_bytes := _flatten_texture(texture)
	if direct_bytes != raw_bytes: failures.append("%s direct LUT texels differ from the validated raw source" % kind); return
	print("DIRECT_LUT_RESOURCE kind=%s contract=%s bytes=%d" % [kind, String(raw.get(&"contract")), direct_bytes.size()])
func _flatten_texture(texture: ImageTexture3D) -> PackedByteArray:
	var bytes := PackedByteArray()
	for image in texture.get_data():
		if image == null: return PackedByteArray()
		bytes.append_array(image.get_data())
	return bytes
