extends SceneTree

## Headless production material/profile wiring test. Run after generating the two
## default LUT resources. In addition to the Fast/Cinematic LUT contracts, this
## verifies the consolidated authoring API: dynamic mode-specific Inspector
## visibility, automatic compiled-shader selection, and preservation of
## groom-owned parameters across shader swaps.
## Explicit local types are intentional: Godot 4.7 rejects inference from
## Script.new(), dynamic property access, and some Variant-returning APIs.
##
## The packaged addon profile exposes the three production tiers (Approx, Fast,
## Cinematic). Reference Marschner is a separate development/validation tier and
## is checked directly against its shader rather than through the profile.

const ProfileScript := preload("res://addons/marschner_hair/hair_material_profile.gd")
const LUTAdapterScript := preload("res://addons/marschner_hair/hair_marschner_lut_adapter.gd")
const LegacyLUTAdapterScript := preload("res://benchmark/resources/hair_marschner_legacy_lut_adapter.gd")
const APPROX_SHADER_PATH: String = "res://addons/marschner_hair/shaders/hair_approx.gdshader"
const FAST_SHADER_PATH: String = "res://addons/marschner_hair/shaders/hair_marschner_unity_fast.gdshader"
const CINEMATIC_SHADER_PATH: String = "res://addons/marschner_hair/shaders/hair_marschner_cinematic.gdshader"
const REFERENCE_SHADER_PATH: String = "res://assets/hair/materials/shaders/hair.gdshader"
const CINEMATIC_CONTRACT: String = "deon_physical_longitudinal_log2q_v2"
const CINEMATIC_BLEND: Vector2 = Vector2(0.05, 0.10)

const TIER_APPROX: int = 0
const TIER_FAST: int = 1
const TIER_CINEMATIC: int = 2

var _failures: PackedStringArray = PackedStringArray()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var adapter: RefCounted = LUTAdapterScript.new()
	var missing: PackedStringArray = adapter.missing_default_resources()
	if not missing.is_empty():
		for message_value in missing:
			push_error(String(message_value))
		quit(1)
		return

	var profile: Resource = ProfileScript.new()
	_assert_shader(profile, TIER_APPROX, APPROX_SHADER_PATH)
	_assert_shader(profile, TIER_FAST, FAST_SHADER_PATH)
	_assert_shader(profile, TIER_CINEMATIC, CINEMATIC_SHADER_PATH)
	_assert_dynamic_authoring_surface(profile)
	_assert_consolidated_apply(profile, adapter)
	_assert_explicit_shader_compatibility(profile, adapter)
	_assert_reference_shader_contract()

	if not _failures.is_empty():
		for failure_value in _failures:
			push_error(String(failure_value))
		quit(1)
		return
	print("MARSCHNER_PRODUCTION_PROFILE_TEST_OK")
	quit(0)


