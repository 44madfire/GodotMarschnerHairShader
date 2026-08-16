@tool
extends Resource
class_name HairMaterialProfile

## User-facing hair material profile.
##
## Presents one authoring surface while keeping Approx, Fast Marschner, and
## Cinematic Marschner as separate compiled shaders. Pair this resource with
## HairGroomData for new hair-card grooms.
##
## Coverage AUTO is editor-safe: without a runtime viewport it resolves to a
## stable Bayer phase. With HairCoverageController, AUTO follows viewport AA:
## MSAA -> alpha-to-coverage, otherwise TAA -> temporal Bayer, otherwise static.
##
## Optical wetness changes only the shading response. Groom clumping, strand
## adhesion, weight, and other geometry changes belong to the groom/deformation
## pipeline rather than this material profile.

enum QualityTier {
	APPROX = 0,
	FAST_MARSCHNER = 1,
	CINEMATIC_MARSCHNER = 2,
}

const APPROX_SHADER: Shader = preload("res://addons/marschner_hair/shaders/hair_approx.gdshader")
const FAST_MARSCHNER_SHADER: Shader = preload("res://addons/marschner_hair/shaders/hair_marschner_fast.gdshader")
const CINEMATIC_MARSCHNER_SHADER: Shader = preload("res://addons/marschner_hair/shaders/hair_marschner_cinematic.gdshader")
const APPROX_A2C_SHADER: Shader = preload("res://addons/marschner_hair/shaders/hair_approx_a2c.gdshader")
const FAST_MARSCHNER_A2C_SHADER: Shader = preload("res://addons/marschner_hair/shaders/hair_marschner_fast_a2c.gdshader")
const CINEMATIC_MARSCHNER_A2C_SHADER: Shader = preload("res://addons/marschner_hair/shaders/hair_marschner_cinematic_a2c.gdshader")
const LUTAdapter := preload("res://addons/marschner_hair/hair_marschner_lut_adapter.gd")
const CoveragePolicy := preload("res://addons/marschner_hair/hair_coverage_policy.gd")
const ShaderUtils := preload("res://addons/marschner_hair/internal/hair_shader_utils.gd")

## Shader parameters intentionally owned by the groom/material rather than this
## profile. apply_to() carries them across compiled shader changes when both the
## previous and target shaders expose the parameter.
const PRESERVED_SHADER_PARAMETERS: Array[StringName] = [
	&"coords_texture",
	&"attributes_texture",
	&"show_hair_cards",
	&"show_hashed_strands",
	&"bayer_phase_index",
	&"freeze_bayer_phase",
	&"comparison_exposure_gain",
	&"lobe_scales",
	&"use_area_light_multipliers",
]


# --- Authoring properties ----------------------------------------------------

@export_category("Quality")
## Selects the compiled lighting model. Switching this value also refreshes the
## Inspector and hides controls that are irrelevant to the chosen tier.
@export_enum("Approx / Kajiya-Kay", "Fast Marschner", "Cinematic Marschner")
var quality_tier: int = QualityTier.APPROX:
	set(value):
		var clamped_value: int = clampi(value, QualityTier.APPROX, QualityTier.CINEMATIC_MARSCHNER)
		if quality_tier == clamped_value:
			return
		quality_tier = clamped_value
		notify_property_list_changed()

@export_category("Coverage")
## AUTO chooses alpha-to-coverage when 3D MSAA is active, otherwise a 16-phase
## rendered-frame Bayer sequence when TAA is active, otherwise stable Bayer.
## Explicit modes are primarily for debugging or custom render pipelines.
@export_enum("Auto", "Static Bayer", "TAA Temporal Bayer", "Alpha-to-Coverage")
var coverage_mode: int = CoveragePolicy.Mode.AUTO

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

@export_category("Wetness")
## Optical wetness from 0 (dry) to 1 (saturated). The dry value is a strict
## compatibility point: at 0 the wetness helpers reduce to the prior dry model.
@export_range(0.0, 1.0, 0.001) var wetness: float = 0.0
## Roughness of the added dielectric water-film highlight.
@export_range(0.015, 1.0, 0.001) var wet_film_roughness: float = 0.10
## Intensity of the untinted water-film reflection at full wetness.
@export_range(0.0, 4.0, 0.001) var wet_film_specular_strength: float = 2.0
## Multiplier applied to longitudinal highlight roughness at full wetness.
@export_range(0.05, 1.0, 0.001) var wet_longitudinal_roughness_scale: float = 0.45
## Multiplier applied to azimuthal roughness at full wetness.
@export_range(0.05, 1.0, 0.001) var wet_azimuthal_roughness_scale: float = 0.55
## Remaining diffuse/multiple-scattering intensity at full wetness.
@export_range(0.0, 1.0, 0.001) var wet_internal_scatter_scale: float = 0.35
## Remaining Marschner TT/TRT transport at full wetness.
@export_range(0.0, 1.0, 0.001) var wet_transmission_scale: float = 0.65
## Remaining cuticle/tangent-shift separation at full wetness.
@export_range(0.0, 1.0, 0.001) var wet_cuticle_shift_scale: float = 0.5

