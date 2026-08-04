extends Node3D

## Standalone visual-only comparison of the three hair shading tiers.
##
## This scene deliberately does not use the timing harness, run state machine,
## or output capture. It clones the baked Blowout source
## material from main.tscn once per column and only changes the shader binding.
##
## Exposure calibration in this scene is a deterministic, frame-settled state
## machine: gains are applied, at least one rendered frame passes before any
## capture (a ShaderMaterial uniform change lands one rendered frame after it
## is set), and each tier's gain is corrected iteratively. All ratios reported
## here are screenshot-space luminance ratios used to equalize the presentation
## for viewing — they are NOT benchmark metrics. Benchmark timing is the only
## source of truth for CPU/GPU measurements.

const HairMaterialAdapter := preload("res://benchmark/scripts/hair_material_adapter.gd")
const SOURCE_PROFILE: Resource = preload("res://benchmark/resources/profiles/source_current.tres")

const TIER_1_SHADER: Shader = preload("res://assets/hair/materials/shaders/hair_approx.gdshader")
const TIER_2_SHADER: Shader = preload("res://assets/hair/materials/shaders/hair_marschner_fast.gdshader")
const BASELINE_SHADER: Shader = preload("res://benchmark/reference/baseline_hair_preview.gdshader")

const BACKGROUND_COLOR := Color(0.012, 0.019, 0.029, 0.42)
const TEXT_PRIMARY := Color(0.91, 0.95, 0.98, 1.0)
const TEXT_SECONDARY := Color(0.57, 0.67, 0.75, 1.0)
const TEXT_MUTED := Color(0.38, 0.48, 0.56, 1.0)
const COLUMN_GAP_RATIO := 0.24

# These bounds keep a very dark or very bright native tier from producing an
# unusable presentation gain. They are calibration limits only; benchmark
# shaders and benchmark timing never use this control.
const EXPOSURE_GAIN_MIN := 0.25
const EXPOSURE_GAIN_MAX := 8.0
# A ShaderMaterial uniform change reaches a rendered frame one frame after it
# is set (the RenderingServer applies material params on the next frame pass).
# Every calibration measurement therefore waits this many rendered frames
# after applying gains before capturing, so matched ratios can never come from
# a pre-update frame. Three gives one margin frame beyond the proven need.
const CALIBRATION_SETTLE_FRAMES := 3
# Corrective iterations after the initial gain application: each round applies
# gain * baseline_mean / tier_mean (clamped to the safe range) until the
# measured ratios are within tolerance or this cap is reached.
const CALIBRATION_MAX_ITERATIONS := 5
# A tier ratio within ±2% of BASELINE is considered converged.
const CALIBRATION_RATIO_TOLERANCE := 0.02
const LUMINANCE_EPSILON := 0.000001
const LUMINANCE_WEIGHTS := Vector3(0.2126, 0.7152, 0.0722)
const TIER_LABELS := ["TIER 1", "TIER 2", "BASELINE"]

enum CalibrationPhase {
	PHASE_IDLE,
	PHASE_SETTLING_NATIVE,
	PHASE_MEASURING_NATIVE,
	PHASE_SETTLING_APPLIED,
	PHASE_MEASURING_MATCHED,
	PHASE_COMPLETE,
	PHASE_FAILED,
}

enum CalibrationMode {
	MODE_NONE,
	MODE_CALIBRATE,
	MODE_RESET,
}

var _material_adapter = HairMaterialAdapter.new()
var _source_groom: MeshInstance3D
var _source_aabb := AABB()
var _comparison_grooms: Array[MeshInstance3D] = []
var _comparison_materials_by_tier: Dictionary = {}
var _layout_pending := false
var _interface_root: Control
var _mode_label: Label
var _readout_labels: Dictionary = {}
var _matched_to_baseline := false
var _last_measurement: Dictionary = {}
var _last_background_luminance: Dictionary = {}
var _active_exposure_gains_state: Dictionary = {}

# Exposure-calibration state machine. Only _process advances it, so each step
# is bound to one rendered frame; while the scene tree is paused (frozen game
# time) it stays PENDING until frames are stepped — the deterministic contract
# the public API promises.
var _calibration_phase: int = CalibrationPhase.PHASE_IDLE
var _calibration_mode: int = CalibrationMode.MODE_NONE
var _calibration_settle_frames := 0
var _calibration_iteration := 0
var _calibration_converged := false
var _calibration_error := ""
var _calibration_native_means: Dictionary = {}
var _calibration_baseline_mean := 0.0
var _calibration_latest_matched_means: Dictionary = {}
var _calibration_latest_ratios: Dictionary = {}
var _calibration_result: Dictionary = {}
var _status_label: Label


func _ready() -> void:
	get_viewport().size_changed.connect(_queue_layout)
	_build_comparison_grooms()
	_build_interface()
	call_deferred("_layout_stage")
	call_deferred("_initialise_native_readout")


## Advances the exposure-calibration state machine. One _process call belongs
## to one rendered frame, so frame counting here is render-bound; the machine
## never measures in the same frame it applied gains.
func _process(_delta: float) -> void:
	_advance_calibration()