func _assert_dynamic_authoring_surface(profile: Resource) -> void:
	profile.set(&"quality_tier", TIER_APPROX)
	_check(_editor_property_visible(profile, &"primary_color"), "Approx should expose Kajiya-Kay lobe controls")
	_check(not _editor_property_visible(profile, &"absorption_mode"), "Approx should hide Fast absorption controls")
	_check(not _editor_property_visible(profile, &"ior"), "Approx should hide Cinematic IOR")
	_check(not _editor_property_visible(profile, &"azimuthal_roughness"), "Approx should hide unused azimuthal roughness")
	_check(not _editor_property_visible(profile, &"cuticle_tilt_offset"), "Approx should hide unused cuticle tilt")
	_check(_editor_category_visible(profile, &"Approx / Kajiya-Kay"), "Approx category should be visible in Approx mode")
	_check(not _editor_category_visible(profile, &"Fast Marschner"), "Fast category should be hidden in Approx mode")
	_check(not _editor_category_visible(profile, &"Cinematic Marschner"), "Cinematic category should be hidden in Approx mode")

	profile.set(&"quality_tier", TIER_FAST)
	profile.set(&"absorption_mode", 0)
	_check(_editor_property_visible(profile, &"absorption_mode"), "Fast should expose absorption mode")
	_check(_editor_property_visible(profile, &"unity_azimuthal_lut_data"), "Fast should expose its optional Unity LUT override")
	_check(not _editor_property_visible(profile, &"ior"), "Fast should hide IOR because the Unity contract pins eta")
	_check(not _editor_property_visible(profile, &"absorption"), "Fast albedo absorption mode should hide direct sigma_a")
	_check(not _editor_property_visible(profile, &"eumelanin"), "Fast albedo absorption mode should hide melanin controls")
	_check(_editor_category_visible(profile, &"Fast Marschner"), "Fast category should be visible in Fast mode")

	profile.set(&"absorption_mode", 1)
	_check(_editor_property_visible(profile, &"absorption"), "Direct absorption mode should expose absorption")
	_check(not _editor_property_visible(profile, &"eumelanin"), "Direct absorption mode should hide melanin controls")

	profile.set(&"absorption_mode", 2)
	_check(not _editor_property_visible(profile, &"absorption"), "Melanin mode should hide direct absorption")
	_check(_editor_property_visible(profile, &"eumelanin"), "Melanin mode should expose eumelanin")
	_check(_editor_property_visible(profile, &"pheomelanin"), "Melanin mode should expose pheomelanin")
	_check(_editor_property_visible(profile, &"melanin_absorption_scale"), "Melanin mode should expose absorption scale")

	profile.set(&"quality_tier", TIER_CINEMATIC)
	_check(_editor_property_visible(profile, &"ior"), "Cinematic should expose IOR")
	_check(_editor_property_visible(profile, &"cinematic_longitudinal_lut_data"), "Cinematic should expose its optional LUT override")
	_check(not _editor_property_visible(profile, &"unity_azimuthal_lut_data"), "Cinematic should hide the Fast LUT override")
	_check(not _editor_property_visible(profile, &"primary_color"), "Cinematic should hide Kajiya-Kay controls")
	_check(_editor_category_visible(profile, &"Cinematic Marschner"), "Cinematic category should be visible in Cinematic mode")


func _assert_consolidated_apply(profile: Resource, adapter: RefCounted) -> void:
	var groom_material: ShaderMaterial = ShaderMaterial.new()
	profile.set(&"quality_tier", TIER_APPROX)
	groom_material.shader = profile.call(&"get_shader_resource") as Shader

	var image: Image = Image.create(2, 2, false, Image.FORMAT_RGBA8)
	var coords_texture: ImageTexture = ImageTexture.create_from_image(image)
	var attributes_texture: ImageTexture = ImageTexture.create_from_image(image)
	groom_material.set_shader_parameter(&"coords_texture", coords_texture)
	groom_material.set_shader_parameter(&"attributes_texture", attributes_texture)
	groom_material.set_shader_parameter(&"show_hair_cards", true)

	profile.set(&"quality_tier", TIER_FAST)
	profile.set(&"absorption_mode", 0)
	var fast_apply_result: bool = bool(profile.call(&"apply_to", groom_material))
	_check(fast_apply_result, "Consolidated apply_to() failed to bind Fast")
	_check(groom_material.shader != null and groom_material.shader.resource_path == FAST_SHADER_PATH, "apply_to() did not switch the material to Fast")
	_check(groom_material.get_shader_parameter(&"coords_texture") == coords_texture, "coords_texture was not preserved across Approx -> Fast")
	_check(groom_material.get_shader_parameter(&"attributes_texture") == attributes_texture, "attributes_texture was not preserved across Approx -> Fast")
	_check(bool(groom_material.get_shader_parameter(&"show_hair_cards")), "show_hair_cards was not preserved across Approx -> Fast")
	var fast_texture: Texture3D = groom_material.get_shader_parameter(&"unity_azimuthal_lut") as Texture3D
	_check(fast_texture != null and fast_texture.get_rid().is_valid(), "apply_to() did not bind the Fast Unity azimuthal LUT")
	var unity_data: Resource = LegacyLUTAdapterScript.new().call(&"load_default_unity_data") as Resource
	if unity_data != null:
		var eta: float = float(unity_data.get(&"eta"))
		_check(is_equal_approx(float(groom_material.get_shader_parameter(&"ior")), eta), "Fast apply_to() did not pin IOR to the Unity LUT eta")

	profile.set(&"quality_tier", TIER_CINEMATIC)
	profile.set(&"ior", 1.42)
	var cinematic_apply_result: bool = bool(profile.call(&"apply_to", groom_material))
	_check(cinematic_apply_result, "Consolidated apply_to() failed to bind Cinematic")
	_check(groom_material.shader != null and groom_material.shader.resource_path == CINEMATIC_SHADER_PATH, "apply_to() did not switch the material to Cinematic")
	_check(groom_material.get_shader_parameter(&"coords_texture") == coords_texture, "coords_texture was not preserved across Fast -> Cinematic")
	_check(groom_material.get_shader_parameter(&"attributes_texture") == attributes_texture, "attributes_texture was not preserved across Fast -> Cinematic")
	_check(bool(groom_material.get_shader_parameter(&"show_hair_cards")), "show_hair_cards was not preserved across Fast -> Cinematic")
	_check(is_equal_approx(float(groom_material.get_shader_parameter(&"ior")), 1.42), "Cinematic apply_to() should preserve arbitrary profile IOR")
	var cinematic_texture: Texture3D = groom_material.get_shader_parameter(&"cinematic_longitudinal_lut") as Texture3D
	_check(cinematic_texture != null and cinematic_texture.get_rid().is_valid(), "apply_to() did not bind the Cinematic longitudinal LUT")


