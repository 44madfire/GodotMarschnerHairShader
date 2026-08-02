extends Control

## Compact, optional developer UI for non-timed variant comparisons. The UI only
## calls the controller's public preview API; it never constructs materials or
## reads benchmark output files.

const REFRESH_INTERVAL := 0.25
const PREVIEW_MODE_NAMES := ["NO_HAIR", "INDIVIDUAL_GROOM", "ALL_GROOMS", "REPRESENTATIVE_DEFAULT"]
const PREVIEW_VARIANT_NAMES := ["NO_HAIR", "COVERAGE_CONTROL", "CURRENT_MARSCHNER_BASELINE", "APPROX_KAJIYA_KAY", "BUILTIN_ALPHA_HASH_CONTROL"]

@export_category("Preview UI")
@export var show_preview_ui: bool = true
@export var controller_path: NodePath = NodePath("../../BenchmarkController")

@onready var preview_panel: PanelContainer = $PreviewPanel
@onready var groom_select: OptionButton = $PreviewPanel/Margin/VBox/ControlsGrid/GroomSelect
@onready var variant_select: OptionButton = $PreviewPanel/Margin/VBox/ControlsGrid/VariantSelect
@onready var mode_select: OptionButton = $PreviewPanel/Margin/VBox/ControlsGrid/ModeSelect
@onready var apply_button: Button = $PreviewPanel/Margin/VBox/ApplyButton
@onready var apply_note: Label = $PreviewPanel/Margin/VBox/ApplyNote
@onready var preview_badge: Label = $PreviewPanel/Margin/VBox/Header/PreviewBadge
@onready var state_label: Label = $PreviewPanel/Margin/VBox/StatusCard/Margin/StatusVBox/StateRow/StateLabel
@onready var active_groom: Label = $PreviewPanel/Margin/VBox/StatusCard/Margin/StatusVBox/ActiveGrid/ActiveGroom
@onready var active_variant: Label = $PreviewPanel/Margin/VBox/StatusCard/Margin/StatusVBox/ActiveGrid/ActiveVariant
@onready var active_profile: Label = $PreviewPanel/Margin/VBox/StatusCard/Margin/StatusVBox/ActiveGrid/ActiveProfile
@onready var cpu_metric: Label = $PreviewPanel/Margin/VBox/StatusCard/Margin/StatusVBox/MetricsGrid/CPUMetric
@onready var gpu_metric: Label = $PreviewPanel/Margin/VBox/StatusCard/Margin/StatusVBox/MetricsGrid/GPUMetric
@onready var visible_metric: Label = $PreviewPanel/Margin/VBox/StatusCard/Margin/StatusVBox/DrawGrid/VisibleMetric
@onready var shadow_metric: Label = $PreviewPanel/Margin/VBox/StatusCard/Margin/StatusVBox/DrawGrid/ShadowMetric
@onready var validation_label: Label = $PreviewPanel/Margin/VBox/StatusCard/Margin/StatusVBox/ValidationRow/ValidationLabel
@onready var explanation: Label = $PreviewPanel/Margin/VBox/Explanation

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
	_select_by_int(variant_select, int(status.get("variant", 2)))
	_select_by_int(mode_select, int(status.get("mode", 3)))
	_select_groom(String(status.get("groom_id", "Blowout")))
	_on_variant_selected(variant_select.selected)


func _select_by_int(option: OptionButton, index: int) -> void:
	if option.item_count == 0:
		return
	option.select(clampi(index, 0, option.item_count - 1))


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
	if variant_select.selected == 0:
		apply_note.text = "NO_HAIR hides hair regardless of the selected display mode."
	else:
		apply_note.text = "Material preview only • no files written or samples collected."


func _on_apply_pressed() -> void:
	if _timed_run_active or not _controller or groom_select.disabled:
		return
	var requested_mode := mode_select.selected
	var requested_variant := variant_select.selected
	var requested_groom := _selected_groom()
	var applied: bool = bool(_controller.call(&"apply_preview", requested_mode, requested_variant, requested_groom))
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
	active_variant.text = String(status.get("variant_name", "—"))
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
