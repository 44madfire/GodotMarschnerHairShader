extends SceneTree

## Focused differential runtime regression test for the fast Marschner tier:
## baseline (variant 2) vs FAST_MARSCHNER_ANALYTIC (variant 5) on Blowout.
##
## Runnable directly with the normal (windowed) Godot binary via --script:
##
##   godot --path <project> --script res://benchmark/tests/test_fast_marschner_differential_runtime.gd
##
## Regression contract under test:
##  1. Lighting-only comparison: show_hair_cards=true forces the identical
##     card coverage path in both shaders, so only the lighting model differs.
##  2. Fast frames are byte-stable at a frozen time scale (evidence from
##     _diagnose_fast_marschner.gd: zero byte diffs with cards=true).
##  3. The fast/baseline luminance ratio stays in a broad non-parity sanity band
##     (0.25..2.50): parity is NOT expected, and the accepted Fast approximation
##     has documented angle/material-dependent differences. The band catches
##     black/overflowing output without pretending image-space parity.
##  4. With normal hashed cards at real-time preview, the fast frame sequence
##     stays byte-stable because apply_preview() freezes the Bayer phase
##     (freeze_bayer_phase) for every FAST_MARSCHNER_* variant.
##
## No timed benchmark runs start and no benchmark artifacts are written. The
## known unrelated `util/light_controller.gd:36` Camera3D `_current_mode`
## script warning may appear in the harness; it is not a test failure.

const INDIVIDUAL_GROOM := 1
const BASELINE_VARIANT := 2
const FAST_ANALYTIC_VARIANT := 5
const GROOM_ID := &"Blowout"
const FROZEN_TIME_SCALE := 1e-9
const STABILITY_SAMPLES := 6
## Evidence from _diagnose_fast_marschner.gd: frozen-scale and (after the
## freeze_bayer_phase fix) real-time preview frames are byte-identical. The
## regression signature being guarded against was 317k-401k differing bytes.
const MAX_STABILITY_BYTE_DIFF := 0
## Central hair mask: only the middle 60% x 60% of the frame is sampled, and
## only pixels with a lit (non-background) sum are included.
const MASK_START_FRACTION := 0.2
const MASK_END_FRACTION := 0.8
const MIN_LIT_SUM := 0.12
## Broad non-parity sanity band for fast/baseline mean luminance: not exact
## parity. The limits cover the accepted approximation's current visual range;
## angular-integrated energy remains the authoritative numerical diagnostic.
const LUMINANCE_RATIO_MIN := 0.25
const LUMINANCE_RATIO_MAX := 2.50
const FREEZE_UNIFORM_NAME := &"freeze_bayer_phase"

var _failures: PackedStringArray = []


