extends SceneTree

## Focused Phase 4 runtime test for the FAST_MARSCHNER_R_STANDARDIZED_LUT
## preview variant (enum 10): the diagnostic wrapper
## hair_marschner_fast_r_standardized_lut.gdshader (FM_R_STANDARDIZED_LUT_MODE
## 1) with the committed 256x256x128 RGBAF standardized projected-R LUT.
##
## Runnable directly with the normal (windowed) Godot binary via --script:
##
##   godot.exe --path <project> --script res://benchmark/tests/test_fast_marschner_standardized_r_lut_runtime.gd
##
## Asserts: apply_preview accepts the variant; the selected surface override
## uses the diagnostic wrapper path with the committed Texture3D bound (valid
## RID, 256x256x128) and the standardized flags/modes forced (azimuthal
## LUT/dual/preintegrated/environment off, r_standardized_lut_log_decode
## false, frozen Bayer preview contract); the preview renders non-black
## output; toggling r_standardized_lut_log_decode=true changes the rendered
## frame pixels (both decodes return linear Q, but the linear-vs-log2 decode
## and its interpolation space differ); an observed multi-frame average
## wall-time metric is printed WITHOUT a brittle machine-specific FPS gate;
## and the analytic FAST_MARSCHNER_ANALYTIC variant restores the shipping
## shader with the opt-in flags false.
##
## Ends with FAST_MARSCHNER_R_STANDARDIZED_LUT_RUNTIME_TEST_OK (exit 0) or
## pushed errors and exit 1. No timed benchmark starts and no benchmark
## artifacts are written. The known unrelated `util/light_controller.gd:36`
## Camera3D `_current_mode` script warning may appear in the harness; it is
## not a test failure.

