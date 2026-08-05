extends SceneTree

## Focused runtime test for the PR4/PR5 diagnostic shader variants: the shipping
## selector wrapper and the three committed diagnostic wrappers that share the
## same body (hair_marschner_fast_body.gdshaderinc).
##
## Runnable directly with the normal (windowed) Godot binary via --script:
##
##   godot.exe --path <project> --script res://benchmark/tests/test_fast_marschner_diagnostic_variants_runtime.gd
##
## The four shader paths under test:
##   - res://assets/hair/materials/shaders/hair_marschner_fast.gdshader
##     (shipping selectors: FM_LONGITUDINAL_MODE 0, FM_R_LONGITUDINAL_MODE 0,
##     FM_CUTICLE_TILT_CONVENTION 0, FM_AZIMUTHAL_MODE 0)
##   - res://assets/hair/materials/shaders/hair_marschner_fast_baseline_longitudinal.gdshader
##     (diagnostic: FM_LONGITUDINAL_MODE 1, R mode 0, baseline convention 0)
##   - res://assets/hair/materials/shaders/hair_marschner_fast_r_nonseparable.gdshader
##     (diagnostic: FM_LONGITUDINAL_MODE 0, R mode 1, baseline convention 0)
##   - res://assets/hair/materials/shaders/hair_marschner_fast_baseline_azimuthal.gdshader
##     (diagnostic: FM_LONGITUDINAL_MODE 0, R mode 0, baseline convention 0,
##     FM_AZIMUTHAL_MODE 1 baseline cross-section offsets for the analytic BSDF
##     only; LUT sampling and the fixed-h attenuation family are unchanged)
##
## For each path the test instantiates BenchmarkHarness.tscn, hides the preview
## overlay, finds the Blowout groom, duplicates the source/override
## ShaderMaterial, assigns the loaded wrapper shader to the duplicate, renders
## several frames, and asserts the shader loads/compiles (RenderingServer code
## retrieval), the output image dimensions are valid, and a minimum lit-pixel
## count is met (the shader actually renders hair). Variant identity and
## per-variant evidence are printed; the test ends with
## FAST_MARSCHNER_DIAGNOSTIC_VARIANTS_RUNTIME_TEST_OK (exit 0) or pushed
## errors and exit 1.
##
## No timed benchmarks start and no benchmark artifacts are written. The known
## unrelated `util/light_controller.gd:36` Camera3D `_current_mode` script
## warning may appear in the harness; it is not a test failure.

const GROOM_ID := &"Blowout"
const INDIVIDUAL_GROOM := 1
const FAST_MARSCHNER_ANALYTIC := 5
const SHIPPING_SHADER_PATH := "res://assets/hair/materials/shaders/hair_marschner_fast.gdshader"
const BASELINE_LONGITUDINAL_SHADER_PATH := "res://assets/hair/materials/shaders/hair_marschner_fast_baseline_longitudinal.gdshader"
const R_NONSEPARABLE_SHADER_PATH := "res://assets/hair/materials/shaders/hair_marschner_fast_r_nonseparable.gdshader"
const BASELINE_AZIMUTHAL_SHADER_PATH := "res://assets/hair/materials/shaders/hair_marschner_fast_baseline_azimuthal.gdshader"
const VARIANT_PATHS := [
	{"id": "shipping", "path": SHIPPING_SHADER_PATH},
	{"id": "baseline_longitudinal", "path": BASELINE_LONGITUDINAL_SHADER_PATH},
	{"id": "r_nonseparable", "path": R_NONSEPARABLE_SHADER_PATH},
	{"id": "baseline_azimuthal", "path": BASELINE_AZIMUTHAL_SHADER_PATH},
]
const RENDER_FRAMES := 3
const MIN_NONBLACK_PIXELS := 20000
const MIN_IMAGE_DIMENSION := 256
const LIT_LUMINANCE_THRESHOLD := 0.18

var _failures: PackedStringArray = []


func _initialize() -> void:
	# Keep the ImGui overlay out of the captures; it would add UI pixels.
	var debug_manager: Node = root.get_node_or_null("DebugManager")
	if debug_manager:
		debug_manager.set(&"should_render_imgui", false)
	call_deferred("_run")