@export_category("Fast Marschner")
## Selects how Fast Marschner derives the absorption coefficient.
@export_enum("Albedo reparameterization", "Direct absorption", "Melanin")
var absorption_mode: int = 0:
	set(value):
		var clamped_value: int = clampi(value, 0, 2)
		if absorption_mode == clamped_value:
			return
		absorption_mode = clamped_value
		notify_property_list_changed()
## Direct RGB absorption coefficient used when absorption mode is Direct.
@export var absorption: Color = Color(0.1, 0.1, 0.1, 1.0)
## Relative eumelanin amount used by Fast Marschner's melanin absorption mode.
@export_range(0.0, 1.0, 0.001) var eumelanin: float = 0.2
## Relative pheomelanin amount used by Fast Marschner's melanin absorption mode.
@export_range(0.0, 1.0, 0.001) var pheomelanin: float = 0.8
## Multiplier applied to the melanin absorption coefficients.
@export_range(0.0, 0.01, 0.0001) var melanin_absorption_scale: float = 0.001
## Optional Fast Marschner azimuthal Texture3D override. Leave null to load the
## packaged production LUT.
@export var unity_azimuthal_lut_data: Resource

@export_category("Cinematic Marschner")
## Fiber index of refraction used by Cinematic Marschner.
@export_range(1.0, 2.0, 0.001) var ior: float = 1.55
## Optional conditioned longitudinal Texture3D override. Leave null to load the
## packaged production LUT.
@export var cinematic_longitudinal_lut_data: Resource

@export_category("Approx / Kajiya-Kay")
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


# --- Inspector filtering -----------------------------------------------------

func _validate_property(property: Dictionary) -> void:
	var property_name: StringName = StringName(property.get("name", ""))
	var usage: int = int(property.get("usage", PROPERTY_USAGE_DEFAULT))

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
		&"azimuthal_roughness", &"cuticle_tilt_offset":
			return quality_tier != QualityTier.APPROX
		&"absorption_mode", &"unity_azimuthal_lut_data":
			return quality_tier == QualityTier.FAST_MARSCHNER
		&"absorption":
			return quality_tier == QualityTier.FAST_MARSCHNER and absorption_mode == 1
		&"eumelanin", &"pheomelanin", &"melanin_absorption_scale":
			return quality_tier == QualityTier.FAST_MARSCHNER and absorption_mode == 2
		&"ior", &"cinematic_longitudinal_lut_data":
			return quality_tier == QualityTier.CINEMATIC_MARSCHNER
		&"primary_color", &"secondary_color", &"primary_shift", &"secondary_shift", &"primary_roughness", &"secondary_roughness", &"primary_strength", &"secondary_strength", &"scatter":
			return quality_tier == QualityTier.APPROX
	return true


# --- Shader selection and coverage ------------------------------------------

func get_shader_resource(viewport: Viewport = null) -> Shader:
	return _shader_for_effective_coverage(get_effective_coverage_mode(viewport))


func get_effective_coverage_mode(viewport: Viewport = null) -> int:
	return CoveragePolicy.resolve(viewport, coverage_mode)


func _shader_for_effective_coverage(effective_mode: int) -> Shader:
	var use_a2c: bool = CoveragePolicy.uses_alpha_to_coverage(effective_mode)
	match quality_tier:
		QualityTier.APPROX:
			return APPROX_A2C_SHADER if use_a2c else APPROX_SHADER
		QualityTier.FAST_MARSCHNER:
			return FAST_MARSCHNER_A2C_SHADER if use_a2c else FAST_MARSCHNER_SHADER
		QualityTier.CINEMATIC_MARSCHNER:
			return CINEMATIC_MARSCHNER_A2C_SHADER if use_a2c else CINEMATIC_MARSCHNER_SHADER
	return APPROX_A2C_SHADER if use_a2c else APPROX_SHADER


# --- Material binding --------------------------------------------------------