func _build_comparison_grooms() -> void:
	var fixture := get_node_or_null(^"MainFixture")
	var head := get_node_or_null(^"MainFixture/Head") as MeshInstance3D
	_source_groom = get_node_or_null(^"MainFixture/Head/Blowout") as MeshInstance3D
	if not fixture or not head or not _source_groom or not _source_groom.mesh:
		push_error("VisualShaderComparison: MainFixture/Head/Blowout could not be resolved.")
		return

	# Keep main.tscn as the source of truth for the baked groom, environment,
	# and production material values, but never render its original fixture.
	fixture.process_mode = Node.PROCESS_MODE_DISABLED
	var fixture_camera := get_node_or_null(^"MainFixture/Camera3D") as Camera3D
	if fixture_camera:
		fixture_camera.current = false
		fixture_camera.process_mode = Node.PROCESS_MODE_DISABLED
	var fixture_light := get_node_or_null(^"MainFixture/DirectionalLight3D") as DirectionalLight3D
	if fixture_light:
		fixture_light.visible = true
		fixture_light.directional_shadow_max_distance = 10.0

	_source_aabb = _source_groom.get_aabb()
	var source_transform := _source_groom.global_transform
	var source_surface_count := _source_groom.mesh.get_surface_count()
	_source_groom.visible = false
	head.visible = false

	var column_specs := _column_specs()
	for spec in column_specs:
		_comparison_materials_by_tier[spec["label"]] = []
		var groom := _source_groom.duplicate() as MeshInstance3D
		if not groom:
			push_error("VisualShaderComparison: failed to duplicate the Blowout groom for %s." % spec["label"])
			continue

		groom.name = "%sBlowout" % spec["id"]
		groom.visible = true
		groom.process_mode = Node.PROCESS_MODE_DISABLED
		groom.transform = _source_groom.transform
		groom.material_override = null

		var bound_surface_count := 0
		for surface_index in source_surface_count:
			var source_material := _source_groom.get_active_material(surface_index) as ShaderMaterial
			if not source_material:
				push_error(
					"VisualShaderComparison: Blowout surface %d has no ShaderMaterial for %s."
					% [surface_index, spec["label"]]
				)
				continue

			var variant_material: ShaderMaterial = _material_adapter.make_shader_variant_material(
				source_material,
				spec["shader"],
				SOURCE_PROFILE
			)
			if not variant_material:
				push_error(
					"VisualShaderComparison: could not clone the Blowout material for %s surface %d."
					% [spec["label"], surface_index]
				)
				continue

			# This uniform exists only on the three preview shaders used here. Its
			# default is one, so native mode is unchanged.
			_set_uniform_if_declared(variant_material, spec["shader"], &"freeze_bayer_phase", true)
			_set_uniform_if_declared(variant_material, spec["shader"], &"comparison_exposure_gain", 1.0)
			if spec["id"] == &"Tier2":
				# Make the canonical analytic Tier-2 path explicit even if the
				# profile defaults change later: no LUT, dual scatter, or environment.
				_set_uniform_if_declared(variant_material, spec["shader"], &"use_azimuthal_lut", false)
				_set_uniform_if_declared(variant_material, spec["shader"], &"use_dual_scatter", false)
				_set_uniform_if_declared(variant_material, spec["shader"], &"use_preintegrated_dual_scatter", false)
				_set_uniform_if_declared(variant_material, spec["shader"], &"use_environment", false)

			groom.set_surface_override_material(surface_index, variant_material)
			# The adapter returns a new ShaderMaterial for every source surface and
			# every column. Keep those references so calibration changes only this
			# standalone scene's independent clones.
			_comparison_materials_by_tier[spec["label"]].append(variant_material)
			bound_surface_count += 1

		if bound_surface_count > 0:
			$ComparisonGrooms.add_child(groom)
			groom.global_transform = source_transform
			groom.set_meta("comparison_tier", spec["label"])
			groom.set_meta("comparison_shader", spec["shader_path"])
			_comparison_grooms.append(groom)
		else:
			groom.free()


func _column_specs() -> Array[Dictionary]:
	return [
		{
			"id": &"Tier1",
			"label": "TIER 1",
			"name": "Approximate Kajiya–Kay",
			"shader": TIER_1_SHADER,
			"shader_path": "hair_approx.gdshader",
			"accent": Color(0.96, 0.54, 0.31, 1.0),
			"phase": "Frozen Bayer phase",
			"detail": "Wrapped diffuse + two Kajiya–Kay lobes",
		},
		{
			"id": &"Tier2",
			"label": "TIER 2",
			"name": "Fast Marschner · analytic",
			"shader": TIER_2_SHADER,
			"shader_path": "hair_marschner_fast.gdshader",
			"accent": Color(0.30, 0.88, 0.76, 1.0),
			"phase": "Frozen Bayer phase",
			"detail": "Analytic d’Eon path · dual / LUT / env OFF",
		},
		{
			"id": &"Baseline",
			"label": "BASELINE",
			"name": "Current Marschner baseline",
			"shader": BASELINE_SHADER,
			"shader_path": "baseline_hair_preview.gdshader",
			"accent": Color(0.55, 0.60, 0.98, 1.0),
			"phase": "Frozen Bayer phase",
			"detail": "Preview copy of the current production path",
		},
	]


func _set_uniform_if_declared(material: ShaderMaterial, shader: Shader, uniform_name: StringName, value: Variant) -> void:
	for uniform_info in shader.get_shader_uniform_list():
		if StringName(uniform_info.get(&"name", "")) != uniform_name:
			continue
		material.set("shader_parameter/%s" % String(uniform_name), value)
		return


func _build_interface() -> void:
	_interface_root = Control.new()
	_interface_root.name = "ComparisonOverlay"
	_interface_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_interface_root.mouse_filter = Control.MOUSE_FILTER_PASS
	$Interface.add_child(_interface_root)

	var wash := ColorRect.new()
	wash.name = "AtmosphereWash"
	wash.color = BACKGROUND_COLOR
	wash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_interface_root.add_child(wash)

	var page := VBoxContainer.new()
	page.name = "Page"
	page.anchor_right = 1.0
	page.anchor_bottom = 1.0
	page.offset_left = 22.0
	page.offset_top = 16.0
	page.offset_right = -22.0
	page.offset_bottom = -14.0
	page.add_theme_constant_override("separation", 10)
	page.mouse_filter = Control.MOUSE_FILTER_PASS
	_interface_root.add_child(page)

	page.add_child(_make_header())
	page.add_child(_make_calibration_bar())
	page.add_child(_make_cards())
	page.add_child(_make_footer())
	_refresh_status_ui()


func _make_header() -> Control:
	var panel := PanelContainer.new()
	panel.name = "TitlePanel"
	panel.custom_minimum_size = Vector2(0, 64)
	panel.add_theme_stylebox_override("panel", _make_stylebox(Color(0.035, 0.055, 0.08, 0.72), Color(0.18, 0.30, 0.38, 0.8), 12, 14))

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_bottom", 10)
	panel.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	margin.add_child(row)

	var title_stack := VBoxContainer.new()
	title_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_stack.add_theme_constant_override("separation", 1)
	row.add_child(title_stack)
	title_stack.add_child(_make_label("HAIR SHADER / VISUAL COMPARISON", 20, TEXT_PRIMARY))
	title_stack.add_child(_make_label("Same Blowout groom · same camera, lighting, scale, and environment", 11, TEXT_SECONDARY))

	var note := _make_label("VISUAL-ONLY\nBenchmark timing remains the source of truth\nfor CPU / GPU measurements", 10, Color(0.56, 0.84, 0.78, 1.0))
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(note)
	return panel


