extends Resource
class_name FastMarschnerRStandardizedLUTData

## Raw non-cubic standardized projected-R LUT data.
##
## Stored quantity:
##   Q = beta_r * sqrt(cos(theta_cone) * cos(theta_o)) * cos(theta_o) * M_R
##
## Axes:
##   X = q = (theta_o - theta_cone) / beta_r
##   Y = theta_cone
##   Z = log2(beta_r)
##
## The committed v1 asset is RGBAF with R=linear Q and G=log2(Q). The new
## boundary sampler manually renormalizes trilinear weights after rejecting
## corners whose implied theta_o lies outside the physical [-PI/2, PI/2]
## interval. This lets the GPU use the LUT at grazing instead of evaluating the
## direct Bessel reference.

const INV_LN_2 := 1.4426950408889634
const DECODE_LINEAR := 0
const DECODE_LOG := 1
const FALLBACK_NONE := 0
const FALLBACK_OUTSIDE := 1
const FALLBACK_ALWAYS := 2
const Reference := preload("res://benchmark/reference/fast_marschner_r_standardized_kernel_reference.gd")

@export var size_x: int = 128
@export var size_y: int = 128
@export var size_z: int = 64
@export var format: int = Image.FORMAT_RGBAF
@export var q_min: float = -12.0
@export var q_max: float = 12.0
@export var theta_cone_min: float = -PI * 0.5
@export var theta_cone_max: float = PI * 0.5
@export var beta_min: float = 0.02
@export var beta_max: float = 9.0
@export var log_value_floor: float = -120.0
@export var contract: String = "standardized_r_projected_q_v1"
@export var channels: String = "R=linear_Q,G=log2_Q,B=0,A=1"
@export var fallback_policy: String = "hardware trilinear in the physical interior; renormalized physical-corner trilinear at grazing; asymptotic low-beta path; direct reference only for unresolved pole/high-beta diagnostics"
@export var raw_m_unit_normalization_claimed: bool = false
@export var notes: String = ""
@export var data: PackedByteArray = PackedByteArray()

func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if size_x < 2 or size_y < 2 or size_z < 2:
		errors.append("all dimensions must be at least 2")
	if size_x == size_y and size_y == size_z:
		errors.append("resolution must be non-cubic (got %dx%dx%d)" % [size_x, size_y, size_z])
	if not is_finite(q_min) or not is_finite(q_max) or q_max <= q_min:
		errors.append("q axis must be finite with q_max > q_min")
	if not is_finite(theta_cone_min) or not is_finite(theta_cone_max) or theta_cone_max <= theta_cone_min:
		errors.append("theta_cone axis must be finite with max > min")
	if not is_finite(beta_min) or not is_finite(beta_max) or beta_min <= 0.0 or beta_max <= beta_min:
		errors.append("beta axis must be finite with 0 < beta_min < beta_max")
	if not is_finite(log_value_floor):
		errors.append("log_value_floor must be finite")
	if contract.strip_edges().is_empty() or channels.strip_edges().is_empty() or fallback_policy.strip_edges().is_empty():
		errors.append("contract/channels/fallback_policy must be non-empty")
	if raw_m_unit_normalization_claimed:
		errors.append("raw_m_unit_normalization_claimed must be false")
	var expected_bytes := size_x * size_y * size_z * 16
	if data.size() != expected_bytes:
		errors.append("data must contain %d bytes (%dx%dx%d RGBAF), got %d" % [expected_bytes, size_x, size_y, size_z, data.size()])
	return errors

func is_valid() -> bool:
	return validation_errors().is_empty()