func _run() -> void:
	var packed: PackedScene = load("res://benchmark/BenchmarkHarness.tscn")
	if packed == null:
		_fail("BenchmarkHarness.tscn failed to load")
		_finish()
		return
	var harness: Node = packed.instantiate()
	root.add_child(harness)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	var overlay: Control = harness.get_node_or_null("PreviewUILayer/BenchmarkPreviewOverlay")
	if overlay:
		overlay.visible = false
		print("EVIDENCE preview_overlay=hidden")

	var controller: Node = harness.get_node_or_null("BenchmarkController")
	if controller == null:
		_fail("BenchmarkController not found in the harness")
		_finish()
		return

	var groom: MeshInstance3D = null
	for groom_entry in controller.get(&"groom_catalog"):
		if String(groom_entry.get("groom_id", "")) == String(GROOM_ID):
			groom = groom_entry.get("node") as MeshInstance3D
			break
	if groom == null or not is_instance_valid(groom):
		_fail("Blowout groom not found in groom_catalog")
		_finish()
		return
	var applied: bool = bool(controller.call(&"apply_preview", INDIVIDUAL_GROOM, FAST_MARSCHNER_ANALYTIC, GROOM_ID))
	if not applied:
		_fail("failed to apply the shipping Fast preview before diagnostic replacement")
		_finish()
		return
	await RenderingServer.frame_post_draw

	# The fixture grooms carry an instance-level material_override which wins
	# over every surface override; clear it (and restore it at the end) exactly
	# like the controller's variant application does.
	var original_instance_override: Material = groom.material_override
	groom.material_override = null
	await RenderingServer.frame_post_draw

	for variant in VARIANT_PATHS:
		var variant_id: String = variant["id"]
		var shader_path: String = variant["path"]
		await _exercise_variant(groom, variant_id, shader_path)

	groom.material_override = original_instance_override
	_finish()


func _exercise_variant(groom: MeshInstance3D, variant_id: String, shader_path: String) -> void:
	# Load the wrapper shader and confirm it resolves to the expected path.
	var loaded_shader: Shader = load(shader_path) as Shader
	if loaded_shader == null:
		_fail("[%s] shader failed to load: %s" % [variant_id, shader_path])
		return
	if loaded_shader.resource_path != shader_path:
		_fail("[%s] loaded shader path is '%s', expected '%s'" % [variant_id, loaded_shader.resource_path, shader_path])
		return

	# Duplicate the source/override ShaderMaterial: the previous variant's
	# surface override if one exists, otherwise the groom's active (instance
	# override) material. The duplicate preserves the groom textures and
	# artist-facing parameters; only the shader resource is replaced.
	var source_material := groom.get_surface_override_material(0) as ShaderMaterial
	if source_material == null:
		source_material = groom.get_active_material(0) as ShaderMaterial
	if source_material == null:
		_fail("[%s] no source ShaderMaterial found on the Blowout groom surface 0" % variant_id)
		return
	var variant_material: ShaderMaterial = source_material.duplicate()
	variant_material.shader = loaded_shader
	groom.set_surface_override_material(0, variant_material)

	# Render several frames so the shader actually compiles and draws.
	for frame_index in RENDER_FRAMES:
		await RenderingServer.frame_post_draw

	# Compile evidence: the shader must be registered with the RenderingServer
	# and its code must be retrievable (empty code means it never loaded).
	var shader_rid := loaded_shader.get_rid()
	var compiled_code: String = RenderingServer.shader_get_code(shader_rid)
	if compiled_code.is_empty():
		_fail("[%s] RenderingServer has no code for the loaded shader (failed to compile): %s" % [variant_id, shader_path])
		return

	# Output image validity and a minimum lit-pixel count.
	var frame: Image = root.get_texture().get_image()
	if frame == null:
		_fail("[%s] viewport image capture failed" % variant_id)
		return
	var width := frame.get_width()
	var height := frame.get_height()
	if width < MIN_IMAGE_DIMENSION or height < MIN_IMAGE_DIMENSION:
		_fail("[%s] viewport image too small: %dx%d (minimum %d)" % [variant_id, width, height, MIN_IMAGE_DIMENSION])
	var lit_pixels := _count_lit_pixels(frame)
	print("EVIDENCE diagnostic_variant=%s shader_path=%s code_bytes=%d frame_size=%dx%d lit_pixels=%d" % [variant_id, shader_path, compiled_code.length(), width, height, lit_pixels])
	if lit_pixels < MIN_NONBLACK_PIXELS:
		_fail("[%s] variant renders only %d lit pixels (threshold %d); the shader is not drawing hair" % [variant_id, lit_pixels, MIN_NONBLACK_PIXELS])


func _count_lit_pixels(image: Image) -> int:
	var count := 0
	for y in image.get_height():
		for x in image.get_width():
			var pixel: Color = image.get_pixel(x, y)
			if pixel.r + pixel.g + pixel.b > LIT_LUMINANCE_THRESHOLD:
				count += 1
	return count


func _fail(message: String) -> void:
	_failures.append(message)
	push_error(message)


func _finish() -> void:
	if _failures.is_empty():
		print("FAST_MARSCHNER_DIAGNOSTIC_VARIANTS_RUNTIME_TEST_OK")
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)
