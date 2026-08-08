extends Resource
class_name HairMaterialProfile

## Production hair quality selection.
## Approx remains the Kajiya-Kay fallback; Fast is a coherent Unity HDRP
## Standard-style Marschner model; Cinematic keeps the analytic baseline's
## non-separable geometry while preintegrating only the expensive longitudinal
## kernel; Reference is the full analytic shader and is intended primarily for
## validation/comparison.
enum QualityTier {
	APPROX = 0,
	FAST_MARSCHNER = 1,
	CINEMATIC_MARSCHNER = 2,
	REFERENCE_MARSCHNER = 3,
}

const APPROX_SHADER: Shader = preload("res://assets/hair/materials/shaders/hair_approx.gdshader")
const FAST_MARSCHNER_SHADER: Shader = preload("res://assets/hair/materials/shaders/hair_marschner_unity_fast.gdshader")
const CINEMATIC_MARSCHNER_SHADER: Shader = preload("res://assets/hair/materials/shaders/hair_marschner_cinematic.gdshader")
const REFERENCE_MARSCHNER_SHADER: Shader = preload("res://assets/hair/materials/shaders/hair.gdshader")
const LUTAdapter := preload("res://assets/hair/materials/HairMarschnerLUTAdapter.gd")

@export_category("Quality")
@export var quality_tier: QualityTier = QualityTier.APPROX

@export_category("Base Hair")
@export var albedo: Color = Color(0.1, 0.1, 0.1, 1.0)
@export_range(0.0, 1.0, 0.001) var longitudinal_roughness: float = 0.3
@export_range(0.0, 1.0, 0.001) var azimuthal_roughness: float = 0.8
@export_range(0.0, 1.0, 0.001) var specular: float = 1.0
@export_range(0.0, 0.5, 0.001) var cuticle_tilt_offset: float = 0.1

@export_category("Marschner")
## Fast is pinned to the Unity LUT's baked eta by the LUT adapter. Cinematic
## uses this value directly and therefore remains valid across the profile's
## supported IOR range.
@export_range(1.0, 2.0, 0.001) var ior: float = 1.55
@export_enum("Albedo reparameterization", "Direct absorption", "Melanin") var absorption_mode: int = 0
@export var absorption: Color = Color(0.1, 0.1, 0.1, 1.0)
@export_range(0.0, 1.0, 0.001) var eumelanin: float = 0.2
@export_range(0.0, 1.0, 0.001) var pheomelanin: float = 0.8
@export_range(0.0, 0.01, 0.0001) var melanin_absorption_scale: float = 0.001

@export_category("Marschner LUT Resources")
## Optional overrides. When null, the runtime adapter loads the default
## generated resources under benchmark/resources/luts/.
@export var unity_azimuthal_lut_data: Resource
@export var cinematic_longitudinal_lut_data: Resource

@export_category("Kajiya-Kay Tier 1")
@export var primary_color: Color = Color.WHITE
@export var secondary_color: Color = Color(0.45, 0.45, 0.45, 1.0)
@export_range(-1.0, 1.0, 0.001) var primary_shift: float = 0.0
@export_range(-1.0, 1.0, 0.001) var secondary_shift: float = 0.12
@export_range(0.0, 1.0, 0.001) var primary_roughness: float = 0.3
@export_range(0.0, 1.0, 0.001) var secondary_roughness: float = 0.55
@export_range(0.0, 4.0, 0.001) var primary_strength: float = 1.0
@export_range(0.0, 4.0, 0.001) var secondary_strength: float = 0.35
@export_range(0.0, 1.0, 0.001) var scatter: float = 0.35

var _lut_adapter: RefCounted


## Returns the explicit compile-time shader for this quality tier.
func get_shader_resource() -> Shader:
	match quality_tier:
		QualityTier.APPROX:
			return APPROX_SHADER
		QualityTier.FAST_MARSCHNER:
			return FAST_MARSCHNER_SHADER
		QualityTier.CINEMATIC_MARSCHNER:
			return CINEMATIC_MARSCHNER_SHADER
		QualityTier.REFERENCE_MARSCHNER:
			return REFERENCE_MARSCHNER_SHADER
	return REFERENCE_MARSCHNER_SHADER


## Applies only parameters declared by the material's current shader, then
## binds the required production LUT when the material is Fast or Cinematic.
## Groom-specific coords/attributes textures remain owned by the groom material.
func apply_to_shader_material(material: ShaderMaterial) -> void:
	if material == null or material.shader == null:
		return

	var known_parameters: Dictionary = {}
	for uniform in material.shader.get_shader_uniform_list():
		var uniform_name = uniform.get("name", "")
		if uniform_name != "":
			known_parameters[StringName(uniform_name)] = true

	var values: Dictionary = {
		&"albedo": albedo,
		&"longitudinal_roughness": longitudinal_roughness,
		&"azimuthal_roughness": azimuthal_roughness,
		&"specular": specular,
		&"cuticle_tilt_offset": cuticle_tilt_offset,
		&"ior": ior,
		&"absorption_mode": absorption_mode,
		&"absorption": absorption,
		&"eumelanin": eumelanin,
		&"pheomelanin": pheomelanin,
		&"melanin_absorption_scale": melanin_absorption_scale,
		&"primary_color": primary_color,
		&"secondary_color": secondary_color,
		&"primary_shift": primary_shift,
		&"secondary_shift": secondary_shift,
		&"primary_roughness": primary_roughness,
		&"secondary_roughness": secondary_roughness,
		&"primary_strength": primary_strength,
		&"secondary_strength": secondary_strength,
		&"scatter": scatter,
	}

	for parameter_name in values:
		if known_parameters.has(parameter_name):
			material.set_shader_parameter(parameter_name, values[parameter_name])

	if not bind_quality_resources(material):
		push_warning("HairMaterialProfile could not bind the LUT required by %s. Generate the benchmark LUT resources before using this quality tier." % material.shader.resource_path)


## Binds only the resources required by the material's explicit shader.
## Returns true for shaders that do not require a production LUT.
func bind_quality_resources(material: ShaderMaterial) -> bool:
	if material == null or material.shader == null:
		return false
	if _lut_adapter == null:
		_lut_adapter = LUTAdapter.new()
	var shader_path := material.shader.resource_path
	if shader_path == FAST_MARSCHNER_SHADER.resource_path:
		return _lut_adapter.bind_unity_fast(material, unity_azimuthal_lut_data)
	if shader_path == CINEMATIC_MARSCHNER_SHADER.resource_path:
		return _lut_adapter.bind_cinematic(material, cinematic_longitudinal_lut_data)
	return true
