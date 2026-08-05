extends RefCounted
class_name HairMaterialAdapter

## Bounded material-construction adapter for benchmark variants.
##
## Owns every material clone/parameter/alpha-hash construction step; the
## controller keeps variant selection, per-groom surface selection, and run
## bookkeeping. The adapter never edits mesh resources or source materials:
## shader variants are per-surface duplicates, and the built-in control is a
## transient StandardMaterial3D.
##
## Profile application rule: source-compatible profiles
## (preserve_source_parameters == true, the default and the value of
## `source_current`) keep every per-groom parameter and texture from the cloned
## source material, so rendered behavior is unchanged. Canonical profiles
## (preserve_source_parameters == false) override the source-compatible
## parameters and textures with the profile's values.

const PROFILES_DIRECTORY := "res://benchmark/resources/profiles"
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
	# Preview/timing/validation uniforms declared only through the shared
	# includes (hair_marschner_fast_body.gdshaderinc and the fast common
	# include): the Fast wrapper declares no uniforms of its own, so these
	# names can be missed by get_shader_uniform_list() on some import paths.
	&"comparison_exposure_gain",
	&"freeze_bayer_phase",
	&"use_area_light_multipliers",
	&"lobe_scales",
]

var _alpha_hash_texture_cache: Dictionary = {}
var _azimuthal_lut_texture_cache: Dictionary = {}
var _dual_scatter_lut_texture_cache: Dictionary = {}


## Resolves a profile_id to its HairBenchmarkProfile resource, or null when the
## profile resource does not exist or fails to load. The default profile id
## `source_current` maps to profiles/source_current.tres.
func resolve_profile(profile_id: StringName) -> Resource:
	var profile_id_text := String(profile_id).strip_edges()
	if profile_id_text.is_empty():
		return null
	var profile_path := "%s/%s.tres" % [PROFILES_DIRECTORY, profile_id_text]
	if not ResourceLoader.exists(profile_path):
		return null
	var profile: Resource = load(profile_path)
	if not profile:
		return null
	return profile


## Clones the source ShaderMaterial and swaps in the benchmark shader, then
## applies canonical profile parameters/textures (source-compatible profiles
## preserve the clone's per-groom values). Returns null on clone failure.
func make_shader_variant_material(source_material: ShaderMaterial, benchmark_shader: Shader, profile: Resource) -> ShaderMaterial:
	var cloned_material := source_material.duplicate() as ShaderMaterial
	if cloned_material == null:
		return null
	cloned_material.shader = benchmark_shader
	apply_profile_parameters(cloned_material, profile)
	return cloned_material


## Applies the profile's source-compatible parameters and textures to the given
## ShaderMaterial. With preserve_source_parameters == true (the default and the
## `source_current` profile) this is a no-op: the cloned source material keeps
## its per-groom values. With preserve_source_parameters == false the profile's
## albedo/roughness/cuticle/specular and (when set) coords/attributes textures
## override the clone's values.
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


## Builds the built-in StandardMaterial3D alpha-hash control for one surface
## from the source ShaderMaterial and profile: each source attributes texture
## (RGB, coverage in red, no alpha) is converted once into a cached in-memory
## texture with white RGB and the source red channel copied to alpha, which
## drives Godot's TRANSPARENCY_ALPHA_HASH discard. Returns null when the source
## attributes texture is missing or empty; the controller reports the failure
## with groom/surface context. The albedo color comes from the source material
## for source-compatible profiles, or from the profile for canonical profiles.
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
	# Depth write and shadow casting keep their alpha-hash defaults so the
	# built-in variant participates in shadows/depth as the hash supports.
	alpha_hash_material.albedo_color = builtin_albedo_color(source_material, profile)
	alpha_hash_material.albedo_texture = alpha_texture
	return alpha_hash_material


