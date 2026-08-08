extends Resource
class_name HairMarschnerCinematicLongitudinalLUTData

## Generic energy-conserving longitudinal kernel over a physical angular domain.
## X = theta_cone in [-PI/2, PI/2]
## Y = theta_o in [-PI/2, PI/2]
## Z = log2(beta_eff) in [beta_min,beta_max]
## R stores log2(Q), where Q = beta * sqrt(cos_cone*cos_o) * cos_o * M.
##
## Angular coordinates avoid the grazing-density loss of a uniform sin(theta)
## grid, while log2(Q) makes the very narrow longitudinal peaks interpolate in
## their smooth log domain instead of linearly blending a near-delta function.

const INV_LN_2: float = 1.4426950408889634
const LOG2_Q_FLOOR: float = -120.0

@export var size_x: int = 128
@export var size_y: int = 128
@export var size_z: int = 64
@export var format: int = Image.FORMAT_RH
@export var beta_min: float = 0.05
@export var beta_max: float = 64.0
@export var contract: String = "deon_physical_longitudinal_log2q_v2"
@export var channels: String = "R=log2(Q)"
@export var data: PackedByteArray = PackedByteArray()
@export var notes: String = ""

func validation_errors() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if size_x < 2 or size_y < 2 or size_z < 2:
		errors.append("all dimensions must be >= 2")
	if format != Image.FORMAT_RH and format != Image.FORMAT_RF and format != Image.FORMAT_RGBAH and format != Image.FORMAT_RGBAF:
		errors.append("format must be RH, RF, RGBAH, or RGBAF")
	if not is_finite(beta_min) or not is_finite(beta_max) or beta_min <= 0.0 or beta_max <= beta_min:
		errors.append("invalid beta range")
	if contract != "deon_physical_longitudinal_log2q_v2":
		errors.append("unexpected contract: %s" % contract)
	if channels != "R=log2(Q)":
		errors.append("unexpected channels: %s" % channels)
	var bytes_per_texel: int = _bytes_per_texel()
	var expected: int = size_x * size_y * size_z * bytes_per_texel
	if data.size() != expected:
		errors.append("expected %d bytes, got %d" % [expected, data.size()])
	return errors

func is_valid() -> bool:
	return validation_errors().is_empty()

func sample_q(sin_cone: float, sin_o: float, beta_eff: float) -> float:
	if data.is_empty():
		return 0.0
	var half_x: float = 0.5 / float(size_x)
	var half_y: float = 0.5 / float(size_y)
	var half_z: float = 0.5 / float(size_z)
	var theta_cone: float = asin(clampf(sin_cone, -1.0, 1.0))
	var theta_o: float = asin(clampf(sin_o, -1.0, 1.0))
	var u: float = clampf(0.5 + theta_cone / PI, half_x, 1.0 - half_x)
	var v: float = clampf(0.5 + theta_o / PI, half_y, 1.0 - half_y)
	var beta: float = clampf(beta_eff, beta_min, beta_max)
	var log_min: float = log(beta_min) * INV_LN_2
	var log_span: float = (log(beta_max) - log(beta_min)) * INV_LN_2
	var w: float = clampf((log(beta) * INV_LN_2 - log_min) / log_span, half_z, 1.0 - half_z)
	var px: float = u * float(size_x) - 0.5
	var py: float = v * float(size_y) - 0.5
	var pz: float = w * float(size_z) - 0.5
	var x0: int = int(floor(px))
	var y0: int = int(floor(py))
	var z0: int = int(floor(pz))
	var tx: float = px - float(x0)
	var ty: float = py - float(y0)
	var tz: float = pz - float(z0)
	var log2_q: float = 0.0
	for dz in 2:
		for dy in 2:
			for dx in 2:
				var x: int = clampi(x0 + dx, 0, size_x - 1)
				var y: int = clampi(y0 + dy, 0, size_y - 1)
				var z: int = clampi(z0 + dz, 0, size_z - 1)
				var weight: float = (tx if dx == 1 else 1.0 - tx) * (ty if dy == 1 else 1.0 - ty) * (tz if dz == 1 else 1.0 - tz)
				log2_q += _texel_r(x, y, z) * weight
	return pow(2.0, maxf(log2_q, LOG2_Q_FLOOR))

func regularized_sin_cone(sin_cone: float) -> float:
	var half_x: float = 0.5 / float(size_x)
	var theta: float = asin(clampf(sin_cone, -1.0, 1.0))
	var u: float = clampf(0.5 + theta / PI, half_x, 1.0 - half_x)
	return sin((u - 0.5) * PI)

func regularized_sin_o(sin_o: float) -> float:
	var half_y: float = 0.5 / float(size_y)
	var theta: float = asin(clampf(sin_o, -1.0, 1.0))
	var v: float = clampf(0.5 + theta / PI, half_y, 1.0 - half_y)
	return sin((v - 0.5) * PI)

func _bytes_per_texel() -> int:
	if format == Image.FORMAT_RH:
		return 2
	if format == Image.FORMAT_RF:
		return 4
	if format == Image.FORMAT_RGBAH:
		return 8
	return 16

func _texel_r(x: int, y: int, z: int) -> float:
	var bytes_per_texel: int = _bytes_per_texel()
	var offset: int = ((z * size_y + y) * size_x + x) * bytes_per_texel
	if offset < 0 or offset + bytes_per_texel > data.size():
		return LOG2_Q_FLOOR
	if format == Image.FORMAT_RH or format == Image.FORMAT_RGBAH:
		return data.decode_half(offset)
	return data.decode_float(offset)
