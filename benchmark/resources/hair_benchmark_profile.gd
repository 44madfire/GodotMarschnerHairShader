extends Resource
class_name HairBenchmarkProfile

## Canonical material profile for hair benchmark variants. Source-compatible
## fields mirror the current production shader interface (hair.gdshader) and can
## be applied today by cloning the source ShaderMaterials and setting the
## matching shader_parameter values. Tier-2 (Fast Marschner) fields mirror the
## hair_marschner_fast.gdshader uniforms (absorption mode/coefficient, melanin,
## IOR) and are applied by the adapter to FAST_MARSCHNER_ANALYTIC clones.
## Remaining future-tier fields are placeholders for the upcoming profile
## adapter (R/TT/TRT lobe weights, multiple scattering, root/tip gradients,
## flow maps, coverage overrides) and are not yet read by the controller.

@export_category("Identity")
@export var profile_id: StringName = &""
@export var display_name: String = ""
@export var notes: String = ""

@export_category("Source-Compatible")
## Source shader `albedo` uniform (vec3; alpha is ignored by the shader).
@export var albedo: Color = Color(0.1, 0.1, 0.1, 1.0)
## Source shader `longitudinal_roughness` uniform (highlight width along strands).
@export_range(0.0, 1.0, 0.001) var longitudinal_roughness: float = 0.3
## Source shader `azimuthal_roughness` uniform (highlight width around strands).
@export_range(0.0, 1.0, 0.001) var azimuthal_roughness: float = 0.8
## Source shader `cuticle_tilt_offset` uniform (radians, outward tilt).
@export_range(0.0, 0.5, 0.001) var cuticle_tilt_offset: float = 0.1
## Source shader `specular` uniform (single-scattering highlight strength).
@export_range(0.0, 1.0, 0.001) var specular: float = 1.0
## Source shader `coords_texture` (RGB tangent, A u coordinate).
@export var coords_texture: Texture2D
## Source shader `attributes_texture` (R coverage, G depth, B seed).
@export var attributes_texture: Texture2D
## When true (the default, and the value of the `source_current` profile), the
## adapter preserves every per-groom parameter and texture from the cloned
## source material, so rendered behavior is unchanged. Canonical profiles set
## this false to override the source-compatible parameters below.
@export var preserve_source_parameters: bool = true

@export_category("Tier 2 - Fast Marschner")
## Mirrors hair_marschner_fast.gdshaderinc: 0 = albedo reparameterization,
## 1 = direct absorption, 2 = melanin. Applied to FAST_MARSCHNER_ANALYTIC
## clones when the target shader declares the parameter.
@export_enum("Albedo reparameterization", "Direct absorption", "Melanin") var absorption_mode: int = 0
## Direct absorption coefficient (absorption_mode = 1).
@export var absorption: Color = Color(0.1, 0.1, 0.1, 1.0)
## Melanin parameters (absorption_mode = 2).
@export_range(0.0, 1.0, 0.001) var eumelanin: float = 0.2
@export_range(0.0, 1.0, 0.001) var pheomelanin: float = 0.8
@export_range(0.0, 0.01, 0.0001) var melanin_absorption_scale: float = 0.001
## Hair index of refraction; the fast shader has an ior uniform (the source
## shader does not).
@export_range(1.0, 2.0, 0.001) var ior: float = 1.55
## Opt-in azimuthal LUT path (FAST_MARSCHNER_LUT). Default false keeps the
## analytic d'Eon azimuthal model as the reference; enabling requires the
## committed LUT data (res://benchmark/resources/luts/
## fast_marschner_azimuthal_lut_64.res).
@export var use_azimuthal_lut: bool = false
## FastMarschnerLUTData resource backing the azimuthal LUT.
@export var azimuthal_lut_data: Resource
## Opt-in local dual-scattering slice (FAST_MARSCHNER_DUAL_SCATTER variant).
## Default false keeps the Karis multiple-scattering reference for the
## analytic and LUT variants.
@export var use_dual_scatter: bool = false
## Strength of the dual-scattering diffuse term (0 = no dual diffuse).
@export_range(0.0, 2.0, 0.01) var dual_scatter_strength: float = 0.5
## Density multiplier applied to the packed attributes depth proxy.
@export_range(0.0, 1.0, 0.01) var dual_scatter_density: float = 0.5
## Opt-in Stage-B preintegrated (LUT-backed) dual-scattering slice
## (FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED variant). Default false keeps the
## analytic Stage-A local dual scattering; enabling requires the committed LUT
## data (res://benchmark/resources/luts/fast_marschner_dual_scatter_lut_64.res).
@export var use_preintegrated_dual_scatter: bool = false
## FastMarschnerDualLUTData resource backing the preintegrated dual-scatter LUT.
@export var dual_scatter_lut_data: Resource
## Opt-in fragment-stage environment response (FAST_MARSCHNER_ENVIRONMENT
## variant). Default false keeps the analytic/LUT/dual paths; the environment
## term is added via EMISSION in fragment() and is light-count invariant.
@export var use_environment: bool = false
## 2D equirectangular environment stand-in (committed
## res://benchmark/resources/textures/environment_gradient.tres).
@export var environment_texture: Texture2D
## Strength of the environment EMISSION contribution.
@export_range(0.0, 2.0, 0.01) var environment_strength: float = 1.0

