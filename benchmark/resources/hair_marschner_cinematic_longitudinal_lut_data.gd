extends Resource
class_name HairMarschnerCinematicLongitudinalLUTData

## Generic energy-conserving longitudinal kernel over a fully physical domain.
## X = sin(theta_cone) in [-1,1]
## Y = sin(theta_o) in [-1,1]
## Z = log2(beta_eff) in [beta_min,beta_max]
## R stores conditioned Q = beta * sqrt(cos_cone*cos_o) * cos_o * M.
## Production candidate uses one R16F channel; RGBA formats remain accepted for
## diagnostic comparisons without changing the sampling contract.

const INV_LN_2 := 1.4426950408889634

@export var size_x: int = 128
@export var size_y: int = 128
@export var size_z: int = 64
@export var format: int = Image.FORMAT_RH
@export var beta_min: float = 0.015
@export var beta_max: float = 64.0
@export var contract: String = "deon_physical_longitudinal_q_v1"
@export var channels: String = "R=Q"
@export var data: PackedByteArray = PackedByteArray()
@export var notes: String = ""

func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if size_x < 2 or size_y < 2 or size_z < 2:
		errors.append("all dimensions must be >= 2")
	if format != Image.FORMAT_RH and format != Image.FORMAT_RF and format != Image.FORMAT_RGBAH and format != Image.FORMAT_RGBAF:
		errors.append("format must be RH, RF, RGBAH, or RGBAF")
	if not is_finite(beta_min) or not is_finite(beta_max) or beta_min <= 0.0 or beta_max <= beta_min:
		errors.append("invalid beta range")
	if contract != "deon_physical_longitudinal_q_v1":
		errors.append("unexpected contract: %s" % contract)
	if channels != "R=Q":
		errors.append("unexpected channels: %s" % channels)
	var bytes_per_texel := _bytes_per_texel()
	var expected := size_x * size_y * size_z * bytes_per_texel
	if data.size() != expected:
		errors.append("expected %d bytes, got %d" % [expected, data.size()])
	return errors

func is_valid() -> bool:
	return validation_errors().is_empty()

func sample_q(sin_cone: float, sin_o: float, beta_eff: float) -> float:
	if data.is_empty():
		return 0.0
	var half_x := 0.5 / float(size_x)
	var half_y := 0.5 / float(size_y)
	var half_z := 0.5 / float(size_z)
	var u := clampf(0.5 + 0.5 * sin_cone, half_x, 1.0 - half_x)
	var v := clampf(0.5 + 0.5 * sin_o, half_y, 1.0 - half_y)
	var beta := clampf(beta_eff, beta_min, beta_max)
	var log_min := log(beta_min) * INV_LN_2
	var log_span := (log(beta_max) - log(beta_min)) * INV_LN_2
	var w := clampf((log(beta) * INV_LN_2 - log_min) / log_span, half_z, 1.0 - half_z)
	var px := u * float(size_x) - 0.5
	var py := v * float(size_y) - 0.5
	var pz := w * float(size_z) - 0.5
	var x0 := int(floor(px))
	var y0 := int(floor(py))
	var z0 := int(floor(pz))
	var tx := px - float(x0)
	var ty := py - float(y0)
	var tz := pz - float(z0)
	var result := 0.0
	for dz in 2:
		for dy in 2:
			for dx in 2:
				var x := clampi(x0 + dx, 0, size_x - 1)
				var y := clampi(y0 + dy, 0, size_y - 1)
				var z := clampi(z0 + dz, 0, size_z - 1)
				var weight := (tx if dx == 1 else 1.0 - tx) * (ty if dy == 1 else 1.0 - ty) * (tz if dz == 1 else 1.0 - tz)
				result += _texel_r(x, y, z) * weight
	return maxf(result, 0.0)

func regularized_sin_cone(sin_cone: float) -> float:
	var half_x := 0.5 / float(size_x)
	return 2.0 * clampf(0.5 + 0.5 * sin_cone, half_x, 1.0 - half_x) - 1.0

func regularized_sin_o(sin_o: float) -> float:
	var half_y := 0.5 / float(size_y)
	return 2.0 * clampf(0.5 + 0.5 * sin_o, half_y, 1.0 - half_y) - 1.0

func _bytes_per_texel() -> int:
	if format == Image.FORMAT_RH:
		return 2
	if format == Image.FORMAT_RF:
		return 4
	if format == Image.FORMAT_RGBAH:
		return 8
	return 16

func _texel_r(x: int, y: int, z: int) -> float:
	var bytes_per_texel := _bytes_per_texel()
	var offset := ((z * size_y + y) * size_x + x) * bytes_per_texel
	if offset < 0 or offset + bytes_per_texel > data.size():
		return 0.0
	if format == Image.FORMAT_RH or format == Image.FORMAT_RGBAH:
		return data.decode_half(offset)
	return data.decode_float(offset)
