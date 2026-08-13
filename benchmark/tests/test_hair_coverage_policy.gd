extends SceneTree
const Policy := preload("res://assets/hair/materials/HairCoveragePolicy.gd")
const Profile := preload("res://assets/hair/materials/HairMaterialProfile.gd")
func _initialize() -> void:
	var failures := PackedStringArray()
	var viewport := SubViewport.new()
	root.add_child(viewport)
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.use_taa = false
	_check(Policy.resolve(viewport, Policy.Mode.AUTO) == Policy.Mode.STATIC_BAYER, "AUTO no-AA", failures)
	viewport.use_taa = true
	_check(Policy.resolve(viewport, Policy.Mode.AUTO) == Policy.Mode.TAA_BAYER, "AUTO TAA", failures)
	viewport.msaa_3d = Viewport.MSAA_2X
	_check(Policy.resolve(viewport, Policy.Mode.AUTO) == Policy.Mode.ALPHA_TO_COVERAGE, "AUTO MSAA", failures)
	for frame in 32:
		_check(Policy.bayer_phase(Policy.Mode.STATIC_BAYER, frame) == 0, "static phase", failures)
		_check(Policy.bayer_phase(Policy.Mode.TAA_BAYER, frame) == (frame & 15), "temporal phase", failures)
	var profile: Resource = Profile.new()
	profile.set(&"coverage_mode", Policy.Mode.AUTO)
	for tier in 4:
		profile.set(&"quality_tier", tier)
		viewport.msaa_3d = Viewport.MSAA_DISABLED
		viewport.use_taa = false
		var stable: Shader = profile.call(&"get_shader_resource", viewport) as Shader
		viewport.use_taa = true
		var temporal: Shader = profile.call(&"get_shader_resource", viewport) as Shader
		viewport.msaa_3d = Viewport.MSAA_2X
		var a2c: Shader = profile.call(&"get_shader_resource", viewport) as Shader
		_check(stable != null and temporal == stable, "tier %d Bayer shader" % tier, failures)
		_check(a2c != null and a2c != stable, "tier %d A2C shader" % tier, failures)
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