const GROOM_ID := &"Blowout"
const INDIVIDUAL_GROOM := 1
const FAST_MARSCHNER_ANALYTIC := 5
const FAST_MARSCHNER_R_STANDARDIZED_LUT := 10
const EXPECTED_SHADER_PATH := "res://assets/hair/materials/shaders/hair_marschner_fast_r_standardized_lut.gdshader"
const EXPECTED_SHIPPING_SHADER_PATH := "res://assets/hair/materials/shaders/hair_marschner_fast.gdshader"
const R_STANDARDIZED_LUT_DATA_PATH := "res://benchmark/resources/luts/fast_marschner_r_standardized_lut_256x256x128.res"
const EXPECTED_LUT_SIZE_X := 256
const EXPECTED_LUT_SIZE_Y := 256
const EXPECTED_LUT_SIZE_Z := 128
const MIN_NONBLACK_PIXELS := 20000
const MIN_IMAGE_DIMENSION := 256
const LIT_LUMINANCE_THRESHOLD := 0.18
const TOGGLE_WAIT_FRAMES := 2
const WALL_TIME_FRAMES := 60

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

	# 0) Committed LUT data resource: metadata contract before any preview.
	var lut_data: Resource = load(R_STANDARDIZED_LUT_DATA_PATH)
	if lut_data == null:
		_fail("standardized-R LUT data resource failed to load: %s" % R_STANDARDIZED_LUT_DATA_PATH)
		_finish()
		return
	var data_size_x: Variant = lut_data.get(&"size_x")
	var data_size_y: Variant = lut_data.get(&"size_y")
	var data_size_z: Variant = lut_data.get(&"size_z")
	var data_format: Variant = lut_data.get(&"format")
	var data_contract: Variant = lut_data.get(&"contract")
	print("EVIDENCE lut_data path=%s size=%sx%sx%s format=%s contract=%s" % [R_STANDARDIZED_LUT_DATA_PATH, data_size_x, data_size_y, data_size_z, data_format, data_contract])
	if data_size_x != EXPECTED_LUT_SIZE_X or data_size_y != EXPECTED_LUT_SIZE_Y or data_size_z != EXPECTED_LUT_SIZE_Z:
		_fail("standardized-R LUT data size %sx%sx%s, expected %dx%dx%d" % [data_size_x, data_size_y, data_size_z, EXPECTED_LUT_SIZE_X, EXPECTED_LUT_SIZE_Y, EXPECTED_LUT_SIZE_Z])
	if data_format != Image.FORMAT_RGBAF:
		_fail("standardized-R LUT data format %s, expected RGBAF (%d)" % [data_format, Image.FORMAT_RGBAF])
	if not (data_contract is String) or String(data_contract).strip_edges().is_empty():
		_fail("standardized-R LUT data contract metadata missing")
	var data_bytes: Variant = lut_data.get(&"data")
	if not (data_bytes is PackedByteArray) or (data_bytes as PackedByteArray).size() != EXPECTED_LUT_SIZE_X * EXPECTED_LUT_SIZE_Y * EXPECTED_LUT_SIZE_Z * 16:
		_fail("standardized-R LUT data byte payload does not match 256x256x128 RGBAF")

	# 1) Standardized-R LUT variant: accepted, diagnostic wrapper, texture bound.
	var applied: bool = bool(controller.call(&"apply_preview", INDIVIDUAL_GROOM, FAST_MARSCHNER_R_STANDARDIZED_LUT, GROOM_ID))
	if not applied:
		_fail("apply_preview(INDIVIDUAL_GROOM, FAST_MARSCHNER_R_STANDARDIZED_LUT, Blowout) returned false")
		_finish()
		return
	print("EVIDENCE apply_preview=accepted variant=FAST_MARSCHNER_R_STANDARDIZED_LUT time_scale=%s" % Engine.time_scale)

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
		_fail("shader path is '%s', expected the diagnostic wrapper '%s'" % [shader_path, EXPECTED_SHADER_PATH])

	var lut_flag_value: Variant = shader_material.get(&"shader_parameter/use_azimuthal_lut")
	var dual_flag_value: Variant = shader_material.get(&"shader_parameter/use_dual_scatter")
	var preintegrated_flag_value: Variant = shader_material.get(&"shader_parameter/use_preintegrated_dual_scatter")
	var env_flag_value: Variant = shader_material.get(&"shader_parameter/use_environment")
	var log_decode_value: Variant = shader_material.get(&"shader_parameter/r_standardized_lut_log_decode")
	print("EVIDENCE use_azimuthal_lut=%s use_dual_scatter=%s use_preintegrated_dual_scatter=%s use_environment=%s r_standardized_lut_log_decode=%s" % [lut_flag_value, dual_flag_value, preintegrated_flag_value, env_flag_value, log_decode_value])
	if lut_flag_value != false or dual_flag_value != false or preintegrated_flag_value != false or env_flag_value != false:
		_fail("standardized-R variant must force azimuthal/dual/preintegrated/environment off, got %s/%s/%s/%s" % [lut_flag_value, dual_flag_value, preintegrated_flag_value, env_flag_value])
	if log_decode_value != false:
		_fail("r_standardized_lut_log_decode must default false, got %s" % log_decode_value)

	var lut_value: Variant = shader_material.get(&"shader_parameter/r_standardized_lut")
	var lut_texture := lut_value as Texture3D
	if lut_texture == null:
		_fail("r_standardized_lut Texture3D is not bound")
	else:
		print("EVIDENCE r_standardized_lut=%s %dx%dx%d rid_valid=%s" % [lut_texture.resource_path, lut_texture.get_width(), lut_texture.get_height(), lut_texture.get_depth(), lut_texture.get_rid().is_valid()])
		if lut_texture.get_width() != EXPECTED_LUT_SIZE_X or lut_texture.get_height() != EXPECTED_LUT_SIZE_Y or lut_texture.get_depth() != EXPECTED_LUT_SIZE_Z:
			_fail("standardized-R LUT texture size %dx%dx%d, expected %dx%dx%d" % [lut_texture.get_width(), lut_texture.get_height(), lut_texture.get_depth(), EXPECTED_LUT_SIZE_X, EXPECTED_LUT_SIZE_Y, EXPECTED_LUT_SIZE_Z])
		if not lut_texture.get_rid().is_valid():
			_fail("bound Texture3D has an invalid RID: the LUT binding fell back silently")

	# 2) Non-black output (the diagnostic R path actually renders hair) and
	# the frozen-Bayer preview contract.
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
		_fail("standardized-R LUT preview has only %d lit pixels (threshold %d)" % [lit_pixels, MIN_NONBLACK_PIXELS])
	var freeze_value: Variant = shader_material.get(&"shader_parameter/freeze_bayer_phase")
	print("EVIDENCE preview_freeze_bayer_phase=%s" % freeze_value)
	if freeze_value != true:
		_fail("apply_preview did not freeze the Bayer phase for FAST_MARSCHNER_R_STANDARDIZED_LUT (got %s)" % freeze_value)

	# 3) Log-decode toggle must change the rendered frame pixels: with the
	# Bayer phase frozen, the only change between captures is the decode
	# selector. The on/off magnitude diff is compared against a toggled-back
	# noise capture so frame noise (if any) cannot fake the assertion.
	shader_material.set(&"shader_parameter/r_standardized_lut_log_decode", true)
	for wait_frame in TOGGLE_WAIT_FRAMES:
		await RenderingServer.frame_post_draw
	var frame_b: Image = root.get_texture().get_image()
	shader_material.set(&"shader_parameter/r_standardized_lut_log_decode", false)
	for wait_frame in TOGGLE_WAIT_FRAMES:
		await RenderingServer.frame_post_draw
	var frame_c: Image = root.get_texture().get_image()
	var on_vs_off := _masked_magnitude_diff(frame_a, frame_b)
	var noise := _masked_magnitude_diff(frame_a, frame_c)
	print("EVIDENCE log_decode_toggle_masked_magnitude_on_vs_off=%.3f noise=%.3f" % [on_vs_off, noise])
	if on_vs_off <= 0.0:
		_fail("toggling r_standardized_lut_log_decode must change the frame pixels (on_vs_off=%.3f)" % on_vs_off)
	if on_vs_off <= noise:
		_fail("log-decode toggle must change masked hair magnitude more than frame noise (%.3f <= %.3f)" % [on_vs_off, noise])

	# 4) Observed wall-time metric over a multi-frame window (informational,
	# never gated: machine-specific FPS numbers are not part of the contract).
	var frame_start := Time.get_ticks_usec()
	var last_tick := frame_start
	var frame_deltas: Array[float] = []
	for frame_index in WALL_TIME_FRAMES:
		await RenderingServer.frame_post_draw
		var now_tick := Time.get_ticks_usec()
		frame_deltas.append(float(now_tick - last_tick) * 0.001)
		last_tick = now_tick
	var wall_total_ms := float(last_tick - frame_start) * 0.001
	var wall_mean_ms := wall_total_ms / float(WALL_TIME_FRAMES)
	var wall_min_ms := 1e30
	var wall_max_ms := 0.0
	for frame_delta in frame_deltas:
		wall_min_ms = minf(wall_min_ms, frame_delta)
		wall_max_ms = maxf(wall_max_ms, frame_delta)
	print("EVIDENCE standardized_r_lut_wall_time frames=%d total_ms=%.3f mean_ms=%.3f min_ms=%.3f max_ms=%.3f (observed, no FPS gate)" % [WALL_TIME_FRAMES, wall_total_ms, wall_mean_ms, wall_min_ms, wall_max_ms])

	# 5) Reset to the analytic variant: shipping shader, opt-in flags off.
	var analytic_applied: bool = bool(controller.call(&"apply_preview", INDIVIDUAL_GROOM, FAST_MARSCHNER_ANALYTIC, GROOM_ID))
	if not analytic_applied:
		_fail("apply_preview(FAST_MARSCHNER_ANALYTIC) returned false")
		_finish()
		return
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var analytic_material := groom.get_surface_override_material(0) as ShaderMaterial
	var analytic_shader_path := "none"
	if analytic_material and analytic_material.shader:
		analytic_shader_path = analytic_material.shader.resource_path
	print("EVIDENCE analytic_shader_path=%s" % analytic_shader_path)
	if analytic_shader_path != EXPECTED_SHIPPING_SHADER_PATH:
		_fail("analytic reset shader path is '%s', expected '%s'" % [analytic_shader_path, EXPECTED_SHIPPING_SHADER_PATH])
	if analytic_material:
		var analytic_lut: Variant = analytic_material.get(&"shader_parameter/use_azimuthal_lut")
		var analytic_dual: Variant = analytic_material.get(&"shader_parameter/use_dual_scatter")
		var analytic_env: Variant = analytic_material.get(&"shader_parameter/use_environment")
		print("EVIDENCE analytic_use_azimuthal_lut=%s analytic_use_dual_scatter=%s analytic_use_environment=%s (expected false/false/false)" % [analytic_lut, analytic_dual, analytic_env])
		if analytic_lut != false or analytic_dual != false or analytic_env != false:
			_fail("analytic reset must force lut/dual/environment false, got %s/%s/%s" % [analytic_lut, analytic_dual, analytic_env])

	_finish()


