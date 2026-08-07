extends RefCounted
class_name HairMaterialAdapter

## Bounded material-construction adapter for benchmark variants. Variant
## materials are transient per-surface clones; source mesh/material resources
## are never edited.

const PROFILES_DIRECTORY := "res://benchmark/resources/profiles"
const R_STANDARDIZED_SHADER_PATH := "res://assets/hair/materials/shaders/hair_marschner_fast_r_standardized_lut.gdshader"
const R_STANDARDIZED_LUT_DATA_PATH := "res://benchmark/resources/luts/fast_marschner_r_standardized_lut_256x256x128.res"
const R_STANDARDIZED_CONTRACT := "standardized_r_projected_q_v1"
const R_STANDARDIZED_CHANNELS := "R=linear_Q,G=log2_Q,B=0,A=1"
const R_STANDARDIZED_LOW_BETA_BLEND := Vector2(0.015, 0.03)

const FAST_MARSCHNER_UNIFORMS: Array[StringName] = [
	&"absorption_mode",
	&"absorption",
	&"eumelanin",
	&"pheomelanin",
	&"melanin_absorption_scale",
	&"ior",
	&"use_azimuthal_lut",
	&"azimuthal_lut",
	&"azimuthal_lut_eta",
	&"use_dual_scatter",
	&"dual_scatter_strength",
	&"dual_scatter_density",
	&"use_preintegrated_dual_scatter",
	&"dual_scatter_lut",
	&"dual_scatter_lut_eta",
	&"dual_scatter_lut_tau_max",
	&"use_environment",
	&"environment_texture",
	&"environment_strength",
	&"r_standardized_lut",
	&"r_standardized_lut_log_decode",
	&"r_standardized_lut_q_range",
	&"r_standardized_lut_theta_cone_range",
	&"r_standardized_lut_beta_range",
	&"r_standardized_lut_low_beta_blend",
	&"comparison_exposure_gain",
	&"freeze_bayer_phase",
	&"use_area_light_multipliers",
	&"lobe_scales",
]

const FAST_MARSCHNER_SOURCE_UNIFORMS: Array[StringName] = [
	&"albedo",
	&"longitudinal_roughness",
	&"azimuthal_roughness",
	&"specular",
	&"cuticle_tilt_offset",
	&"coords_texture",
	&"attributes_texture",
	&"show_hair_cards",
	&"show_hashed_strands",
	&"freeze_bayer_phase",
	&"comparison_exposure_gain",
	&"use_area_light_multipliers",
	&"lobe_scales",
]

var _alpha_hash_texture_cache: Dictionary = {}
var _azimuthal_lut_texture_cache: Dictionary = {}
var _dual_scatter_lut_texture_cache: Dictionary = {}
var _r_standardized_lut_texture_cache: Dictionary = {}

func resolve_profile(profile_id: StringName) -> Resource:
	var profile_id_text := String(profile_id).strip_edges()
	if profile_id_text.is_empty():
		return null
	var profile_path := "%s/%s.tres" % [PROFILES_DIRECTORY, profile_id_text]
	if not ResourceLoader.exists(profile_path):
		return null
	var profile: Resource = load(profile_path)
	return profile

func make_shader_variant_material(source_material: ShaderMaterial, benchmark_shader: Shader, profile: Resource) -> ShaderMaterial:
	var cloned_material := source_material.duplicate() as ShaderMaterial
	if cloned_material == null:
		return null
	var source_parameters: Dictionary = {}
	for parameter_name in FAST_MARSCHNER_SOURCE_UNIFORMS:
		var source_value: Variant = source_material.get_shader_parameter(parameter_name)
		if source_value != null:
			source_parameters[parameter_name] = source_value
	cloned_material.shader = benchmark_shader
	for parameter_name in source_parameters:
		cloned_material.set("shader_parameter/%s" % String(parameter_name), source_parameters[parameter_name])
	apply_profile_parameters(cloned_material, profile)

	# The standardized diagnostic owns an additional LUT-domain contract that
	# source materials/profiles do not carry. Bind it here, where the adapter
	# already owns texture creation, so shader sampling cannot silently drift
	# from the committed resource metadata. The controller may subsequently
	# re-bind the same cached texture/selector while forcing variant flags off.
	if benchmark_shader != null and benchmark_shader.resource_path == R_STANDARDIZED_SHADER_PATH:
		var lut_data: Resource = load(R_STANDARDIZED_LUT_DATA_PATH)
		if not apply_standardized_r_lut_contract(cloned_material, lut_data):
			return null
	return cloned_material

