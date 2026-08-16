extends RefCounted

## Small shared helpers for querying and preserving ShaderMaterial parameters.
## Keeping uniform reflection here avoids repeating Godot's shader-interface
## plumbing throughout the public authoring resources and demo code.

static func uniform_names(shader: Shader) -> Dictionary:
	var names: Dictionary = {}
	if shader == null:
		return names
	for uniform_value in shader.get_shader_uniform_list():
		var uniform: Dictionary = uniform_value
		var uniform_name: StringName = StringName(uniform.get("name", ""))
		if uniform_name != &"":
			names[uniform_name] = true
	return names


static func has_uniform(shader: Shader, uniform_name: StringName) -> bool:
	return uniform_names(shader).has(uniform_name)


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