## Hardware-equivalent clamp/no-wrap trilinear sample.
func sample_q(q: float, theta_cone: float, beta_r: float, decode: int) -> float:
	if data.is_empty():
		return 0.0
	var position := _sample_position(q, theta_cone, beta_r)
	var p: Vector3 = position
	var x0 := int(floor(p.x))
	var y0 := int(floor(p.y))
	var z0 := int(floor(p.z))
	var tx := p.x - float(x0)
	var ty := p.y - float(y0)
	var tz := p.z - float(z0)
	var channel := 1 if decode == DECODE_LOG else 0
	var result := 0.0
	for dz in 2:
		for dy in 2:
			for dx in 2:
				var ix := mini(x0 + dx, size_x - 1)
				var iy := mini(y0 + dy, size_y - 1)
				var iz := mini(z0 + dz, size_z - 1)
				var weight := (tx if dx == 1 else 1.0 - tx) \
					* (ty if dy == 1 else 1.0 - ty) \
					* (tz if dz == 1 else 1.0 - tz)
				result += _texel_channel(ix, iy, iz, channel) * weight
	return pow(2.0, result) if decode == DECODE_LOG else maxf(result, 0.0)

## Manual trilinear sample which rejects nonphysical outgoing-angle texels and
## renormalizes the surviving weights. Returns {q, valid_weight}. For log
## decode, the G values are interpolated/renormalized in log space before the
## final exp2, matching the ordinary sampler's decode contract.
func sample_q_boundary_renormalized(q: float, theta_cone: float, beta_r: float, decode: int) -> Dictionary:
	if data.is_empty() or q < q_min or q > q_max \
			or theta_cone < theta_cone_min or theta_cone > theta_cone_max \
			or beta_r < beta_min or beta_r > beta_max:
		return {"q": 0.0, "valid_weight": 0.0}
	var p := _sample_position(q, theta_cone, beta_r)
	var x0 := int(floor(p.x))
	var y0 := int(floor(p.y))
	var z0 := int(floor(p.z))
	var tx := p.x - float(x0)
	var ty := p.y - float(y0)
	var tz := p.z - float(z0)
	var channel := 1 if decode == DECODE_LOG else 0
	var accumulated := 0.0
	var valid_weight := 0.0
	for dz in 2:
		for dy in 2:
			for dx in 2:
				var ix := mini(x0 + dx, size_x - 1)
				var iy := mini(y0 + dy, size_y - 1)
				var iz := mini(z0 + dz, size_z - 1)
				var weight := (tx if dx == 1 else 1.0 - tx) \
					* (ty if dy == 1 else 1.0 - ty) \
					* (tz if dz == 1 else 1.0 - tz)
				if weight <= 0.0:
					continue
				var q_corner := q_min + (float(ix) + 0.5) / float(size_x) * (q_max - q_min)
				var cone_corner := theta_cone_min + (float(iy) + 0.5) / float(size_y) * (theta_cone_max - theta_cone_min)
				var beta_corner := pow(2.0, _log2_beta_min() + (float(iz) + 0.5) / float(size_z) * _log2_beta_span())
				var theta_o_corner := cone_corner + q_corner * beta_corner
				if theta_o_corner < -0.5 * PI or theta_o_corner > 0.5 * PI:
					continue
				accumulated += _texel_channel(ix, iy, iz, channel) * weight
				valid_weight += weight
	if valid_weight <= 1e-12:
		return {"q": 0.0, "valid_weight": 0.0}
	var value := accumulated / valid_weight
	if decode == DECODE_LOG:
		value = pow(2.0, value)
	return {"q": maxf(value, 0.0), "valid_weight": valid_weight}

## True when the hardware trilinear footprint approaches or crosses the
## physical outgoing-angle boundary. This excludes the cone-pole policy: pole
## handling remains separately attributable while grazing can use the new
## renormalized sampler.
func requires_boundary_renormalization(q: float, theta_cone: float, beta_r: float) -> bool:
	if q < q_min or q > q_max or theta_cone < theta_cone_min or theta_cone > theta_cone_max \
			or beta_r < beta_min or beta_r > beta_max:
		return false
	var q_half_step := 0.5 * (q_max - q_min) / float(size_x)
	var cone_half_step := 0.5 * (theta_cone_max - theta_cone_min) / float(size_y)
	var log2_half_step := 0.5 * _log2_beta_span() / float(size_z)
	var log2_beta := log(beta_r) * INV_LN_2
	var beta_lo := maxf(beta_min, pow(2.0, log2_beta - log2_half_step))
	var beta_hi := minf(beta_max, pow(2.0, log2_beta + log2_half_step))
	for q_offset in [-q_half_step, q_half_step]:
		for cone_offset in [-cone_half_step, cone_half_step]:
			for beta_corner in [beta_lo, beta_hi]:
				var theta_o_corner: float = theta_cone + cone_offset + (q + q_offset) * beta_corner
				if absf(theta_o_corner) > 0.5 * PI:
					return true
	var grazing_margin := 1.25 * (q_half_step * beta_hi + cone_half_step + absf(q) * (beta_hi - beta_lo))
	return absf(theta_cone + q * beta_r) > 0.5 * PI - grazing_margin