func _make_calibration_bar() -> Control:
	var panel := PanelContainer.new()
	panel.name = "ExposureCalibrationPanel"
	panel.custom_minimum_size = Vector2(0, 92)
	panel.add_theme_stylebox_override(
		"panel",
		_make_stylebox(Color(0.035, 0.055, 0.08, 0.88), Color(0.25, 0.48, 0.52, 0.78), 10, 8)
	)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_bottom", 8)
	panel.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	margin.add_child(row)

	var copy := VBoxContainer.new()
	copy.custom_minimum_size = Vector2(265, 0)
	copy.add_theme_constant_override("separation", 1)
	row.add_child(copy)
	_mode_label = _make_label("NATIVE", 11, Color(0.62, 0.93, 0.84, 1.0))
	copy.add_child(_mode_label)
	copy.add_child(_make_label("PRESENTATION CALIBRATION · NOT A BENCHMARK RESULT", 9, TEXT_SECONDARY))
	copy.add_child(_make_label("Screen luminance is matched to BASELINE for viewing only.", 9, TEXT_MUTED))
	_status_label = _make_label("", 9, TEXT_MUTED)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	copy.add_child(_status_label)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 6)
	row.add_child(actions)

	var match_button := Button.new()
	match_button.name = "MatchExposureToBaseline"
	match_button.text = "MATCH EXPOSURE TO BASELINE"
	match_button.custom_minimum_size = Vector2(222, 34)
	match_button.tooltip_text = "Calibrate Tier 1 and Tier 2 presentation gains against the current BASELINE screenshot."
	match_button.pressed.connect(_on_match_exposure_pressed)
	actions.add_child(match_button)

	var reset_button := Button.new()
	reset_button.name = "ResetNativeExposure"
	reset_button.text = "RESET NATIVE EXPOSURE"
	reset_button.custom_minimum_size = Vector2(170, 34)
	reset_button.tooltip_text = "Set all comparison exposure gains back to 1.0 and remeasure."
	reset_button.pressed.connect(_on_reset_native_exposure_pressed)
	actions.add_child(reset_button)

	var readouts := HBoxContainer.new()
	readouts.name = "LuminanceReadouts"
	readouts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	readouts.add_theme_constant_override("separation", 8)
	row.add_child(readouts)
	for label_text in TIER_LABELS:
		var readout := _make_label("%s\nMEAN  —   GAIN 1.000×   RATIO —" % label_text, 9, TEXT_PRIMARY)
		readout.name = "%sReadout" % label_text.replace(" ", "")
		readout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		readout.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		readout.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		readouts.add_child(readout)
		_readout_labels[label_text] = readout

	return panel


func _make_cards() -> Control:
	var cards := HBoxContainer.new()
	cards.name = "ComparisonCards"
	cards.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cards.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cards.add_theme_constant_override("separation", 10)
	cards.mouse_filter = Control.MOUSE_FILTER_IGNORE

	for spec in _column_specs():
		cards.add_child(_make_card(spec))
	return cards


func _make_card(spec: Dictionary) -> Control:
	var accent: Color = spec["accent"]
	var panel := PanelContainer.new()
	panel.name = "%sCard" % spec["id"]
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.size_flags_stretch_ratio = 1.0
	panel.add_theme_stylebox_override(
		"panel",
		_make_stylebox(Color(0.025, 0.040, 0.060, 0.18), accent.lerp(Color.WHITE, 0.15), 12, 12)
	)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_top", 13)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_bottom", 12)
	panel.add_child(margin)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 5)
	margin.add_child(stack)

	var badge := PanelContainer.new()
	badge.custom_minimum_size = Vector2(0, 25)
	badge.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	badge.add_theme_stylebox_override(
		"panel",
		_make_stylebox(accent.lerp(Color(0.01, 0.02, 0.03, 1.0), 0.72), accent.lerp(Color.WHITE, 0.1), 6, 0)
	)
	var badge_label := _make_label(spec["label"], 10, accent.lightened(0.12))
	badge_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.add_child(badge_label)
	stack.add_child(badge)

	stack.add_child(_make_label(spec["name"], 17, TEXT_PRIMARY))
	var shader_file := _make_label(spec["shader_path"], 10, accent.lightened(0.08))
	shader_file.clip_text = true
	stack.add_child(shader_file)

	var rule := HSeparator.new()
	var rule_color := accent
	rule_color.a = 0.45
	rule.modulate = rule_color
	stack.add_child(rule)

	var visual_space := Control.new()
	visual_space.size_flags_vertical = Control.SIZE_EXPAND_FILL
	visual_space.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(visual_space)

	var details := _make_label(spec["detail"], 10, TEXT_SECONDARY)
	details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(details)
	var phase := _make_label("BLOWOUT  /  %s" % spec["phase"].to_upper(), 9, TEXT_MUTED)
	phase.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(phase)
	return panel


func _make_footer() -> Control:
	var footer := HBoxContainer.new()
	footer.name = "Footer"
	footer.custom_minimum_size = Vector2(0, 22)
	footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var left := _make_label("THREE INDEPENDENT MATERIAL CLONES", 9, TEXT_MUTED)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(left)
	var right := _make_label("BAYER PHASE FROZEN WHERE SUPPORTED  ·  NO TIMING OR OUTPUT WRITES", 9, TEXT_MUTED)
	right.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	footer.add_child(right)
	return footer


func _make_label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _make_stylebox(background: Color, border: Color, radius: int, shadow_size: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = border
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_right = radius
	style.corner_radius_bottom_left = radius
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.34)
	style.shadow_size = shadow_size
	style.shadow_offset = Vector2(0, 4)
	return style


