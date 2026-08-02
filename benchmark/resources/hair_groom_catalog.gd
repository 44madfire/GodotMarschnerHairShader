extends Resource
class_name HairGroomCatalog

## Ordered, resource-backed catalog of stable groom definitions. The controller
## merges display metadata from this catalog into its runtime groom catalog
## (keyed by groom_id); the future adapter resolves groom_root paths and applies
## the expected_material_profile per groom.

@export_category("Identity")
@export var catalog_id: StringName = &"hair_groom_catalog"
@export var display_name: String = "Hair groom catalog"
@export var notes: String = ""

@export_category("Grooms")
## Resource entries (HairGroomDefinition). Resource typing avoids class_name
## cache ordering failures when a .tres is loaded directly while sibling
## scripts are still being registered.
@export var groom_definitions: Array[Resource] = []


func validation_errors() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if String(catalog_id).strip_edges().is_empty():
		errors.append("catalog_id must not be empty")
	var seen_ids: Dictionary = {}
	for definition_index in groom_definitions.size():
		var definition: Resource = groom_definitions[definition_index]
		if not definition:
			errors.append("groom_definitions[%d] is missing" % definition_index)
			continue
		var groom_id_value: Variant = definition.get(&"groom_id")
		if groom_id_value is StringName or groom_id_value is String:
			var groom_id := StringName(groom_id_value)
			if seen_ids.has(groom_id):
				errors.append("duplicate groom_id '%s'" % groom_id)
			seen_ids[groom_id] = true
		if not definition.has_method(&"validation_errors"):
			errors.append("groom_definitions[%d] must expose validation_errors()" % definition_index)
			continue
		var nested_value: Variant = definition.call(&"validation_errors")
		if not (nested_value is PackedStringArray):
			errors.append("groom_definitions[%d] validation_errors() must return PackedStringArray" % definition_index)
			continue
		var nested_errors: PackedStringArray = nested_value
		for nested_error in nested_errors:
			errors.append("groom_definitions[%d]: %s" % [definition_index, String(nested_error)])
	return errors


func is_valid() -> bool:
	return validation_errors().is_empty()
