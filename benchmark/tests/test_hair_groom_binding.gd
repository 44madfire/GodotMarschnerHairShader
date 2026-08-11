extends SceneTree

## LUT-independent smoke test for the shared groom/card contract.
## Verifies that a new groom can build a material from HairGroomData without an
## existing generated source ShaderMaterial and that every compiled production
## variant still exposes the common card texture interface.

const ProfileScript := preload("res://assets/hair/materials/HairMaterialProfile.gd")
const GroomDataScript := preload("res://assets/hair/materials/HairGroomData.gd")
const PreviewScript := preload("res://demos/hair_material_profile_preview.gd")

const TIER_APPROX: int = 0
const TIER_FAST: int = 1
const TIER_CINEMATIC: int = 2
const TIER_REFERENCE: int = 3

var _failures: PackedStringArray = PackedStringArray()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var profile: Resource = ProfileScript.new()
	var groom: Resource = GroomDataScript.new()

	var image: Image = Image.create(4, 4, false, Image.FORMAT_RGBA8)
	var coords_texture: ImageTexture = ImageTexture.create_from_image(image)
	var attributes_texture: ImageTexture = ImageTexture.create_from_image(image)
	groom.set(&"coords_texture", coords_texture)
	groom.set(&"attributes_texture", attributes_texture)
	_check(bool(groom.call(&"is_complete")), "HairGroomData should be complete after both textures are assigned")

	for tier in [TIER_APPROX, TIER_FAST, TIER_CINEMATIC, TIER_REFERENCE]:
		profile.set(&"quality_tier", tier)
		var shader: Shader = profile.call(&"get_shader_resource") as Shader
		_check(shader != null, "tier %d returned a null shader" % tier)
		if shader != null:
			_assert_uniform(shader, &"coords_texture")
			_assert_uniform(shader, &"attributes_texture")

	# New-groom path: no source ShaderMaterial exists. The profile creates the
	# material, selects Approx, and HairGroomData supplies both generated maps.
	profile.set(&"quality_tier", TIER_APPROX)
	var material: ShaderMaterial = profile.call(&"create_material", groom) as ShaderMaterial
	_check(material != null and material.shader != null, "create_material() did not create an Approx material")
	if material != null:
		_check(material.get_shader_parameter(&"coords_texture") == coords_texture, "new material did not receive coords_texture")
		_check(material.get_shader_parameter(&"attributes_texture") == attributes_texture, "new material did not receive attributes_texture")

	# Reference needs no LUT, so use it to verify explicit groom data rebinds the
	# card contract after a shader-variant swap rather than relying on preserved
	# state from the source material.
	profile.set(&"quality_tier", TIER_REFERENCE)
	var reference_applied: bool = bool(profile.call(&"apply_to", material, groom))
	_check(reference_applied, "Reference apply_to(material, groom) failed")
	_check(material.get_shader_parameter(&"coords_texture") == coords_texture, "Reference swap lost coords_texture")
	_check(material.get_shader_parameter(&"attributes_texture") == attributes_texture, "Reference swap lost attributes_texture")

	# Hardening: a non-null Resource that is not HairGroomData-compatible must be
	# rejected before apply_to() mutates the material. Select a different target
	# tier first so this catches accidental shader/profile/LUT application before
	# groom validation.
	var shader_before_rejection: Shader = material.shader
	var coords_before_rejection: Variant = material.get_shader_parameter(&"coords_texture")
	var attributes_before_rejection: Variant = material.get_shader_parameter(&"attributes_texture")
	profile.set(&"quality_tier", TIER_APPROX)
	var unrelated: Resource = Resource.new()
	var rejected: bool = bool(profile.call(&"apply_to", material, unrelated))
	_check(not rejected, "apply_to() accepted an unrelated Resource as groom_data")
	_check(material.shader == shader_before_rejection, "rejected groom_data changed the material shader")
	_check(material.get_shader_parameter(&"coords_texture") == coords_before_rejection, "rejected groom_data changed coords_texture")
	_check(material.get_shader_parameter(&"attributes_texture") == attributes_before_rejection, "rejected groom_data changed attributes_texture")

	# Hardening: the preview's groom_data Inspector field must restrict
	# assignment to HairGroomData through the resource-type hint while the
	# exported member itself stays a parser-safe untyped Resource.
	var preview: Node3D = PreviewScript.new()
	var preview_properties: Array[Dictionary] = preview.get_property_list()
	var groom_hint_ok: bool = false
	for property_info in preview_properties:
		var property_name: StringName = StringName(property_info.get("name", ""))
		if property_name == &"groom_data":
			groom_hint_ok = int(property_info.get("hint", 0)) == PROPERTY_HINT_RESOURCE_TYPE
			groom_hint_ok = groom_hint_ok and String(property_info.get("hint_string", "")) == "HairGroomData"
			break
	_check(groom_hint_ok, "preview groom_data does not expose the HairGroomData resource-type hint")
	preview.free()

	if not _failures.is_empty():
		for failure_value in _failures:
			push_error(String(failure_value))
		quit(1)
		return
	print("HAIR_GROOM_BINDING_TEST_OK")
	quit(0)


func _assert_uniform(shader: Shader, required_name: StringName) -> void:
	var uniforms: Array = shader.get_shader_uniform_list()
	for uniform_value in uniforms:
		var uniform: Dictionary = uniform_value
		if StringName(uniform.get("name", "")) == required_name:
			return
	_check(false, "%s is missing shared groom uniform %s" % [shader.resource_path, String(required_name)])


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