## Captures and measures the currently displayed comparison in memory. This is
## also the explicit measurement entry point for GDScript/MCP callers. The
## overlay is hidden for the forced draw so UI pixels cannot enter the three
## equal column regions, then restored before this method returns.
##
## A measurement is only valid once the displayed frame reflects the current
## gains (a ShaderMaterial uniform change lands one rendered frame after it is
## set). While a calibration or native reset is mid-flight a live capture would
## be taken from a pre-update frame, so this method refuses and returns the
## calibration status plus the latest valid measurement instead.
func measure_current_comparison() -> Dictionary:
	if _calibration_phase != CalibrationPhase.PHASE_IDLE and _calibration_phase != CalibrationPhase.PHASE_COMPLETE:
		return {
			"ok": false,
			"error": "calibration_in_progress" if _calibration_is_running() else "calibration_failed",
			"mode": "CALIBRATING" if _calibration_is_running() else "CALIBRATION FAILED",
			"status": get_exposure_calibration_status(),
			"latest_valid": _last_measurement.duplicate() if not _last_measurement.is_empty() else {},
		}

	var capture := _capture_and_measure()
	var result := {
		"ok": bool(capture["ok"]),
		"mode": "MATCHED TO BASELINE" if _matched_to_baseline else "NATIVE",
		"means": capture["means"],
		"gains": _active_exposure_gains(),
		"ratios": capture["ratios"],
		"background_luminance": _last_background_luminance.duplicate(),
		"safe_gain_range": [EXPOSURE_GAIN_MIN, EXPOSURE_GAIN_MAX],
	}
	_last_measurement = result
	_update_readout(capture["means"], _active_exposure_gains())
	_refresh_status_ui()
	return result


## Returns the exact mode-selection inputs used by the Fast shader's LUT guards.
## This is a deterministic shader-state probe, not a replacement for the Phase 4
## linear/HDR energy harness: it makes the selected analytic/LUT branch explicit
## when a screenshot-space comparison would otherwise conflate tone mapping and
## coverage with branch selection.
func get_fast_shader_mode_state() -> Dictionary:
	var material_clones: Array = _comparison_materials_by_tier.get("TIER 2", [])
	if material_clones.is_empty():
		return {"ok": false, "error": "Tier 2 material is not ready."}
	var material := material_clones[0] as ShaderMaterial
	if material == null:
		return {"ok": false, "error": "Tier 2 material clone is invalid."}
	var ior := float(material.get("shader_parameter/ior"))
	var azimuthal_eta_value: Variant = material.get("shader_parameter/azimuthal_lut_eta")
	var dual_eta_value: Variant = material.get("shader_parameter/dual_scatter_lut_eta")
	var azimuthal_eta := float(azimuthal_eta_value) if azimuthal_eta_value != null else 1.55
	var dual_eta := float(dual_eta_value) if dual_eta_value != null else 1.55
	var azimuthal_requested := bool(material.get("shader_parameter/use_azimuthal_lut"))
	var dual_scatter_requested := bool(material.get("shader_parameter/use_dual_scatter"))
	var dual_lut_requested := bool(material.get("shader_parameter/use_preintegrated_dual_scatter"))
	var azimuthal_compatible := absf(ior - azimuthal_eta) <= 0.0005
	var dual_compatible := absf(ior - dual_eta) <= 0.0005
	return {
		"ok": true,
		"ior": ior,
		"azimuthal_lut_eta": azimuthal_eta,
		"dual_scatter_lut_eta": dual_eta,
		"azimuthal_lut_requested": azimuthal_requested,
		"azimuthal_lut_branch": "lut" if azimuthal_requested and azimuthal_compatible else "analytic",
		"dual_scatter_requested": dual_scatter_requested,
		"dual_lut_requested": dual_lut_requested,
		"dual_lut_branch": "lut" if dual_scatter_requested and dual_lut_requested and dual_compatible else "analytic_contract_b",
	}


## Evaluates the Contract B dual-scatter fallback inputs at the live Tier 2
## material. This is a deterministic runtime probe for the zero-density edge:
## it verifies the shader is requesting the analytic Contract B branch at an
## incompatible IOR and that P1/P3 produce no secondary energy when density is
## zero, including with distinct RGB absorption values.
func probe_dual_contract_b_fallback() -> Dictionary:
	var material_clones: Array = _comparison_materials_by_tier.get("TIER 2", [])
	if material_clones.is_empty():
		return {"ok": false, "error": "Tier 2 material is not ready."}
	var material := material_clones[0] as ShaderMaterial
	if material == null:
		return {"ok": false, "error": "Tier 2 material clone is invalid."}
	var state := get_fast_shader_mode_state()
	var density := clampf(float(material.get("shader_parameter/dual_scatter_density")), 0.0, 1.0)
	var depth := 0.0
	var tau_d := (1.0 - depth) * density * 4.0
	var eta := float(material.get("shader_parameter/ior"))
	var f0 := (1.0 - eta) * (1.0 - eta) / ((1.0 + eta) * (1.0 + eta))
	var p1 := 1.0 - exp(-tau_d)
	var p3 := 1.0 - exp(-1.5 * tau_d)
	var base_color_value: Variant = material.get("shader_parameter/albedo")
	var base_color := Vector3(0.0, 0.0, 0.0)
	if base_color_value is Color:
		base_color = Vector3(base_color_value.r, base_color_value.g, base_color_value.b)
	var strength := maxf(float(material.get("shader_parameter/dual_scatter_strength")), 0.0)
	var expected_energy := base_color * strength * ((1.0 - f0) * (1.0 - f0) * p1 + (1.0 - f0) * (1.0 - f0) * f0 * p3)
	var passed := bool(state.get("dual_scatter_requested", false)) \
		and String(state.get("dual_lut_branch", "")) == "analytic_contract_b" \
		and is_zero_approx(tau_d) \
		and expected_energy.length() <= 0.000001
	return {
		"ok": passed,
		"branch": state.get("dual_lut_branch", ""),
		"dual_scatter_requested": state.get("dual_scatter_requested", false),
		"ior": eta,
		"dual_scatter_lut_eta": state.get("dual_scatter_lut_eta", 1.55),
		"density": density,
		"tau_d": tau_d,
		"absorption_mode": material.get("shader_parameter/absorption_mode"),
		"absorption": str(material.get("shader_parameter/absorption")),
		"expected_energy": str(expected_energy),
	}


