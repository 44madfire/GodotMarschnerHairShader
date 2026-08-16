extends Node
class_name HairCoverageController

var _entries: Array[Dictionary] = []

func register_material(profile: Resource, material: ShaderMaterial, viewport: Viewport = null) -> bool:
	if profile == null or material == null or not profile.has_method(&"update_coverage_for_viewport"):
		return false
	unregister_material(material)
	var target_viewport: Viewport = viewport if viewport != null else get_viewport()
	if not bool(profile.call(&"update_coverage_for_viewport", material, target_viewport, Engine.get_frames_drawn())):
		return false
	_entries.append({"profile": profile, "material": material, "viewport": viewport})
	set_process(true)
	return true

func unregister_material(material: ShaderMaterial) -> void:
	if material == null:
		return
	for index in range(_entries.size() - 1, -1, -1):
		if _entries[index].get("material") == material:
			_entries.remove_at(index)
	if _entries.is_empty():
		set_process(false)

func clear_materials() -> void:
	_entries.clear()
	set_process(false)

func _ready() -> void:
	set_process(not _entries.is_empty())

func _process(_delta: float) -> void:
	var rendered_frame_index: int = Engine.get_frames_drawn()
	for entry in _entries:
		var profile: Resource = entry.get("profile") as Resource
		var material: ShaderMaterial = entry.get("material") as ShaderMaterial
		var explicit_viewport: Viewport = entry.get("viewport") as Viewport
		if profile == null or material == null:
			continue
		var target_viewport: Viewport = explicit_viewport if explicit_viewport != null else get_viewport()
		profile.call(&"update_coverage_for_viewport", material, target_viewport, rendered_frame_index)
