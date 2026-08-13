extends SceneTree
const PATHS := {"fast": "user://marschner_lut_storage_fast_manifest.res", "cinematic": "user://marschner_lut_storage_cinematic_manifest.res"}
func _initialize() -> void:
	var kind := ""
	for value in OS.get_cmdline_user_args():
		var arg := String(value)
		if arg.begins_with("--kind="): kind = arg.trim_prefix("--kind=")
	if not PATHS.has(kind): push_error("--kind must be fast or cinematic"); quit(2); return
	var path: String = PATHS[kind]
	var start_us := Time.get_ticks_usec()
	var asset: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	var loaded_us := Time.get_ticks_usec()
	if asset == null or not asset.has_method(&"validation_errors"): _fail(kind, path, "manifest load failed"); return
	var errors: PackedStringArray = asset.call(&"validation_errors")
	var validated_us := Time.get_ticks_usec()
	if not errors.is_empty(): _fail(kind, path, "; ".join(errors)); return
	var texture: Texture3D = asset.get(&"texture") as Texture3D
	var rid_ok := texture != null and texture.get_rid().is_valid()
	var ready_us := Time.get_ticks_usec()
	if not rid_ok: _fail(kind, path, "manifest texture RID invalid"); return
	var result := {"schema":"marschner_lut_storage_case_v1","ok":true,"kind":kind,"mode":"manifest","path":path,"resource_load_us":loaded_us-start_us,"validation_us":validated_us-loaded_us,"texture_build_us":ready_us-validated_us,"ready_us":ready_us-start_us,"size_x":texture.get_width(),"size_y":texture.get_height(),"size_z":texture.get_depth(),"format":texture.get_format(),"contract":String(asset.get(&"contract")),"godot_version":Engine.get_version_info().get("string","unknown"),"os":OS.get_name()}
	print("LUT_STORAGE_BENCHMARK_RESULT " + JSON.stringify(result)); quit(0)
func _fail(kind: String, path: String, error: String) -> void:
	print("LUT_STORAGE_BENCHMARK_RESULT " + JSON.stringify({"schema":"marschner_lut_storage_case_v1","ok":false,"kind":kind,"mode":"manifest","path":path,"error":error})); quit(1)