## Starts the deterministic exposure calibration as a state machine. This call
## is synchronous-safe: it only records intent and returns the PENDING status
## immediately. Calibration advances in _process — at least one rendered frame
## passes after every gain change before a capture, so no matched ratio can
## come from a pre-update frame — and corrects each tier's gain with
## gain * baseline_mean / tier_mean for up to CALIBRATION_MAX_ITERATIONS
## corrective iterations (clamped to the documented safe range). Poll
## get_exposure_calibration_status() until "active" is false, then read the
## final "result".
func start_exposure_calibration() -> Dictionary:
	if _comparison_grooms.size() < 3 or _comparison_materials_by_tier.is_empty():
		return {"ok": false, "error": "Comparison grooms are not ready."}
	if _calibration_is_running():
		return get_exposure_calibration_status()
	_calibration_phase = CalibrationPhase.PHASE_SETTLING_NATIVE
	_calibration_mode = CalibrationMode.MODE_CALIBRATE
	_calibration_settle_frames = CALIBRATION_SETTLE_FRAMES
	_calibration_iteration = 0
	_calibration_converged = false
	_calibration_error = ""
	_calibration_result.clear()
	_calibration_native_means.clear()
	_calibration_baseline_mean = 0.0
	_calibration_latest_matched_means.clear()
	_calibration_latest_ratios.clear()
	_matched_to_baseline = false
	# Native gains are restored and settled before the first capture, so a
	# repeated call always derives gains from native mode rather than
	# compounding an earlier presentation calibration.
	_set_all_comparison_gains(_native_gain_dictionary())
	_refresh_status_ui()
	return get_exposure_calibration_status()


## Deprecated synchronous trigger. The old implementation captured immediately
## after applying gains, which in a frozen game returned matched ratios from a
## pre-update frame (the uniform change lands one rendered frame later). It now
## only starts the deterministic state machine and returns its PENDING status;
## it never reports matched ratios synchronously. Use start_exposure_calibration
## plus get_exposure_calibration_status instead.
func calibrate_exposure_to_baseline() -> Dictionary:
	return start_exposure_calibration()


## Resets the presentation calibration to native mode. Like calibration, the
## reset goes through the settle state machine so the readout and the returned
## measurement never come from a frame that still displayed the previous gains.
## Returns the pending status; poll get_exposure_calibration_status() until
## "active" is false.
func reset_native_exposure() -> Dictionary:
	if _comparison_grooms.size() < 3 or _comparison_materials_by_tier.is_empty():
		return {"ok": false, "error": "Comparison grooms are not ready."}
	if _calibration_is_running():
		return get_exposure_calibration_status()
	_calibration_phase = CalibrationPhase.PHASE_SETTLING_NATIVE
	_calibration_mode = CalibrationMode.MODE_RESET
	_calibration_settle_frames = CALIBRATION_SETTLE_FRAMES
	_calibration_iteration = 0
	_calibration_converged = false
	_calibration_error = ""
	_calibration_result.clear()
	_calibration_native_means.clear()
	_calibration_baseline_mean = 0.0
	_calibration_latest_matched_means.clear()
	_calibration_latest_ratios.clear()
	_matched_to_baseline = false
	_set_all_comparison_gains(_native_gain_dictionary())
	_refresh_status_ui()
	return get_exposure_calibration_status()


## Returns the current calibration state machine snapshot.
##   - "active" is true while a calibration/reset is pending;
##   - "phase" names the current step and "settle_frames_left" the frames
##     remaining before the next capture;
##   - "matched_means"/"ratios" hold the latest valid post-frame measurement
##     (empty until the first settled matched capture);
##   - "result" carries the full final data once the phase is COMPLETE.
func get_exposure_calibration_status() -> Dictionary:
	var status := {
		"ok": true,
		"active": _calibration_is_running(),
		"phase": _calibration_phase_name(),
		"phase_index": int(_calibration_phase),
		"iteration": _calibration_iteration,
		"max_iterations": CALIBRATION_MAX_ITERATIONS,
		"settle_frames_left": _calibration_settle_frames,
		"mode": "MATCHED TO BASELINE" if _matched_to_baseline else "NATIVE",
		"gains": _active_exposure_gains(),
		"native_means": _calibration_native_means.duplicate(),
		"baseline_mean": _calibration_baseline_mean,
		"matched_means": _calibration_latest_matched_means.duplicate(),
		"ratios": _calibration_latest_ratios.duplicate(),
		"converged": _calibration_converged,
		"error": _calibration_error,
		"message": _calibration_status_message(),
	}
	if _calibration_phase == CalibrationPhase.PHASE_COMPLETE and not _calibration_result.is_empty():
		status["result"] = _calibration_result.duplicate()
	return status


func _on_match_exposure_pressed() -> void:
	start_exposure_calibration()


func _on_reset_native_exposure_pressed() -> void:
	reset_native_exposure()


func _initialise_native_readout() -> void:
	if _comparison_grooms.size() < 3:
		return
	_matched_to_baseline = false
	_set_all_comparison_gains(_native_gain_dictionary())
	measure_current_comparison()


func _calibration_is_running() -> bool:
	return _calibration_phase == CalibrationPhase.PHASE_SETTLING_NATIVE \
		or _calibration_phase == CalibrationPhase.PHASE_MEASURING_NATIVE \
		or _calibration_phase == CalibrationPhase.PHASE_SETTLING_APPLIED \
		or _calibration_phase == CalibrationPhase.PHASE_MEASURING_MATCHED


func _calibration_phase_name() -> String:
	match _calibration_phase:
		CalibrationPhase.PHASE_IDLE:
			return "IDLE"
		CalibrationPhase.PHASE_SETTLING_NATIVE:
			return "SETTLING_NATIVE"
		CalibrationPhase.PHASE_MEASURING_NATIVE:
			return "MEASURING_NATIVE"
		CalibrationPhase.PHASE_SETTLING_APPLIED:
			return "SETTLING_APPLIED"
		CalibrationPhase.PHASE_MEASURING_MATCHED:
			return "MEASURING_MATCHED"
		CalibrationPhase.PHASE_COMPLETE:
			return "COMPLETE"
		CalibrationPhase.PHASE_FAILED:
			return "FAILED"
	return "UNKNOWN"