func _initialize() -> void:
	Engine.time_scale = FROZEN_TIME_SCALE
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
	var groom := _find_groom(controller)
	if groom == null:
		_fail("Blowout groom not found in groom_catalog")
		_finish()
		return

	# --- Baseline: cards=true, lighting-only comparison frame ---
	if not bool(controller.call("apply_preview", INDIVIDUAL_GROOM, BASELINE_VARIANT, GROOM_ID)):
		_fail("baseline apply_preview rejected")
		_finish()
		return
	await RenderingServer.frame_post_draw
	var baseline_material := groom.get_surface_override_material(0) as ShaderMaterial
	if baseline_material == null:
		_fail("baseline surface override is not a ShaderMaterial")
		_finish()
		return
	baseline_material.set(&"shader_parameter/show_hair_cards", true)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var baseline_frame: Image = root.get_texture().get_image()
	if baseline_frame == null:
		_fail("baseline viewport capture failed")
		_finish()
		return
	print("EVIDENCE baseline_cards=true freeze=%s" % baseline_material.get(&"shader_parameter/freeze_bayer_phase"))

	# --- Fast analytic: cards=true, lighting-only comparison frame ---
	if not bool(controller.call("apply_preview", INDIVIDUAL_GROOM, FAST_ANALYTIC_VARIANT, GROOM_ID)):
		_fail("fast apply_preview rejected")
		_finish()
		return
	await RenderingServer.frame_post_draw
	var fast_material := groom.get_surface_override_material(0) as ShaderMaterial
	if fast_material == null:
		_fail("fast surface override is not a ShaderMaterial")
		_finish()
		return
	print("EVIDENCE fast_shader_path=%s" % (fast_material.shader.resource_path if fast_material.shader else "none"))
	if not _shader_declares_parameter(fast_material, FREEZE_UNIFORM_NAME):
		_fail("fast shader does not declare the %s preview uniform" % FREEZE_UNIFORM_NAME)
	# The controller must have frozen the Bayer phase for the fast preview;
	# this is the preview-only regression fix under test.
	var fast_freeze: Variant = fast_material.get(&"shader_parameter/freeze_bayer_phase")
	print("EVIDENCE fast_cards=true freeze=%s" % fast_freeze)
	if fast_freeze != true:
		_fail("apply_preview did not freeze %s for FAST_MARSCHNER_ANALYTIC (got %s)" % [FREEZE_UNIFORM_NAME, fast_freeze])
	fast_material.set(&"shader_parameter/show_hair_cards", true)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var fast_frame: Image = root.get_texture().get_image()
	if fast_frame == null:
		_fail("fast viewport capture failed")
		_finish()
		return

	# --- Fast frame stability at the frozen time scale (cards=true) ---
	var frozen_diffs: Array[int] = await _sample_stability(fast_frame)
	print("EVIDENCE fast_cards_true_frozen stability byte_diffs=%s max=%d" % [frozen_diffs, _max_int(frozen_diffs)])
	_assert_stability(frozen_diffs, "fast cards=true at frozen time scale")

	# --- Differential luminance over the central hair mask (not exact parity) ---
	var comparison := _compare_luminance(baseline_frame, fast_frame)
	var ratio: float = comparison[2]
	print("EVIDENCE baseline_vs_fast cards=true baseline_mean=%.6f fast_mean=%.6f ratio=%.6f abs_diff=%.6f samples=%d" % [comparison[0], comparison[1], ratio, comparison[3], comparison[4]])
	if ratio < LUMINANCE_RATIO_MIN or ratio > LUMINANCE_RATIO_MAX:
		_fail("fast/baseline luminance ratio %.4f is outside the sanity band [%.2f..%.2f]" % [ratio, LUMINANCE_RATIO_MIN, LUMINANCE_RATIO_MAX])
	if comparison[4] <= 0:
		_fail("central hair mask found no lit samples; differential comparison is vacuous")

	# --- Real-time preview with normal hashed cards ---
	# The preview Bayer phase must stay frozen (apply_preview freeze), so the
	# hashed strand pattern must NOT swim at Engine.time_scale=1.0.
	Engine.time_scale = 1.0
	fast_material.set(&"shader_parameter/show_hair_cards", false)
	await RenderingServer.frame_post_draw
	var previous_hashed: Image = root.get_texture().get_image()
	var hashed_diffs: Array[int] = []
	for sample_index in STABILITY_SAMPLES:
		await RenderingServer.frame_post_draw
		var current_hashed: Image = root.get_texture().get_image()
		hashed_diffs.append(_byte_diff(previous_hashed, current_hashed))
		previous_hashed = current_hashed
	print("EVIDENCE fast_cards_false_realtime_preview stability byte_diffs=%s max=%d" % [hashed_diffs, _max_int(hashed_diffs)])
	_assert_stability(hashed_diffs, "fast cards=false at real-time preview (frozen Bayer phase)")

	_finish()


func _find_groom(controller: Node) -> MeshInstance3D:
	for entry in controller.get(&"groom_catalog"):
		if String(entry.get("groom_id", "")) == String(GROOM_ID):
			return entry.get("node") as MeshInstance3D
	return null


