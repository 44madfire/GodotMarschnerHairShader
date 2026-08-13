extends SceneTree
const LUT_ADAPTER := preload("res://assets/hair/materials/HairMarschnerLUTAdapter.gd")
const PROFILE_TEMPLATE: Resource = preload("res://demos/resources/hair_material_profile_demo.tres")
const GROOM_DATA: Resource = preload("res://demos/resources/blowout_groom_data.tres")
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	if RenderingServer.get_rendering_device() == null:
		push_error("Direct LUT binding smoke test requires a real Forward+/Mobile RenderingDevice; do not use --headless")
		print("DIRECT_LUT_BINDING_FAILED"); quit(1); return
	var adapter: RefCounted = LUT_ADAPTER.new()
	var missing: PackedStringArray = adapter.call(&"missing_default_resources")
	if not missing.is_empty():
		for message in missing: push_error(String(message))
		print("DIRECT_LUT_BINDING_FAILED"); quit(1); return
	var fast: Texture3D = adapter.call(&"load_default_unity_texture") as Texture3D
	var cinematic: Texture3D = adapter.call(&"load_default_cinematic_texture") as Texture3D
	var fast_errors: PackedStringArray = adapter.call(&"validate_unity_texture", fast, true)
	var cinematic_errors: PackedStringArray = adapter.call(&"validate_cinematic_texture", cinematic, true)
	if not fast_errors.is_empty() or not cinematic_errors.is_empty():
		push_error("Fast direct LUT validation: %s" % "; ".join(fast_errors))
		push_error("Cinematic direct LUT validation: %s" % "; ".join(cinematic_errors))
		print("DIRECT_LUT_BINDING_FAILED"); quit(1); return
	for tier in 4:
		var profile: Resource = PROFILE_TEMPLATE.duplicate(true)
		profile.set(&"quality_tier", tier)
		var material: ShaderMaterial = profile.call(&"create_material", GROOM_DATA) as ShaderMaterial
		if material == null or material.shader == null:
			push_error("tier %d failed to create a ShaderMaterial" % tier); print("DIRECT_LUT_BINDING_FAILED"); quit(1); return
		if not bool(profile.call(&"apply_to", material, GROOM_DATA)):
			push_error("tier %d HairMaterialProfile.apply_to() failed" % tier); print("DIRECT_LUT_BINDING_FAILED"); quit(1); return
		if tier == 1:
			var bound_fast: Texture3D = material.get_shader_parameter(&"unity_azimuthal_lut") as Texture3D
			if bound_fast == null or not bound_fast.get_rid().is_valid() or absf(float(material.get_shader_parameter(&"unity_azimuthal_lut_eta")) - LUT_ADAPTER.UNITY_ETA) > 1e-6:
				push_error("Fast tier did not bind the direct LUT/eta contract"); print("DIRECT_LUT_BINDING_FAILED"); quit(1); return
		elif tier == 2:
			var bound_cinematic: Texture3D = material.get_shader_parameter(&"cinematic_longitudinal_lut") as Texture3D
			var beta_range: Vector2 = material.get_shader_parameter(&"cinematic_longitudinal_beta_range")
			if bound_cinematic == null or not bound_cinematic.get_rid().is_valid() or not beta_range.is_equal_approx(LUT_ADAPTER.CINEMATIC_BETA_RANGE):
				push_error("Cinematic tier did not bind the direct LUT/beta contract"); print("DIRECT_LUT_BINDING_FAILED"); quit(1); return
	print("DIRECT_LUT_BINDING_OK"); quit(0)