## Advances one calibration step per rendered frame. Settle phases decrement a
## frame counter; measuring phases capture only after a settle phase finished,
## so a capture always reflects gains that already reached at least one
## rendered frame.
func _advance_calibration() -> void:
	match _calibration_phase:
		CalibrationPhase.PHASE_SETTLING_NATIVE, CalibrationPhase.PHASE_SETTLING_APPLIED:
			_calibration_settle_frames -= 1
			if _calibration_settle_frames > 0:
				_refresh_status_ui()
				return
			if _calibration_phase == CalibrationPhase.PHASE_SETTLING_NATIVE:
				_calibration_phase = CalibrationPhase.PHASE_MEASURING_NATIVE
			else:
				_calibration_phase = CalibrationPhase.PHASE_MEASURING_MATCHED
			_refresh_status_ui()
		CalibrationPhase.PHASE_MEASURING_NATIVE:
			_run_native_measurement()
		CalibrationPhase.PHASE_MEASURING_MATCHED:
			_run_matched_measurement()


func _run_native_measurement() -> void:
	var capture := _capture_and_measure()
	_calibration_native_means = capture["means"].duplicate()
	_calibration_baseline_mean = float(capture["means"].get("BASELINE", 0.0))
	if _calibration_mode == CalibrationMode.MODE_RESET:
		_finish_native_reset(capture)
		return
	if not bool(capture["ok"]):
		_fail_calibration("Could not capture the comparison viewport.")
		return

	var gains := _native_gain_dictionary()
	for tier_label in ["TIER 1", "TIER 2"]:
		var native_mean := float(capture["means"].get(tier_label, 0.0))
		var gain := 1.0
		if native_mean > LUMINANCE_EPSILON:
			gain = _calibration_baseline_mean / native_mean
		elif _calibration_baseline_mean > LUMINANCE_EPSILON:
			# A zero native signal would produce an infinite ratio; the documented
			# safe range makes that case deterministic without an oversized boost.
			gain = EXPOSURE_GAIN_MAX
		gains[tier_label] = clampf(gain, EXPOSURE_GAIN_MIN, EXPOSURE_GAIN_MAX)
	# BASELINE is the reference and is deliberately never boosted.
	gains["BASELINE"] = 1.0
	_apply_calibration_gains(gains)


func _finish_native_reset(capture: Dictionary) -> void:
	_calibration_phase = CalibrationPhase.PHASE_IDLE
	_calibration_mode = CalibrationMode.MODE_NONE
	_matched_to_baseline = false
	var means: Dictionary = capture["means"]
	_last_measurement = {
		"ok": bool(capture["ok"]),
		"mode": "NATIVE",
		"means": means,
		"gains": _active_exposure_gains(),
		"ratios": capture["ratios"],
		"background_luminance": _last_background_luminance.duplicate(),
		"safe_gain_range": [EXPOSURE_GAIN_MIN, EXPOSURE_GAIN_MAX],
	}
	_update_readout(means, _active_exposure_gains())
	_refresh_status_ui()


func _apply_calibration_gains(gains: Dictionary) -> void:
	_set_all_comparison_gains(gains)
	_calibration_phase = CalibrationPhase.PHASE_SETTLING_APPLIED
	_calibration_settle_frames = CALIBRATION_SETTLE_FRAMES
	_refresh_status_ui()


func _run_matched_measurement() -> void:
	var capture := _capture_and_measure()
	if not bool(capture["ok"]):
		_fail_calibration("Could not capture the comparison viewport.")
		return
	var means: Dictionary = capture["means"]
	var ratios: Dictionary = capture["ratios"]
	_calibration_latest_matched_means = means.duplicate()
	_calibration_latest_ratios = ratios.duplicate()
	var converged := true
	for tier_label in ["TIER 1", "TIER 2"]:
		if absf(float(ratios.get(tier_label, 0.0)) - 1.0) > CALIBRATION_RATIO_TOLERANCE:
			converged = false
	if converged or _calibration_iteration >= CALIBRATION_MAX_ITERATIONS:
		_complete_calibration(means, ratios, converged)
		return

	# Nonlinear display/measurement path: the applied gain never maps linearly
	# to the measured ratio, so correct multiplicatively and re-settle.
	var gains := _active_exposure_gains()
	var baseline_mean := float(means.get("BASELINE", 0.0))
	for tier_label in ["TIER 1", "TIER 2"]:
		var tier_mean := float(means.get(tier_label, 0.0))
		if baseline_mean > LUMINANCE_EPSILON and tier_mean > LUMINANCE_EPSILON:
			gains[tier_label] = clampf(
				float(gains[tier_label]) * baseline_mean / tier_mean,
				EXPOSURE_GAIN_MIN,
				EXPOSURE_GAIN_MAX
			)
	_calibration_iteration += 1
	_apply_calibration_gains(gains)


func _complete_calibration(means: Dictionary, ratios: Dictionary, converged: bool) -> void:
	_calibration_converged = converged
	_calibration_phase = CalibrationPhase.PHASE_COMPLETE
	_calibration_mode = CalibrationMode.MODE_NONE
	_matched_to_baseline = true
	var result := {
		"ok": true,
		"mode": "MATCHED TO BASELINE",
		"native_means": _calibration_native_means.duplicate(),
		"gains": _active_exposure_gains(),
		"matched_means": means,
		"ratios": ratios,
		"native_ratios": _baseline_relative_ratios(_calibration_native_means),
		"matched_ratios": ratios,
		"converged": converged,
		"iterations": _calibration_iteration,
		"background_luminance": _last_background_luminance.duplicate(),
		"safe_gain_range": [EXPOSURE_GAIN_MIN, EXPOSURE_GAIN_MAX],
	}
	_calibration_result = result
	_last_measurement = result
	# Readout and mode label update from this settled, post-frame measurement
	# only — never from a capture taken before the gains reached a rendered
	# frame.
	_update_readout(means, _active_exposure_gains())
	_refresh_status_ui()


