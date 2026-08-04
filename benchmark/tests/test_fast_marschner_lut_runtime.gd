extends SceneTree

## Focused runtime test for the FAST_MARSCHNER_LUT preview variant (enum 6).
##
## Runnable directly with the normal (windowed) Godot binary via --script:
##
##   godot.exe --path <project> --script res://benchmark/tests/test_fast_marschner_lut_runtime.gd
##
## Asserts: apply_preview accepts the LUT variant; the selected surface
## override is the fast Marschner shader with use_azimuthal_lut=true and the
## committed 64^3 Texture3D bound; the preview renders non-black output with a
## frozen Bayer phase (freeze_bayer_phase, deterministic preview contract);
## and the analytic FAST_MARSCHNER_ANALYTIC variant keeps the LUT flag false.

const INDIVIDUAL_GROOM := 1
const FAST_MARSCHNER_ANALYTIC := 5
const FAST_MARSCHNER_LUT := 6
const EXPECTED_SHADER_PATH := "res://assets/hair/materials/shaders/hair_marschner_fast.gdshader"
const PHASE_MOVE_FRAMES := 30
const MIN_NONBLACK_PIXELS := 20000
const MIN_IMAGE_DIMENSION := 256
const LIT_LUMINANCE_THRESHOLD := 0.18
const EXPECTED_LUT_SIZE := 64

var _failures: PackedStringArray = []