func _assert_explicit_shader_compatibility(profile: Resource, adapter: RefCounted) -> void:
	# Keep the legacy explicit-current-shader API covered because benchmark and
	# experimental callers intentionally use it without automatic shader swaps.
	var fast: ShaderMaterial = ShaderMaterial.new()
	profile.set(&"quality_tier", TIER_FAST)
	fast.shader = profile.call(&"get_shader_resource") as Shader
	_assert_required_uniforms(fast.shader, [
		&"albedo", &"coords_texture", &"attributes_texture", &"unity_azimuthal_lut",
		&"ior", &"absorption_mode", &"bayer_phase_index", &"lobe_scales",
	])
	profile.call(&"apply_to_shader_material", fast)
	var fast_texture: Texture3D = fast.get_shader_parameter(&"unity_azimuthal_lut") as Texture3D
	_check(fast_texture != null and fast_texture.get_rid().is_valid(), "Fast Unity azimuthal LUT was not bound as a valid Texture3D")
	var unity_data: Resource = LegacyLUTAdapterScript.new().call(&"load_default_unity_data") as Resource
	if unity_data != null:
		var eta: float = float(unity_data.get(&"eta"))
		_check(is_equal_approx(float(fast.get_shader_parameter(&"ior")), eta), "Fast ior was not pinned to the Unity LUT eta")
		_check(is_equal_approx(float(fast.get_shader_parameter(&"unity_azimuthal_lut_eta")), eta), "Fast LUT eta metadata was not propagated")

	var cinematic: ShaderMaterial = ShaderMaterial.new()
	profile.set(&"quality_tier", TIER_CINEMATIC)
	profile.set(&"ior", 1.42)
	cinematic.shader = profile.call(&"get_shader_resource") as Shader
	_assert_required_uniforms(cinematic.shader, [
		&"albedo", &"coords_texture", &"attributes_texture", &"cinematic_longitudinal_lut",
		&"cinematic_longitudinal_beta_range", &"cinematic_longitudinal_low_beta_blend",
		&"ior", &"bayer_phase_index", &"lobe_scales",
	])
	profile.call(&"apply_to_shader_material", cinematic)
	var cinematic_texture: Texture3D = cinematic.get_shader_parameter(&"cinematic_longitudinal_lut") as Texture3D
	_check(cinematic_texture != null and cinematic_texture.get_rid().is_valid(), "Cinematic longitudinal LUT was not bound as a valid Texture3D")
	_check(is_equal_approx(float(cinematic.get_shader_parameter(&"ior")), 1.42), "Cinematic should preserve the profile IOR instead of pinning to 1.55")
	var cinematic_data: Resource = LegacyLUTAdapterScript.new().call(&"load_default_cinematic_data") as Resource
	if cinematic_data != null:
		_check(String(cinematic_data.get(&"contract")) == CINEMATIC_CONTRACT, "Cinematic LUT contract was not the angle/log-Q v2 contract")
		var expected_beta: Vector2 = Vector2(float(cinematic_data.get(&"beta_min")), float(cinematic_data.get(&"beta_max")))
		var actual_beta_value: Variant = cinematic.get_shader_parameter(&"cinematic_longitudinal_beta_range")
		if actual_beta_value is Vector2:
			var actual_beta: Vector2 = actual_beta_value
			_check(actual_beta.is_equal_approx(expected_beta), "Cinematic beta range did not match LUT metadata")
		else:
			_check(false, "Cinematic beta range was not a Vector2")
		var blend_value: Variant = cinematic.get_shader_parameter(&"cinematic_longitudinal_low_beta_blend")
		if blend_value is Vector2:
			var actual_blend: Vector2 = blend_value
			_check(actual_blend.is_equal_approx(CINEMATIC_BLEND), "Cinematic low-beta transition did not match the v2 contract")
		else:
			_check(false, "Cinematic low-beta transition was not a Vector2")
		_check(cinematic_texture.get_width() == int(cinematic_data.get(&"size_x")), "Cinematic Texture3D width did not match LUT metadata")
		_check(cinematic_texture.get_height() == int(cinematic_data.get(&"size_y")), "Cinematic Texture3D height did not match LUT metadata")
		_check(cinematic_texture.get_depth() == int(cinematic_data.get(&"size_z")), "Cinematic Texture3D depth did not match LUT metadata")