func _fail_calibration(message: String) -> void:
	_calibration_error = message
	_calibration_phase = CalibrationPhase.PHASE_FAILED
	_calibration_mode = CalibrationMode.MODE_NONE
	_matched_to_baseline = false
	# Restore native gains so the displayed scene returns to the default
	# presentation. While the phase is FAILED, measure_current_comparison()
	# refuses live captures, so this restore can never feed a stale capture;
	# start_exposure_calibration() or reset_native_exposure() clears the state.
	_set_all_comparison_gains(_native_gain_dictionary())
	_refresh_status_ui()


func _capture_and_measure() -> Dictionary:
	var overlay_was_visible := _interface_root != null and _interface_root.visible
	if _interface_root:
		_interface_root.visible = false
	RenderingServer.force_draw()

	var image := _capture_viewport_image()
	var means := _measure_groom_luminance(image)
	var ratios := _baseline_relative_ratios(means)

	if _interface_root:
		_interface_root.visible = overlay_was_visible
	RenderingServer.force_draw()
	return {
		"ok": image != null,
		"means": means,
		"ratios": ratios,
	}


func _capture_viewport_image() -> Image:
	if DisplayServer.get_name() == "headless":
		return null
	var viewport := get_viewport()
	if viewport == null:
		return null
	var viewport_texture := viewport.get_texture()
	if viewport_texture == null or not viewport_texture.get_rid().is_valid():
		return null
	return viewport_texture.get_image()


func _measure_groom_luminance(image: Image) -> Dictionary:
	var means := {}
	_last_background_luminance.clear()
	if image == null or image.get_width() <= 0 or image.get_height() <= 0:
		for tier_label in TIER_LABELS:
			means[tier_label] = 0.0
		return means

	var width := image.get_width()
	var height := image.get_height()
	for column_index in 3:
		var left := int(floor(float(column_index * width) / 3.0))
		var right := int(floor(float((column_index + 1) * width) / 3.0))
		var background_luminance := _sample_background_luminance(image, left, right)
		_last_background_luminance[TIER_LABELS[column_index]] = background_luminance

		var positive_delta_sum := 0.0
		var positive_pixel_count := 0
		for y in height:
			for x in range(left, right):
				var delta := _pixel_luminance(image.get_pixel(x, y)) - background_luminance
				# Background subtraction is intentionally one-sided: pixels at or
				# below the sampled background are not groom signal.
				if delta > 0.0:
					positive_delta_sum += delta
					positive_pixel_count += 1
		means[TIER_LABELS[column_index]] = positive_delta_sum / float(positive_pixel_count) \
			if positive_pixel_count > 0 else 0.0
	return means


func _sample_background_luminance(image: Image, left: int, right: int) -> float:
	var region_width := maxi(right - left, 1)
	var width_samples := [0.06, 0.94]
	var height_samples := [0.05, 0.50, 0.95]
	var samples: Array[float] = []
	for x_fraction in width_samples:
		var x := clampi(left + int(round(float(region_width - 1) * x_fraction)), left, right - 1)
		for y_fraction in height_samples:
			var y := clampi(int(round(float(image.get_height() - 1) * y_fraction)), 0, image.get_height() - 1)
			samples.append(_pixel_luminance(image.get_pixel(x, y)))
	if samples.is_empty():
		return 0.0
	var sum := 0.0
	for sample in samples:
		sum += sample
	return sum / float(samples.size())


func _pixel_luminance(color: Color) -> float:
	return color.r * LUMINANCE_WEIGHTS.x + color.g * LUMINANCE_WEIGHTS.y + color.b * LUMINANCE_WEIGHTS.z


func _baseline_relative_ratios(means: Dictionary) -> Dictionary:
	var baseline_mean := float(means.get("BASELINE", 0.0))
	var ratios := {}
	for tier_label in TIER_LABELS:
		var tier_mean := float(means.get(tier_label, 0.0))
		ratios[tier_label] = tier_mean / baseline_mean if baseline_mean > LUMINANCE_EPSILON else 1.0 if tier_mean <= LUMINANCE_EPSILON else 0.0
	return ratios


func _native_gain_dictionary() -> Dictionary:
	return {"TIER 1": 1.0, "TIER 2": 1.0, "BASELINE": 1.0}


func _active_exposure_gains() -> Dictionary:
	var gains := _native_gain_dictionary()
	for tier_label in TIER_LABELS:
		if _active_exposure_gains_state.has(tier_label):
			gains[tier_label] = float(_active_exposure_gains_state[tier_label])
	return gains


func _set_all_comparison_gains(gains: Dictionary) -> void:
	_active_exposure_gains_state.clear()
	for tier_label in TIER_LABELS:
		var gain := clampf(float(gains.get(tier_label, 1.0)), EXPOSURE_GAIN_MIN, EXPOSURE_GAIN_MAX)
		if tier_label == "BASELINE":
			gain = 1.0
		_active_exposure_gains_state[tier_label] = gain
		var material_clones: Array = _comparison_materials_by_tier.get(tier_label, [])
		for material_value in material_clones:
			var material := material_value as ShaderMaterial
			if material and material.shader:
				_set_uniform_if_declared(material, material.shader, &"comparison_exposure_gain", gain)


func _update_readout(means: Dictionary, gains: Dictionary) -> void:
	for tier_label in TIER_LABELS:
		var readout := _readout_labels.get(tier_label) as Label
		if not readout:
			continue
		var mean := float(means.get(tier_label, 0.0))
		var gain := float(gains.get(tier_label, 1.0))
		var baseline_mean := float(means.get("BASELINE", 0.0))
		var ratio := 1.0 if tier_label == "BASELINE" else (mean / baseline_mean if baseline_mean > LUMINANCE_EPSILON else 1.0 if mean <= LUMINANCE_EPSILON else 0.0)
		readout.text = "%s\nMEAN %.4f  ·  GAIN %.3f×  ·  RATIO %.3f×" % [tier_label, mean, gain, ratio]