## Applies the Tier-2 (Fast Marschner) profile parameters to the target
## ShaderMaterial. This runs unconditionally (before the source-preserve gate)
## because source materials never define these parameters: without the mapping,
## FAST_MARSCHNER_ANALYTIC clones would silently use the shader include
## defaults. Each parameter is applied only when the target shader actually
## declares it, so coverage/baseline/Kajiya clones are never touched. The
## uniform-list gate mirrors HairMaterialProfile.apply_to_shader_material().
func _apply_tier2_parameters(material: ShaderMaterial, profile: Resource) -> void:
	if material == null or material.shader == null or profile == null:
		return
	var declared_uniforms: Dictionary = {}
	for uniform_info in material.shader.get_shader_uniform_list():
		var uniform_name_value: Variant = uniform_info.get(&"name", "")
		if StringName(uniform_name_value) != &"":
			declared_uniforms[StringName(uniform_name_value)] = true
	# Godot's uniform introspection does not expose declarations that arrive
	# through a shared .gdshaderinc on every import path. The committed Fast
	# wrappers all include the same body, so use the canonical list as a narrow
	# fallback for those paths only; other benchmark shaders remain gated by
	# get_shader_uniform_list() as before.
	var shader_path := material.shader.resource_path
	if shader_path.begins_with("res://assets/hair/materials/shaders/hair_marschner_fast"):
		for uniform_name in FAST_MARSCHNER_UNIFORMS:
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
	# The baked-IOR guards mirror the shader's 0.0005 tolerance: each eta
	# uniform is populated from the committed LUT data whenever it is declared
	# and the data resource carries an eta, so the guard never silently relies
	# on the shader default.
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
	# The U-axis tau_max metadata mirrors the eta guard: the runtime maps the
	# LUT domain with the resource's own tau_max (dual_scatter_lut_tau_max),
	# so it never silently claims a wider baked domain. Legacy resources
	# without the metadata keep the shader default (4.0, the committed domain).
	if declared_uniforms.has(&"dual_scatter_lut_tau_max"):
		var dual_scatter_data: Variant = profile.get(&"dual_scatter_lut_data")
		if dual_scatter_data != null:
			var dual_scatter_tau_max: Variant = dual_scatter_data.get(&"tau_max")
			if dual_scatter_tau_max is float and float(dual_scatter_tau_max) > 0.0:
				material.set(&"shader_parameter/dual_scatter_lut_tau_max", dual_scatter_tau_max)



## Builds (and caches) the ImageTexture3D for the committed FastMarschnerLUTData
## resource. Godot 4.7's ResourceSaver cannot self-contain an ImageTexture3D and
## its static create() does not resolve in GDScript, so the texture is built at
## runtime from the committed data with the instance create() call.
func azimuthal_lut_texture(lut_data: Resource) -> Texture3D:
	if lut_data == null:
		return null
	var cache_key: int = lut_data.get_instance_id()
	if _azimuthal_lut_texture_cache.has(cache_key):
		var cached_value: Variant = _azimuthal_lut_texture_cache[cache_key]
		return cached_value as Texture3D
	var data_value: Variant = lut_data.get(&"data")
	var size_value: Variant = lut_data.get(&"size")
	var format_value: Variant = lut_data.get(&"format")
	if not (data_value is PackedByteArray) or not (size_value is int) or not (format_value is int):
		return null
	var data: PackedByteArray = data_value
	var size: int = size_value
	var format: int = format_value
	if size <= 0:
		return null
	if data.size() != size * size * size * 16:
		return null
	# This Godot 4.7 build binds ImageTexture3D.create's data parameter as
	# Array[Image] (one Image per depth slice); a PackedByteArray is coerced
	# per element and yields an uninitialized-RID husk. Split the packed RGBAF
	# bytes into per-Z-slice Images, which Image.create_from_data accepts.
	var slice_bytes := size * size * 16
	var slices: Array[Image] = []
	for z in size:
		var slice_image: Image = Image.create_from_data(size, size, false, format, data.slice(z * slice_bytes, (z + 1) * slice_bytes))
		if slice_image == null:
			return null
		slices.append(slice_image)
	var texture := ImageTexture3D.new()
	texture.create(format, size, size, size, false, slices)
	# Verify the texture is actually usable before caching: a failed create can
	# leave an uninitialized RID that renders nothing.
	if not texture.get_rid().is_valid():
		return null
	if texture.get_width() != size or texture.get_height() != size or texture.get_depth() != size:
		return null
	_azimuthal_lut_texture_cache[cache_key] = texture
	return texture


