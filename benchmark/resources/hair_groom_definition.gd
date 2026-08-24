extends Resource
class_name HairGroomDefinition

## Stable definition of one hair groom for the benchmark harness. Definitions are
## scene-agnostic contracts: groom_root is resolved relative to the Head node by
## the future adapter, so these resources never touch imported scenes or their
## materials. Surface selection is explicit by contract: a definition must name
## the exact mesh surfaces that carry hair material.

@export_category("Identity")
## Stable identifier used by cases, profiles, and the controller catalog. Must
## match the groom node name under Head (e.g. &"Blowout") and must never be a
## transient instance id.
@export var groom_id: StringName = &""
@export var display_name: String = ""
## Style family, e.g. "bangs", "afro", "curly".
@export var category: String = ""

@export_category("Scene Selection")
## Path of the groom node relative to the Head node (e.g. NodePath("Blowout")).
@export var groom_root: NodePath = NodePath()
## Paths of the hair MeshInstance3D nodes relative to groom_root; usually
## NodePath(".") when the groom node is itself the mesh.
@export var hair_mesh_paths: Array[NodePath] = [NodePath(".")]
## Explicit mesh surfaces that carry hair material. Selection must be explicit,
## never an implicit "all surfaces".
@export var hair_surface_indices: Array[int] = []

@export_category("Profile")
## profile_id of the canonical HairBenchmarkProfile expected for this groom.
@export var expected_material_profile: StringName = &""

@export_category("Documentation")
@export var notes: String = ""


func validation_errors() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if String(groom_id).strip_edges().is_empty():
		errors.append("groom_id must not be empty")
	elif not _is_stable_identifier(String(groom_id)):
		errors.append("groom_id '%s' is not a stable identifier: only ASCII letters, digits, and underscores are allowed" % groom_id)
	if display_name.strip_edges().is_empty():
		errors.append("display_name must not be empty")
	if groom_root.is_empty():
		errors.append("groom_root must be assigned")
	if hair_mesh_paths.is_empty():
		errors.append("hair_mesh_paths must not be empty")
	if hair_surface_indices.is_empty():
		errors.append("hair_surface_indices must be explicit: at least one surface must be selected")
	else:
		var seen_surfaces: Dictionary = {}
		for surface_index in hair_surface_indices:
			if surface_index < 0:
				errors.append("hair_surface_indices must not contain negative values")
				continue
			if seen_surfaces.has(surface_index):
				errors.append("hair_surface_indices contains duplicate surface %d" % surface_index)
			seen_surfaces[surface_index] = true
	if String(expected_material_profile).strip_edges().is_empty():
		errors.append("expected_material_profile must not be empty")
	return errors


func is_valid() -> bool:
	return validation_errors().is_empty()


func _is_stable_identifier(value: String) -> bool:
	for character_index in value.length():
		var character := value[character_index]
		if not (character >= "a" and character <= "z") and not (character >= "A" and character <= "Z") and not (character >= "0" and character <= "9") and character != "_":
			return false
	return true