func _initialize() -> void:
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
		if String(groom_entry.get("groom_id", "")) == "Blowout":
			groom = groom_entry.get("node") as MeshInstance3D
			break
	if groom == null or not is_instance_valid(groom):
		_fail("Blowout groom not found in groom_catalog")
		_finish()
		return

	# 1) LUT variant: accepted, flag on, texture bound.
	var applied: bool = bool(controller.call(&"apply_preview", INDIVIDUAL_GROOM, FAST_MARSCHNER_LUT, &"Blowout"))
	if not applied:
		_fail("apply_preview(INDIVIDUAL_GROOM, FAST_MARSCHNER_LUT, Blowout) returned false")
		_finish()
		return
	print("EVIDENCE apply_preview=accepted variant=FAST_MARSCHNER_LUT time_scale=%s" % Engine.time_scale)

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
	print("EVIDENCE shader_path=%s" % shader_path)
	if shader_path != EXPECTED_SHADER_PATH:
		_fail("shader path is '%s', expected '%s'" % [shader_path, EXPECTED_SHADER_PATH])

	var lut_flag_value: Variant = shader_material.get(&"shader_parameter/use_azimuthal_lut")
	var dual_flag_value: Variant = shader_material.get(&"shader_parameter/use_dual_scatter")
	var env_flag_value: Variant = shader_material.get(&"shader_parameter/use_environment")
	print("EVIDENCE use_azimuthal_lut=%s use_dual_scatter=%s use_environment=%s" % [lut_flag_value, dual_flag_value, env_flag_value])
	if lut_flag_value != true:
		_fail("use_azimuthal_lut must be true on the LUT variant, got %s" % lut_flag_value)
	if dual_flag_value != false or env_flag_value != false:
		_fail("LUT variant must force dual=false and environment=false, got %s/%s" % [dual_flag_value, env_flag_value])

	var clone_roughness: Variant = shader_material.get(&"shader_parameter/azimuthal_roughness")
	print("EVIDENCE lut_clone_azimuthal_roughness=%s" % clone_roughness)
	if not (clone_roughness is float or clone_roughness is int) or float(clone_roughness) < 0.3:
		_fail("LUT clone azimuthal_roughness must be in the validated range (>= 0.3), got %s" % clone_roughness)

	var lut_value: Variant = shader_material.get(&"shader_parameter/azimuthal_lut")
	var lut_texture := lut_value as Texture3D
	if lut_texture == null:
		_fail("azimuthal_lut Texture3D is not bound")
	else:
		print("EVIDENCE azimuthal_lut=%s %dx%dx%d rid_valid=%s" % [lut_texture.resource_path, lut_texture.get_width(), lut_texture.get_height(), lut_texture.get_depth(), lut_texture.get_rid().is_valid()])
		if lut_texture.get_width() != EXPECTED_LUT_SIZE or lut_texture.get_height() != EXPECTED_LUT_SIZE or lut_texture.get_depth() != EXPECTED_LUT_SIZE:
			_fail("LUT texture size %dx%dx%d, expected %d^3" % [lut_texture.get_width(), lut_texture.get_height(), lut_texture.get_depth(), EXPECTED_LUT_SIZE])
		if not lut_texture.get_rid().is_valid():
			_fail("bound Texture3D has an invalid RID: the LUT binding fell back silently")

	# 2) Non-black output and live preview frame changes.
	var frame_a: Image = root.get_texture().get_image()
	if frame_a == null:
		_fail("viewport image capture failed")
		_finish()
		return
	var width := frame_a.get_width()
	var height := frame_a.get_height()
	if width < MIN_IMAGE_DIMENSION or height < MIN_IMAGE_DIMENSION:
		_fail("viewport image too small: %dx%d" % [width, height])
	var lit_pixels := _count_lit_pixels(frame_a)
	print("EVIDENCE frame_size=%dx%d lit_pixels=%d" % [width, height, lit_pixels])
	if lit_pixels < MIN_NONBLACK_PIXELS:
		_fail("LUT preview has only %d lit pixels (threshold %d)" % [lit_pixels, MIN_NONBLACK_PIXELS])

	# Second capture after enough preview frames for the Bayer TIME phase to
	# move: interactive previews freeze the Bayer phase (freeze_bayer_phase,
	# applied by apply_preview for every FAST_MARSCHNER_* variant), so the
	# hashed strand pattern must stay byte-identical. A nonzero diff would mean
	# the preview freeze regressed; the lit-pixel check above proves the
	# variant is rendering (a flat fallback has no lit pixels).
	var freeze_value: Variant = shader_material.get(&"shader_parameter/freeze_bayer_phase")
	print("EVIDENCE preview_freeze_bayer_phase=%s" % freeze_value)
	if freeze_value != true:
		_fail("apply_preview did not freeze the Bayer phase for FAST_MARSCHNER_LUT (got %s)" % freeze_value)
	for wait_frame in PHASE_MOVE_FRAMES:
		await RenderingServer.frame_post_draw
	var frame_b: Image = root.get_texture().get_image()
	var differing_bytes := _byte_diff(frame_a, frame_b)
	print("EVIDENCE frame_diff_bytes_after_%d_frames=%d" % [PHASE_MOVE_FRAMES, differing_bytes])
	if differing_bytes > 0:
		_fail("frame diff is %d after %d frames: the LUT preview Bayer phase should be frozen (freeze_bayer_phase)" % [differing_bytes, PHASE_MOVE_FRAMES])

	# 3) Analytic variant must keep the LUT flag off (reference path unchanged).
	var analytic_applied: bool = bool(controller.call(&"apply_preview", INDIVIDUAL_GROOM, FAST_MARSCHNER_ANALYTIC, &"Blowout"))
	if not analytic_applied:
		_fail("apply_preview(FAST_MARSCHNER_ANALYTIC) returned false")
		_finish()
		return
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var analytic_material := groom.get_surface_override_material(0) as ShaderMaterial
	var analytic_flag: Variant = analytic_material.get(&"shader_parameter/use_azimuthal_lut")
	print("EVIDENCE analytic_use_azimuthal_lut=%s (expected false)" % analytic_flag)
	if analytic_flag != false:
		_fail("analytic variant must keep use_azimuthal_lut=false, got %s" % analytic_flag)

	# 4) Range seam: a selected surface below the LUT's validated roughness
	# must be rejected with a clear start failure, and the original surface
	# state must be restored. The committed source material is mutated only
	# temporarily in-process and restored immediately.
	var catalog_surface: Dictionary = {}
	for groom_entry in controller.get(&"groom_catalog"):
		if String(groom_entry.get("groom_id", "")) == "Blowout":
			catalog_surface = groom_entry["surfaces"][0]
			break
	var source_material: ShaderMaterial = catalog_surface.get("source_active_material") as ShaderMaterial
	var original_override: Material = catalog_surface.get("original_override")
	var original_roughness: Variant = source_material.get(&"shader_parameter/azimuthal_roughness")
	source_material.set(&"shader_parameter/azimuthal_roughness", 0.1)
	var rejected: bool = bool(controller.call(&"apply_preview", INDIVIDUAL_GROOM, FAST_MARSCHNER_LUT, &"Blowout"))
	source_material.set(&"shader_parameter/azimuthal_roughness", original_roughness)
	if rejected:
		_fail("LUT preview with azimuthal_roughness 0.1 must be rejected")
	var start_error: String = String(controller.get(&"last_start_error"))
	print("EVIDENCE rejected_start_error=%s" % start_error)
	if not start_error.contains("below the supported minimum"):
		_fail("rejection must name the roughness range, got: %s" % start_error)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var restored_material: Material = groom.get_surface_override_material(0)
	if restored_material != original_override:
		_fail("surface override must be restored after the rejected LUT apply")
	var reapply: bool = bool(controller.call(&"apply_preview", INDIVIDUAL_GROOM, FAST_MARSCHNER_LUT, &"Blowout"))
	if not reapply:
		_fail("LUT preview must succeed again after restoring the source roughness")
	print("EVIDENCE reapply_after_restore=true")

	_finish()


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
		print("FAST_MARSCHNER_LUT_RUNTIME_TEST_OK")
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)
