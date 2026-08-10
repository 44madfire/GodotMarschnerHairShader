@tool
extends Node3D
class_name HairMaterialProfilePreview

## Editor-facing preview for one HairMaterialProfile and HairGroomData pair.
##
## New grooms should supply their generated coords/attributes textures through
## HairGroomData. groom_source_material remains an optional migration/fallback
## path for older generated materials and is never edited directly.

const PREVIEW_ROOT_PATH: NodePath = NodePath("HairPreview")
const PREVIEW_EXPOSURE_GAIN: float = 1.1

@export_category("Hair Setup")
@export var material_profile: HairMaterialProfile:
	set(value):
		if material_profile == value:
			return
		material_profile = value
		_preview_signature = ""
		_queue_preview_refresh()

## Groom-specific generated card textures. This is the preferred way to supply
## coords_texture and attributes_texture for a new groom.
@export var groom_data: Resource:
	set(value):
		if groom_data == value:
			return
		groom_data = value
		_preview_signature = ""
		_queue_preview_refresh()

@export_category("Legacy / Preview Fallback")
## Optional existing ShaderMaterial used as a starting point. This keeps older
## generated grooms working while their texture bindings are migrated into a
## HairGroomData resource.
@export var groom_source_material: ShaderMaterial

## Select the HairMaterialProfile resource above, then change its quality tier.
## The visible groom refreshes in the editor without entering play mode.
@export_multiline var editor_instructions: String = "Assign a HairMaterialProfile and HairGroomData. Change quality_tier to compare Approx, Fast, Cinematic, and Reference in the editor viewport."

var _preview_mesh: MeshInstance3D
var _source_material: ShaderMaterial
var _preview_material: ShaderMaterial
var _preview_signature: String = ""
var _last_warning_signature: String = ""
var _refresh_queued: bool = false


func _ready() -> void:
	set_process(true)
	_queue_preview_refresh()


func _process(_delta: float) -> void:
	if material_profile == null:
		return
	var current_signature: String = _make_preview_signature()
	if current_signature != _preview_signature:
		_refresh_preview()


func _queue_preview_refresh() -> void:
	if not is_inside_tree() or _refresh_queued:
		return
	_refresh_queued = true
	call_deferred("_refresh_preview")


func _refresh_preview() -> void:
	_refresh_queued = false
	if material_profile == null:
		return

	var resolved_mesh: MeshInstance3D = _resolve_preview_mesh()
	if resolved_mesh == null:
		return
	if resolved_mesh != _preview_mesh:
		_preview_mesh = resolved_mesh
		_source_material = null
		_preview_material = null

	var source_material: ShaderMaterial = groom_source_material
	if source_material == null:
		source_material = resolved_mesh.material_override as ShaderMaterial

	if source_material != _source_material or _preview_material == null:
		_source_material = source_material
		if source_material != null:
			_preview_material = source_material.duplicate() as ShaderMaterial
		else:
			_preview_material = ShaderMaterial.new()
		if _preview_material == null:
			push_warning("HairMaterialProfilePreview could not create a local groom material.")
			return

	# material_override belongs to this preview instance. Imported materials and
	# source materials remain untouched while the profile switches variants.
	resolved_mesh.material_override = _preview_material
	var applied: bool = material_profile.apply_to(_preview_material, groom_data)
	_apply_preview_material_defaults()
	var current_signature: String = _make_preview_signature()
	_preview_signature = current_signature

	var has_groom_textures: bool = _has_required_groom_textures(_preview_material)
	if applied and has_groom_textures:
		_last_warning_signature = ""
	elif current_signature != _last_warning_signature:
		_last_warning_signature = current_signature
		if not has_groom_textures:
			push_warning("Hair preview needs coords_texture and attributes_texture. Assign a HairGroomData resource for a new groom.")
		else:
			push_warning("HairMaterialProfilePreview could not bind every resource for the selected tier. Fast and Cinematic need their generated LUT resources.")


func _apply_preview_material_defaults() -> void:
	if _preview_material == null or _preview_material.shader == null:
		return

	var uniform_names: Dictionary = {}
	for uniform_value in _preview_material.shader.get_shader_uniform_list():
		var uniform: Dictionary = uniform_value
		var uniform_name: StringName = StringName(uniform.get("name", ""))
		if uniform_name != &"":
			uniform_names[uniform_name] = true

	# These are presentation-only controls exposed by the compiled preview
	# variants. Keep them on the local copy so profile/groom resources remain the
	# source of truth for authoring values.
	if uniform_names.has(&"freeze_bayer_phase"):
		_preview_material.set_shader_parameter(&"freeze_bayer_phase", true)
	if uniform_names.has(&"comparison_exposure_gain"):
		_preview_material.set_shader_parameter(&"comparison_exposure_gain", PREVIEW_EXPOSURE_GAIN)


func _has_required_groom_textures(material: ShaderMaterial) -> bool:
	if material == null or material.shader == null:
		return false
	var coords_value: Variant = material.get_shader_parameter(&"coords_texture")
	var attributes_value: Variant = material.get_shader_parameter(&"attributes_texture")
	return coords_value is Texture2D and attributes_value is Texture2D


func _resolve_preview_mesh() -> MeshInstance3D:
	var preview_root: Node = get_node_or_null(PREVIEW_ROOT_PATH)
	if preview_root == null:
		return null
	if preview_root is MeshInstance3D:
		return preview_root as MeshInstance3D

	var descendants: Array[Node] = preview_root.find_children("*", "MeshInstance3D", true, false)
	for descendant in descendants:
		var mesh_instance: MeshInstance3D = descendant as MeshInstance3D
		if mesh_instance != null and mesh_instance.mesh != null:
			return mesh_instance
	return null


func _make_preview_signature() -> String:
	var values: PackedStringArray = PackedStringArray()
	values.append(_make_profile_signature())
	if groom_data == null:
		values.append("groom=null")
	else:
		values.append("groom=%d" % groom_data.get_instance_id())
		values.append("coords=%s" % _value_signature(groom_data.get(&"coords_texture")))
		values.append("attributes=%s" % _value_signature(groom_data.get(&"attributes_texture")))
	values.append("source=%s" % _value_signature(groom_source_material))
	return "|".join(values)


func _make_profile_signature() -> String:
	if material_profile == null:
		return "profile=null"

	var values: PackedStringArray = PackedStringArray()
	var properties: Array[Dictionary] = material_profile.get_property_list()
	for property_info in properties:
		var usage: int = int(property_info.get("usage", 0))
		if (usage & PROPERTY_USAGE_STORAGE) == 0:
			continue
		var property_name: StringName = StringName(property_info.get("name", ""))
		if property_name == &"script":
			continue
		values.append("%s=%s" % [String(property_name), _value_signature(material_profile.get(property_name))])
	return "|".join(values)


func _value_signature(value: Variant) -> String:
	if value is Resource:
		var resource_value: Resource = value as Resource
		return "resource:%s:%d" % [resource_value.resource_path, resource_value.get_instance_id()]
	return var_to_str(value)