func apply_profile_parameters(material: ShaderMaterial, profile: Resource) -> void:
	if material == null or profile == null:
		return
	_apply_tier2_parameters(material, profile)
	if bool(profile.get(&"preserve_source_parameters")):
		return
	var parameter_names: Array[StringName] = [
		&"shader_parameter/albedo",
		&"shader_parameter/longitudinal_roughness",
		&"shader_parameter/azimuthal_roughness",
		&"shader_parameter/cuticle_tilt_offset",
		&"shader_parameter/specular",
	]
	for parameter_name in parameter_names:
		var parameter_value: Variant = profile.get(String(parameter_name).trim_prefix("shader_parameter/"))
		material.set(parameter_name, parameter_value)
	var coords_value: Variant = profile.get(&"coords_texture")
	if coords_value is Texture2D:
		material.set(&"shader_parameter/coords_texture", coords_value)
	var attributes_value: Variant = profile.get(&"attributes_texture")
	if attributes_value is Texture2D:
		material.set(&"shader_parameter/attributes_texture", attributes_value)

func make_builtin_alpha_hash_material(source_material: ShaderMaterial, profile: Resource) -> StandardMaterial3D:
	if source_material == null:
		return null
	var attributes_value: Variant = source_material.get(&"shader_parameter/attributes_texture")
	var attributes_texture: Texture2D = attributes_value as Texture2D
	if not attributes_texture:
		return null
	var alpha_texture: ImageTexture = alpha_texture_for(attributes_texture)
	if not alpha_texture:
		return null
	var alpha_hash_material := StandardMaterial3D.new()
	alpha_hash_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_HASH
	alpha_hash_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	alpha_hash_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	alpha_hash_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	alpha_hash_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	alpha_hash_material.roughness = 1.0
	alpha_hash_material.albedo_color = builtin_albedo_color(source_material, profile)
	alpha_hash_material.albedo_texture = alpha_texture
	return alpha_hash_material

