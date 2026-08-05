extends Resource
class_name FastMarschnerLUTData

## Committed data for the FAST_MARSCHNER azimuthal LUT.
##
## Godot 4.7's ResourceSaver cannot self-contain an ImageTexture3D (it writes a
## `local://` stub for .res and a data-less .tres), so the generator commits the
## raw RGBAF texel data here and the adapter constructs the ImageTexture3D at
## runtime with the instance ImageTexture3D.create(...) call (the static form
## does not resolve in this build's GDScript). The data layout is z-slices of
## size x size RGBAF texels (the committed default is 64^3): texel (x, y, z) at
## float offset ((z * size + y) * size + x) * 4, with RGB = R/TT/TRT azimuthal
## terms and A unused (1.0).
##
## See benchmark/tools/generate_marschner_azimuthal_lut.gd for the generator
## and benchmark/tools/validate_marschner_azimuthal_lut.gd for the numerical
## validation.

@export var size: int = 32
@export var format: int = Image.FORMAT_RGBAF
@export var eta: float = 1.55
@export var notes: String = ""
@export var data: PackedByteArray = PackedByteArray()


func validation_errors() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if size <= 0:
		errors.append("size must be positive")
	var expected_bytes := size * size * size * 16
	if data.size() != expected_bytes:
		errors.append("data must contain %d bytes (%d^3 RGBAF), got %d" % [expected_bytes, size, data.size()])
	return errors


func is_valid() -> bool:
	return validation_errors().is_empty()
