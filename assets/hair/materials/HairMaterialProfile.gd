@tool
extends Resource
class_name HairMaterialProfile

## User-facing hair material profile.
##
## Presents one authoring surface while keeping Approx, Fast Marschner,
## Cinematic Marschner, and Reference Marschner as separate compiled shaders.
## Pair this resource with HairGroomData for new hair-card grooms.
##
## Changing [member quality_tier] updates the Inspector so only controls that
## affect the selected shader remain visible. Hidden values stay serialized.
##
## Serialized tier values remain unchanged for compatibility:
## 0 = Approx/Kajiya-Kay, 1 = Unity Fast, 2 = Cinematic, 3 = Reference.
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

## Shader parameters intentionally owned by the groom/material rather than this
## profile. apply_to() carries them across shader-variant changes when both the
## previous and target shaders expose the parameter. Supplying HairGroomData to
## apply_to() replaces the two groom textures after the shader swap.
const PRESERVED_SHADER_PARAMETERS: Array[StringName] = [
	&"coords_texture",
	&"attributes_texture",
	&"show_hair_cards",
	&"show_hashed_strands",
	&"freeze_bayer_phase",
	&"comparison_exposure_gain",
	&"lobe_scales",
	&"use_area_light_multipliers",
]

@export_category("Quality")
## Selects the compiled lighting model. Switching this value also refreshes the
## Inspector and hides controls that are irrelevant to the chosen tier.
@export_enum("Approx / Kajiya-Kay", "Fast Marschner", "Cinematic Marschner", "Reference Marschner")
var quality_tier: int = QualityTier.APPROX:
	set(value):
		var clamped_value: int = clampi(value, QualityTier.APPROX, QualityTier.REFERENCE_MARSCHNER)
		if quality_tier == clamped_value:
			return
		quality_tier = clamped_value
		notify_property_list_changed()

@export_category("Base Hair")
## Average hair color used by the selected lighting model.
@export var albedo: Color = Color(0.1, 0.1, 0.1, 1.0)
## Perceptual roughness along the strand. Higher values broaden longitudinal
## highlights and also increase the shared frizz perturbation.
@export_range(0.0, 1.0, 0.001) var longitudinal_roughness: float = 0.3
## Perceptual roughness around the strand. Used by the Marschner tiers to control
## azimuthal scattering width. The Approx tier does not consume this property.
@export_range(0.0, 1.0, 0.001) var azimuthal_roughness: float = 0.8
## Scales the single-scattering/specular contribution of the hair model.
@export_range(0.0, 1.0, 0.001) var specular: float = 1.0
## Cuticle scale tilt in radians. Positive values separate the Marschner lobe
## shifts. The Approx tier does not consume this property.
@export_range(0.0, 0.5, 0.001) var cuticle_tilt_offset: float = 0.1

@export_category("Fast Marschner")
## Selects how Fast Marschner derives the absorption coefficient.
## Albedo reparameterization uses [member albedo]. Direct absorption exposes
## [member absorption]. Melanin exposes the eumelanin/pheomelanin controls.
@export_enum("Albedo reparameterization", "Direct absorption", "Melanin")
var absorption_mode: int = 0:
	set(value):
		var clamped_value: int = clampi(value, 0, 2)
		if absorption_mode == clamped_value:
			return
		absorption_mode = clamped_value
		notify_property_list_changed()
## Direct RGB absorption coefficient used when absorption mode is Direct
## absorption. Larger values attenuate more light inside the fiber.
@export var absorption: Color = Color(0.1, 0.1, 0.1, 1.0)
## Relative eumelanin amount used by Fast Marschner's melanin absorption mode.
@export_range(0.0, 1.0, 0.001) var eumelanin: float = 0.2
## Relative pheomelanin amount used by Fast Marschner's melanin absorption mode.
@export_range(0.0, 1.0, 0.001) var pheomelanin: float = 0.8
## Multiplier applied to the melanin absorption coefficients. Keep this small;
## the default is calibrated to the current Fast Marschner implementation.
@export_range(0.0, 0.01, 0.0001) var melanin_absorption_scale: float = 0.001
## Optional Unity Fast azimuthal LUT-data override. Leave null to load
## res://benchmark/resources/luts/unity_azimuthal_64.res. The LUT metadata pins
## Fast Marschner's IOR/eta contract.
@export var unity_azimuthal_lut_data: Resource

@export_category("Cinematic Marschner")
## Fiber index of refraction used by Cinematic Marschner. Unlike Fast Marschner,
## Cinematic evaluates its geometry/Fresnel terms against this authorable value.
@export_range(1.0, 2.0, 0.001) var ior: float = 1.55
## Optional conditioned longitudinal LUT-data override. Leave null to load
## res://benchmark/resources/luts/cinematic_longitudinal_kernel_128x128x64.res.
@export var cinematic_longitudinal_lut_data: Resource

