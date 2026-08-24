extends SceneTree

## Focused headless test for the ShaderUtils uniform-reflection cache.
##
## Verifies that repeated uniform_names() calls for the same Shader identity are
## served from the cache (no re-reflection), that distinct Shader resources
## cache independently, that invalidate() forces a fresh reflection, and that
## the per-frame Bayer/TAA coverage path performs no reflection after the first
## apply_to().

const ShaderUtils := preload("res://addons/marschner_hair/internal/hair_shader_utils.gd")
const ProfileScript := preload("res://addons/marschner_hair/hair_material_profile.gd")
const Policy := preload("res://addons/marschner_hair/hair_coverage_policy.gd")

func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures := PackedStringArray()

	ShaderUtils.clear_cache()
	ShaderUtils.reflection_count = 0

	# Runtime-created shaders reflect their interface on first query.
	var runtime_shader: Shader = Shader.new()
	runtime_shader.code = "shader_type spatial; uniform float test_uniform; uniform sampler2D tex;"
	var names: Dictionary = ShaderUtils.uniform_names(runtime_shader)
	_check(names.has(&"test_uniform") and names.has(&"tex"), "runtime shader uniforms reflected", failures)
	_check(ShaderUtils.reflection_count == 1, "first query reflects once", failures)

	# Repeated queries for the same identity must not re-reflect.
	ShaderUtils.uniform_names(runtime_shader)
	ShaderUtils.uniform_names(runtime_shader)
	_check(ShaderUtils.reflection_count == 1, "repeated queries served from cache", failures)

	# A distinct Shader resource reflects independently.
	var other_shader: Shader = Shader.new()
	other_shader.code = "shader_type spatial; uniform float other_uniform;"
	var other_names: Dictionary = ShaderUtils.uniform_names(other_shader)
	_check(other_names.has(&"other_uniform"), "distinct shader reflected", failures)
	_check(ShaderUtils.reflection_count == 2, "distinct shader reflects separately", failures)

	# Preloaded production shaders share the same cache path.
	var preloaded_shader: Shader = load("res://addons/marschner_hair/shaders/hair_approx.gdshader") as Shader
	ShaderUtils.uniform_names(preloaded_shader)
	ShaderUtils.uniform_names(preloaded_shader)
	_check(ShaderUtils.reflection_count == 3, "preloaded shader cached after first query", failures)

	# invalidate() drops the cached set and forces re-reflection.
	ShaderUtils.invalidate(runtime_shader)
	ShaderUtils.uniform_names(runtime_shader)
	_check(ShaderUtils.reflection_count == 4, "invalidate forces re-reflection", failures)

	# Null shaders never reflect and return an empty set.
	var null_names: Dictionary = ShaderUtils.uniform_names(null)
	_check(null_names.is_empty(), "null shader returns empty set", failures)
	_check(ShaderUtils.reflection_count == 4, "null shader does not reflect", failures)

	# has_uniform() shares the cache.
	ShaderUtils.reflection_count = 0
	_check(ShaderUtils.has_uniform(runtime_shader, &"test_uniform"), "has_uniform finds cached uniform", failures)
	_check(ShaderUtils.reflection_count == 0, "has_uniform served from cache", failures)

	# End-to-end: normal Bayer/TAA coverage updates perform no reflection after
	# the first apply_to() reflects the target shader once.
	ShaderUtils.clear_cache()
	ShaderUtils.reflection_count = 0
	var profile: Resource = ProfileScript.new()
	profile.set(&"quality_tier", ProfileScript.QualityTier.FAST_MARSCHNER)
	profile.set(&"coverage_mode", Policy.Mode.TAA_BAYER)
	var material: ShaderMaterial = ShaderMaterial.new()
	_check(bool(profile.call(&"apply_to", material)), "apply_to() succeeded", failures)
	_check(ShaderUtils.reflection_count == 1, "apply_to() reflects the target shader once", failures)
	var viewport := SubViewport.new()
	root.add_child(viewport)
	_check(bool(profile.call(&"update_coverage_for_viewport", material, viewport, 5)), "first coverage update succeeded", failures)
	_check(bool(profile.call(&"update_coverage_for_viewport", material, viewport, 6)), "second coverage update succeeded", failures)
	_check(ShaderUtils.reflection_count == 1, "Bayer/TAA updates perform no reflection", failures)

	if failures.is_empty():
		print("SHADER_UNIFORM_CACHE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	print("SHADER_UNIFORM_CACHE_FAILED")
	quit(1)


func _check(ok: bool, label: String, failures: PackedStringArray) -> void:
	if not ok:
		failures.append(label)