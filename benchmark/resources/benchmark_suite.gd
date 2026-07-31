extends Resource
class_name BenchmarkSuite

## Ordered collection of benchmark cases and the relative output directory
## they belong to. Execution and output writing remain controller concerns.

@export_category("Identity")
@export var id: StringName = &"default"
@export var display_name: String = "Default Benchmark Suite"

@export_category("Cases")
## Resource entries avoid class_name cache ordering failures when a .tres is
## loaded directly while sibling scripts are still being registered.
@export var cases: Array[Resource] = []

@export_category("Output")
@export var output_subdirectory: String = "default"


func validation_errors() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if String(id).strip_edges().is_empty():
		errors.append("id must not be empty")
	if display_name.strip_edges().is_empty():
		errors.append("display_name must not be empty")
	if output_subdirectory.strip_edges().is_empty():
		errors.append("output_subdirectory must not be empty")
	if output_subdirectory.contains("://"):
		errors.append("output_subdirectory must be relative")
	if output_subdirectory.find("..") >= 0:
		errors.append("output_subdirectory must not contain parent traversal")

	var case_ids: Dictionary = {}
	for index in cases.size():
		var benchmark_case: Resource = cases[index]
		if benchmark_case == null:
			errors.append("cases[%d] must be assigned" % index)
			continue

		var case_properties: Array[StringName] = [
			&"id", &"display_name", &"mode", &"variant", &"groom_id",
			&"camera_pose", &"lighting_rig", &"viewport_size",
			&"warmup_frames", &"settle_frames", &"sample_frames",
			&"capture_frames", &"repeat_count", &"capture_color",
			&"capture_depth", &"capture_tangent", &"capture_debug"
		]
		var case_errors: PackedStringArray = _validate_case_resource(benchmark_case, case_properties)
		for message_index in case_errors.size():
			var case_error: String = case_errors[message_index]
			errors.append("cases[%d]: %s" % [index, case_error])

		var case_id: String = _string_property(benchmark_case, &"id")
		if case_ids.has(case_id):
			errors.append("cases[%d] duplicates case id '%s'" % [index, case_id])
		else:
			case_ids[case_id] = true
	return errors


func is_valid() -> bool:
	return validation_errors().is_empty()


func _validate_case_resource(resource: Resource, required_properties: Array[StringName]) -> PackedStringArray:
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
			errors.append("missing property '%s'" % required_property)

	if not resource.has_method(&"validation_errors"):
		errors.append("must expose validation_errors()")
		return errors

	var validation_result: Variant = resource.call(&"validation_errors")
	if not (validation_result is PackedStringArray):
		errors.append("validation_errors() must return PackedStringArray")
		return errors

	var nested_errors: PackedStringArray = validation_result
	for error_index in nested_errors.size():
		var nested_error: String = nested_errors[error_index]
		errors.append(nested_error)
	return errors


func _string_property(resource: Resource, property_name: StringName) -> String:
	var value: Variant = resource.get(property_name)
	if value is StringName:
		return String(value)
	if value is String:
		return value
	return ""
