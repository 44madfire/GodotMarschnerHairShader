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