## Builds (and caches) the ImageTexture for the committed
## FastMarschnerDualLUTData resource (Stage-B preintegrated dual-scatter LUT).
## Godot 4.7's ResourceSaver cannot self-contain an ImageTexture, so the
## texture is built at runtime from the committed raw RGBAF data. Uses the
## same defensive shape checks as azimuthal_lut_texture(), adapted to the 2D
## grid: exact byte count, a successful image decode, a valid texture RID, and
## matching dimensions.
func dual_scatter_lut_texture(lut_data: Resource) -> Texture2D:
	if lut_data == null:
		return null
	var cache_key: int = lut_data.get_instance_id()
	if _dual_scatter_lut_texture_cache.has(cache_key):
		var cached_value: Variant = _dual_scatter_lut_texture_cache[cache_key]
		return cached_value as Texture2D
	var data_value: Variant = lut_data.get(&"data")
	var size_value: Variant = lut_data.get(&"size")
	var format_value: Variant = lut_data.get(&"format")
	if not (data_value is PackedByteArray) or not (size_value is int) or not (format_value is int):
		return null
	var data: PackedByteArray = data_value
	var size: int = size_value
	var format: int = format_value
	if size <= 0:
		return null
	if data.size() != size * size * 16:
		return null
	var image := Image.create_from_data(size, size, false, format, data)
	if image == null:
		return null
	var texture := ImageTexture.create_from_image(image)
	# Verify the texture is actually usable before caching: a failed create can
	# leave an uninitialized RID that renders nothing.
	if not texture.get_rid().is_valid():
		return null
	if texture.get_width() != size or texture.get_height() != size:
		return null
	_dual_scatter_lut_texture_cache[cache_key] = texture
	return texture


## Reads the source shader's albedo parameter. The source declares vec3 albedo,
## which Godot exposes as a Color; alpha is forced to 1 so the converted albedo
## texture alpha alone drives the alpha-hash discard.
func source_albedo_color(source_material: ShaderMaterial) -> Color:
	var albedo_value: Variant = source_material.get(&"shader_parameter/albedo")
	if albedo_value is Color:
		var albedo_color: Color = albedo_value
		return Color(albedo_color.r, albedo_color.g, albedo_color.b, 1.0)
	if albedo_value is Vector3:
		var albedo_vector: Vector3 = albedo_value
		return Color(albedo_vector.x, albedo_vector.y, albedo_vector.z, 1.0)
	return Color(0.1, 0.1, 0.1, 1.0)


## Albedo for the built-in control: the source material's albedo for
## source-compatible profiles, or the profile's albedo (alpha forced to 1) for
## canonical profiles.
func builtin_albedo_color(source_material: ShaderMaterial, profile: Resource) -> Color:
	if profile == null or bool(profile.get(&"preserve_source_parameters")):
		return source_albedo_color(source_material)
	var profile_albedo_value: Variant = profile.get(&"albedo")
	if profile_albedo_value is Color:
		var profile_albedo: Color = profile_albedo_value
		return Color(profile_albedo.r, profile_albedo.g, profile_albedo.b, 1.0)
	return source_albedo_color(source_material)


## Returns a cached transient ImageTexture with white RGB and the source red
## channel copied to alpha. Keyed by the source resource path (or instance id
## for pathless textures) so each source attributes texture is converted only
## once per process. The result is never saved to disk or imported.
func alpha_texture_for(source_texture: Texture2D) -> ImageTexture:
	if not source_texture:
		return null
	var cache_key: Variant = source_texture.resource_path
	if String(cache_key).is_empty():
		cache_key = int(source_texture.get_instance_id())
	if _alpha_hash_texture_cache.has(cache_key):
		var cached_value: Variant = _alpha_hash_texture_cache[cache_key]
		return cached_value as ImageTexture

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
