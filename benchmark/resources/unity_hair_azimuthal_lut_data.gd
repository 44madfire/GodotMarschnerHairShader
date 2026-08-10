@tool
extends Resource
class_name UnityHairAzimuthalLUTData

## Unity HDRP-style roughened azimuthal scattering distribution.
## Axes match GetRoughenedAzimuthalScatteringDistribution:
##   X = (phi + 2*PI) / (4*PI), phi in [-2*PI, 2*PI]
##   Y = cos(theta_d) in [0, 1]
##   Z = perceptual radial roughness in [0, 1]
## RGB stores N_R, N_TT, N_TRT only. Fresnel/Beer attenuation stays analytic.

@export var size_x: int = 64
@export var size_y: int = 64
@export var size_z: int = 64
@export var format: int = Image.FORMAT_RGBAH
@export var eta: float = 1.55
@export var contract: String = "unity_hdrp_azimuthal_n_v1"
@export var channels: String = "R=N_R,G=N_TT,B=N_TRT,A=1"
@export var data: PackedByteArray = PackedByteArray()
@export var notes: String = ""

func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if size_x < 2 or size_y < 2 or size_z < 2:
		errors.append("all dimensions must be >= 2")
	if format != Image.FORMAT_RGBAH and format != Image.FORMAT_RGBAF:
		errors.append("format must be RGBAH or RGBAF")
	if not is_finite(eta) or eta <= 1.0:
		errors.append("eta must be finite and > 1")
	if contract != "unity_hdrp_azimuthal_n_v1":
		errors.append("unexpected contract: %s" % contract)
	if channels != "R=N_R,G=N_TT,B=N_TRT,A=1":
		errors.append("unexpected channel contract: %s" % channels)
	var bytes_per_texel := 8 if format == Image.FORMAT_RGBAH else 16
	var expected := size_x * size_y * size_z * bytes_per_texel
	if data.size() != expected:
		errors.append("expected %d bytes, got %d" % [expected, data.size()])
	return errors

func is_valid() -> bool:
	return validation_errors().is_empty()

func sample_n(phi: float, cos_theta_d: float, radial_roughness: float) -> Vector3:
	if data.is_empty():
		return Vector3.ZERO
	var half_x := 0.5 / float(size_x)
	var half_y := 0.5 / float(size_y)
	var half_z := 0.5 / float(size_z)
	var u := clampf((phi + TAU) / (2.0 * TAU), half_x, 1.0 - half_x)
	var v := clampf(cos_theta_d, half_y, 1.0 - half_y)
	var w := clampf(radial_roughness, half_z, 1.0 - half_z)
	var px := u * float(size_x) - 0.5
	var py := v * float(size_y) - 0.5
	var pz := w * float(size_z) - 0.5
	var x0 := int(floor(px))
	var y0 := int(floor(py))
	var z0 := int(floor(pz))
	var tx := px - float(x0)
	var ty := py - float(y0)
	var tz := pz - float(z0)
	var result := Vector3.ZERO
	for dz in 2:
		for dy in 2:
			for dx in 2:
				var x := clampi(x0 + dx, 0, size_x - 1)
				var y := clampi(y0 + dy, 0, size_y - 1)
				var z := clampi(z0 + dz, 0, size_z - 1)
				var weight := (tx if dx == 1 else 1.0 - tx) * (ty if dy == 1 else 1.0 - ty) * (tz if dz == 1 else 1.0 - tz)
				result += _texel_rgb(x, y, z) * weight
	return Vector3(maxf(result.x, 0.0), maxf(result.y, 0.0), maxf(result.z, 0.0))

func _texel_rgb(x: int, y: int, z: int) -> Vector3:
	var bytes_per_texel := 8 if format == Image.FORMAT_RGBAH else 16
	var offset := ((z * size_y + y) * size_x + x) * bytes_per_texel
	if offset < 0 or offset + bytes_per_texel > data.size():
		return Vector3.ZERO
	if format == Image.FORMAT_RGBAH:
		return Vector3(data.decode_half(offset), data.decode_half(offset + 2), data.decode_half(offset + 4))
	return Vector3(data.decode_float(offset), data.decode_float(offset + 4), data.decode_float(offset + 8))
