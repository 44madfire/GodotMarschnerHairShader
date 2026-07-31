extends Resource
class_name BenchmarkCameraPose

## Reproducible camera settings for a benchmark case. This resource stores
## data only; applying it to a Camera3D remains a controller concern.

@export_category("Identity")
@export var id: StringName = &"default"

@export_category("Camera")
@export var transform: Transform3D = Transform3D.IDENTITY
@export_range(1.0, 179.0, 0.1) var fov: float = 60.0
@export_range(0.001, 1000.0, 0.001) var near: float = 0.05
@export_range(0.01, 100000.0, 0.01) var far: float = 100.0


func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if String(id).strip_edges().is_empty():
		errors.append("id must not be empty")
	if fov <= 0.0 or fov >= 180.0:
		errors.append("fov must be greater than 0 and less than 180 degrees")
	if near <= 0.0:
		errors.append("near must be greater than 0")
	if far <= near:
		errors.append("far must be greater than near")
	return errors


func is_valid() -> bool:
	return validation_errors().is_empty()