## Updates the mode and calibration-status labels. Call this from every state
## transition and after every measurement; the readout labels themselves are
## only ever updated from settled, post-frame measurements.
func _refresh_status_ui() -> void:
	if _mode_label:
		var mode_text := "NATIVE" if not _matched_to_baseline else "MATCHED TO BASELINE"
		if _calibration_is_running():
			mode_text = "CALIBRATING…"
		elif _calibration_phase == CalibrationPhase.PHASE_FAILED:
			mode_text = "CALIBRATION FAILED"
		_mode_label.text = mode_text
	if _status_label:
		_status_label.text = _calibration_status_message()
		_status_label.add_theme_color_override("font_color", _calibration_status_color())


func _calibration_status_message() -> String:
	var gains := _active_exposure_gains()
	match _calibration_phase:
		CalibrationPhase.PHASE_IDLE:
			return "NATIVE MODE · ratios are screenshot-space luminance only — NOT benchmark metrics."
		CalibrationPhase.PHASE_SETTLING_NATIVE:
			if _calibration_mode == CalibrationMode.MODE_RESET:
				return "RESETTING TO NATIVE · waiting for a rendered frame (%d left)…" % _calibration_settle_frames
			return "CALIBRATING · restoring native gains · waiting for a rendered frame (%d left)…" % _calibration_settle_frames
		CalibrationPhase.PHASE_MEASURING_NATIVE:
			return "CALIBRATING · measuring native columns…"
		CalibrationPhase.PHASE_SETTLING_APPLIED:
			return "CALIBRATING · iteration %d/%d · gains applied · waiting for a rendered frame (%d left)…" % [
				mini(_calibration_iteration + 1, CALIBRATION_MAX_ITERATIONS + 1),
				CALIBRATION_MAX_ITERATIONS + 1,
				_calibration_settle_frames,
			]
		CalibrationPhase.PHASE_MEASURING_MATCHED:
			return "CALIBRATING · iteration %d/%d · measuring matched columns…" % [
				mini(_calibration_iteration + 1, CALIBRATION_MAX_ITERATIONS + 1),
				CALIBRATION_MAX_ITERATIONS + 1,
			]
		CalibrationPhase.PHASE_COMPLETE:
			var close := "within ±%.1f%% of BASELINE" % (CALIBRATION_RATIO_TOLERANCE * 100.0) \
				if _calibration_converged else "best effort — iteration limit reached"
			return "CALIBRATION COMPLETE · %s · T1 %.3f×  T2 %.3f× · ratios are screenshot-space luminance only — NOT benchmark metrics." % [
				close,
				float(gains.get("TIER 1", 1.0)),
				float(gains.get("TIER 2", 1.0)),
			]
		CalibrationPhase.PHASE_FAILED:
			return "CALIBRATION FAILED · %s" % _calibration_error
	return ""


func _calibration_status_color() -> Color:
	match _calibration_phase:
		CalibrationPhase.PHASE_IDLE:
			return TEXT_MUTED
		CalibrationPhase.PHASE_COMPLETE:
			return Color(0.62, 0.93, 0.84, 1.0)
		CalibrationPhase.PHASE_FAILED:
			return Color(0.95, 0.50, 0.45, 1.0)
	return Color(1.0, 0.80, 0.40, 1.0)


func _queue_layout() -> void:
	if _layout_pending:
		return
	_layout_pending = true
	call_deferred("_layout_stage")


func _layout_stage() -> void:
	_layout_pending = false
	if _comparison_grooms.is_empty() or not _source_groom or not _source_groom.mesh:
		return

	var camera := $ComparisonCamera as Camera3D
	var fixture_camera := get_node_or_null(^"MainFixture/Camera3D") as Camera3D
	if not camera:
		return

	var source_points := _source_world_points()
	if source_points.is_empty():
		return
	var source_center := _average_point(source_points)
	var camera_position := fixture_camera.global_position if fixture_camera else Vector3(0.0, 0.0, 1.0)
	camera.global_position = camera_position
	camera.look_at(source_center, Vector3.UP)

	var right := camera.global_basis.x.normalized()
	var up := camera.global_basis.y.normalized()
	var half_width := 0.0
	var half_height := 0.0
	for point in source_points:
		half_width = maxf(half_width, absf((point - source_center).dot(right)))
		half_height = maxf(half_height, absf((point - source_center).dot(up)))
	if half_width <= 0.001 or half_height <= 0.001:
		return

	var viewport_size := get_viewport().get_visible_rect().size
	var aspect := maxf(viewport_size.x / maxf(viewport_size.y, 1.0), 1.0)
	var groom_width := half_width * 2.0
	var gap := maxf(groom_width * COLUMN_GAP_RATIO, 0.04)
	var total_width := groom_width * 3.0 + gap * 2.0
	var orthographic_size := maxf(half_height * 2.0 * 1.22, total_width / aspect * 1.12)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = maxf(orthographic_size, 0.1)
	camera.near = 0.01
	camera.far = 50.0
	camera.make_current()

	# The camera is shared. Each groom keeps the source transform and receives
	# only a camera-right translation, so scale, orientation, and depth remain
	# identical across all three columns.
	var source_transform := _source_groom.global_transform
	for index in _comparison_grooms.size():
		var groom := _comparison_grooms[index]
		if not is_instance_valid(groom):
			continue
		var groom_transform := source_transform
		var column_offset := (float(index) - 1.0) * (groom_width + gap)
		groom_transform.origin = source_transform.origin + right * column_offset
		groom.global_transform = groom_transform


func _source_world_points() -> Array[Vector3]:
	if not _source_groom or not _source_groom.mesh:
		return []
	var points: Array[Vector3] = []
	for x in [0.0, 1.0]:
		for y in [0.0, 1.0]:
			for z in [0.0, 1.0]:
				var local_point := _source_aabb.position + Vector3(
					_source_aabb.size.x * x,
					_source_aabb.size.y * y,
					_source_aabb.size.z * z
				)
				points.append(_source_groom.global_transform * local_point)
	return points


func _average_point(points: Array[Vector3]) -> Vector3:
	var sum := Vector3.ZERO
	for point in points:
		sum += point
	return sum / float(points.size())