@export_category("Approx / Kajiya-Kay")
## Color of the primary Kajiya-Kay highlight lobe.
@export var primary_color: Color = Color.WHITE
## Color of the secondary Kajiya-Kay highlight lobe.
@export var secondary_color: Color = Color(0.45, 0.45, 0.45, 1.0)
## Tangent-space shift of the primary Kajiya-Kay lobe.
@export_range(-1.0, 1.0, 0.001) var primary_shift: float = 0.0
## Tangent-space shift of the secondary Kajiya-Kay lobe.
@export_range(-1.0, 1.0, 0.001) var secondary_shift: float = 0.12
## Width/roughness control for the primary Kajiya-Kay lobe.
@export_range(0.0, 1.0, 0.001) var primary_roughness: float = 0.3
## Width/roughness control for the secondary Kajiya-Kay lobe.
@export_range(0.0, 1.0, 0.001) var secondary_roughness: float = 0.55
## Intensity multiplier for the primary Kajiya-Kay lobe.
@export_range(0.0, 4.0, 0.001) var primary_strength: float = 1.0
## Intensity multiplier for the secondary Kajiya-Kay lobe.
@export_range(0.0, 4.0, 0.001) var secondary_strength: float = 0.35
## Approximate diffuse/scatter contribution used by the Kajiya-Kay fallback.
@export_range(0.0, 1.0, 0.001) var scatter: float = 0.35

var _lut_adapter: RefCounted


## Keeps the serialized backing properties intact while presenting only controls
## that affect the selected compiled shader. Hidden properties retain
## PROPERTY_USAGE_STORAGE, so switching modes does not discard prior settings.
func _validate_property(property: Dictionary) -> void:
	var property_name: StringName = StringName(property.get("name", ""))
	var usage: int = int(property.get("usage", PROPERTY_USAGE_DEFAULT))

	# Category markers are editor-only, so remove irrelevant ones completely.
	if (usage & PROPERTY_USAGE_CATEGORY) != 0:
		var category_visible: bool = true
		match property_name:
			&"Fast Marschner":
				category_visible = quality_tier == QualityTier.FAST_MARSCHNER
			&"Cinematic Marschner":
				category_visible = quality_tier == QualityTier.CINEMATIC_MARSCHNER
			&"Approx / Kajiya-Kay":
				category_visible = quality_tier == QualityTier.APPROX
		if not category_visible:
			property["usage"] = PROPERTY_USAGE_NONE
		return

	if not _is_property_relevant(property_name):
		property["usage"] = usage & ~PROPERTY_USAGE_EDITOR


func _is_property_relevant(property_name: StringName) -> bool:
	match property_name:
		# Approx's azimuthal roughness and cuticle offset are retained for
		# serialization/variant switching but do not affect the Kajiya-Kay path.
		&"azimuthal_roughness", &"cuticle_tilt_offset":
			return quality_tier != QualityTier.APPROX

		# Fast-only absorption model and LUT.
		&"absorption_mode", &"unity_azimuthal_lut_data":
			return quality_tier == QualityTier.FAST_MARSCHNER
		&"absorption":
			return quality_tier == QualityTier.FAST_MARSCHNER and absorption_mode == 1
		&"eumelanin", &"pheomelanin", &"melanin_absorption_scale":
			return quality_tier == QualityTier.FAST_MARSCHNER and absorption_mode == 2

		# Cinematic-only controls. Fast is pinned to eta=1.55 by its LUT
		# contract; Reference keeps its existing analytic baseline interface.
		&"ior", &"cinematic_longitudinal_lut_data":
			return quality_tier == QualityTier.CINEMATIC_MARSCHNER

		# Approx-only lobe controls.
		&"primary_color", &"secondary_color", &"primary_shift", &"secondary_shift", &"primary_roughness", &"secondary_roughness", &"primary_strength", &"secondary_strength", &"scatter":
			return quality_tier == QualityTier.APPROX

	return true


## Returns the explicit compiled shader selected by [member quality_tier].
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


