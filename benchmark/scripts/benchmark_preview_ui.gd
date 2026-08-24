extends Control

## Compact, optional developer UI for non-timed variant comparisons. The UI only
## calls the controller's public preview API; it never constructs materials or
## reads benchmark output files.

const REFRESH_INTERVAL := 0.25
const PREVIEW_MODE_NAMES := ["NO_HAIR", "INDIVIDUAL_GROOM", "ALL_GROOMS", "REPRESENTATIVE_DEFAULT"]
const PREVIEW_VARIANT_NAMES := ["NO_HAIR", "COVERAGE_CONTROL", "CURRENT_MARSCHNER_BASELINE", "APPROX_KAJIYA_KAY", "BUILTIN_ALPHA_HASH_CONTROL", "FAST_MARSCHNER", "FAST_MARSCHNER_R_STANDARDIZED_LUT"]
const FAST_MARSCHNER_VARIANT_ID := 5
const FAST_MARSCHNER_R_STANDARDIZED_LUT_VARIANT_ID := 10
const PREVIEW_VARIANT_IDS := [0, 1, 2, 3, 4, FAST_MARSCHNER_VARIANT_ID, FAST_MARSCHNER_R_STANDARDIZED_LUT_VARIANT_ID]

@export_category("Preview UI")
@export var show_preview_ui: bool = true
@export var controller_path: NodePath = NodePath("../../BenchmarkController")

@onready var preview_panel: PanelContainer = $PreviewPanel
@onready var groom_select: OptionButton = $PreviewPanel/ContentScroll/Margin/VBox/ControlsGrid/GroomSelect
@onready var variant_select: OptionButton = $PreviewPanel/ContentScroll/Margin/VBox/ControlsGrid/VariantSelect
@onready var mode_select: OptionButton = $PreviewPanel/ContentScroll/Margin/VBox/ControlsGrid/ModeSelect
@onready var apply_button: Button = $PreviewPanel/ContentScroll/Margin/VBox/ApplyButton
@onready var apply_note: Label = $PreviewPanel/ContentScroll/Margin/VBox/ApplyNote
@onready var preview_badge: Label = $PreviewPanel/ContentScroll/Margin/VBox/Header/PreviewBadge
@onready var fast_settings: PanelContainer = $PreviewPanel/ContentScroll/Margin/VBox/FastSettings
@onready var azimuthal_lut_toggle: CheckBox = $PreviewPanel/ContentScroll/Margin/VBox/FastSettings/Margin/SettingsVBox/SettingsGrid/AzimuthalLUT
@onready var local_dual_scatter_toggle: CheckBox = $PreviewPanel/ContentScroll/Margin/VBox/FastSettings/Margin/SettingsVBox/SettingsGrid/LocalDualScatter
@onready var preintegrated_dual_scatter_toggle: CheckBox = $PreviewPanel/ContentScroll/Margin/VBox/FastSettings/Margin/SettingsVBox/SettingsGrid/PreintegratedDualScatter
@onready var environment_toggle: CheckBox = $PreviewPanel/ContentScroll/Margin/VBox/FastSettings/Margin/SettingsVBox/SettingsGrid/Environment
@onready var dual_scatter_strength_spin: SpinBox = $PreviewPanel/ContentScroll/Margin/VBox/FastSettings/Margin/SettingsVBox/SettingsGrid/DualScatterStrength
@onready var dual_scatter_density_spin: SpinBox = $PreviewPanel/ContentScroll/Margin/VBox/FastSettings/Margin/SettingsVBox/SettingsGrid/DualScatterDensity
@onready var environment_strength_spin: SpinBox = $PreviewPanel/ContentScroll/Margin/VBox/FastSettings/Margin/SettingsVBox/SettingsGrid/EnvironmentStrength
@onready var state_label: Label = $PreviewPanel/ContentScroll/Margin/VBox/StatusCard/Margin/StatusVBox/StateRow/StateLabel
@onready var active_groom: Label = $PreviewPanel/ContentScroll/Margin/VBox/StatusCard/Margin/StatusVBox/ActiveGrid/ActiveGroom
@onready var active_variant: Label = $PreviewPanel/ContentScroll/Margin/VBox/StatusCard/Margin/StatusVBox/ActiveGrid/ActiveVariant
@onready var active_profile: Label = $PreviewPanel/ContentScroll/Margin/VBox/StatusCard/Margin/StatusVBox/ActiveGrid/ActiveProfile
@onready var cpu_metric: Label = $PreviewPanel/ContentScroll/Margin/VBox/StatusCard/Margin/StatusVBox/MetricsGrid/CPUMetric
@onready var gpu_metric: Label = $PreviewPanel/ContentScroll/Margin/VBox/StatusCard/Margin/StatusVBox/MetricsGrid/GPUMetric
@onready var visible_metric: Label = $PreviewPanel/ContentScroll/Margin/VBox/StatusCard/Margin/StatusVBox/DrawGrid/VisibleMetric
@onready var shadow_metric: Label = $PreviewPanel/ContentScroll/Margin/VBox/StatusCard/Margin/StatusVBox/DrawGrid/ShadowMetric
@onready var validation_label: Label = $PreviewPanel/ContentScroll/Margin/VBox/StatusCard/Margin/StatusVBox/ValidationRow/ValidationLabel
@onready var explanation: Label = $PreviewPanel/ContentScroll/Margin/VBox/Explanation