func _apply_tier2_parameters(material: ShaderMaterial, profile: Resource) -> void:
	if material == null or material.shader == null or profile == null:
		return
	var declared_uniforms: Dictionary = {}
	for uniform_info in material.shader.get_shader_uniform_list():
		var uniform_name_value: Variant = uniform_info.get(&"name", "")
		if StringName(uniform_name_value) != &"":
			declared_uniforms[StringName(uniform_name_value)] = true
	var shader_path := material.shader.resource_path
	if shader_path.begins_with("res://assets/hair/materials/shaders/hair_marschner_fast"):
		for uniform_name in FAST_MARSCHNER_UNIFORMS:
			declared_uniforms[uniform_name] = true
		for uniform_name in FAST_MARSCHNER_SOURCE_UNIFORMS:
			declared_uniforms[uniform_name] = true
	var tier2_parameters := {
		&"absorption_mode": profile.get(&"absorption_mode"),
		&"absorption": profile.get(&"absorption"),
		&"eumelanin": profile.get(&"eumelanin"),
		&"pheomelanin": profile.get(&"pheomelanin"),
		&"melanin_absorption_scale": profile.get(&"melanin_absorption_scale"),
		&"ior": profile.get(&"ior"),
		&"use_azimuthal_lut": profile.get(&"use_azimuthal_lut"),
		&"use_dual_scatter": profile.get(&"use_dual_scatter"),
		&"dual_scatter_strength": profile.get(&"dual_scatter_strength"),
		&"dual_scatter_density": profile.get(&"dual_scatter_density"),
		&"use_preintegrated_dual_scatter": profile.get(&"use_preintegrated_dual_scatter"),
		&"use_environment": profile.get(&"use_environment"),
		&"environment_texture": profile.get(&"environment_texture"),
		&"environment_strength": profile.get(&"environment_strength"),
	}
	for parameter_name in tier2_parameters:
		if declared_uniforms.has(parameter_name):
			material.set("shader_parameter/%s" % parameter_name, tier2_parameters[parameter_name])
	if declared_uniforms.has(&"azimuthal_lut") and bool(profile.get(&"use_azimuthal_lut")):
		var lut_texture: Texture3D = azimuthal_lut_texture(profile.get(&"azimuthal_lut_data"))
		if lut_texture != null:
			material.set(&"shader_parameter/azimuthal_lut", lut_texture)
	if declared_uniforms.has(&"azimuthal_lut_eta"):
		var azimuthal_data: Variant = profile.get(&"azimuthal_lut_data")
		if azimuthal_data != null:
			var azimuthal_eta: Variant = azimuthal_data.get(&"eta")
			if azimuthal_eta is float:
				material.set(&"shader_parameter/azimuthal_lut_eta", azimuthal_eta)
	if declared_uniforms.has(&"dual_scatter_lut") and bool(profile.get(&"use_preintegrated_dual_scatter")):
		var dual_lut_texture: Texture2D = dual_scatter_lut_texture(profile.get(&"dual_scatter_lut_data"))
		if dual_lut_texture != null:
			material.set(&"shader_parameter/dual_scatter_lut", dual_lut_texture)
	if declared_uniforms.has(&"dual_scatter_lut_eta"):
		var dual_scatter_data: Variant = profile.get(&"dual_scatter_lut_data")
		if dual_scatter_data != null:
			var dual_scatter_eta: Variant = dual_scatter_data.get(&"eta")
			if dual_scatter_eta is float:
				material.set(&"shader_parameter/dual_scatter_lut_eta", dual_scatter_eta)
	if declared_uniforms.has(&"dual_scatter_lut_tau_max"):
		var dual_scatter_data: Variant = profile.get(&"dual_scatter_lut_data")
		if dual_scatter_data != null:
			var dual_scatter_tau_max: Variant = dual_scatter_data.get(&"tau_max")
			if dual_scatter_tau_max is float and float(dual_scatter_tau_max) > 0.0:
				material.set(&"shader_parameter/dual_scatter_lut_tau_max", dual_scatter_tau_max)

func azimuthal_lut_texture(lut_data: Resource) -> Texture3D:
	if lut_data == null:
		return null
	var cache_key: int = lut_data.get_instance_id()
	if _azimuthal_lut_texture_cache.has(cache_key):
		return _azimuthal_lut_texture_cache[cache_key] as Texture3D
	var data_value: Variant = lut_data.get(&"data")
	var size_value: Variant = lut_data.get(&"size")
	var format_value: Variant = lut_data.get(&"format")
	if not (data_value is PackedByteArray) or not (size_value is int) or not (format_value is int):
		return null
	var data: PackedByteArray = data_value
	var size: int = size_value
	var format: int = format_value
	if size <= 0 or data.size() != size * size * size * 16:
		return null
	var slice_bytes := size * size * 16
	var slices: Array[Image] = []
	for z in size:
		var slice_image: Image = Image.create_from_data(size, size, false, format, data.slice(z * slice_bytes, (z + 1) * slice_bytes))
		if slice_image == null:
			return null
		slices.append(slice_image)
	var texture := ImageTexture3D.new()
	texture.create(format, size, size, size, false, slices)
	if not texture.get_rid().is_valid() or texture.get_width() != size or texture.get_height() != size or texture.get_depth() != size:
		return null
	_azimuthal_lut_texture_cache[cache_key] = texture
	return texture