## Reference Marschner is a development/validation tier outside the packaged
## addon. It is not part of the production profile's tier enum; verify its
## shader contract directly so the Reference validation case stays covered.
func _assert_reference_shader_contract() -> void:
	var reference_shader: Shader = load(REFERENCE_SHADER_PATH) as Shader
	_check(reference_shader != null, "Reference shader failed to load")
	if reference_shader != null:
		_assert_required_uniforms(reference_shader, [
			&"albedo", &"coords_texture", &"attributes_texture",
			&"wetness", &"wet_film_roughness", &"wet_film_specular_strength",
			&"bayer_phase_index", &"lobe_scales",
		])


func _editor_property_visible(profile: Resource, property_name: StringName) -> bool:
	var properties: Array[Dictionary] = profile.get_property_list()
	for info in properties:
		var name: StringName = StringName(info.get("name", ""))
		if name == property_name:
			return (int(info.get("usage", 0)) & PROPERTY_USAGE_EDITOR) != 0
	_check(false, "Profile property %s was not found" % String(property_name))
	return false


func _editor_category_visible(profile: Resource, category_name: StringName) -> bool:
	var properties: Array[Dictionary] = profile.get_property_list()
	for info in properties:
		var name: StringName = StringName(info.get("name", ""))
		if name == category_name:
			return (int(info.get("usage", 0)) & PROPERTY_USAGE_CATEGORY) != 0
	_check(false, "Profile category %s was not found" % String(category_name))
	return false


func _assert_shader(profile: Resource, tier: int, expected_path: String) -> void:
	profile.set(&"quality_tier", tier)
	var shader: Shader = profile.call(&"get_shader_resource") as Shader
	_check(shader != null, "quality tier %d returned a null shader" % tier)
	if shader != null:
		_check(shader.resource_path == expected_path, "quality tier %d selected %s instead of %s" % [tier, shader.resource_path, expected_path])


func _assert_required_uniforms(shader: Shader, required: Array[StringName]) -> void:
	if shader == null:
		return
	var names: Dictionary = {}
	var uniform_list: Array = shader.get_shader_uniform_list()
	for info_value in uniform_list:
		var info: Dictionary = info_value
		var name: StringName = StringName(info.get("name", ""))
		if name != &"":
			names[name] = true
	for required_name in required:
		_check(names.has(required_name), "%s is missing reflected uniform %s" % [shader.resource_path, String(required_name)])


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
