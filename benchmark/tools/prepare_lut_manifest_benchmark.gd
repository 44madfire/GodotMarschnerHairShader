extends SceneTree
const Asset := preload("res://benchmark/resources/hair_marschner_lut_asset_benchmark.gd")
const KINDS := {"fast": ["res://benchmark/resources/luts/unity_azimuthal_64.res", "user://marschner_lut_storage_fast_direct.res", "user://marschner_lut_storage_fast_manifest.res"], "cinematic": ["res://benchmark/resources/luts/cinematic_longitudinal_kernel_128x128x64.res", "user://marschner_lut_storage_cinematic_direct.res", "user://marschner_lut_storage_cinematic_manifest.res"]}
func _initialize() -> void:
	if OS.get_cmdline_user_args().has("--cleanup"):
		for value in KINDS.values():
			var path: String = value[2]
			if FileAccess.file_exists(path): DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		print("LUT_MANIFEST_PREP_CLEANUP_OK"); quit(0); return
	var result := {"schema": "marschner_lut_manifest_prep_v1"}
	for kind in KINDS: result[kind] = _prepare(kind, KINDS[kind])
	print("LUT_MANIFEST_PREP_RESULT " + JSON.stringify(result))
	if not result.fast.ok or not result.cinematic.ok: quit(1); return
	print("LUT_MANIFEST_PREP_OK"); quit(0)
func _prepare(kind: String, paths: Array) -> Dictionary:
	var raw: Resource = ResourceLoader.load(paths[0], "", ResourceLoader.CACHE_MODE_IGNORE)
	var texture: Texture3D = ResourceLoader.load(paths[1], "ImageTexture3D", ResourceLoader.CACHE_MODE_IGNORE) as Texture3D
	if raw == null or texture == null: return {"ok": false, "error": "raw or direct resource missing"}
	var asset: Resource = Asset.new()
	for key in [&"contract", &"size_x", &"size_y", &"size_z", &"format", &"channels", &"notes", &"eta", &"beta_min", &"beta_max"]:
		var value: Variant = raw.get(key)
		if value != null: asset.set(key, value)
	asset.set(&"texture", texture)
	var errors: PackedStringArray = asset.call(&"validation_errors")
	if not errors.is_empty(): return {"ok": false, "error": "; ".join(errors)}
	var save_error := ResourceSaver.save(asset, paths[2])
	if save_error != OK: return {"ok": false, "error": error_string(save_error)}
	var loaded: Resource = ResourceLoader.load(paths[2], "", ResourceLoader.CACHE_MODE_IGNORE)
	if loaded == null: return {"ok": false, "error": "manifest reload failed"}
	var loaded_errors: PackedStringArray = loaded.call(&"validation_errors")
	var loaded_texture: Texture3D = loaded.get(&"texture") as Texture3D
	if not loaded_errors.is_empty() or loaded_texture == null or loaded_texture.resource_path != paths[1]: return {"ok": false, "error": "invalid external texture reference"}
	var file := FileAccess.open(paths[2], FileAccess.READ)
	return {"ok": true, "kind": kind, "manifest_path": paths[2], "manifest_res_bytes": file.get_length(), "direct_path": paths[1]}