func _sample_stability(first_frame: Image) -> Array[int]:
	var diffs: Array[int] = []
	var previous := first_frame
	for sample_index in STABILITY_SAMPLES:
		await RenderingServer.frame_post_draw
		var current: Image = root.get_texture().get_image()
		diffs.append(_byte_diff(previous, current))
		previous = current
	return diffs


func _assert_stability(diffs: Array[int], label: String) -> void:
	for sample_index in diffs.size():
		if diffs[sample_index] < 0:
			_fail("%s: frame size changed between samples (byte diff %d)" % [label, diffs[sample_index]])
		elif diffs[sample_index] > MAX_STABILITY_BYTE_DIFF:
			_fail("%s: unstable frame sequence, byte diff %d exceeds the %d-byte budget (regression signature was ~300k)" % [label, diffs[sample_index], MAX_STABILITY_BYTE_DIFF])


func _shader_declares_parameter(shader_material: ShaderMaterial, parameter_name: StringName) -> bool:
	if shader_material == null or shader_material.shader == null:
		return false
	# Godot 4.7 exposes no shader parameter introspection RID API, so the
	# compiled source is checked for a full `uniform` declaration line (a bare
	# comment mention must never satisfy the check).
	var source: String = RenderingServer.shader_get_code(shader_material.shader.get_rid())
	if source.is_empty():
		return false
	for line in source.split("\n"):
		if line.strip_edges().begins_with("uniform ") and String(parameter_name) in line:
			return true
	return false


func _compare_luminance(baseline: Image, fast: Image) -> Array:
	var total_baseline := 0.0
	var total_fast := 0.0
	var total_diff := 0.0
	var samples := 0
	var width := mini(baseline.get_width(), fast.get_width())
	var height := mini(baseline.get_height(), fast.get_height())
	var mask_start_x := int(width * MASK_START_FRACTION)
	var mask_end_x := int(width * MASK_END_FRACTION)
	var mask_start_y := int(height * MASK_START_FRACTION)
	var mask_end_y := int(height * MASK_END_FRACTION)
	for y in range(mask_start_y, mask_end_y):
		for x in range(mask_start_x, mask_end_x):
			var baseline_pixel := baseline.get_pixel(x, y)
			if baseline_pixel.r + baseline_pixel.g + baseline_pixel.b < MIN_LIT_SUM:
				continue
			var fast_pixel := fast.get_pixel(x, y)
			var baseline_luma := baseline_pixel.r + baseline_pixel.g + baseline_pixel.b
			var fast_luma := fast_pixel.r + fast_pixel.g + fast_pixel.b
			total_baseline += baseline_luma
			total_fast += fast_luma
			total_diff += absf(baseline_luma - fast_luma)
			samples += 1
	var baseline_mean := total_baseline / maxf(float(samples), 1.0)
	var fast_mean := total_fast / maxf(float(samples), 1.0)
	return [baseline_mean, fast_mean, fast_mean / maxf(baseline_mean, 1e-6), total_diff / maxf(float(samples), 1.0), samples]


func _byte_diff(image_a: Image, image_b: Image) -> int:
	if image_a == null or image_b == null or image_a.get_size() != image_b.get_size():
		return -1
	var bytes_a := image_a.get_data()
	var bytes_b := image_b.get_data()
	var differing := 0
	for byte_index in bytes_a.size():
		if bytes_a[byte_index] != bytes_b[byte_index]:
			differing += 1
	return differing


func _max_int(values: Array[int]) -> int:
	var result := 0
	for value in values:
		result = maxi(result, value)
	return result


func _fail(message: String) -> void:
	_failures.append(message)
	push_error(message)


func _finish() -> void:
	if _failures.is_empty():
		print("FAST_MARSCHNER_DIFFERENTIAL_RUNTIME_TEST_OK")
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)