## Retained compatibility sampler used by older validation/generation tools.
func sample_q_fallback(q: float, theta_cone: float, beta_r: float, decode: int, fallback: int) -> float:
	var in_support := q >= q_min and q <= q_max \
		and theta_cone >= theta_cone_min and theta_cone <= theta_cone_max \
		and beta_r >= beta_min and beta_r <= beta_max \
		and not requires_reference_fallback(q, theta_cone, beta_r)
	if fallback == FALLBACK_NONE or (fallback == FALLBACK_OUTSIDE and in_support):
		return sample_q(q, theta_cone, beta_r, decode)
	var q_ref := reference_q_value(q, theta_cone, beta_r)
	if decode == DECODE_LOG:
		return pow(2.0, maxf(log(maxf(q_ref, 1e-300)) * INV_LN_2, log_value_floor))
	return q_ref

func requires_pole_band_fallback(theta_cone: float) -> bool:
	var cone_half_step := 0.5 * (theta_cone_max - theta_cone_min) / float(size_y)
	return absf(theta_cone) > theta_cone_max - 2.0 * cone_half_step

## Legacy combined predicate retained for existing generator/diagnostic tests.
func requires_reference_fallback(q: float, theta_cone: float, beta_r: float) -> bool:
	if q < q_min or q > q_max or theta_cone < theta_cone_min or theta_cone > theta_cone_max:
		return true
	if beta_r < beta_min or beta_r > beta_max:
		return true
	if requires_pole_band_fallback(theta_cone):
		return true
	return requires_boundary_renormalization(q, theta_cone, beta_r)

func reference_q_value(q: float, theta_cone: float, beta_r: float) -> float:
	var theta_o := theta_cone + q * beta_r
	if beta_r > Reference.BETA_NUMERIC_EPSILON:
		return Reference.direct_q_value(theta_o, theta_cone, beta_r)
	return Reference.asymptotic_q_value(theta_o, theta_cone, beta_r)

func texel(x: int, y: int, z: int) -> Vector4:
	return Vector4(
		_texel_channel(x, y, z, 0),
		_texel_channel(x, y, z, 1),
		_texel_channel(x, y, z, 2),
		_texel_channel(x, y, z, 3)
	)

func _sample_position(q: float, theta_cone: float, beta_r: float) -> Vector3:
	var half_x := 0.5 / float(size_x)
	var half_y := 0.5 / float(size_y)
	var half_z := 0.5 / float(size_z)
	var u := clampf((q - q_min) / (q_max - q_min), half_x, 1.0 - half_x)
	var v := clampf((theta_cone - theta_cone_min) / (theta_cone_max - theta_cone_min), half_y, 1.0 - half_y)
	var beta_c := clampf(beta_r, beta_min, beta_max)
	var w := clampf((log(beta_c) * INV_LN_2 - _log2_beta_min()) / _log2_beta_span(), half_z, 1.0 - half_z)
	return Vector3(u * float(size_x) - 0.5, v * float(size_y) - 0.5, w * float(size_z) - 0.5)

func _log2_beta_min() -> float:
	return log(beta_min) * INV_LN_2

func _log2_beta_span() -> float:
	return (log(beta_max) - log(beta_min)) * INV_LN_2

func _texel_channel(x: int, y: int, z: int, channel: int) -> float:
	var byte_offset := ((z * size_y + y) * size_x + x) * 16 + channel * 4
	if byte_offset < 0 or byte_offset + 4 > data.size():
		return 0.0
	return data.decode_float(byte_offset)
