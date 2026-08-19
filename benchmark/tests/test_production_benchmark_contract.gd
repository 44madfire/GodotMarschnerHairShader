extends SceneTree

## LUT-independent structural smoke test for the production benchmark suite.
## This does not measure GPU performance; the runtime benchmark must be windowed.
##
## The packaged addon profile exposes the three production tiers (Approx, Fast,
## Cinematic). Reference Marschner is a separate development/validation tier and
## is checked directly against its shader.

const ProfileScript := preload("res://addons/marschner_hair/hair_material_profile.gd")
const CARD_CONTROL_SHADER: Shader = preload("res://benchmark/shaders/hair_card_cost_control.gdshader")
const ALU_PROBE_SHADER: Shader = preload("res://benchmark/shaders/hair_alu_cost_probe.gdshader")
const LUT_PROBE_SHADER: Shader = preload("res://benchmark/shaders/hair_lut_cost_probe.gdshader")
const REFERENCE_SHADER: Shader = preload("res://assets/hair/materials/shaders/hair.gdshader")

var _failures := PackedStringArray()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var profile: Resource = ProfileScript.new()
	var expected_paths := [
		"res://addons/marschner_hair/shaders/hair_approx.gdshader",
		"res://addons/marschner_hair/shaders/hair_marschner_unity_fast.gdshader",
		"res://addons/marschner_hair/shaders/hair_marschner_cinematic.gdshader",
	]
	for tier in 3:
		profile.set(&"quality_tier", tier)
		var shader: Shader = profile.call(&"get_shader_resource") as Shader
		_check(shader != null, "tier %d returned null shader" % tier)
		if shader != null:
			_check(shader.resource_path == expected_paths[tier], "tier %d mapped to %s instead of %s" % [tier, shader.resource_path, expected_paths[tier]])
			_assert_uniform(shader, &"coords_texture")
			_assert_uniform(shader, &"attributes_texture")

	# Reference Marschner is a separate validation tier outside the packaged
	# addon; verify its shared groom contract directly.
	_check(REFERENCE_SHADER != null, "Reference shader failed to load")
	if REFERENCE_SHADER != null:
		_assert_uniform(REFERENCE_SHADER, &"coords_texture")
		_assert_uniform(REFERENCE_SHADER, &"attributes_texture")

	for probe in [CARD_CONTROL_SHADER, ALU_PROBE_SHADER, LUT_PROBE_SHADER]:
		_check(probe != null, "probe shader failed to load")
		if probe != null:
			_assert_uniform(probe, &"coords_texture")
			_assert_uniform(probe, &"attributes_texture")
			_assert_uniform(probe, &"show_hair_cards")
			_assert_uniform(probe, &"freeze_bayer_phase")
	_assert_uniform(LUT_PROBE_SHADER, &"probe_lut")

	if not _failures.is_empty():
		for failure_value in _failures:
			push_error(String(failure_value))
		quit(1)
		return
	print("PRODUCTION_BENCHMARK_CONTRACT_TEST_OK")
	quit(0)


func _assert_uniform(shader: Shader, required_name: StringName) -> void:
	for uniform_value in shader.get_shader_uniform_list():
		var uniform: Dictionary = uniform_value
		if StringName(uniform.get("name", "")) == required_name:
			return
	_check(false, "%s is missing uniform %s" % [shader.resource_path, String(required_name)])


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
