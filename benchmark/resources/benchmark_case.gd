extends Resource
class_name BenchmarkCase

## A single reproducible benchmark request. Mode and variant intentionally stay
## plain integers so this resource does not duplicate or depend on controller
## enums; their values are interpreted by the existing manual API later.

@export_category("Identity")
@export var id: StringName = &"representative_default"
@export var display_name: String = "Representative Default"

@export_category("Selection")
## Defaults match the current controller's REPRESENTATIVE_DEFAULT value.
@export var mode: int = 3
## Defaults match the current controller's CURRENT_MARSCHNER_BASELINE value.
@export var variant: int = 2
@export var groom_id: StringName = &"Blowout"

@export_category("Fixture")
## Resource is intentional here: typed class_name references can fail during
## direct .tres reload before the sibling scripts have been registered.
@export var camera_pose: Resource
@export var lighting_rig: Resource
@export var viewport_size: Vector2i = Vector2i(1280, 720)

@export_category("Timing")
@export_range(0, 100000, 1) var warmup_frames: int = 180
@export_range(0, 100000, 1) var settle_frames: int = 30
@export_range(1, 100000, 1) var sample_frames: int = 300
@export_range(1, 100, 1) var capture_frames: int = 1
@export_range(1, 1000, 1) var repeat_count: int = 1

@export_category("Capture")
## These flags describe future capture work; this resource does not implement it.
@export var capture_color: bool = true
## Coverage capture is opt-in so existing performance cases retain their defaults.
@export var capture_coverage: bool = false
@export var capture_depth: bool = false
@export var capture_tangent: bool = false
@export var capture_debug: bool = false


func validation_errors() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if String(id).strip_edges().is_empty():
		errors.append("id must not be empty")
	if display_name.strip_edges().is_empty():
		errors.append("display_name must not be empty")
	if mode < 0:
		errors.append("mode must be a non-negative controller integer")
	if variant < 0:
		errors.append("variant must be a non-negative controller integer")
	if viewport_size.x <= 0 or viewport_size.y <= 0:
		errors.append("viewport_size dimensions must be greater than 0")
	if warmup_frames < 0:
		errors.append("warmup_frames must not be negative")
	if settle_frames < 0:
		errors.append("settle_frames must not be negative")
	if sample_frames <= 0:
		errors.append("sample_frames must be greater than 0")
	if capture_frames <= 0:
		errors.append("capture_frames must be greater than 0")
	if repeat_count <= 0:
		errors.append("repeat_count must be greater than 0")
	if camera_pose == null:
		errors.append("camera_pose must be assigned")
	else:
		var camera_properties: Array[StringName] = [
			&"id", &"transform", &"fov", &"near", &"far"
		]
		var camera_errors: PackedStringArray = _validate_resource_reference(camera_pose, "camera_pose", camera_properties)
		for message_index in camera_errors.size():
			var camera_error: String = camera_errors[message_index]
			errors.append(camera_error)
	if lighting_rig == null:
		errors.append("lighting_rig must be assigned")
	else:
		var lighting_properties: Array[StringName] = [
			&"id", &"name", &"notes", &"packed_scene"
		]
		var lighting_errors: PackedStringArray = _validate_resource_reference(lighting_rig, "lighting_rig", lighting_properties)
		for message_index in lighting_errors.size():
			var lighting_error: String = lighting_errors[message_index]
			errors.append(lighting_error)
	return errors


func is_valid() -> bool:
	return validation_errors().is_empty()


func _validate_resource_reference(resource: Resource, label: String, required_properties: Array[StringName]) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	var property_list: Array[Dictionary] = resource.get_property_list()
	for property_index in required_properties.size():
		var required_property: StringName = required_properties[property_index]
		var found: bool = false
		for property_info_index in property_list.size():
			var property_info: Dictionary = property_list[property_info_index]
			var property_name: StringName = StringName(property_info.get("name", ""))
			if property_name == required_property:
				found = true
				break
		if not found:
			errors.append("%s is missing property '%s'" % [label, required_property])

	if not resource.has_method(&"validation_errors"):
		errors.append("%s must expose validation_errors()" % label)
		return errors

	var validation_result: Variant = resource.call(&"validation_errors")
	if not (validation_result is PackedStringArray):
		errors.append("%s validation_errors() must return PackedStringArray" % label)
		return errors

	var nested_errors: PackedStringArray = validation_result
	for error_index in nested_errors.size():
		var nested_error: String = nested_errors[error_index]
		errors.append("%s: %s" % [label, nested_error])
	return errors
