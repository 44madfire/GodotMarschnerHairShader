@tool
extends Resource
class_name HairGroomData

## Groom-specific textures consumed by every hair lighting model.
##
## These textures describe generated card geometry rather than material look,
## so they intentionally live outside HairMaterialProfile. A material profile
## can therefore be reused across many grooms while each groom owns the texture
## data generated for its card atlas.

const ShaderUtils := preload("res://addons/marschner_hair/internal/hair_shader_utils.gd")

@export_category("Hair Card Textures")
## RGB = tangent direction encoded from [-1, 1] to [0, 1].
## A   = root-to-tip coordinate.
@export var coords_texture: Texture2D

## R = coverage/occupancy.
## G = strand depth.
## B = deterministic per-strand seed.
@export var attributes_texture: Texture2D


func is_complete() -> bool:
	return coords_texture != null and attributes_texture != null


func validation_message() -> String:
	var missing := PackedStringArray()
	if coords_texture == null:
		missing.append("coords_texture")
	if attributes_texture == null:
		missing.append("attributes_texture")
	if missing.is_empty():
		return ""
	return "HairGroomData is missing: %s" % ", ".join(missing)


## Applies this groom's generated textures to any production hair shader.
## Returns false when the material does not expose the shared groom contract or
## when either required texture is missing.
func apply_to_shader_material(material: ShaderMaterial, warn_on_failure: bool = true) -> bool:
	if material == null or material.shader == null:
		if warn_on_failure:
			push_warning("HairGroomData needs a ShaderMaterial with an assigned hair shader.")
		return false

	if not is_complete():
		if warn_on_failure:
			push_warning(validation_message())
		return false

	var uniform_names: Dictionary = ShaderUtils.uniform_names(material.shader)
	if not uniform_names.has(&"coords_texture") or not uniform_names.has(&"attributes_texture"):
		if warn_on_failure:
			push_warning("%s does not expose the shared hair groom texture contract." % material.shader.resource_path)
		return false

	material.set_shader_parameter(&"coords_texture", coords_texture)
	material.set_shader_parameter(&"attributes_texture", attributes_texture)
	return true


## Convenience constructor for migrating an existing generated source material.
## It reads the two shared groom texture uniforms without modifying the source.
## Returned as Resource so this script never depends on its own global class
## name being registered during headless parsing.
static func from_shader_material(material: ShaderMaterial) -> Resource:
	var groom: Resource = (load("res://addons/marschner_hair/hair_groom_data.gd") as GDScript).new()
	if material == null or material.shader == null:
		return groom
	groom.set(&"coords_texture", material.get_shader_parameter(&"coords_texture") as Texture2D)
	groom.set(&"attributes_texture", material.get_shader_parameter(&"attributes_texture") as Texture2D)
	return groom
