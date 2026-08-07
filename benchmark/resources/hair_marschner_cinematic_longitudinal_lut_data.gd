extends Resource
class_name HairMarschnerCinematicLongitudinalLUTData

## Generic energy-conserving longitudinal kernel over a fully physical domain.
## X = sin(theta_cone) in [-1,1]
## Y = sin(theta_o) in [-1,1]
## Z = log2(beta_eff) in [beta_min,beta_max]
## R stores conditioned Q = beta * sqrt(cos_cone*cos_o) * cos_o * M.

@export var size_x: int = 128
@export var size_y: int = 128
@export var size_z: int = 64
@export var format: int = Image.FORMAT_RGBAH
@export var beta_min: float = 0.02
@export var beta_max: float = 16.0
@export var contract: String = "deon_physical_longitudinal_q_v1"
@export var channels: String = "R=Q,G=0,B=0,A=1"
@export var data: PackedByteArray = PackedByteArray()
@export var notes: String = ""

func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if size_x < 2 or size_y < 2 or size_z < 2:
		errors.append("all dimensions must be >= 2")
	if format != Image.FORMAT_RGBAH and format != Image.FORMAT_RGBAF:
		errors.append("format must be RGBAH or RGBAF")
	if not is_finite(beta_min) or not is_finite(beta_max) or beta_min <= 0.0 or beta_max <= beta_min:
		errors.append("invalid beta range")
	if contract != "deon_physical_longitudinal_q_v1":
		errors.append("unexpected contract: %s" % contract)
	if channels != "R=Q,G=0,B=0,A=1":
		errors.append("unexpected channels: %s" % channels)
	var bytes_per_texel := 8 if format == Image.FORMAT_RGBAH else 16
	var expected := size_x * size_y * size_z * bytes_per_texel
	if data.size() != expected:
		errors.append("expected %d bytes, got %d" % [expected, data.size()])
	return errors

func is_valid() -> bool:
	return validation_errors().is_empty()
