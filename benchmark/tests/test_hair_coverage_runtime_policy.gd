extends SceneTree
const Policy := preload("res://addons/marschner_hair/hair_coverage_policy.gd")
const ProfileTemplate: Resource = preload("res://demos/resources/hair_material_profile_demo.tres")
const GroomData: Resource = preload("res://demos/resources/blowout_groom_data.tres")
const REFERENCE_SHADER: Shader = preload("res://assets/hair/materials/shaders/hair.gdshader")
const REFERENCE_A2C_SHADER: Shader = preload("res://assets/hair/materials/shaders/hair_a2c.gdshader")
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	if RenderingServer.get_rendering_device() == null:
		print("HAIR_COVERAGE_RUNTIME_POLICY_FAILED")
		quit(1)
		return
	var failures := PackedStringArray()
	# The packaged addon profile exposes the three production tiers. Reference
	# Marschner is a separate validation tier exercised directly below.
	for tier in 3:
		var profile: Resource = ProfileTemplate.duplicate(true)
		profile.set(&"quality_tier", tier)
		profile.set(&"coverage_mode", Policy.Mode.AUTO)
		root.msaa_3d = Viewport.MSAA_DISABLED
		root.use_taa = false
		var material: ShaderMaterial = profile.call(&"create_material", GroomData, root) as ShaderMaterial
		_check(material != null and bool(profile.call(&"apply_to", material, GroomData, root)), "static %d" % tier, failures)
		var stable: Shader = material.shader if material != null else null
		if material != null:
			_check(int(material.get_shader_parameter(&"bayer_phase_index")) == 0, "phase0 %d" % tier, failures)
		root.use_taa = true
		_check(bool(profile.call(&"update_coverage_for_viewport", material, root, 21)), "taa %d" % tier, failures)
		if material != null:
			_check(material.shader == stable, "taa shader %d" % tier, failures)
			_check(int(material.get_shader_parameter(&"bayer_phase_index")) == 5, "phase5 %d" % tier, failures)
		root.msaa_3d = Viewport.MSAA_2X
		_check(bool(profile.call(&"update_coverage_for_viewport", material, root, 22)), "a2c %d" % tier, failures)
		if material != null:
			_check(material.shader != null and material.shader != stable, "a2c shader %d" % tier, failures)

	# Reference coverage runtime: the normal and A2C compiled families must both
	# create valid materials and expose the shared groom contract.
	var reference_material := ShaderMaterial.new()
	reference_material.shader = REFERENCE_SHADER
	_check(reference_material.shader != null and reference_material.get_rid().is_valid(), "reference static material", failures)
	if reference_material.shader != null:
		GroomData.call(&"apply_to_shader_material", reference_material)
		_check(reference_material.get_shader_parameter(&"coords_texture") != null, "reference static groom textures", failures)
	var reference_a2c_material := ShaderMaterial.new()
	reference_a2c_material.shader = REFERENCE_A2C_SHADER
	_check(reference_a2c_material.shader != null and reference_a2c_material.get_rid().is_valid(), "reference a2c material", failures)
	if reference_a2c_material.shader != null:
		GroomData.call(&"apply_to_shader_material", reference_a2c_material)
		_check(reference_a2c_material.get_shader_parameter(&"coords_texture") != null, "reference a2c groom textures", failures)

	if failures.is_empty():
		print("HAIR_COVERAGE_RUNTIME_POLICY_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	print("HAIR_COVERAGE_RUNTIME_POLICY_FAILED")
	quit(1)
func _check(ok: bool, label: String, failures: PackedStringArray) -> void:
	if not ok:
		failures.append(label)
