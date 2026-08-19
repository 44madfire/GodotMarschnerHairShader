extends SceneTree
const Policy := preload("res://addons/marschner_hair/hair_coverage_policy.gd")
const Profile := preload("res://addons/marschner_hair/hair_material_profile.gd")
const REFERENCE_SHADER: Shader = preload("res://assets/hair/materials/shaders/hair.gdshader")
const REFERENCE_A2C_SHADER: Shader = preload("res://assets/hair/materials/shaders/hair_a2c.gdshader")
func _initialize() -> void:
	var failures := PackedStringArray()
	var viewport := SubViewport.new()
	root.add_child(viewport)

	# Forward+ supports both TAA and 3D MSAA.
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.use_taa = false
	_check(Policy.resolve(viewport, Policy.Mode.AUTO, "forward_plus") == Policy.Mode.STATIC_BAYER, "Forward+ AUTO no-AA", failures)
	viewport.use_taa = true
	_check(Policy.resolve(viewport, Policy.Mode.AUTO, "forward_plus") == Policy.Mode.TAA_BAYER, "Forward+ AUTO TAA", failures)
	viewport.msaa_3d = Viewport.MSAA_2X
	_check(Policy.resolve(viewport, Policy.Mode.AUTO, "forward_plus") == Policy.Mode.ALPHA_TO_COVERAGE, "Forward+ AUTO MSAA", failures)

	# Mobile supports MSAA but not TAA; Compatibility supports neither production
	# temporal path. These explicit method strings make the headless test stable.
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.use_taa = true
	_check(Policy.resolve(viewport, Policy.Mode.AUTO, "mobile") == Policy.Mode.STATIC_BAYER, "Mobile must ignore TAA property", failures)
	viewport.msaa_3d = Viewport.MSAA_2X
	_check(Policy.resolve(viewport, Policy.Mode.AUTO, "mobile") == Policy.Mode.ALPHA_TO_COVERAGE, "Mobile AUTO MSAA", failures)
	_check(Policy.resolve(viewport, Policy.Mode.AUTO, "gl_compatibility") == Policy.Mode.STATIC_BAYER, "Compatibility must remain static", failures)

	# Explicit overrides remain available for testing/custom render pipelines.
	_check(Policy.resolve(viewport, Policy.Mode.TAA_BAYER, "gl_compatibility") == Policy.Mode.TAA_BAYER, "explicit TAA override", failures)
	_check(Policy.resolve(viewport, Policy.Mode.ALPHA_TO_COVERAGE, "gl_compatibility") == Policy.Mode.ALPHA_TO_COVERAGE, "explicit A2C override", failures)

	for frame in 32:
		_check(Policy.bayer_phase(Policy.Mode.STATIC_BAYER, frame) == 0, "static phase", failures)
		_check(Policy.bayer_phase(Policy.Mode.TAA_BAYER, frame) == (frame & 15), "temporal phase", failures)

	# Shader selection is verified against the real current rendering method in
	# the separate windowed runtime-policy smoke test. Here we keep deterministic
	# headless coverage-policy assertions independent of that environment.
	# The packaged addon profile exposes the three production tiers; Reference
	# Marschner is a separate validation tier checked directly below.
	var profile: Resource = Profile.new()
	profile.set(&"coverage_mode", Policy.Mode.STATIC_BAYER)
	for tier in 3:
		profile.set(&"quality_tier", tier)
		var stable: Shader = profile.call(&"get_shader_resource", viewport) as Shader
		profile.set(&"coverage_mode", Policy.Mode.TAA_BAYER)
		var temporal: Shader = profile.call(&"get_shader_resource", viewport) as Shader
		profile.set(&"coverage_mode", Policy.Mode.ALPHA_TO_COVERAGE)
		var a2c: Shader = profile.call(&"get_shader_resource", viewport) as Shader
		profile.set(&"coverage_mode", Policy.Mode.STATIC_BAYER)
		_check(stable != null and temporal == stable, "tier %d Bayer shader" % tier, failures)
		_check(a2c != null and a2c != stable, "tier %d A2C shader" % tier, failures)

	# Reference coverage: the normal and A2C compiled families must differ while
	# both expose the shared groom contract.
	_check(REFERENCE_SHADER != null and REFERENCE_A2C_SHADER != null, "Reference shaders failed to load", failures)
	if REFERENCE_SHADER != null and REFERENCE_A2C_SHADER != null:
		_check(REFERENCE_A2C_SHADER != REFERENCE_SHADER, "Reference A2C shader must differ from the normal variant", failures)

	if failures.is_empty():
		print("HAIR_COVERAGE_POLICY_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	print("HAIR_COVERAGE_POLICY_FAILED")
	quit(1)
func _check(ok: bool, label: String, failures: PackedStringArray) -> void:
	if not ok:
		failures.append(label)
