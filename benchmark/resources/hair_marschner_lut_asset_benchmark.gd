@tool
extends Resource
class_name HairMarschnerLUTAssetBenchmark

@export var contract: String = ""
@export var texture: Texture3D
@export var size_x: int = 0
@export var size_y: int = 0
@export var size_z: int = 0
@export var format: int = -1
@export var eta: float = 0.0
@export var beta_min: float = 0.0
@export var beta_max: float = 0.0
@export var channels: String = ""
@export var notes: String = ""

func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if contract.is_empty(): errors.append("contract must not be empty")
	if texture == null:
		errors.append("texture must not be null")
		return errors
	if size_x <= 0 or size_y <= 0 or size_z <= 0: errors.append("all dimensions must be > 0")
	if texture.get_width() != size_x or texture.get_height() != size_y or texture.get_depth() != size_z: errors.append("texture dimensions do not match manifest metadata")
	if texture.get_format() != format: errors.append("texture format does not match manifest metadata")
	match contract:
		"unity_hdrp_azimuthal_n_v1":
			if not is_finite(eta) or eta <= 1.0: errors.append("Fast LUT eta must be finite and > 1")
			if channels != "R=N_R,G=N_TT,B=N_TRT,A=1": errors.append("unexpected Fast LUT channel contract")
		"deon_physical_longitudinal_log2q_v2":
			if not is_finite(beta_min) or not is_finite(beta_max) or beta_min <= 0.0 or beta_max <= beta_min: errors.append("Cinematic beta range is invalid")
			if channels != "R=log2(Q)": errors.append("unexpected Cinematic LUT channel contract")
		_:
			errors.append("unsupported LUT contract: %s" % contract)
	return errors

func is_valid() -> bool:
	return validation_errors().is_empty()
