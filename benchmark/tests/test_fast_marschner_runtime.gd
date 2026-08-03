extends SceneTree

## Tier-2 focused runtime test for the FAST_MARSCHNER_ANALYTIC preview variant.
##
## Runnable directly with the normal (windowed) Godot binary via --script:
##
##   godot.exe --path <project> --script res://benchmark/tests/test_fast_marschner_runtime.gd
##
## The test drives the interactive preview path (Engine.time_scale stays 1.0);
## timed benchmark runs freeze time and would fail the Bayer phase-motion
## assertion, so no benchmark artifacts are written and no timed runs start.
## The known unrelated `util/light_controller.gd:36` Camera3D `_current_mode`
## script warning may appear in the harness; it is not a test failure.

const INDIVIDUAL_GROOM := 1
const FAST_MARSCHNER_ANALYTIC := 5
const EXPECTED_SHADER_PATH := "res://assets/hair/materials/shaders/hair_marschner_fast.gdshader"
const PHASE_MOVE_FRAMES := 30
const MIN_NONBLACK_PIXELS := 20000
const MIN_IMAGE_DIMENSION := 256
const LIT_LUMINANCE_THRESHOLD := 0.18
const TIER2_PROFILE_PARAMETERS := [
	&"absorption_mode",
	&"absorption",
	&"eumelanin",
	&"pheomelanin",
	&"melanin_absorption_scale",
	&"ior",
]

var _failures: PackedStringArray = []


func _initialize() -> void:
	# Keep the ImGui overlay out of captures; it would add frame diffs.
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
	var groom_entries: Array = controller.get(&"groom_catalog")
	for groom_entry in groom_entries:
		if String(groom_entry.get("groom_id", "")) == "Blowout":
			groom = groom_entry.get("node") as MeshInstance3D
			break
	if groom == null or not is_instance_valid(groom):
		_fail("Blowout groom not found in groom_catalog")
		_finish()
		return

	var applied: bool = bool(controller.call(&"apply_preview", INDIVIDUAL_GROOM, FAST_MARSCHNER_ANALYTIC, &"Blowout"))
	if not applied:
		_fail("apply_preview(INDIVIDUAL_GROOM, FAST_MARSCHNER_ANALYTIC, Blowout) returned false")
		_finish()
		return
	print("EVIDENCE apply_preview=accepted variant=FAST_MARSCHNER_ANALYTIC time_scale=%s" % Engine.time_scale)
	if not is_equal_approx(Engine.time_scale, 1.0):
		_fail("preview test requires Engine.time_scale == 1.0, got %s" % Engine.time_scale)

	# Let the variant render for a few frames before sampling.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	var override_material: Material = groom.get_surface_override_material(0)
	if not (override_material is ShaderMaterial):
		_fail("selected surface override is %s, expected ShaderMaterial" % override_material.get_class())
		_finish()
		return
	var shader_material := override_material as ShaderMaterial
	var shader_path := "none"
	if shader_material.shader:
		shader_path = shader_material.shader.resource_path
	print("EVIDENCE surface_override_class=%s shader_path=%s" % [shader_material.get_class(), shader_path])
	if shader_path != EXPECTED_SHADER_PATH:
		_fail("shader path is '%s', expected '%s'" % [shader_path, EXPECTED_SHADER_PATH])
	_assert_tier2_profile_parameters(shader_material)

	# First capture: must have usable dimensions and lit (non-background) pixels.
	var frame_a: Image = root.get_texture().get_image()
	if frame_a == null:
		_fail("viewport image capture failed")
		_finish()
		return
	var width := frame_a.get_width()
	var height := frame_a.get_height()
	print("EVIDENCE frame_size=%dx%d" % [width, height])
	if width < MIN_IMAGE_DIMENSION or height < MIN_IMAGE_DIMENSION:
		_fail("viewport image too small: %dx%d" % [width, height])
	var lit_pixels_a := _count_lit_pixels(frame_a)
	print("EVIDENCE lit_pixels_first_capture=%d" % lit_pixels_a)
	if lit_pixels_a < MIN_NONBLACK_PIXELS:
		_fail("first capture has only %d lit pixels (threshold %d); the variant is not rendering hair" % [lit_pixels_a, MIN_NONBLACK_PIXELS])

	# Second capture after enough preview frames for the Bayer TIME phase to
	# move: a flat fallback material is static, a live discard shifts every
	# frame, so a nonzero diff proves the preview is alive.
	for wait_frame in PHASE_MOVE_FRAMES:
		await RenderingServer.frame_post_draw
	var frame_b: Image = root.get_texture().get_image()
	var differing_bytes := _byte_diff(frame_a, frame_b)
	print("EVIDENCE frame_diff_bytes_after_%d_frames=%d" % [PHASE_MOVE_FRAMES, differing_bytes])
	if differing_bytes <= 0:
		_fail("frame diff is zero after %d frames: the preview appears to be a static flat fallback" % PHASE_MOVE_FRAMES)

	_finish()


func _assert_tier2_profile_parameters(shader_material: ShaderMaterial) -> void:
	var profile: Resource = load("res://benchmark/resources/profiles/source_current.tres")
	if profile == null:
		_fail("source_current profile failed to load")
		return
	for parameter_name in TIER2_PROFILE_PARAMETERS:
		var expected: Variant = profile.get(parameter_name)
		var actual: Variant = shader_material.get("shader_parameter/%s" % parameter_name)
		var matches: bool
		if expected is float:
			matches = is_equal_approx(float(actual), float(expected))
		else:
			matches = actual == expected
		print("EVIDENCE tier2_profile_%s=%s" % [parameter_name, actual])
		if not matches:
			_fail("Tier-2 profile parameter %s is %s, expected %s" % [parameter_name, actual, expected])


func _count_lit_pixels(image: Image) -> int:
	var count := 0
	for y in image.get_height():
		for x in image.get_width():
			var pixel: Color = image.get_pixel(x, y)
			if pixel.r + pixel.g + pixel.b > LIT_LUMINANCE_THRESHOLD:
				count += 1
	return count


func _byte_diff(image_a: Image, image_b: Image) -> int:
	if image_a == null or image_b == null or image_a.get_size() != image_b.get_size():
		return -1
	var bytes_a: PackedByteArray = image_a.get_data()
	var bytes_b: PackedByteArray = image_b.get_data()
	var differing := 0
	for byte_index in bytes_a.size():
		if bytes_a[byte_index] != bytes_b[byte_index]:
			differing += 1
	return differing


func _fail(message: String) -> void:
	_failures.append(message)
	push_error(message)


func _finish() -> void:
	if _failures.is_empty():
		print("FAST_MARSCHNER_RUNTIME_TEST_OK")
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)