var _controller: Node
var _refresh_clock := 0.0
var _timed_run_active := false


func _ready() -> void:
	if not show_preview_ui:
		visible = false
		set_process(false)
		return

	_controller = get_node_or_null(controller_path)
	if not _controller:
		visible = false
		set_process(false)
		push_warning("Benchmark preview UI could not find its BenchmarkController.")
		return

	_populate_selectors()
	apply_button.pressed.connect(_on_apply_pressed)
	variant_select.item_selected.connect(_on_variant_selected)
	local_dual_scatter_toggle.toggled.connect(_on_local_dual_scatter_toggled)
	preintegrated_dual_scatter_toggle.toggled.connect(_on_preintegrated_dual_scatter_toggled)
	environment_toggle.toggled.connect(_on_environment_toggled)
	_on_local_dual_scatter_toggled(local_dual_scatter_toggle.button_pressed)
	_on_environment_toggled(environment_toggle.button_pressed)
	if _controller.has_signal(&"benchmark_state_changed"):
		_controller.connect(&"benchmark_state_changed", Callable(self, "_on_benchmark_state_changed"))
	if _controller.has_signal(&"preview_applied"):
		_controller.connect(&"preview_applied", Callable(self, "_on_preview_applied"))

	_refresh_status()
	_on_benchmark_state_changed(int(_controller.get(&"benchmark_state")))


func _process(delta: float) -> void:
	if _timed_run_active or not _controller:
		return
	_refresh_clock += delta
	if _refresh_clock < REFRESH_INTERVAL:
		return
	_refresh_clock = 0.0
	_refresh_status()


func _populate_selectors() -> void:
	groom_select.clear()
	var groom_entries: Array = _controller.call(&"get_preview_grooms")
	for groom_entry in groom_entries:
		if not groom_entry is Dictionary:
			continue
		var display_name := String(groom_entry.get("display_name", groom_entry.get("groom_id", "Groom")))
		var groom_id := StringName(groom_entry.get("groom_id", display_name))
		groom_select.add_item(display_name)
		groom_select.set_item_metadata(groom_select.item_count - 1, groom_id)
	if groom_select.item_count == 0:
		groom_select.add_item("No grooms discovered")
		groom_select.disabled = true

	variant_select.clear()
	for variant_name in PREVIEW_VARIANT_NAMES:
		variant_select.add_item(variant_name)

	mode_select.clear()
	for mode_name in PREVIEW_MODE_NAMES:
		mode_select.add_item(mode_name)

	var status: Dictionary = _controller.call(&"get_preview_status")
	_select_variant_by_id(int(status.get("variant", 2)))
	_select_by_int(mode_select, int(status.get("mode", 3)))
	_select_groom(String(status.get("groom_id", "Blowout")))
	_on_variant_selected(variant_select.selected)


