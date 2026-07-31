extends Resource
class_name HairMaterialProfile

## Selects the shader implementation used by a hair material profile.
enum QualityTier {
	APPROX,
	FAST_MARSCHNER,
	HIGH_MARSCHNER,
}

const APPROX_SHADER: Shader = preload("res://assets/hair/materials/shaders/hair_approx.gdshader")
const CURRENT_HIGH_SHADER: Shader = preload("res://assets/hair/materials/shaders/hair.gdshader")

@export_category("Quality")
@export var quality_tier: QualityTier = QualityTier.APPROX

@export_category("Base Hair")
@export var albedo: Color = Color(0.1, 0.1, 0.1, 1.0)
@export_range(0.0, 1.0, 0.001) var longitudinal_roughness: float = 0.3
@export_range(0.0, 1.0, 0.001) var azimuthal_roughness: float = 0.8
@export_range(0.0, 1.0, 0.001) var specular: float = 1.0
@export_range(0.0, 0.5, 0.001) var cuticle_tilt_offset: float = 0.1

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


## Returns the shader resource for this profile's supported quality tier.
## FAST_MARSCHNER is intentionally a documented placeholder until a separate
## fast Marschner implementation exists; it maps to the current high shader.
func get_shader_resource() -> Shader:
	match quality_tier:
		QualityTier.APPROX:
			return APPROX_SHADER
		QualityTier.FAST_MARSCHNER:
			return CURRENT_HIGH_SHADER
		QualityTier.HIGH_MARSCHNER:
			return CURRENT_HIGH_SHADER
	return CURRENT_HIGH_SHADER


## Applies only parameters declared by the material's current shader.
## Groom-specific texture assignments are deliberately not part of this map.
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
