extends Resource
class_name HairBenchmarkProfile

## Canonical material profile for hair benchmark variants. Source-compatible
## fields mirror the current production shader interface (hair.gdshader) and can
## be applied today by cloning the source ShaderMaterials and setting the
## matching shader_parameter values. Future-tier fields are placeholders for the
## upcoming profile adapter (R/TT/TRT lobe weights, multiple scattering,
## root/tip gradients, melanin/absorption, flow maps, coverage overrides) and
## are not yet read by the controller.

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

@export_category("Future Tier - Placeholders")
## Absorption coefficient for the dual-scattering approximation; not yet read.
@export var absorption_coefficient: Color = Color(0.0, 0.0, 0.0, 1.0)
## Melanin parameters for analytical absorption; not yet read.
@export_range(0.0, 1.0, 0.001) var melanin_concentration: float = 0.5
@export_range(0.0, 1.0, 0.001) var melanin_eumelanin_ratio: float = 0.8
## Hair index of refraction; the source shader has no IOR uniform yet.
@export var index_of_refraction: float = 1.55
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
	return errors


func is_valid() -> bool:
	return validation_errors().is_empty()