func dual_scatter_lut_texture(lut_data: Resource) -> Texture2D:
	if lut_data == null:
		return null
	var cache_key: int = lut_data.get_instance_id()
	if _dual_scatter_lut_texture_cache.has(cache_key):
		return _dual_scatter_lut_texture_cache[cache_key] as Texture2D
	var data_value: Variant = lut_data.get(&"data")
	var size_value: Variant = lut_data.get(&"size")
	var format_value: Variant = lut_data.get(&"format")
	if not (data_value is PackedByteArray) or not (size_value is int) or not (format_value is int):
		return null
	var data: PackedByteArray = data_value
	var size: int = size_value
	var format: int = format_value
	if size <= 0 or data.size() != size * size * 16:
		return null
	var image := Image.create_from_data(size, size, false, format, data)
	if image == null:
		return null
	var texture := ImageTexture.create_from_image(image)
	if not texture.get_rid().is_valid() or texture.get_width() != size or texture.get_height() != size:
		return null
	_dual_scatter_lut_texture_cache[cache_key] = texture
	return texture

## Returns contract errors for the current standardized-R diagnostic resource.
## This is deliberately stricter than generic Resource.validation_errors(): a
## resource may be structurally valid yet incompatible with this wrapper's
## channel/decode contract.
func standardized_r_lut_contract_errors(lut_data: Resource) -> PackedStringArray:
	var errors := PackedStringArray()
	if lut_data == null:
		errors.append("resource is null")
		return errors
	if not lut_data.has_method(&"validation_errors"):
		errors.append("resource must expose validation_errors()")
		return errors
	var nested: Variant = lut_data.call(&"validation_errors")
	if nested is PackedStringArray:
		for message in nested:
			errors.append(message)
	else:
		errors.append("validation_errors() must return PackedStringArray")
	if String(lut_data.get(&"contract")) != R_STANDARDIZED_CONTRACT:
		errors.append("contract must be %s" % R_STANDARDIZED_CONTRACT)
	if String(lut_data.get(&"channels")) != R_STANDARDIZED_CHANNELS:
		errors.append("channels must be %s" % R_STANDARDIZED_CHANNELS)
	var format_value: Variant = lut_data.get(&"format")
	if not (format_value is int) or int(format_value) != Image.FORMAT_RGBAF:
		errors.append("diagnostic v1 resource must use Image.FORMAT_RGBAF")
	for range_pair in [[&"q_min", &"q_max", "q"], [&"theta_cone_min", &"theta_cone_max", "theta_cone"], [&"beta_min", &"beta_max", "beta"]]:
		var min_value: Variant = lut_data.get(range_pair[0])
		var max_value: Variant = lut_data.get(range_pair[1])
		if not (min_value is float or min_value is int) or not (max_value is float or max_value is int):
			errors.append("%s range metadata missing" % range_pair[2])
			continue
		var min_float := float(min_value)
		var max_float := float(max_value)
		if not is_finite(min_float) or not is_finite(max_float) or max_float <= min_float:
			errors.append("%s range must be finite/increasing" % range_pair[2])
	if float(lut_data.get(&"beta_min")) <= 0.0:
		errors.append("beta_min must be > 0")
	if bool(lut_data.get(&"raw_m_unit_normalization_claimed")):
		errors.append("raw_m_unit_normalization_claimed must be false")
	return errors

func standardized_r_lut_texture(lut_data: Resource) -> Texture3D:
	if not standardized_r_lut_contract_errors(lut_data).is_empty():
		return null
	var cache_key: int = lut_data.get_instance_id()
	if _r_standardized_lut_texture_cache.has(cache_key):
		return _r_standardized_lut_texture_cache[cache_key] as Texture3D
	var data: PackedByteArray = lut_data.get(&"data")
	var size_x := int(lut_data.get(&"size_x"))
	var size_y := int(lut_data.get(&"size_y"))
	var size_z := int(lut_data.get(&"size_z"))
	var format := int(lut_data.get(&"format"))
	if size_x <= 0 or size_y <= 0 or size_z <= 0 or data.size() != size_x * size_y * size_z * 16:
		return null
	var slice_bytes := size_x * size_y * 16
	var slices: Array[Image] = []
	for z in size_z:
		var slice_image: Image = Image.create_from_data(size_x, size_y, false, format, data.slice(z * slice_bytes, (z + 1) * slice_bytes))
		if slice_image == null:
			return null
		slices.append(slice_image)
	var texture := ImageTexture3D.new()
	texture.create(format, size_x, size_y, size_z, false, slices)
	if not texture.get_rid().is_valid() or texture.get_width() != size_x or texture.get_height() != size_y or texture.get_depth() != size_z:
		return null
	_r_standardized_lut_texture_cache[cache_key] = texture
	return texture