func _select_by_int(option: OptionButton, index: int) -> void:
	if option.item_count == 0:
		return
	option.select(clampi(index, 0, option.item_count - 1))


func _select_variant_by_id(variant_id: int) -> void:
	var item_index := PREVIEW_VARIANT_IDS.find(variant_id)
	_select_by_int(variant_select, item_index if item_index >= 0 else 2)


func _select_groom(groom_id: String) -> void:
	for item_index in groom_select.item_count:
		if String(groom_select.get_item_metadata(item_index)) == groom_id:
			groom_select.select(item_index)
			return
	if groom_select.item_count > 0:
		groom_select.select(0)


func _selected_groom() -> StringName:
	if groom_select.disabled or groom_select.selected < 0:
		return &""
	return StringName(groom_select.get_item_metadata(groom_select.selected))


func _on_variant_selected(_index: int) -> void:
	var is_fast_marschner := _preview_variant_id() == FAST_MARSCHNER_VARIANT_ID
	fast_settings.visible = is_fast_marschner
	if variant_select.selected == 0:
		apply_note.text = "NO_HAIR hides hair regardless of the selected display mode."
	elif is_fast_marschner:
		apply_note.text = "FAST_MARSCHNER uses the analytic path by default. Additive modes are preview-only."
	else:
		apply_note.text = "Material preview only • no files written or samples collected."


func _on_local_dual_scatter_toggled(enabled: bool) -> void:
	dual_scatter_strength_spin.editable = enabled
	dual_scatter_density_spin.editable = enabled
	if not enabled:
		preintegrated_dual_scatter_toggle.button_pressed = false


func _on_preintegrated_dual_scatter_toggled(enabled: bool) -> void:
	if enabled:
		# The preintegrated path is the LUT-backed form of local dual scatter.
		local_dual_scatter_toggle.button_pressed = true
		_on_local_dual_scatter_toggled(true)


func _on_environment_toggled(enabled: bool) -> void:
	environment_strength_spin.editable = enabled


func _sync_active_variant_name(variant_name: String) -> String:
	if variant_name == "FAST_MARSCHNER_R_STANDARDIZED_LUT":
		return variant_name
	if variant_name.begins_with("FAST_MARSCHNER"):
		return "FAST_MARSCHNER"
	return variant_name


func _preview_settings() -> Dictionary:
	return {
		"use_azimuthal_lut": azimuthal_lut_toggle.button_pressed,
		"use_dual_scatter": local_dual_scatter_toggle.button_pressed,
		"use_preintegrated_dual_scatter": preintegrated_dual_scatter_toggle.button_pressed,
		"use_environment": environment_toggle.button_pressed,
		"dual_scatter_strength": dual_scatter_strength_spin.value,
		"dual_scatter_density": dual_scatter_density_spin.value,
		"environment_strength": environment_strength_spin.value,
	}


func _preview_variant_id() -> int:
	# The generic FAST_MARSCHNER entry keeps its settings seam; the standardized
	# R LUT entry maps explicitly to controller enum value 10 rather than the
	# azimuthal LUT variant at value 6.
	return PREVIEW_VARIANT_IDS[clampi(variant_select.selected, 0, PREVIEW_VARIANT_IDS.size() - 1)]


func _controller_accepts_preview_settings() -> bool:
	if not _controller:
		return false
	for method_info in _controller.get_method_list():
		if StringName(method_info.get("name", "")) != &"apply_preview":
			continue
		var args: Variant = method_info.get("args", [])
		return args is Array and args.size() >= 4
	return false