## Primary material authoring/runtime API.
##
## Validates a supplied groom resource before mutating the material, selects the
## compiled shader for [member quality_tier], preserves compatible caller-owned
## parameters, applies profile values, binds tier LUT resources, and finally
## applies explicit groom textures when provided.
##
## Returns false when the material is invalid, the supplied groom resource is
## incompatible/incomplete, or a required Fast/Cinematic LUT cannot be bound.
func apply_to(material: ShaderMaterial, groom_data: Resource = null) -> bool:
	if material == null:
		return false

	# Validate an explicit groom before changing any material state. This keeps
	# rejection transactional: callers that receive false for an incompatible
	# resource keep their original shader/profile/LUT state intact.
	if groom_data != null and not groom_data.has_method(&"apply_to_shader_material"):
		var groom_description: String = groom_data.resource_path
		if groom_description.is_empty():
			groom_description = groom_data.get_class()
		push_warning("HairMaterialProfile.apply_to() rejected %s: groom_data must be a HairGroomData-compatible resource that exposes apply_to_shader_material()." % groom_description)
		return false

	var target_shader: Shader = get_shader_resource()
	if target_shader == null:
		return false

	var preserved_values: Dictionary = {}
	if material.shader != null and material.shader != target_shader:
		preserved_values = _capture_shader_parameters(material, PRESERVED_SHADER_PARAMETERS)

	material.shader = target_shader
	if not preserved_values.is_empty():
		_restore_shader_parameters(material, preserved_values)

	var profile_bound: bool = _apply_profile_to_current_shader(material, true)
	var groom_bound: bool = true
	if groom_data != null:
		groom_bound = bool(groom_data.call(&"apply_to_shader_material", material, true))
	return profile_bound and groom_bound


## Creates a new ShaderMaterial, applies this profile, and optionally binds groom
## data. The material is returned even if a LUT prerequisite is missing so it can
## be inspected/fixed in the editor. Use [method apply_to] when the boolean
## success result is required by application logic.
func create_material(groom_data: Resource = null) -> ShaderMaterial:
	var material: ShaderMaterial = ShaderMaterial.new()
	apply_to(material, groom_data)
	return material


## Compatibility API for benchmark/experimental callers that deliberately own
## shader selection. Applies supported profile values/resources to the current
## shader without replacing material.shader.
func apply_to_shader_material(material: ShaderMaterial) -> void:
	_apply_profile_to_current_shader(material, true)


func _apply_profile_to_current_shader(material: ShaderMaterial, warn_on_bind_failure: bool) -> bool:
	if material == null or material.shader == null:
		return false

	var known_parameters: Dictionary = _shader_uniform_names(material.shader)
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

	for parameter_name_value in values:
		var parameter_name: StringName = StringName(parameter_name_value)
		if known_parameters.has(parameter_name):
			material.set_shader_parameter(parameter_name, values[parameter_name_value])

	var bound: bool = bind_mode_resources(material)
	if not bound and warn_on_bind_failure:
		push_warning("HairMaterialProfile could not bind the LUT required by %s. Generate the benchmark LUT resources before using this shader mode." % material.shader.resource_path)
	return bound


func _shader_uniform_names(shader: Shader) -> Dictionary:
	var known_parameters: Dictionary = {}
	if shader == null:
		return known_parameters
	var uniforms: Array = shader.get_shader_uniform_list()
	for uniform_value in uniforms:
		var uniform: Dictionary = uniform_value
		var uniform_name: StringName = StringName(uniform.get("name", ""))
		if uniform_name != &"":
			known_parameters[uniform_name] = true
	return known_parameters


func _capture_shader_parameters(material: ShaderMaterial, parameter_names: Array[StringName]) -> Dictionary:
	var captured: Dictionary = {}
	if material == null or material.shader == null:
		return captured
	var known_parameters: Dictionary = _shader_uniform_names(material.shader)
	for parameter_name in parameter_names:
		if known_parameters.has(parameter_name):
			captured[parameter_name] = material.get_shader_parameter(parameter_name)
	return captured


func _restore_shader_parameters(material: ShaderMaterial, captured: Dictionary) -> void:
	if material == null or material.shader == null:
		return
	var known_parameters: Dictionary = _shader_uniform_names(material.shader)
	for parameter_name_value in captured:
		var parameter_name: StringName = StringName(parameter_name_value)
		if known_parameters.has(parameter_name):
			material.set_shader_parameter(parameter_name, captured[parameter_name_value])


## Binds only the resource required by the material's explicit shader variant.
## Returns true for shaders that do not require a production LUT.
func bind_mode_resources(material: ShaderMaterial) -> bool:
	if material == null or material.shader == null:
		return false
	if _lut_adapter == null:
		_lut_adapter = LUTAdapter.new()
	var shader_path: String = material.shader.resource_path
	if shader_path == FAST_MARSCHNER_SHADER.resource_path:
		return _lut_adapter.bind_unity_fast(material, unity_azimuthal_lut_data)
	if shader_path == CINEMATIC_MARSCHNER_SHADER.resource_path:
		return _lut_adapter.bind_cinematic(material, cinematic_longitudinal_lut_data)
	return true


## Compatibility alias retained for existing benchmark/runtime callers.
func bind_quality_resources(material: ShaderMaterial) -> bool:
	return bind_mode_resources(material)
