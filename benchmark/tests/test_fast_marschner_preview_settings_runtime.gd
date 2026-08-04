extends SceneTree

## Durable runtime test for the settings-driven FAST_MARSCHNER preview seam.
##
## The preview UI exposes one `FAST_MARSCHNER` entry (variant 5) and passes a
## settings dictionary to `BenchmarkController.apply_preview(mode, variant,
## groom, settings)`. This test exercises the controller seam directly for:
## analytic defaults, azimuthal LUT, analytic dual scattering, preintegrated
## dual scattering (implies dual), environment, a combined LUT+environment
## setting, and strength clamping. Each scenario asserts the live material
## flags/textures and a successful non-black preview.
##
## Runnable directly with the normal (windowed) Godot binary via --script:
##
##   godot.exe --path <project> --script res://benchmark/tests/test_fast_marschner_preview_settings_runtime.gd

const INDIVIDUAL_GROOM := 1
const FAST_MARSCHNER_ANALYTIC := 5
const MIN_NONBLACK_PIXELS := 20000
const LIT_LUMINANCE_THRESHOLD := 0.18

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

	# Exercise the actual UI seam once: the dropdown exposes one FAST_MARSCHNER
	# entry, and its settings controls forward a combined payload to the
	# controller rather than selecting a separate shader variant.
	if overlay == null:
		_fail("BenchmarkPreviewOverlay not found")
	else:
		var variant_select := overlay.get_node("PreviewPanel/ContentScroll/Margin/VBox/ControlsGrid/VariantSelect") as OptionButton
		var lut_toggle := overlay.get_node("PreviewPanel/ContentScroll/Margin/VBox/FastSettings/Margin/SettingsVBox/SettingsGrid/AzimuthalLUT") as CheckBox
		var environment_toggle := overlay.get_node("PreviewPanel/ContentScroll/Margin/VBox/FastSettings/Margin/SettingsVBox/SettingsGrid/Environment") as CheckBox
		if variant_select.item_count != 6 or variant_select.get_item_text(5) != "FAST_MARSCHNER":
			_fail("preview UI must expose exactly one FAST_MARSCHNER entry, got %d items" % variant_select.item_count)
		else:
			variant_select.select(5)
			lut_toggle.button_pressed = true
			environment_toggle.button_pressed = true
			overlay.call("_on_apply_pressed")
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			var ui_material := groom.get_surface_override_material(0) as ShaderMaterial
			if ui_material == null or ui_material.get(&"shader_parameter/use_azimuthal_lut") != true or ui_material.get(&"shader_parameter/use_environment") != true:
				_fail("FAST_MARSCHNER UI settings did not reach the canonical shader")
			else:
				print("EVIDENCE ui_fast_marschner_entry=single lut=true environment=true")

	# 1) Analytic defaults: no settings -> all modes off.
	await _scenario(controller, groom, {}, {
		"use_azimuthal_lut": false,
		"use_dual_scatter": false,
		"use_preintegrated_dual_scatter": false,
		"use_environment": false,
	}, "defaults")

	# 2) Azimuthal LUT.
	await _scenario(controller, groom, {"use_azimuthal_lut": true}, {
		"use_azimuthal_lut": true,
		"use_dual_scatter": false,
		"use_preintegrated_dual_scatter": false,
		"use_environment": false,
		"azimuthal_lut_is_texture3d": true,
	}, "azimuthal_lut")

	# 3) Analytic dual scattering.
	await _scenario(controller, groom, {"use_dual_scatter": true, "dual_scatter_strength": 0.75, "dual_scatter_density": 0.4}, {
		"use_dual_scatter": true,
		"use_preintegrated_dual_scatter": false,
		"use_azimuthal_lut": false,
		"use_environment": false,
		"dual_scatter_strength": 0.75,
		"dual_scatter_density": 0.4,
	}, "analytic_dual")

	# 4) Preintegrated dual scattering (implies dual=true).
	await _scenario(controller, groom, {"use_preintegrated_dual_scatter": true}, {
		"use_preintegrated_dual_scatter": true,
		"use_dual_scatter": true,
		"use_azimuthal_lut": false,
		"use_environment": false,
		"dual_scatter_lut_is_texture2d": true,
	}, "preintegrated_dual")

	# 5) Environment.
	await _scenario(controller, groom, {"use_environment": true, "environment_strength": 0.8}, {
		"use_environment": true,
		"use_azimuthal_lut": false,
		"use_dual_scatter": false,
		"use_preintegrated_dual_scatter": false,
		"environment_texture_is_texture2d": true,
		"environment_strength": 0.8,
	}, "environment")

	# 6) Combined LUT + environment.
	await _scenario(controller, groom, {"use_azimuthal_lut": true, "use_environment": true}, {
		"use_azimuthal_lut": true,
		"use_environment": true,
		"use_dual_scatter": false,
		"use_preintegrated_dual_scatter": false,
		"azimuthal_lut_is_texture3d": true,
		"environment_texture_is_texture2d": true,
	}, "lut_plus_environment")

	# 7) Strength clamping: out-of-range payload values are clamped.
	await _scenario(controller, groom, {"use_dual_scatter": true, "dual_scatter_strength": 99.0, "dual_scatter_density": -3.0, "use_environment": true, "environment_strength": 99.0}, {
		"use_dual_scatter": true,
		"use_environment": true,
		"dual_scatter_strength": 2.0,
		"dual_scatter_density": 0.0,
		"environment_strength": 2.0,
	}, "clamped_strengths")

	_finish()


