extends SceneTree

## Focused runtime test for the FAST_MARSCHNER_ENVIRONMENT preview variant
## (enum 8).
##
## Runnable directly with the normal (windowed) Godot binary via --script:
##
##   godot.exe --path <project> --script res://benchmark/tests/test_fast_marschner_environment_runtime.gd
##
## Asserts: apply_preview accepts the environment variant; the selected surface
## override is the fast Marschner shader with use_environment=true, the LUT and
## dual flags forced false (identity authoritative), and the committed
## environment texture + profile-driven strength bound; the preview renders
## non-black output with live frame changes; the environment term is
## fragment-only (non-black under a zero-light environment_only rig, i.e.
## light-count invariant); and the analytic variant forces use_environment=false.

const INDIVIDUAL_GROOM := 1
const FAST_MARSCHNER_ANALYTIC := 5
const FAST_MARSCHNER_ENVIRONMENT := 8
const EXPECTED_SHADER_PATH := "res://assets/hair/materials/shaders/hair_marschner_fast.gdshader"
const PHASE_MOVE_FRAMES := 30
const MIN_NONBLACK_PIXELS := 20000
const MIN_IMAGE_DIMENSION := 256
const LIT_LUMINANCE_THRESHOLD := 0.18
# The zero-light frame is ambient + EMISSION only; post-tonemap it is dimmer
# than a key-lit frame, so the fragment-only check uses its own threshold.
const ZERO_LIGHT_LIT_THRESHOLD := 0.10

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

	# 1) Environment variant: accepted, identity flags, texture bound.
	var applied: bool = bool(controller.call(&"apply_preview", INDIVIDUAL_GROOM, FAST_MARSCHNER_ENVIRONMENT, &"Blowout"))
	if not applied:
		_fail("apply_preview(INDIVIDUAL_GROOM, FAST_MARSCHNER_ENVIRONMENT, Blowout) returned false")
		_finish()
		return
	print("EVIDENCE apply_preview=accepted variant=FAST_MARSCHNER_ENVIRONMENT time_scale=%s" % Engine.time_scale)

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

	var env_flag: Variant = shader_material.get(&"shader_parameter/use_environment")
	var lut_flag: Variant = shader_material.get(&"shader_parameter/use_azimuthal_lut")
	var dual_flag: Variant = shader_material.get(&"shader_parameter/use_dual_scatter")
	var env_texture_value: Variant = shader_material.get(&"shader_parameter/environment_texture")
	var env_texture := env_texture_value as Texture2D
	var strength: Variant = shader_material.get(&"shader_parameter/environment_strength")
	print("EVIDENCE use_environment=%s use_azimuthal_lut=%s use_dual_scatter=%s environment_strength=%s" % [env_flag, lut_flag, dual_flag, strength])
	if env_flag != true:
		_fail("use_environment must be true on the environment variant, got %s" % env_flag)
	if lut_flag != false or dual_flag != false:
		_fail("environment variant must force use_azimuthal_lut=false and use_dual_scatter=false, got %s/%s" % [lut_flag, dual_flag])
	if env_texture == null or env_texture.get_width() <= 0:
		_fail("environment_texture is not bound to a valid Texture2D")
	else:
		print("EVIDENCE environment_texture=%s %dx%d" % [env_texture.resource_path, env_texture.get_width(), env_texture.get_height()])
	if not (strength is float) or float(strength) <= 0.0:
		_fail("environment_strength must be bound to the profile value (> 0), got %s" % strength)

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
		_fail("environment preview has only %d lit pixels (threshold %d)" % [lit_pixels, MIN_NONBLACK_PIXELS])

	for wait_frame in PHASE_MOVE_FRAMES:
		await RenderingServer.frame_post_draw
	var frame_b: Image = root.get_texture().get_image()
	var differing_bytes := _byte_diff(frame_a, frame_b)
	print("EVIDENCE frame_diff_bytes_after_%d_frames=%d" % [PHASE_MOVE_FRAMES, differing_bytes])
	if differing_bytes <= 0:
		_fail("frame diff is zero after %d frames: the environment preview appears static" % PHASE_MOVE_FRAMES)

	# 3) Light-count invariance: with the legacy key light off and the
	# environment_only rig instantiated (zero light nodes), the fragment-stage
	# environment term must still render non-black. This proves the term is
	# fragment-only (EMISSION) and not light() work.
	var legacy_light: DirectionalLight3D = harness.get_node_or_null("LightingRigHost") as DirectionalLight3D
	if legacy_light:
		legacy_light.visible = false
	var host: Node = harness.get_node_or_null("CaseLightingRigHost")
	var env_rig: PackedScene = load("res://benchmark/lighting/environment_only.tscn")
	var rig_instance: Node = env_rig.instantiate()
	host.add_child(rig_instance)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var zero_light_frame: Image = root.get_texture().get_image()
	var zero_light_lit := _count_lit_pixels_threshold(zero_light_frame, ZERO_LIGHT_LIT_THRESHOLD)
	print("EVIDENCE zero_light_lit_pixels=%d (fragment-only environment term, threshold %s)" % [zero_light_lit, ZERO_LIGHT_LIT_THRESHOLD])
	if zero_light_lit < MIN_NONBLACK_PIXELS:
		_fail("environment term must render non-black with zero lights (fragment-only), got %d lit pixels" % zero_light_lit)

	# The environment term is strength-driven: under the zero-light rig the env
	# EMISSION dominates the hair pixels, so zeroing the live strength (clone
	# only, no source mutation) must change the masked hair-band magnitude far
	# more than frame-to-frame Bayer noise. Restore afterwards.
	var zl_strength_a: Image = root.get_texture().get_image()
	shader_material.set(&"shader_parameter/environment_strength", 0.0)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var zl_strength_b: Image = root.get_texture().get_image()
	shader_material.set(&"shader_parameter/environment_strength", strength)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var zl_strength_c: Image = root.get_texture().get_image()
	var zl_on_vs_zero := _masked_magnitude_diff(zl_strength_a, zl_strength_b)
	var zl_noise := _masked_magnitude_diff(zl_strength_a, zl_strength_c)
	print("EVIDENCE zero_light_masked_magnitude_on_vs_zero=%.3f noise=%.3f" % [zl_on_vs_zero, zl_noise])
	if zl_on_vs_zero <= zl_noise:
		_fail("zeroing environment_strength must change masked hair magnitude more than frame noise (%.3f <= %.3f)" % [zl_on_vs_zero, zl_noise])
	rig_instance.free()
	if legacy_light:
		legacy_light.visible = true
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var lit_again := _count_lit_pixels(root.get_texture().get_image())
	print("EVIDENCE relit_lit_pixels=%d" % lit_again)
	if lit_again < MIN_NONBLACK_PIXELS:
		_fail("environment preview must stay non-black when lights are restored")

	# 4) Analytic variant forces all three flags false (identity authoritative).
	var analytic_applied: bool = bool(controller.call(&"apply_preview", INDIVIDUAL_GROOM, FAST_MARSCHNER_ANALYTIC, &"Blowout"))
	if not analytic_applied:
		_fail("apply_preview(FAST_MARSCHNER_ANALYTIC) returned false")
		_finish()
		return
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var analytic_material := groom.get_surface_override_material(0) as ShaderMaterial
	var analytic_env: Variant = analytic_material.get(&"shader_parameter/use_environment")
	var analytic_lut: Variant = analytic_material.get(&"shader_parameter/use_azimuthal_lut")
	var analytic_dual: Variant = analytic_material.get(&"shader_parameter/use_dual_scatter")
	print("EVIDENCE analytic_use_environment=%s analytic_use_azimuthal_lut=%s analytic_use_dual_scatter=%s (expected false/false/false)" % [analytic_env, analytic_lut, analytic_dual])
	if analytic_env != false or analytic_lut != false or analytic_dual != false:
		_fail("analytic variant must force environment=false, lut=false, dual=false, got %s/%s/%s" % [analytic_env, analytic_lut, analytic_dual])

	_finish()


func _count_lit_pixels(image: Image) -> int:
	return _count_lit_pixels_threshold(image, LIT_LUMINANCE_THRESHOLD)


func _count_lit_pixels_threshold(image: Image, threshold: float) -> int:
	var count := 0
	for y in image.get_height():
		for x in image.get_width():
			var pixel: Color = image.get_pixel(x, y)
			if pixel.r + pixel.g + pixel.b > threshold:
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
		print("FAST_MARSCHNER_ENVIRONMENT_RUNTIME_TEST_OK")
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)
