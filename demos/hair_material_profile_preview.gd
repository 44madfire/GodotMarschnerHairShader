@tool
extends Node3D
class_name HairMaterialProfilePreview

## Editor-facing preview for one HairMaterialProfile + HairGroomData pair.
## Existing ShaderMaterials can still be supplied as a migration fallback, but
## the profile and groom resources are the preferred release workflow.

const PREVIEW_ROOT_PATH := NodePath("HairPreview")
const PREVIEW_EXPOSURE_GAIN: float = 1.1
const APPROX_ALBEDO_GAIN := Vector3(0.979, 1.158, 1.162)
const ShaderUtils := preload("res://addons/marschner_hair/internal/hair_shader_utils.gd")

@export_category("Hair Setup")
@export var material_profile: HairMaterialProfile:
	set(value):
		if material_profile == value:
			return
		material_profile = value
		_preview_signature = ""
		_queue_preview_refresh()

## Groom-specific generated card textures.
@export var groom_data: Resource:
	set(value):
		if groom_data == value:
			return
		groom_data = value
		_preview_signature = ""
		_queue_preview_refresh()

@export_category("Legacy / Preview Fallback")
## Optional existing ShaderMaterial used only as the local preview starting point.
@export var groom_source_material: ShaderMaterial

@export_multiline var editor_instructions: String = "Assign a HairMaterialProfile and HairGroomData. Change quality_tier to compare Approx, Fast Marschner, and Cinematic Marschner in the editor viewport."

var _preview_mesh: MeshInstance3D
var _source_material: ShaderMaterial
var _preview_material: ShaderMaterial
var _preview_signature: String = ""
var _last_warning_signature: String = ""
var _refresh_queued: bool = false


func _validate_property(property: Dictionary) -> void:
	if StringName(property.get("name", "")) == &"groom_data":
		property["hint"] = PROPERTY_HINT_RESOURCE_TYPE
		property["hint_string"] = "HairGroomData"


func _ready() -> void:
	set_process(true)
	_queue_preview_refresh()


func _process(_delta: float) -> void:
	if material_profile == null:
		return
	if _make_preview_signature() != _preview_signature:
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

	var resolved_mesh := _resolve_preview_mesh()
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
		_preview_material = source_material.duplicate() as ShaderMaterial if source_material != null else ShaderMaterial.new()
		if _preview_material == null:
			push_warning("HairMaterialProfilePreview could not create a local groom material.")
			return

	resolved_mesh.material_override = _preview_material
	var applied: bool = material_profile.apply_to(_preview_material, groom_data)
	_apply_preview_material_defaults()

	var current_signature := _make_preview_signature()
	_preview_signature = current_signature
	var has_groom_textures := _has_required_groom_textures(_preview_material)
	if applied and has_groom_textures:
		_last_warning_signature = ""
	elif current_signature != _last_warning_signature:
		_last_warning_signature = current_signature
		if not has_groom_textures:
			push_warning("Hair preview needs coords_texture and attributes_texture. Assign a HairGroomData resource.")
		else:
			push_warning("HairMaterialProfilePreview could not bind every resource required by the selected tier.")


func _apply_preview_material_defaults() -> void:
	if _preview_material == null or _preview_material.shader == null:
		return
	var uniform_names: Dictionary = ShaderUtils.uniform_names(_preview_material.shader)
	if uniform_names.has(&"comparison_exposure_gain"):
		_preview_material.set_shader_parameter(&"comparison_exposure_gain", PREVIEW_EXPOSURE_GAIN)

	# Approx multiplies its highlight colors by ALBEDO. These preview-only values
	# keep the comparison scene calibrated without modifying the profile resource.
	if material_profile != null and material_profile.quality_tier == HairMaterialProfile.QualityTier.APPROX:
		if uniform_names.has(&"primary_color"):
			_preview_material.set_shader_parameter(&"primary_color", Color.WHITE)
		if uniform_names.has(&"secondary_color"):
			_preview_material.set_shader_parameter(&"secondary_color", Color.WHITE)
		if uniform_names.has(&"albedo"):
			var authored := material_profile.albedo
			_preview_material.set_shader_parameter(&"albedo", Color(
				clampf(authored.r * APPROX_ALBEDO_GAIN.x, 0.0, 1.0),
				clampf(authored.g * APPROX_ALBEDO_GAIN.y, 0.0, 1.0),
				clampf(authored.b * APPROX_ALBEDO_GAIN.z, 0.0, 1.0),
				authored.a))


func _has_required_groom_textures(material: ShaderMaterial) -> bool:
	if material == null or material.shader == null:
		return false
	return material.get_shader_parameter(&"coords_texture") is Texture2D \
		and material.get_shader_parameter(&"attributes_texture") is Texture2D


func _resolve_preview_mesh() -> MeshInstance3D:
	var preview_root := get_node_or_null(PREVIEW_ROOT_PATH)
	if preview_root == null:
		return null
	if preview_root is MeshInstance3D:
		return preview_root as MeshInstance3D
	for descendant in preview_root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := descendant as MeshInstance3D
		if mesh_instance != null and mesh_instance.mesh != null:
			return mesh_instance
	return null


func _make_preview_signature() -> String:
	var values := PackedStringArray([_make_profile_signature()])
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
	var values := PackedStringArray()
	for property_info in material_profile.get_property_list():
		if (int(property_info.get("usage", 0)) & PROPERTY_USAGE_STORAGE) == 0:
			continue
		var property_name := StringName(property_info.get("name", ""))
		if property_name == &"script":
			continue
		values.append("%s=%s" % [String(property_name), _value_signature(material_profile.get(property_name))])
	return "|".join(values)


func _value_signature(value: Variant) -> String:
	if value is Resource:
		var resource_value := value as Resource
		return "resource:%s:%d" % [resource_value.resource_path, resource_value.get_instance_id()]
	return var_to_str(value)
