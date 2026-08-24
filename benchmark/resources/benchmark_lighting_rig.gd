extends Resource
class_name BenchmarkLightingRig

## Describes a lighting fixture without instantiating or controlling it.
## PackedScene support is data-only in Phase 1A.

@export_category("Identity")
@export var id: StringName = &"default"
@export var name: String = "Default"
@export_multiline var notes: String = ""

@export_category("Fixture")
@export var packed_scene: PackedScene


func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if String(id).strip_edges().is_empty():
		errors.append("id must not be empty")
	if name.strip_edges().is_empty():
		errors.append("name must not be empty")
	if packed_scene == null:
		errors.append("packed_scene must be assigned")
	return errors


func is_valid() -> bool:
	return validation_errors().is_empty()
