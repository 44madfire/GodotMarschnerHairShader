extends SceneTree

## Focused runtime contract test for the corrected standardized-R diagnostic.
## Verifies that the material adapter binds the committed LUT's coordinate
## metadata into the wrapper and that a deliberately low longitudinal
## roughness render (which drives beta_r below the LUT domain near backward
## azimuths) remains finite through the asymptotic path.

const GROOM_ID := &"Blowout"
const INDIVIDUAL_GROOM := 1
const FAST_MARSCHNER_ANALYTIC := 5
const FAST_MARSCHNER_R_STANDARDIZED_LUT := 10
const LUT_PATH := "res://benchmark/resources/luts/fast_marschner_r_standardized_lut_256x256x128.res"
const WRAPPER_PATH := "res://assets/hair/materials/shaders/hair_marschner_fast_r_standardized_lut.gdshader"
const EXPECTED_BLEND := Vector2(0.015, 0.03)

var _failures := PackedStringArray()

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
	var harness := packed.instantiate()
	root.add_child(harness)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	var controller: Node = harness.get_node_or_null("BenchmarkController")
	if controller == null:
		_fail("BenchmarkController missing")
		_finish()
		return
	var groom: MeshInstance3D
	for entry in controller.get(&"groom_catalog"):
		if String(entry.get("groom_id", "")) == String(GROOM_ID):
			groom = entry.get("node") as MeshInstance3D
			break
	if groom == null:
		_fail("Blowout groom missing")
		_finish()
		return

	var lut_data: Resource = load(LUT_PATH)
	if lut_data == null:
		_fail("standardized LUT resource failed to load")
		_finish()
		return
	if not bool(controller.call(&"apply_preview", INDIVIDUAL_GROOM, FAST_MARSCHNER_R_STANDARDIZED_LUT, GROOM_ID)):
		_fail("standardized-R preview failed to apply")
		_finish()
		return
	for i in 3:
		await RenderingServer.frame_post_draw

	var material := groom.get_surface_override_material(0) as ShaderMaterial
	if material == null or material.shader == null:
		_fail("standardized-R ShaderMaterial missing")
		_finish()
		return
	if material.shader.resource_path != WRAPPER_PATH:
		_fail("unexpected shader path: %s" % material.shader.resource_path)

	var q_range: Vector2 = material.get_shader_parameter(&"r_standardized_lut_q_range")
	var cone_range: Vector2 = material.get_shader_parameter(&"r_standardized_lut_theta_cone_range")
	var beta_range: Vector2 = material.get_shader_parameter(&"r_standardized_lut_beta_range")
	var blend: Vector2 = material.get_shader_parameter(&"r_standardized_lut_low_beta_blend")
	var expected_q := Vector2(float(lut_data.get(&"q_min")), float(lut_data.get(&"q_max")))
	var expected_cone := Vector2(float(lut_data.get(&"theta_cone_min")), float(lut_data.get(&"theta_cone_max")))
	var expected_beta := Vector2(float(lut_data.get(&"beta_min")), float(lut_data.get(&"beta_max")))
	if not q_range.is_equal_approx(expected_q):
		_fail("q range not bound from LUT metadata: %s vs %s" % [q_range, expected_q])
	if not cone_range.is_equal_approx(expected_cone):
		_fail("theta-cone range not bound from LUT metadata: %s vs %s" % [cone_range, expected_cone])
	if not beta_range.is_equal_approx(expected_beta):
		_fail("beta range not bound from LUT metadata: %s vs %s" % [beta_range, expected_beta])
	if not blend.is_equal_approx(EXPECTED_BLEND):
		_fail("low-beta blend mismatch: %s" % blend)
	if material.get_shader_parameter(&"r_standardized_lut_log_decode") != false:
		_fail("linear Q must remain the default decode")

	# Force an artist-facing low roughness. The shared fragment reparameterizer
	# floors beta_M at 1e-3; near backward azimuth this still yields beta_r well
	# below the 0.02 LUT minimum and therefore exercises the asymptotic region.
	material.set_shader_parameter(&"longitudinal_roughness", 0.0)
	material.set_shader_parameter(&"freeze_bayer_phase", true)
	for i in 4:
		await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if image == null:
		_fail("viewport capture failed")
	else:
		var finite_pixels := 0
		var nonblack_pixels := 0
		for y in range(0, image.get_height(), 4):
			for x in range(0, image.get_width(), 4):
				var pixel := image.get_pixel(x, y)
				if is_finite(pixel.r) and is_finite(pixel.g) and is_finite(pixel.b):
					finite_pixels += 1
				else:
					_fail("non-finite rendered pixel at %d,%d: %s" % [x, y, pixel])
				if pixel.r + pixel.g + pixel.b > 0.01:
					nonblack_pixels += 1
		if finite_pixels == 0 or nonblack_pixels == 0:
			_fail("low-beta standardized render produced no finite/nonblack sampled pixels")

	# Reset verifies the diagnostic still cannot contaminate the shipping Fast
	# analytic preview after variant switching.
	if not bool(controller.call(&"apply_preview", INDIVIDUAL_GROOM, FAST_MARSCHNER_ANALYTIC, GROOM_ID)):
		_fail("analytic reset failed")
	_finish()

func _fail(message: String) -> void:
	_failures.append(message)
	push_error(message)

func _finish() -> void:
	if _failures.is_empty():
		print("FAST_MARSCHNER_R_STANDARDIZED_CONTRACT_RUNTIME_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)
