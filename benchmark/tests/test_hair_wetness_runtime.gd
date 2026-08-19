extends SceneTree

const LUT_ADAPTER := preload("res://addons/marschner_hair/hair_marschner_lut_adapter.gd")
const PROFILE_TEMPLATE: Resource = preload("res://demos/resources/hair_material_profile_demo.tres")
const GROOM_DATA: Resource = preload("res://demos/resources/blowout_groom_data.tres")
const REFERENCE_SHADER: Shader = preload("res://assets/hair/materials/shaders/hair.gdshader")

const COVERAGE_STATIC_BAYER := 1
const COVERAGE_ALPHA_TO_COVERAGE := 3
const WETNESS_VALUES: Array[float] = [0.0, 0.25, 0.5, 0.75, 1.0]

const EXPECTED_ENDPOINTS := {
	&"wet_film_roughness": 0.10,
	&"wet_film_specular_strength": 2.0,
	&"wet_longitudinal_roughness_scale": 0.45,
	&"wet_azimuthal_roughness_scale": 0.55,
	&"wet_internal_scatter_scale": 0.35,
	&"wet_transmission_scale": 0.65,
	&"wet_cuticle_shift_scale": 0.5,
}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	if RenderingServer.get_rendering_device() == null:
		_fail("Hair wetness runtime smoke requires a real Forward+/Mobile RenderingDevice; do not use --headless")
		return

	# The packaged addon profile exposes the three production tiers. Reference
	# Marschner is a separate validation tier exercised directly below.
	for coverage_mode in [COVERAGE_STATIC_BAYER, COVERAGE_ALPHA_TO_COVERAGE]:
		for tier in range(3):
			for wetness_value in WETNESS_VALUES:
				var profile: Resource = PROFILE_TEMPLATE.duplicate(true)
				profile.set(&"quality_tier", tier)
				profile.set(&"coverage_mode", coverage_mode)
				profile.set(&"wetness", wetness_value)

				var material: ShaderMaterial = profile.call(&"create_material", GROOM_DATA) as ShaderMaterial
				if material == null or material.shader == null:
					_fail("tier %d coverage %d wetness %.2f failed to create a ShaderMaterial" % [tier, coverage_mode, wetness_value])
					return
				if not material.get_rid().is_valid():
					_fail("tier %d coverage %d wetness %.2f produced an invalid material RID" % [tier, coverage_mode, wetness_value])
					return

				var expect_a2c: bool = coverage_mode == COVERAGE_ALPHA_TO_COVERAGE
				var is_a2c: bool = material.shader.resource_path.ends_with("_a2c.gdshader")
				if is_a2c != expect_a2c:
					_fail("tier %d coverage %d selected unexpected shader %s" % [tier, coverage_mode, material.shader.resource_path])
					return

				if absf(float(material.get_shader_parameter(&"wetness")) - wetness_value) > 1e-6:
					_fail("tier %d coverage %d did not bind wetness %.2f" % [tier, coverage_mode, wetness_value])
					return
				for parameter_name_value in EXPECTED_ENDPOINTS:
					var parameter_name := StringName(parameter_name_value)
					var expected := float(EXPECTED_ENDPOINTS[parameter_name_value])
					var actual := float(material.get_shader_parameter(parameter_name))
					if absf(actual - expected) > 1e-6:
						_fail("%s bound %s instead of %s on %s" % [parameter_name, actual, expected, material.shader.resource_path])
						return

				# Wetness must never mutate Fast's preintegrated eta=1.55 contract.
				if tier == 1:
					var fast_lut: Texture3D = material.get_shader_parameter(&"unity_azimuthal_lut") as Texture3D
					if fast_lut == null or not fast_lut.get_rid().is_valid():
						_fail("Fast tier did not bind a valid direct LUT")
						return
					if absf(float(material.get_shader_parameter(&"unity_azimuthal_lut_eta")) - LUT_ADAPTER.UNITY_ETA) > 1e-6:
						_fail("Wetness changed the Fast LUT eta contract")
						return
					if absf(float(material.get_shader_parameter(&"ior")) - LUT_ADAPTER.UNITY_ETA) > 1e-6:
						_fail("Wetness changed Fast's pinned fiber IOR")
						return
				elif tier == 2:
					var cinematic_lut: Texture3D = material.get_shader_parameter(&"cinematic_longitudinal_lut") as Texture3D
					if cinematic_lut == null or not cinematic_lut.get_rid().is_valid():
						_fail("Cinematic tier did not bind a valid direct LUT")
						return

	# Reference wetness runtime: build a material from the Reference shader and
	# verify wetness propagation and the dry compatibility endpoints. The demo
	# profile's explicit-shader API applies the same wetness contract the
	# production tiers receive through apply_to().
	for coverage_mode in [COVERAGE_STATIC_BAYER, COVERAGE_ALPHA_TO_COVERAGE]:
		for wetness_value in WETNESS_VALUES:
			var reference_material := ShaderMaterial.new()
			reference_material.shader = REFERENCE_SHADER if coverage_mode == COVERAGE_STATIC_BAYER else load("res://assets/hair/materials/shaders/hair_a2c.gdshader") as Shader
			if reference_material.shader == null:
				_fail("Reference shader failed to load for coverage %d" % coverage_mode)
				return
			var reference_profile: Resource = PROFILE_TEMPLATE.duplicate(true)
			reference_profile.set(&"wetness", wetness_value)
			reference_profile.call(&"apply_to_shader_material", reference_material)
			GROOM_DATA.call(&"apply_to_shader_material", reference_material)
			if not reference_material.get_rid().is_valid():
				_fail("Reference coverage %d wetness %.2f produced an invalid material RID" % [coverage_mode, wetness_value])
				return
			if absf(float(reference_material.get_shader_parameter(&"wetness")) - wetness_value) > 1e-6:
				_fail("Reference coverage %d did not bind wetness %.2f" % [coverage_mode, wetness_value])
				return
			for parameter_name_value in EXPECTED_ENDPOINTS:
				var parameter_name := StringName(parameter_name_value)
				var expected := float(EXPECTED_ENDPOINTS[parameter_name_value])
				var actual := float(reference_material.get_shader_parameter(parameter_name))
				if absf(actual - expected) > 1e-6:
					_fail("%s bound %s instead of %s on Reference %s" % [parameter_name, actual, expected, reference_material.shader.resource_path])
					return

	print("HAIR_WETNESS_RUNTIME_OK")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	print("HAIR_WETNESS_RUNTIME_FAILED")
	quit(1)
