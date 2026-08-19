extends RefCounted

## Small shared helpers for querying and preserving ShaderMaterial parameters.
## Keeping uniform reflection here avoids repeating Godot's shader-interface
## plumbing throughout the public authoring resources and demo code.
##
## Uniform reflection is cached per Shader identity for the lifetime of the
## process. A compiled shader's uniform interface is immutable, so the cached
## name sets never go stale for preloaded or normally-created shaders, and the
## per-frame coverage path in HairMaterialProfile performs a single dictionary
## lookup instead of re-running get_shader_uniform_list() and rebuilding the
## name set on every Bayer/TAA update.
##
## The cache intentionally retains every Shader it has reflected, matching the
## process-lifetime scope. Shaders whose source is replaced at runtime through
## [member Shader.code] must call [method invalidate] after recompiling so the
## next query re-reflects the new interface.

## Cached uniform-name sets keyed by Shader identity. Each value is the same
## Dictionary shape returned by [method uniform_names] (uniform name -> true).
static var _uniform_name_cache: Dictionary = {}

## Number of times uniform reflection actually queried the shader interface.
## Increments only on cache misses; exposed for tests and profiling.
static var reflection_count: int = 0

## Returns the uniform names exposed by the shader. The returned Dictionary is
## cached and shared per Shader identity; callers must treat it as read-only.
static func uniform_names(shader: Shader) -> Dictionary:
	if shader == null:
		return {}
	if _uniform_name_cache.has(shader):
		return _uniform_name_cache[shader]
	reflection_count += 1
	var names: Dictionary = {}
	for uniform_value in shader.get_shader_uniform_list():
		var uniform: Dictionary = uniform_value
		var uniform_name: StringName = StringName(uniform.get("name", ""))
		if uniform_name != &"":
			names[uniform_name] = true
	_uniform_name_cache[shader] = names
	return names


static func has_uniform(shader: Shader, uniform_name: StringName) -> bool:
	return uniform_names(shader).has(uniform_name)


## Drops the cached uniform set for a shader. Only required when shader source
## is replaced at runtime via [member Shader.code]; preloaded and normally
## created shaders never need invalidation.
static func invalidate(shader: Shader) -> void:
	if shader != null:
		_uniform_name_cache.erase(shader)


## Clears every cached uniform set. Primarily for tests that need a clean slate.
static func clear_cache() -> void:
	_uniform_name_cache.clear()


static func capture_parameters(material: ShaderMaterial, parameter_names: Array[StringName]) -> Dictionary:
	var captured: Dictionary = {}
	if material == null or material.shader == null:
		return captured
	var known_parameters: Dictionary = uniform_names(material.shader)
	for parameter_name in parameter_names:
		if known_parameters.has(parameter_name):
			captured[parameter_name] = material.get_shader_parameter(parameter_name)
	return captured


static func restore_parameters(material: ShaderMaterial, captured: Dictionary) -> void:
	if material == null or material.shader == null:
		return
	var known_parameters: Dictionary = uniform_names(material.shader)
	for parameter_name_value in captured:
		var parameter_name := StringName(parameter_name_value)
		if known_parameters.has(parameter_name):
			material.set_shader_parameter(parameter_name, captured[parameter_name_value])