@export_category("Future Tier - Placeholders")
## Marschner R/TT/TRT lobe weights; not yet read.
@export_range(0.0, 1.0, 0.001) var r_weight: float = 1.0
@export_range(0.0, 1.0, 0.001) var tt_weight: float = 0.5
@export_range(0.0, 1.0, 0.001) var trt_weight: float = 0.3
## Multiple-scattering toggle and intensity; not yet read.
@export var multiple_scattering: bool = false
@export_range(0.0, 1.0, 0.001) var multiple_scattering_intensity: float = 0.0
## Root/tip gradient colors; not yet read.
@export var root_color: Color = Color(0.1, 0.1, 0.1, 1.0)
@export var tip_color: Color = Color(0.1, 0.1, 0.1, 1.0)
## Flow texture (strand direction map); not yet read.
@export var flow_texture: Texture2D
## Coverage/alpha overrides; not yet read (the source uses attributes R plus the
## TIME-driven hash discard).
@export var coverage_override_enabled: bool = false
@export_range(0.0, 1.0, 0.001) var coverage_value: float = 1.0
@export var alpha_hash_enabled: bool = true


func validation_errors() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if String(profile_id).strip_edges().is_empty():
		errors.append("profile_id must not be empty")
	if display_name.strip_edges().is_empty():
		errors.append("display_name must not be empty")
	if longitudinal_roughness < 0.0 or longitudinal_roughness > 1.0:
		errors.append("longitudinal_roughness must be within [0, 1]")
	if azimuthal_roughness < 0.0 or azimuthal_roughness > 1.0:
		errors.append("azimuthal_roughness must be within [0, 1]")
	if cuticle_tilt_offset < 0.0 or cuticle_tilt_offset > 0.5:
		errors.append("cuticle_tilt_offset must be within [0, 0.5]")
	if specular < 0.0 or specular > 1.0:
		errors.append("specular must be within [0, 1]")
	if absorption_mode < 0 or absorption_mode > 2:
		errors.append("absorption_mode must be within [0, 2]")
	if eumelanin < 0.0 or eumelanin > 1.0:
		errors.append("eumelanin must be within [0, 1]")
	if pheomelanin < 0.0 or pheomelanin > 1.0:
		errors.append("pheomelanin must be within [0, 1]")
	if melanin_absorption_scale < 0.0 or melanin_absorption_scale > 0.01:
		errors.append("melanin_absorption_scale must be within [0, 0.01]")
	if ior < 1.0 or ior > 2.0:
		errors.append("ior must be within [1, 2]")
	if use_azimuthal_lut and azimuthal_lut_data == null:
		errors.append("use_azimuthal_lut requires azimuthal_lut_data to be assigned")
	elif azimuthal_lut_data != null and not azimuthal_lut_data.has_method(&"validation_errors"):
		errors.append("azimuthal_lut_data must expose validation_errors()")
	elif azimuthal_lut_data != null:
		var lut_errors: PackedStringArray = azimuthal_lut_data.call(&"validation_errors")
		for lut_error in lut_errors:
			errors.append("azimuthal_lut_data: %s" % lut_error)
	if use_preintegrated_dual_scatter and dual_scatter_lut_data == null:
		errors.append("use_preintegrated_dual_scatter requires dual_scatter_lut_data to be assigned")
	elif dual_scatter_lut_data != null and not dual_scatter_lut_data.has_method(&"validation_errors"):
		errors.append("dual_scatter_lut_data must expose validation_errors()")
	elif dual_scatter_lut_data != null:
		var dual_lut_errors: PackedStringArray = dual_scatter_lut_data.call(&"validation_errors")
		for lut_error in dual_lut_errors:
			errors.append("dual_scatter_lut_data: %s" % lut_error)
	if dual_scatter_strength < 0.0 or dual_scatter_strength > 2.0:
		errors.append("dual_scatter_strength must be within [0, 2]")
	if dual_scatter_density < 0.0 or dual_scatter_density > 1.0:
		errors.append("dual_scatter_density must be within [0, 1]")
	if environment_strength < 0.0 or environment_strength > 2.0:
		errors.append("environment_strength must be within [0, 2]")
	if use_environment and environment_texture == null:
		errors.append("use_environment requires environment_texture to be assigned")
	return errors


func is_valid() -> bool:
	return validation_errors().is_empty()