func _scenario(controller: Node, groom: MeshInstance3D, settings: Dictionary, expected: Dictionary, label: String) -> void:
	var applied: bool = bool(controller.call(&"apply_preview", INDIVIDUAL_GROOM, FAST_MARSCHNER_ANALYTIC, &"Blowout", settings))
	if not applied:
		_fail("[%s] apply_preview returned false" % label)
		return
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var material := groom.get_surface_override_material(0) as ShaderMaterial
	if material == null:
		_fail("[%s] override is not a ShaderMaterial" % label)
		return
	var evidence := "[%s]" % label
	for key in expected:
		if key == "azimuthal_lut_is_texture3d":
			var texture := material.get(&"shader_parameter/azimuthal_lut") as Texture3D
			evidence += " azimuthal_lut=" + ("bound" if texture != null else "NULL")
			if texture == null or texture.get_width() <= 0:
				_fail("[%s] azimuthal_lut Texture3D not bound" % label)
		elif key == "dual_scatter_lut_is_texture2d":
			var texture := material.get(&"shader_parameter/dual_scatter_lut") as Texture2D
			evidence += " dual_scatter_lut=" + ("bound" if texture != null else "NULL")
			if texture == null or texture.get_width() <= 0:
				_fail("[%s] dual_scatter_lut Texture2D not bound" % label)
		elif key == "environment_texture_is_texture2d":
			var texture := material.get(&"shader_parameter/environment_texture") as Texture2D
			evidence += " environment_texture=" + ("bound" if texture != null else "NULL")
			if texture == null or texture.get_width() <= 0:
				_fail("[%s] environment_texture Texture2D not bound" % label)
		else:
			var value: Variant = material.get(&"shader_parameter/%s" % key)
			evidence += " %s=%s" % [key, value]
			if value != expected[key]:
				_fail("[%s] shader_parameter/%s = %s, expected %s" % [label, key, value, expected[key]])
	var lit_pixels := _count_lit_pixels(root.get_texture().get_image())
	evidence += " lit_pixels=%d" % lit_pixels
	print("EVIDENCE " + evidence)
	if lit_pixels < MIN_NONBLACK_PIXELS:
		_fail("[%s] preview has only %d lit pixels (threshold %d)" % [label, lit_pixels, MIN_NONBLACK_PIXELS])


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
		print("FAST_MARSCHNER_PREVIEW_SETTINGS_RUNTIME_TEST_OK")
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)
