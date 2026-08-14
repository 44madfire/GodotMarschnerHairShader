extends SceneTree

const HairMaterialProfileScript := preload("res://assets/hair/materials/HairMaterialProfile.gd")

const REQUIRED_WETNESS_UNIFORMS: Array[StringName] = [
	&"wetness",
	&"wet_film_roughness",
	&"wet_film_specular_strength",
	&"wet_longitudinal_roughness_scale",
	&"wet_azimuthal_roughness_scale",
	&"wet_internal_scatter_scale",
	&"wet_transmission_scale",
	&"wet_cuticle_shift_scale",
]

const STATIC_BAYER_MODE := 1
const ALPHA_TO_COVERAGE_MODE := 3

func _initialize() -> void:
	var profile: Resource = HairMaterialProfileScript.new()
	if profile == null:
		_fail("Could not instantiate HairMaterialProfile")
		return

	if not is_equal_approx(float(profile.wetness), 0.0):
		_fail("HairMaterialProfile wetness must default to 0.0 so the dry shader remains the compatibility baseline")
		return

	var expected_defaults := {
		&"wet_film_roughness": 0.10,
		&"wet_film_specular_strength": 2.0,
		&"wet_longitudinal_roughness_scale": 0.45,
		&"wet_azimuthal_roughness_scale": 0.55,
		&"wet_internal_scatter_scale": 0.35,
		&"wet_transmission_scale": 0.65,
		&"wet_cuticle_shift_scale": 0.5,
	}
	for property_name_value in expected_defaults:
		var property_name := StringName(property_name_value)
		var actual := float(profile.get(property_name))
		var expected := float(expected_defaults[property_name_value])
		if not is_equal_approx(actual, expected):
			_fail("Unexpected wetness default for %s: got %s, expected %s" % [property_name, actual, expected])
			return

	for tier in range(4):
		profile.quality_tier = tier
		for coverage_mode in [STATIC_BAYER_MODE, ALPHA_TO_COVERAGE_MODE]:
			profile.coverage_mode = coverage_mode
			var shader: Shader = profile.get_shader_resource(null)
			if shader == null:
				_fail("Tier %d coverage mode %d did not resolve a shader" % [tier, coverage_mode])
				return
			var uniform_names := _shader_uniform_names(shader)
			for required_name in REQUIRED_WETNESS_UNIFORMS:
				if not uniform_names.has(required_name):
					_fail("%s is missing wetness uniform %s" % [shader.resource_path, required_name])
					return

	print("HAIR_WETNESS_INTERFACE_OK")
	quit(0)

func _shader_uniform_names(shader: Shader) -> Dictionary:
	var result: Dictionary = {}
	for uniform_value in shader.get_shader_uniform_list():
		var uniform: Dictionary = uniform_value
		var uniform_name := StringName(uniform.get("name", ""))
		if uniform_name != &"":
			result[uniform_name] = true
	return result

func _fail(message: String) -> void:
	push_error(message)
	quit(1)