func _count_lit_pixels(image: Image) -> int:
	var count := 0
	for y in image.get_height():
		for x in image.get_width():
			var pixel: Color = image.get_pixel(x, y)
			if pixel.r + pixel.g + pixel.b > LIT_LUMINANCE_THRESHOLD:
				count += 1
	return count


func _masked_magnitude_diff(image_a: Image, image_b: Image) -> float:
	# Total absolute channel difference over the hair band: measures how much
	# the hair values changed, robust to which pixels the Bayer discard shifts.
	var width := image_a.get_width()
	var x0 := int(float(width) * 0.3)
	var x1 := int(float(width) * 0.7)
	var y0 := int(float(image_a.get_height()) * 0.25)
	var y1 := int(float(image_a.get_height()) * 0.75)
	var total := 0.0
	for y in range(y0, y1):
		for x in range(x0, x1):
			var pixel_a: Color = image_a.get_pixel(x, y)
			var pixel_b: Color = image_b.get_pixel(x, y)
			total += absf(pixel_a.r - pixel_b.r) + absf(pixel_a.g - pixel_b.g) + absf(pixel_a.b - pixel_b.b)
	return total


func _fail(message: String) -> void:
	_failures.append(message)
	push_error(message)


func _finish() -> void:
	if _failures.is_empty():
		print("FAST_MARSCHNER_R_STANDARDIZED_LUT_RUNTIME_TEST_OK")
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)
