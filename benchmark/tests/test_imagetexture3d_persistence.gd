extends SceneTree

## Cross-process ImageTexture3D serialization probe.
##
## Run this script in separate --write and --verify processes. The historical
## Godot 4.0/4.1 failure only became visible after the saved texture was loaded
## again, so the paired runner intentionally avoids treating a same-process
## ResourceLoader cache hit as evidence of persistence.

const SIZE_X: int = 8
const SIZE_Y: int = 6
const SIZE_Z: int = 4
const FORMAT: int = Image.FORMAT_RGBA8
const TEST_PATHS: Array[String] = [
	"user://marschner_imagetexture3d_roundtrip.res",
	"user://marschner_imagetexture3d_roundtrip.tres",
]


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.has("--write"):
		quit(_write_resources())
		return
	if args.has("--verify"):
		quit(_verify_resources())
		return
	if args.has("--cleanup"):
		quit(_cleanup_resources())
		return

	push_error("Choose exactly one phase: --write, --verify, or --cleanup")
	quit(2)


func _write_resources() -> int:
	var slices: Array[Image] = _build_expected_slices()
	var texture: ImageTexture3D = ImageTexture3D.new()
	var create_error: Error = texture.create(FORMAT, SIZE_X, SIZE_Y, SIZE_Z, false, slices)
	if create_error != OK:
		push_error("ImageTexture3D.create() failed: %s" % error_string(create_error))
		return 1

	for path in TEST_PATHS:
		var save_error: Error = ResourceSaver.save(texture, path)
		if save_error != OK:
			push_error("ResourceSaver.save(%s) failed: %s" % [path, error_string(save_error)])
			return 1

	print("IMAGE_TEXTURE_3D_PERSISTENCE_WRITE_OK")
	return 0


func _verify_resources() -> int:
	var expected: Array[Image] = _build_expected_slices()
	for path in TEST_PATHS:
		if not ResourceLoader.exists(path):
			push_error("Saved resource does not exist: %s" % path)
			return 1

		var loaded_resource: Resource = ResourceLoader.load(path, "ImageTexture3D", ResourceLoader.CACHE_MODE_IGNORE)
		var texture: ImageTexture3D = loaded_resource as ImageTexture3D
		if texture == null:
			push_error("Saved resource did not reload as ImageTexture3D: %s" % path)
			return 1
		if texture.get_width() != SIZE_X or texture.get_height() != SIZE_Y or texture.get_depth() != SIZE_Z:
			push_error("Dimension mismatch after reload for %s: got %dx%dx%d" % [path, texture.get_width(), texture.get_height(), texture.get_depth()])
			return 1
		if texture.get_format() != FORMAT:
			push_error("Format mismatch after reload for %s: got %d expected %d" % [path, texture.get_format(), FORMAT])
			return 1
		if texture.has_mipmaps():
			push_error("Unexpected mipmaps after reload for %s" % path)
			return 1

		var actual: Array[Image] = texture.get_data()
		if actual.size() != SIZE_Z:
			push_error("Slice-count mismatch after reload for %s: got %d expected %d" % [path, actual.size(), SIZE_Z])
			return 1
		for z in SIZE_Z:
			if actual[z] == null:
				push_error("Null image slice %d after reload for %s" % [z, path])
				return 1
			if actual[z].get_data() != expected[z].get_data():
				push_error("Texel payload mismatch in slice %d after reload for %s" % [z, path])
				return 1

	print("IMAGE_TEXTURE_3D_PERSISTENCE_VERIFY_OK")
	return 0


func _cleanup_resources() -> int:
	var failed: bool = false
	for path in TEST_PATHS:
		var absolute_path: String = ProjectSettings.globalize_path(path)
		if FileAccess.file_exists(path):
			var remove_error: Error = DirAccess.remove_absolute(absolute_path)
			if remove_error != OK:
				push_error("Failed to remove %s: %s" % [path, error_string(remove_error)])
				failed = true
	if failed:
		return 1
	print("IMAGE_TEXTURE_3D_PERSISTENCE_CLEANUP_OK")
	return 0


func _build_expected_slices() -> Array[Image]:
	var slices: Array[Image] = []
	for z in SIZE_Z:
		var image: Image = Image.create(SIZE_X, SIZE_Y, false, FORMAT)
		for y in SIZE_Y:
			for x in SIZE_X:
				# Exact 8-bit-friendly values make byte-for-byte comparison useful.
				var r: float = float((x * 31 + z * 17) & 0xff) / 255.0
				var g: float = float((y * 47 + z * 29) & 0xff) / 255.0
				var b: float = float((x * 13 + y * 19 + z * 53) & 0xff) / 255.0
				var a: float = float((x * 7 + y * 11 + z * 23 + 64) & 0xff) / 255.0
				image.set_pixel(x, y, Color(r, g, b, a))
		slices.append(image)
	return slices
