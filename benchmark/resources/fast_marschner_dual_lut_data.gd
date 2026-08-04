extends Resource
class_name FastMarschnerDualLUTData

## Committed data for the FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED LUT.
##
## Godot 4.7's ResourceSaver cannot self-contain an ImageTexture (it writes a
## `local://` stub for .res and a data-less .tres), so the generator commits the
## raw RGBAF texel data here and the adapter constructs the ImageTexture at
## runtime with Image.create_from_data / ImageTexture.create_from_image. The
## data layout is a 2D grid of size x size RGBAF texels: texel (x, y) at float
## offset (y * size + x) * 4, with RGBA = one-event forward/backward and
## three-event forward/backward aggregate event weights. The committed default
## is 64x64. The first and last texels represent the exact domain endpoints;
## the shader remaps both endpoints to their corresponding texel centers
## before filtering.
##
## Axes (all in [0, 1] texture space, with exact endpoints represented by the
## first and last texels):
##   U = scalar density/event proxy tau_d = 4 * local_density in [0, 16]
##       (the shader clamps tau_d into this domain before the lookup)
##   V = scattering cosine c in [-1, 1]       (light/view alignment; texel
##       center at -1 + (y + 0.5) / N * 2)
##
## Channels (scalar aggregate event weights, all bounded in [0, 1]):
##   P1 = 1 - exp(-tau_d)                   (one-event aggregate weight)
##   P3 = 1 - exp(-1.5 * tau_d)             (three-event aggregate weight)
##   R = one-event forward weight:  0.5 * (1 + c) * (1 - F0)^2 * P1
##   G = one-event backward weight: 0.5 * (1 - c) * (1 - F0)^2 * P1
##   B = three-event forward weight: 0.5 * (1 + c) * (1 - F0)^2 * F0 * P3
##   A = three-event backward weight: 0.5 * (1 - c) * (1 - F0)^2 * F0 * P3
## with F0 = ((1 - eta) / (1 + eta))^2 baked at eta = 1.55. Zero density
## produces zero secondary energy; increasing density saturates toward the
## available one-/three-event energy. The weights are scalar by design: the
## shader samples the LUT once at the scalar tau_d and applies the RGB
## one-/three-event absorption separately (T1 = exp(-sigma_a),
## T3 = exp(-1.5 * sigma_a)), so the LUT never bakes a single hair color.
##
## See benchmark/tools/generate_marschner_dual_scatter_lut.gd for the generator
## and benchmark/tools/validate_marschner_dual_scatter_lut.gd for the numerical
## validation.

@export var size: int = 32
@export var format: int = 11  # Image.FORMAT_RGBAF (4.7 enum value; the generator assigns the constant)
@export var eta: float = 1.55
@export var notes: String = ""
@export var data: PackedByteArray = PackedByteArray()


func validation_errors() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if size < 2:
		errors.append("size must be at least 2")
	var expected_bytes := size * size * 16
	if data.size() != expected_bytes:
		errors.append("data must contain %d bytes (%dx%d RGBAF), got %d" % [expected_bytes, size, size, data.size()])
	return errors


func is_valid() -> bool:
	return validation_errors().is_empty()