func _apply_preview(requested_mode: int, requested_variant: int, requested_groom: StringName, settings: Dictionary) -> bool:
	# Controller seam: apply_preview(mode, variant, groom, settings). The
	# three-argument fallback keeps this UI usable against the current checkout
	# until the controller adopts the optional fourth argument.
	if _controller_accepts_preview_settings():
		return bool(_controller.call(&"apply_preview", requested_mode, requested_variant, requested_groom, settings))
	return bool(_controller.call(&"apply_preview", requested_mode, requested_variant, requested_groom))


func _on_apply_pressed() -> void:
	if _timed_run_active or not _controller or groom_select.disabled:
		return
	var requested_mode := mode_select.selected
	var requested_variant := _preview_variant_id()
	var requested_groom := _selected_groom()
	var settings: Dictionary = _preview_settings() if requested_variant == FAST_MARSCHNER_VARIANT_ID else {}
	var applied := _apply_preview(requested_mode, requested_variant, requested_groom, settings)
	if applied:
		apply_note.text = "Applied • non-timed preview is now visible."
	else:
		var status: Dictionary = _controller.call(&"get_preview_status")
		apply_note.text = "Preview failed: %s" % String(status.get("start_error", "controller rejected the selection"))
	_refresh_status()


func _on_preview_applied(success: bool) -> void:
	if not success:
		return
	_refresh_status()


func _on_benchmark_state_changed(state: int) -> void:
	_timed_run_active = state >= 1 and state <= 4
	if _timed_run_active:
		# Hiding the whole Control also prevents the overlay from entering a color
		# capture. The controller's timed measurement path remains untouched.
		visible = false
		process_mode = Node.PROCESS_MODE_DISABLED
		return
	process_mode = Node.PROCESS_MODE_INHERIT
	visible = show_preview_ui
	if visible:
		_refresh_status()


func _refresh_status() -> void:
	if not _controller or _timed_run_active:
		return
	var status: Dictionary = _controller.call(&"get_preview_status")
	preview_badge.text = "NON-TIMED"
	state_label.text = String(status.get("state_name", "IDLE"))
	active_groom.text = String(status.get("groom_name", status.get("groom_id", "—")))
	active_variant.text = _sync_active_variant_name(String(status.get("variant_name", "—")))
	active_profile.text = String(status.get("profile_id", "—"))

	var metrics: Dictionary = status.get("metrics", {})
	cpu_metric.text = _format_ms(metrics.get("cpu_ms", 0.0))
	gpu_metric.text = _format_ms(metrics.get("gpu_ms", 0.0))
	visible_metric.text = "%d draw  ·  %d prim" % [int(metrics.get("visible_draw_calls", 0)), int(metrics.get("visible_primitives", 0))]
	shadow_metric.text = "%d draw  ·  %d prim" % [int(metrics.get("shadow_draw_calls", 0)), int(metrics.get("shadow_primitives", 0))]

	var validation: Dictionary = status.get("validation", {})
	validation_label.text = "%s  ·  %s" % [String(validation.get("status", "PREVIEW ONLY")), String(status.get("metrics_source", "preview telemetry"))]
	validation_label.add_theme_color_override("font_color", Color("#73e0c0") if String(validation.get("status", "")) == "VALID" else Color("#b8c4d3"))
	state_label.add_theme_color_override("font_color", _state_color(String(status.get("state_name", "IDLE"))))
	explanation.text = "Preview timing is not a benchmark sample. Use the existing CLI/suite APIs for timed runs."


func _format_ms(value: Variant) -> String:
	var milliseconds := float(value)
	if milliseconds <= 0.0:
		return "—"
	return "%.2f ms" % milliseconds


func _state_color(state_name: String) -> Color:
	match state_name:
		"COMPLETE":
			return Color("#73e0c0")
		"PREWARM", "SETTLE", "CAPTURE":
			return Color("#f5c56b")
		"SAMPLE":
			return Color("#f28b82")
		_:
			return Color("#b8c4d3")