## Bind the texture and every coordinate-domain uniform from resource metadata.
## This makes the resource, rather than duplicated shader constants, the
## authoritative sampling contract for the current diagnostic wrapper.
func apply_standardized_r_lut_contract(material: ShaderMaterial, lut_data: Resource) -> bool:
	if material == null or material.shader == null:
		return false
	var errors := standardized_r_lut_contract_errors(lut_data)
	if not errors.is_empty():
		push_warning("standardized R LUT contract rejected: %s" % "; ".join(errors))
		return false
	var texture := standardized_r_lut_texture(lut_data)
	if texture == null:
		return false
	material.set(&"shader_parameter/r_standardized_lut", texture)
	material.set(&"shader_parameter/r_standardized_lut_log_decode", false)
	material.set(&"shader_parameter/r_standardized_lut_q_range", Vector2(float(lut_data.get(&"q_min")), float(lut_data.get(&"q_max"))))
	material.set(&"shader_parameter/r_standardized_lut_theta_cone_range", Vector2(float(lut_data.get(&"theta_cone_min")), float(lut_data.get(&"theta_cone_max"))))
	material.set(&"shader_parameter/r_standardized_lut_beta_range", Vector2(float(lut_data.get(&"beta_min")), float(lut_data.get(&"beta_max"))))
	material.set(&"shader_parameter/r_standardized_lut_low_beta_blend", R_STANDARDIZED_LOW_BETA_BLEND)
	return true

func source_albedo_color(source_material: ShaderMaterial) -> Color:
	var albedo_value: Variant = source_material.get(&"shader_parameter/albedo")
	if albedo_value is Color:
		var albedo_color: Color = albedo_value
		return Color(albedo_color.r, albedo_color.g, albedo_color.b, 1.0)
	if albedo_value is Vector3:
		var albedo_vector: Vector3 = albedo_value
		return Color(albedo_vector.x, albedo_vector.y, albedo_vector.z, 1.0)
	return Color(0.1, 0.1, 0.1, 1.0)

func builtin_albedo_color(source_material: ShaderMaterial, profile: Resource) -> Color:
	if profile == null or bool(profile.get(&"preserve_source_parameters")):
		return source_albedo_color(source_material)
	var profile_albedo_value: Variant = profile.get(&"albedo")
	if profile_albedo_value is Color:
		var profile_albedo: Color = profile_albedo_value
		return Color(profile_albedo.r, profile_albedo.g, profile_albedo.b, 1.0)
	return source_albedo_color(source_material)

func alpha_texture_for(source_texture: Texture2D) -> ImageTexture:
	if not source_texture:
		return null
	var cache_key: Variant = source_texture.resource_path
	if String(cache_key).is_empty():
		cache_key = int(source_texture.get_instance_id())
	if _alpha_hash_texture_cache.has(cache_key):
		return _alpha_hash_texture_cache[cache_key] as ImageTexture
	var source_image: Image = source_texture.get_image()
	if not source_image or source_image.get_width() <= 0 or source_image.get_height() <= 0:
		return null
	source_image.convert(Image.FORMAT_RGBA8)
	var pixels: PackedByteArray = source_image.get_data()
	var pixel_count := pixels.size() >> 2
	for pixel_index in pixel_count:
		var offset := pixel_index << 2
		var coverage_byte: int = pixels[offset]
		pixels[offset] = 255
		pixels[offset + 1] = 255
		pixels[offset + 2] = 255
		pixels[offset + 3] = coverage_byte
	var alpha_image := Image.create_from_data(source_image.get_width(), source_image.get_height(), false, Image.FORMAT_RGBA8, pixels)
	if not alpha_image:
		return null
	var alpha_texture := ImageTexture.create_from_image(alpha_image)
	_alpha_hash_texture_cache[cache_key] = alpha_texture
	return alpha_texture
