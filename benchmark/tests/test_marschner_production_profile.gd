extends SceneTree

## Headless production-tier wiring test. Run after generating the two default
## LUT resources. It verifies explicit shader selection, top-level uniform
## reflection, Texture3D reconstruction/binding, Unity eta pinning, and
## Cinematic beta-domain/transition propagation without starting a timed benchmark.
## Explicit local types are intentional: Godot 4.7 rejects inference from
## Script.new(), dynamic property access, and some Variant-returning APIs.

const ProfileScript := preload("res://assets/hair/materials/HairMaterialProfile.gd")
const LUTAdapterScript := preload("res://assets/hair/materials/HairMarschnerLUTAdapter.gd")
const FAST_SHADER_PATH: String = "res://assets/hair/materials/shaders/hair_marschner_unity_fast.gdshader"
const CINEMATIC_SHADER_PATH: String = "res://assets/hair/materials/shaders/hair_marschner_cinematic.gdshader"
const REFERENCE_SHADER_PATH: String = "res://assets/hair/materials/shaders/hair.gdshader"
const CINEMATIC_CONTRACT: String = "deon_physical_longitudinal_log2q_v2"
const CINEMATIC_BLEND: Vector2 = Vector2(0.05, 0.10)

const TIER_FAST: int = 1
const TIER_CINEMATIC: int = 2
const TIER_REFERENCE: int = 3

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
	_assert_shader(profile, TIER_FAST, FAST_SHADER_PATH)
	_assert_shader(profile, TIER_CINEMATIC, CINEMATIC_SHADER_PATH)
	_assert_shader(profile, TIER_REFERENCE, REFERENCE_SHADER_PATH)

	var fast: ShaderMaterial = ShaderMaterial.new()
	profile.set(&"quality_tier", TIER_FAST)
	fast.shader = profile.call(&"get_shader_resource") as Shader
	_assert_required_uniforms(fast.shader, [
		&"albedo", &"coords_texture", &"attributes_texture", &"unity_azimuthal_lut",
		&"ior", &"absorption_mode", &"freeze_bayer_phase", &"lobe_scales",
	])
	profile.call(&"apply_to_shader_material", fast)
	var fast_texture: Texture3D = fast.get_shader_parameter(&"unity_azimuthal_lut") as Texture3D
	_check(fast_texture != null and fast_texture.get_rid().is_valid(), "Fast Unity azimuthal LUT was not bound as a valid Texture3D")
	var unity_data: Resource = adapter.call(&"load_default_unity_data") as Resource
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
		&"ior", &"freeze_bayer_phase", &"lobe_scales",
	])
	profile.call(&"apply_to_shader_material", cinematic)
	var cinematic_texture: Texture3D = cinematic.get_shader_parameter(&"cinematic_longitudinal_lut") as Texture3D
	_check(cinematic_texture != null and cinematic_texture.get_rid().is_valid(), "Cinematic longitudinal LUT was not bound as a valid Texture3D")
	_check(is_equal_approx(float(cinematic.get_shader_parameter(&"ior")), 1.42), "Cinematic should preserve the profile IOR instead of pinning to 1.55")
	var cinematic_data: Resource = adapter.call(&"load_default_cinematic_data") as Resource
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

	if not _failures.is_empty():
		for failure_value in _failures:
			push_error(String(failure_value))
		quit(1)
		return
	print("MARSCHNER_PRODUCTION_PROFILE_TEST_OK")
	quit(0)


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
	var uniform_list: Array[Dictionary] = shader.get_shader_uniform_list()
	for info in uniform_list:
		var name: StringName = StringName(info.get(&"name", ""))
		if name != &"":
			names[name] = true
	for required_name in required:
		_check(names.has(required_name), "%s is missing reflected uniform %s" % [shader.resource_path, String(required_name)])


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