func apply_to(material: ShaderMaterial, groom_data: Resource = null, viewport: Viewport = null) -> bool:
	if material == null:
		return false

	if groom_data != null and not groom_data.has_method(&"apply_to_shader_material"):
		var groom_description: String = groom_data.resource_path
		if groom_description.is_empty():
			groom_description = groom_data.get_class()
		push_warning("HairMaterialProfile.apply_to() rejected %s: groom_data must expose apply_to_shader_material()." % groom_description)
		return false

	var target_shader: Shader = get_shader_resource(viewport)
	if target_shader == null:
		return false

	var preserved_values: Dictionary = {}
	if material.shader != null and material.shader != target_shader:
		preserved_values = ShaderUtils.capture_parameters(material, PRESERVED_SHADER_PARAMETERS)

	material.shader = target_shader
	if not preserved_values.is_empty():
		ShaderUtils.restore_parameters(material, preserved_values)

	var profile_bound: bool = _apply_profile_to_current_shader(material, true)
	var groom_bound: bool = true
	if groom_data != null:
		groom_bound = bool(groom_data.call(&"apply_to_shader_material", material, true))
	var coverage_bound: bool = _set_coverage_phase(material, get_effective_coverage_mode(viewport), Engine.get_frames_drawn())
	return profile_bound and groom_bound and coverage_bound


func create_material(groom_data: Resource = null, viewport: Viewport = null) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	apply_to(material, groom_data, viewport)
	return material


func update_coverage_for_viewport(material: ShaderMaterial, viewport: Viewport, rendered_frame_index: int = -1) -> bool:
	if material == null:
		return false
	var effective_mode: int = get_effective_coverage_mode(viewport)
	var target_shader: Shader = _shader_for_effective_coverage(effective_mode)
	if material.shader != target_shader:
		if not apply_to(material, null, viewport):
			return false
	var frame_index: int = rendered_frame_index if rendered_frame_index >= 0 else Engine.get_frames_drawn()
	return _set_coverage_phase(material, effective_mode, frame_index)


func _set_coverage_phase(material: ShaderMaterial, effective_mode: int, rendered_frame_index: int) -> bool:
	if material == null or material.shader == null:
		return false
	if CoveragePolicy.uses_alpha_to_coverage(effective_mode):
		return true
	var known_parameters: Dictionary = ShaderUtils.uniform_names(material.shader)
	if not known_parameters.has(&"bayer_phase_index"):
		return false
	material.set_shader_parameter(&"bayer_phase_index", CoveragePolicy.bayer_phase(effective_mode, rendered_frame_index))
	return true


## Compatibility API for callers that deliberately own shader selection.
func apply_to_shader_material(material: ShaderMaterial) -> void:
	_apply_profile_to_current_shader(material, true)


func _apply_profile_to_current_shader(material: ShaderMaterial, warn_on_bind_failure: bool) -> bool:
	if material == null or material.shader == null:
		return false

	var known_parameters: Dictionary = ShaderUtils.uniform_names(material.shader)
	var values: Dictionary = {
		&"albedo": albedo,
		&"longitudinal_roughness": longitudinal_roughness,
		&"azimuthal_roughness": azimuthal_roughness,
		&"specular": specular,
		&"cuticle_tilt_offset": cuticle_tilt_offset,
		&"wetness": wetness,
		&"wet_film_roughness": wet_film_roughness,
		&"wet_film_specular_strength": wet_film_specular_strength,
		&"wet_longitudinal_roughness_scale": wet_longitudinal_roughness_scale,
		&"wet_azimuthal_roughness_scale": wet_azimuthal_roughness_scale,
		&"wet_internal_scatter_scale": wet_internal_scatter_scale,
		&"wet_transmission_scale": wet_transmission_scale,
		&"wet_cuticle_shift_scale": wet_cuticle_shift_scale,
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
		var parameter_name := StringName(parameter_name_value)
		if known_parameters.has(parameter_name):
			material.set_shader_parameter(parameter_name, values[parameter_name_value])

	var bound: bool = bind_mode_resources(material)
	if not bound and warn_on_bind_failure:
		push_warning("HairMaterialProfile could not bind the packaged LUT required by %s." % material.shader.resource_path)
	return bound


# --- Tier resources ----------------------------------------------------------

func bind_mode_resources(material: ShaderMaterial) -> bool:
	if material == null or material.shader == null:
		return false
	if _lut_adapter == null:
		_lut_adapter = LUTAdapter.new()
	var shader_path: String = material.shader.resource_path
	if shader_path == FAST_MARSCHNER_SHADER.resource_path or shader_path == FAST_MARSCHNER_A2C_SHADER.resource_path:
		return _lut_adapter.bind_fast(material, unity_azimuthal_lut_data)
	if shader_path == CINEMATIC_MARSCHNER_SHADER.resource_path or shader_path == CINEMATIC_MARSCHNER_A2C_SHADER.resource_path:
		return _lut_adapter.bind_cinematic(material, cinematic_longitudinal_lut_data)
	return true


## Compatibility alias for bind_mode_resources().
func bind_quality_resources(material: ShaderMaterial) -> bool:
	return bind_mode_resources(material)
