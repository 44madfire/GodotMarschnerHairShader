extends Node

## First-slice benchmark controller for the ten direct hair children in main.tscn.
## The controller never edits a mesh material resource. Variant materials are per-surface
## ShaderMaterial clones installed through set_surface_override_material().

signal suite_completed(success: bool, suite_id: StringName)
signal start_failed(message: String)
signal persistence_failed(message: String)

enum BenchmarkState {
	IDLE,
	PREWARM,
	SETTLE,
	SAMPLE,
	CAPTURE,
	COMPLETE,
}

enum BenchmarkMode {
	NO_HAIR,
	INDIVIDUAL_GROOM,
	ALL_GROOMS,
	REPRESENTATIVE_DEFAULT,
}

enum BenchmarkVariant {
	NO_HAIR,
	COVERAGE_CONTROL,
	CURRENT_MARSCHNER_BASELINE,
	APPROX_KAJIYA_KAY,
}

const MODE_NAMES := ["NO_HAIR", "INDIVIDUAL_GROOM", "ALL_GROOMS", "REPRESENTATIVE_DEFAULT"]
const VARIANT_NAMES := ["NO_HAIR", "COVERAGE_CONTROL", "CURRENT_MARSCHNER_BASELINE", "APPROX_KAJIYA_KAY"]

const PREWARM_DEFAULT := 180
const SETTLE_DEFAULT := 30
const SAMPLE_DEFAULT := 300
const CAPTURE_DEFAULT := 1
const COMPARISON_VALIDITY_SCHEMA := 1
const COMPARISON_VALIDITY_MARKER := "material_override_precedence_repair_v1"

const COVERAGE_CONTROL_SHADER: Shader = preload("res://benchmark/shaders/hair_coverage_control.gdshader")
const COVERAGE_MASK_SHADER: Shader = preload("res://benchmark/shaders/hair_coverage_mask.gdshader")
const DEBUG_TANGENT_SHADER: Shader = preload("res://benchmark/shaders/hair_debug_tangent.gdshader")
const CURRENT_MARSCHNER_SHADER: Shader = preload("res://benchmark/reference/baseline_hair.gdshader")
const APPROX_KAJIYA_KAY_SHADER: Shader = preload("res://assets/hair/materials/shaders/hair_approx.gdshader")
const COVERAGE_WHITE_THRESHOLD: float = 0.95

## RenderingServer's viewport render-info enum values in Godot 4.7.
const RENDER_INFO_OBJECTS := 0
const RENDER_INFO_PRIMITIVES := 1
const RENDER_INFO_DRAW_CALLS := 2
const RENDER_INFO_VISIBLE := 0
const RENDER_INFO_SHADOW := 1

@export_category("Benchmark Scene")
## All scene relationships are configurable NodePaths; these defaults match BenchmarkHarness.
@export var head_path: NodePath = NodePath("../TestSceneHost/Main/Head")
@export var benchmark_camera_path: NodePath = NodePath("../BenchmarkCamera")
@export var lighting_rig_path: NodePath = NodePath("../LightingRigHost")
@export var case_lighting_rig_path: NodePath = NodePath("../CaseLightingRigHost")
@export var world_environment_path: NodePath = NodePath("../WorldEnvironment")
@export var fixture_camera_path: NodePath = NodePath("../TestSceneHost/Main/Camera3D")
@export var fixture_light_path: NodePath = NodePath("../TestSceneHost/Main/DirectionalLight3D")
@export var fixture_environment_path: NodePath = NodePath("../TestSceneHost/Main/WorldEnvironment")
@export var legacy_benchmark_light_path: NodePath = NodePath("../LightingRigHost")

@export_category("Smoke Run")
@export_enum("NO_HAIR", "INDIVIDUAL_GROOM", "ALL_GROOMS", "REPRESENTATIVE_DEFAULT") var benchmark_mode: int = BenchmarkMode.REPRESENTATIVE_DEFAULT
@export var individual_groom: StringName = &"Blowout"
@export_enum("NO_HAIR", "COVERAGE_CONTROL", "CURRENT_MARSCHNER_BASELINE", "APPROX_KAJIYA_KAY") var benchmark_variant: int = BenchmarkVariant.CURRENT_MARSCHNER_BASELINE
@export var auto_start_smoke: bool = false
@export_range(0, 100000, 1) var prewarm_frames: int = PREWARM_DEFAULT
@export_range(0, 100000, 1) var settle_frames: int = SETTLE_DEFAULT
@export_range(1, 100000, 1) var sample_frames: int = SAMPLE_DEFAULT
@export_range(1, 100, 1) var capture_frames: int = CAPTURE_DEFAULT
@export_dir var output_root: String = "user://hair_benchmarks"

## Public catalog: one dictionary per direct MeshInstance3D child of Head.
## Each dictionary contains id, name, node, original_visible, and surfaces.
var groom_catalog: Array[Dictionary] = []
var benchmark_state: int = BenchmarkState.IDLE

var _head: MeshInstance3D
var _original_state_saved := false
var _active_mode := BenchmarkMode.REPRESENTATIVE_DEFAULT
var _active_variant := BenchmarkVariant.CURRENT_MARSCHNER_BASELINE
var _active_individual_groom: StringName = &"Blowout"
var _state_frame := 0
var _samples: Array[Dictionary] = []
var _run_directory := ""
var _run_timestamp := ""
var _capture_requested := false
var _run_token := 0
var _active_prewarm_frames := PREWARM_DEFAULT
var _active_settle_frames := SETTLE_DEFAULT
var _active_sample_frames := SAMPLE_DEFAULT
var _active_capture_frames := CAPTURE_DEFAULT
var _active_capture_color := true
var _active_capture_coverage := false
var _active_capture_records: Array[Dictionary] = []
var _active_coverage_metrics: Dictionary = {}
var _viewport_quality_saved := false
var _saved_viewport_use_taa := false
var _saved_viewport_scaling_3d_mode := Viewport.Scaling3DMode.SCALING_3D_MODE_BILINEAR
var _saved_viewport_scaling_3d_scale := 1.0
var _debug_manager: Node
var _debug_manager_overlay_saved := false
var _debug_manager_overlay_state_saved := false
var _benchmark_environment_active := false
var last_start_error := ""
var last_persistence_error := ""
var _scene_state_saved := false
var _saved_benchmark_camera_transform := Transform3D.IDENTITY
var _saved_benchmark_camera_fov := 60.0
var _saved_benchmark_camera_near := 0.05
var _saved_benchmark_camera_far := 100.0
var _saved_benchmark_camera_current := false
var _saved_benchmark_camera_process_mode := Node.PROCESS_MODE_INHERIT
var _saved_benchmark_light_transform := Transform3D.IDENTITY
var _saved_benchmark_light_visible := true
var _saved_benchmark_light_process_mode := Node.PROCESS_MODE_INHERIT
var _saved_fixture_camera_current := false
var _saved_fixture_camera_process_mode := Node.PROCESS_MODE_INHERIT
var _saved_fixture_light_visible := true
var _saved_fixture_light_process_mode := Node.PROCESS_MODE_INHERIT
var _saved_fixture_environment: Environment
var _saved_viewport_size := Vector2i.ZERO
var _saved_window_size := Vector2i.ZERO
var _window_size_changed := false
var _active_lighting_rig: Node
var _diagnostic_saved_overrides: Array[Dictionary] = []
var _diagnostic_saved_groom_overrides: Array[Dictionary] = []
var _diagnostic_saved_head_material: Material
var _diagnostic_head_material_saved := false
var _diagnostic_capture_active := false
var _active_resource_case := false
var _active_suite_id: StringName = &""
var _active_suite_display_name := ""
var _active_case_id: StringName = &""
var _active_case_display_name := ""
var _active_case_camera_id: StringName = &""
var _active_case_lighting_id: StringName = &""
var _active_case_lighting_name := ""
var _active_case_lighting_notes := ""
var _active_case_viewport_size := Vector2i.ZERO
var _active_case_repeat := 0
var _active_case_capture_flags := {
	"color": true,
	"depth": false,
	"tangent": false,
	"debug": false,
}
var _suite_active := false
var _suite_resource: Resource
var _suite_cases: Array = []
var _suite_case_index := 0
var _suite_repeat_index := 0
var _suite_repeat_count := 1
var _suite_timestamp := ""
var _suite_directory := ""
var _suite_results: Array[Dictionary] = []
var _suite_terminal_emitted := false


func _ready() -> void:
	_configure_benchmark_environment()
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_save_scene_state()
	_disable_fixture_nodes()
	_discover_grooms()
	if auto_start_smoke:
		call_deferred("start_smoke")


func _process(_delta: float) -> void:
	_lock_benchmark_environment()
	match benchmark_state:
		BenchmarkState.PREWARM:
			_advance_timing_state(_active_prewarm_frames, BenchmarkState.SETTLE)
		BenchmarkState.SETTLE:
			_advance_timing_state(_active_settle_frames, BenchmarkState.SAMPLE)
		BenchmarkState.SAMPLE:
			# RenderingServer returns the completed/previous viewport frame here.
			_collect_sample()
			_state_frame += 1
			if _state_frame >= _active_sample_frames:
				benchmark_state = BenchmarkState.CAPTURE
				_state_frame = 0
				_capture_after_frame_post_draw(_run_token)
		BenchmarkState.CAPTURE, BenchmarkState.COMPLETE, BenchmarkState.IDLE:
			pass


## Starts the configured smoke run. This is intentionally public for programmatic starts.
func start_smoke() -> void:
	start_benchmark(benchmark_mode, benchmark_variant, individual_groom)


## Starts one run with explicit mode, variant, and optional groom selection.
func start_benchmark(requested_mode: int = -1, requested_variant: int = -1, requested_groom: StringName = &"") -> void:
	_begin_manual_run()

	_active_mode = benchmark_mode if requested_mode < 0 else clampi(requested_mode, 0, BenchmarkMode.REPRESENTATIVE_DEFAULT)
	_active_variant = benchmark_variant if requested_variant < 0 else clampi(requested_variant, 0, BenchmarkVariant.APPROX_KAJIYA_KAY)
	_active_individual_groom = individual_groom if requested_groom == &"" else requested_groom
	apply_variant(_active_variant)
	_apply_display_mode(BenchmarkMode.NO_HAIR if _active_variant == BenchmarkVariant.NO_HAIR else _active_mode)

	_samples.clear()
	_state_frame = 0
	_run_timestamp = _make_run_timestamp()
	_run_directory = output_root.path_join(_run_timestamp)
	if not _ensure_output_directory(_run_directory):
		benchmark_state = BenchmarkState.IDLE
		return
	benchmark_state = BenchmarkState.PREWARM


## Starts one validated resource-backed case. Returns false without sampling when validation fails.
func start_case(case: Resource) -> bool:
	var validation_errors: PackedStringArray = _resource_validation_errors(case, "Benchmark case")
	if not validation_errors.is_empty():
		_log_validation_failure("Benchmark case", validation_errors)
		return false

	_begin_resource_request()
	_suite_active = true
	_suite_resource = null
	_suite_cases = [case]
	_suite_case_index = 0
	_suite_repeat_index = 0
	_suite_repeat_count = maxi(_resource_int(case, &"repeat_count", 1), 1)
	_suite_timestamp = _make_run_timestamp()
	_suite_directory = output_root.path_join(_suite_timestamp)
	if not _ensure_output_directory(_suite_directory):
		_restore_failed_resource_start()
		return false
	_suite_terminal_emitted = false
	return _start_next_suite_item_now()


## Validates and queues every case before starting the first suite item.
func start_suite(suite: Resource) -> bool:
	var validation_errors: PackedStringArray = _resource_validation_errors(suite, "Benchmark suite")
	if not validation_errors.is_empty():
		_log_validation_failure("Benchmark suite", validation_errors)
		return false

	var case_value: Variant = suite.get(&"cases")
	if not (case_value is Array):
		_record_start_failure("Benchmark suite rejected: cases must be an Array of Resources.")
		return false
	var requested_cases: Array = case_value
	if requested_cases.is_empty():
		_record_start_failure("Benchmark suite rejected: cases must not be empty.")
		return false
	for case_index in requested_cases.size():
		var requested_case: Resource = requested_cases[case_index] as Resource
		var case_errors: PackedStringArray = _resource_validation_errors(requested_case, "Benchmark case %d" % case_index)
		if not case_errors.is_empty():
			_log_validation_failure("Benchmark suite case %d" % case_index, case_errors)
			return false

	_begin_resource_request()
	_suite_active = true
	_suite_resource = suite
	_suite_cases = requested_cases.duplicate()
	_suite_results.clear()
	_suite_case_index = 0
	_suite_repeat_index = 0
	_suite_repeat_count = 1
	_suite_timestamp = _make_run_timestamp()
	_suite_directory = output_root.path_join(_suite_timestamp).path_join(
		_safe_path_component(_resource_string(suite, &"output_subdirectory", "suite"), "suite")
	)
	if not _ensure_output_directory(_suite_directory):
		_restore_failed_resource_start()
		return false
	_suite_terminal_emitted = false
	call_deferred("_start_next_suite_item", _run_token)
	return true


## Applies a supported material/display variant without starting a run.
func apply_variant(variant_id: int) -> void:
	if groom_catalog.is_empty():
		_discover_grooms()
	var selected_variant := clampi(variant_id, 0, BenchmarkVariant.APPROX_KAJIYA_KAY)
	var display_mode := _active_mode
	_restore_original_surface_state()
	_active_variant = selected_variant

	match selected_variant:
		BenchmarkVariant.NO_HAIR:
			_apply_display_mode(BenchmarkMode.NO_HAIR)
		BenchmarkVariant.COVERAGE_CONTROL:
			_apply_shader_variant(COVERAGE_CONTROL_SHADER)
			_apply_display_mode(display_mode)
		BenchmarkVariant.CURRENT_MARSCHNER_BASELINE:
			_apply_shader_variant(CURRENT_MARSCHNER_SHADER)
			_apply_display_mode(display_mode)
		BenchmarkVariant.APPROX_KAJIYA_KAY:
			_apply_shader_variant(APPROX_KAJIYA_KAY_SHADER)
			_apply_display_mode(display_mode)


func _start_next_suite_item(expected_token: int) -> void:
	_start_next_suite_item_now(expected_token)


func _start_next_suite_item_now(expected_token: int = -1) -> bool:
	var token: int = _run_token if expected_token < 0 else expected_token
	if token != _run_token or not _suite_active:
		return false
	if _suite_case_index >= _suite_cases.size():
		_finish_suite(token)
		return true

	var next_case: Resource = _suite_cases[_suite_case_index] as Resource
	_suite_repeat_count = maxi(_resource_int(next_case, &"repeat_count", 1), 1)
	var started: bool = _start_resource_case(
		next_case,
		token,
		_suite_directory,
		_suite_repeat_index,
		_suite_repeat_count
	)
	if not started and _suite_active:
		var failed_suite: bool = _suite_resource != null
		if failed_suite:
			_fail_active_suite()
		else:
			_suite_active = false
	return started


func _start_resource_case(case: Resource, expected_token: int, output_directory: String, repeat_index: int, repeat_count: int) -> bool:
	if expected_token != _run_token:
		return false

	var camera_pose: Resource = _resource_resource(case, &"camera_pose")
	var lighting_rig: Resource = _resource_resource(case, &"lighting_rig")
	if not _apply_case_camera(case, camera_pose):
		_abort_resource_case("camera_pose could not be applied")
		return false

	_remove_active_lighting_rig()
	if not _instantiate_case_lighting(lighting_rig):
		_abort_resource_case("lighting_rig could not be instantiated")
		return false

	_active_resource_case = true
	_active_suite_id = _resource_string_name(_suite_resource, &"id", &"") if _suite_active else &""
	_active_suite_display_name = _resource_string(_suite_resource, &"display_name", "") if _suite_active else ""
	_active_case_id = _resource_string_name(case, &"id", &"case")
	_active_case_display_name = _resource_string(case, &"display_name", String(_active_case_id))
	_active_case_repeat = repeat_index + 1
	_active_case_camera_id = _resource_string_name(camera_pose, &"id", &"")
	_active_case_lighting_id = _resource_string_name(lighting_rig, &"id", &"")
	_active_case_lighting_name = _resource_string(lighting_rig, &"name", "")
	_active_case_lighting_notes = _resource_string(lighting_rig, &"notes", "")
	_active_case_viewport_size = _resource_vector2i(case, &"viewport_size", Vector2i.ZERO)
	_active_case_capture_flags = {
		"color": _resource_bool(case, &"capture_color", true),
		"coverage": _resource_bool(case, &"capture_coverage", false),
		"depth": _resource_bool(case, &"capture_depth", false),
		"tangent": _resource_bool(case, &"capture_tangent", false),
		"debug": _resource_bool(case, &"capture_debug", false),
	}

	_active_prewarm_frames = maxi(_resource_int(case, &"warmup_frames", PREWARM_DEFAULT), 0)
	_active_settle_frames = maxi(_resource_int(case, &"settle_frames", SETTLE_DEFAULT), 0)
	_active_sample_frames = maxi(_resource_int(case, &"sample_frames", SAMPLE_DEFAULT), 1)
	_active_capture_frames = maxi(_resource_int(case, &"capture_frames", CAPTURE_DEFAULT), 1)
	_active_capture_color = bool(_active_case_capture_flags["color"])
	_active_capture_coverage = bool(_active_case_capture_flags["coverage"])
	_active_capture_records.clear()
	_active_coverage_metrics = {}
	_suite_repeat_count = maxi(repeat_count, 1)
	_active_mode = clampi(_resource_int(case, &"mode", BenchmarkMode.REPRESENTATIVE_DEFAULT), 0, BenchmarkMode.REPRESENTATIVE_DEFAULT)
	_active_variant = clampi(_resource_int(case, &"variant", BenchmarkVariant.CURRENT_MARSCHNER_BASELINE), 0, BenchmarkVariant.APPROX_KAJIYA_KAY)
	_active_individual_groom = _resource_string_name(case, &"groom_id", &"")
	apply_variant(_active_variant)
	_apply_display_mode(BenchmarkMode.NO_HAIR if _active_variant == BenchmarkVariant.NO_HAIR else _active_mode)

	_run_timestamp = _make_run_timestamp()
	_run_directory = output_directory.path_join(_safe_path_component(String(_active_case_id), "case"))
	_run_directory = _run_directory.path_join("repeat_%03d" % _active_case_repeat)
	if not _ensure_output_directory(_run_directory):
		_abort_resource_case("Unable to prepare run output directory")
		return false
	_samples.clear()
	_state_frame = 0
	benchmark_state = BenchmarkState.PREWARM
	return true


func _apply_case_camera(case: Resource, camera_pose: Resource) -> bool:
	var benchmark_camera := get_node_or_null(benchmark_camera_path) as Camera3D
	if not benchmark_camera or not camera_pose:
		return false

	var transform_value: Variant = camera_pose.get(&"transform")
	var fov_value: Variant = camera_pose.get(&"fov")
	var near_value: Variant = camera_pose.get(&"near")
	var far_value: Variant = camera_pose.get(&"far")
	if not (transform_value is Transform3D) or not (fov_value is float or fov_value is int) or not (near_value is float or near_value is int) or not (far_value is float or far_value is int):
		return false
	var camera_transform: Transform3D = transform_value
	benchmark_camera.transform = camera_transform
	benchmark_camera.fov = float(fov_value)
	benchmark_camera.near = float(near_value)
	benchmark_camera.far = float(far_value)
	benchmark_camera.make_current()

	var viewport: Viewport = get_viewport()
	var viewport_target := _resource_vector2i(case, &"viewport_size", Vector2i.ZERO)
	if viewport_target != Vector2i.ZERO:
		_set_viewport_target(viewport_target)
	return true


func _instantiate_case_lighting(lighting_rig: Resource) -> bool:
	var host := get_node_or_null(case_lighting_rig_path) as Node
	if not host or not lighting_rig:
		return false
	var packed_scene_value: Variant = lighting_rig.get(&"packed_scene")
	var packed_scene: PackedScene = packed_scene_value as PackedScene
	if not packed_scene:
		return false
	var rig_instance: Node = packed_scene.instantiate()
	if not rig_instance:
		return false
	host.add_child(rig_instance)
	_active_lighting_rig = rig_instance
	_set_legacy_benchmark_light_enabled(false)
	return true


func _abort_resource_case(reason: String) -> void:
	_record_start_failure("Benchmark case rejected during setup: %s" % reason)
	_capture_requested = false
	benchmark_state = BenchmarkState.IDLE
	_restore_original_surface_state()
	_restore_scene_state()
	_restore_benchmark_environment()


func _restore_failed_resource_start() -> void:
	_restore_failed_resource_run()
	benchmark_state = BenchmarkState.IDLE


func _advance_suite_after_output(expected_token: int) -> void:
	if expected_token != _run_token or not _suite_active:
		return

	_suite_results.append({
		"case_id": String(_active_case_id),
		"case_display_name": _active_case_display_name,
		"repeat": _active_case_repeat,
		"directory": _run_directory,
		"sample_count": _samples.size(),
	})
	if _suite_repeat_index + 1 < _suite_repeat_count:
		_suite_repeat_index += 1
	else:
		_suite_case_index += 1
		_suite_repeat_index = 0
	call_deferred("_start_next_suite_item", expected_token)


func _finish_suite(expected_token: int) -> void:
	if expected_token != _run_token:
		return
	var completed_suite_id: StringName = _resource_string_name(_suite_resource, &"id", &"")
	var suite_persisted: bool = true
	if _suite_resource:
		suite_persisted = _write_suite_manifest()
	if not suite_persisted:
		_fail_active_suite()
		benchmark_state = BenchmarkState.COMPLETE
		return
	_restore_original_surface_state()
	_restore_scene_state()
	_restore_benchmark_environment()
	_suite_active = false
	benchmark_state = BenchmarkState.COMPLETE
	if _suite_resource:
		_suite_terminal_emitted = true
		suite_completed.emit(true, completed_suite_id)


func _resource_validation_errors(resource: Resource, label: String) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if not resource:
		errors.append("%s is missing" % label)
		return errors
	if not resource.has_method(&"validation_errors"):
		errors.append("%s must expose validation_errors()" % label)
		return errors
	var result: Variant = resource.call(&"validation_errors")
	if not (result is PackedStringArray):
		errors.append("%s validation_errors() must return PackedStringArray" % label)
		return errors
	var nested_errors: PackedStringArray = result
	for error_index in nested_errors.size():
		var error_message: String = nested_errors[error_index]
		errors.append(error_message)
	return errors


func _log_validation_failure(label: String, errors: PackedStringArray) -> void:
	var message_text := ""
	for error_index in errors.size():
		var error_message: String = errors[error_index]
		if not message_text.is_empty():
			message_text += "; "
		message_text += error_message
	_record_start_failure("%s: %s" % [label, message_text])


func _record_start_failure(message: String) -> void:
	last_start_error = message
	push_warning(message)
	start_failed.emit(message)


func _resource_int(resource: Resource, property_name: StringName, fallback: int) -> int:
	if not resource:
		return fallback
	var value: Variant = resource.get(property_name)
	if value is int or value is float:
		return int(value)
	return fallback


func _resource_bool(resource: Resource, property_name: StringName, fallback: bool) -> bool:
	if not resource:
		return fallback
	var value: Variant = resource.get(property_name)
	if value is bool:
		return bool(value)
	return fallback


func _resource_string(resource: Resource, property_name: StringName, fallback: String) -> String:
	if not resource:
		return fallback
	var value: Variant = resource.get(property_name)
	if value is String:
		return String(value)
	if value is StringName:
		return String(value)
	return fallback


func _resource_string_name(resource: Resource, property_name: StringName, fallback: StringName) -> StringName:
	if not resource:
		return fallback
	var value: Variant = resource.get(property_name)
	if value is StringName:
		return StringName(value)
	if value is String:
		return StringName(value)
	return fallback


func _resource_resource(resource: Resource, property_name: StringName) -> Resource:
	if not resource:
		return null
	var value: Variant = resource.get(property_name)
	return value as Resource


func _resource_vector2i(resource: Resource, property_name: StringName, fallback: Vector2i) -> Vector2i:
	if not resource:
		return fallback
	var value: Variant = resource.get(property_name)
	if value is Vector2i:
		return Vector2i(value)
	return fallback


func _safe_path_component(value: String, fallback: String) -> String:
	var component := value.strip_edges()
	component = component.replace("..", "_").replace("/", "_").replace("\\", "_").replace(":", "_")
	return component if not component.is_empty() else fallback


func _set_viewport_target(target: Vector2i) -> void:
	var viewport: Viewport = get_viewport()
	if not viewport or target == Vector2i.ZERO:
		return
	if viewport == get_tree().root:
		# The root viewport size is window-owned. Embedded editor windows must not
		# be resized by smoke cases; they still record requested and actual sizes.
		if _is_embedded_editor_window():
			return
		var window: Window = get_window()
		if window and window.size != target:
			window.size = target
			_window_size_changed = true
		return
	if viewport.size != target:
		viewport.size = target


## Restores original visibility and every saved surface override, then stops any run.
func reset_benchmark() -> void:
	_fail_active_suite()
	_run_token += 1
	_capture_requested = false
	_suite_active = false
	_suite_resource = null
	_suite_cases.clear()
	_suite_results.clear()
	benchmark_state = BenchmarkState.IDLE
	_state_frame = 0
	_restore_original_surface_state()
	_restore_scene_state()
	_restore_benchmark_environment()


func _exit_tree() -> void:
	_fail_active_suite()
	_run_token += 1
	_capture_requested = false
	_suite_active = false
	_suite_resource = null
	_suite_results.clear()
	_restore_original_surface_state()
	_restore_scene_state()
	_restore_benchmark_environment()


func _begin_manual_run() -> void:
	_cancel_current_request()
	_configure_benchmark_environment()
	_disable_fixture_nodes()
	_discover_grooms()
	_active_prewarm_frames = prewarm_frames
	_active_settle_frames = settle_frames
	_active_sample_frames = sample_frames
	_active_capture_frames = capture_frames
	_active_capture_color = true
	_active_capture_coverage = false
	last_start_error = ""
	last_persistence_error = ""
	_reset_case_metadata()


func _begin_resource_request() -> void:
	_cancel_current_request()
	_configure_benchmark_environment()
	_disable_fixture_nodes()
	_discover_grooms()
	last_start_error = ""
	last_persistence_error = ""


func _cancel_current_request() -> void:
	_fail_active_suite()
	_run_token += 1
	_capture_requested = false
	benchmark_state = BenchmarkState.IDLE
	_state_frame = 0
	_suite_active = false
	_suite_resource = null
	_suite_cases.clear()
	_suite_results.clear()
	_restore_original_surface_state()
	_restore_scene_state()
	_reset_case_metadata()


func _reset_case_metadata() -> void:
	_active_resource_case = false
	_active_suite_id = &""
	_active_suite_display_name = ""
	_active_case_id = &""
	_active_case_display_name = ""
	_active_case_camera_id = &""
	_active_case_lighting_id = &""
	_active_case_lighting_name = ""
	_active_case_lighting_notes = ""
	_active_case_viewport_size = Vector2i.ZERO
	_active_case_repeat = 0
	_active_case_capture_flags = {
		"color": true,
		"coverage": false,
		"depth": false,
		"tangent": false,
		"debug": false,
	}
	_active_capture_records.clear()
	_active_coverage_metrics = {}


func _configure_benchmark_environment() -> void:
	if _benchmark_environment_active:
		_lock_benchmark_environment()
		return

	var viewport: Viewport = get_viewport()
	if viewport:
		_saved_viewport_use_taa = viewport.use_taa
		_saved_viewport_scaling_3d_mode = viewport.scaling_3d_mode
		_saved_viewport_scaling_3d_scale = viewport.scaling_3d_scale
		_viewport_quality_saved = true
		_benchmark_environment_active = true
		_lock_benchmark_environment()

	_debug_manager = get_node_or_null(^'/root/DebugManager')
	if _debug_manager:
		_debug_manager_overlay_saved = bool(_debug_manager.get(&'should_render_imgui'))
		_debug_manager_overlay_state_saved = true
		_debug_manager.set(&'should_render_imgui', false)


func _lock_benchmark_environment() -> void:
	if not _benchmark_environment_active:
		return
	var viewport: Viewport = get_viewport()
	if viewport:
		viewport.use_taa = false
		viewport.scaling_3d_mode = Viewport.Scaling3DMode.SCALING_3D_MODE_BILINEAR
		viewport.scaling_3d_scale = 1.0
	if _debug_manager_overlay_state_saved and is_instance_valid(_debug_manager):
		_debug_manager.set(&'should_render_imgui', false)


func _restore_benchmark_environment() -> void:
	_benchmark_environment_active = false
	var viewport: Viewport = get_viewport()
	if _viewport_quality_saved and viewport:
		viewport.use_taa = _saved_viewport_use_taa
		viewport.scaling_3d_mode = _saved_viewport_scaling_3d_mode
		viewport.scaling_3d_scale = _saved_viewport_scaling_3d_scale
	_viewport_quality_saved = false

	if _debug_manager_overlay_state_saved and is_instance_valid(_debug_manager):
		_debug_manager.set(&'should_render_imgui', _debug_manager_overlay_saved)
	_debug_manager_overlay_state_saved = false


func _save_scene_state() -> void:
	if _scene_state_saved:
		return
	_window_size_changed = false

	var viewport: Viewport = get_viewport()
	if viewport:
		_saved_viewport_size = viewport.size
		if viewport == get_tree().root and not _is_embedded_editor_window():
			var window: Window = get_window()
			if window:
				_saved_window_size = window.size

	var benchmark_camera := get_node_or_null(benchmark_camera_path) as Camera3D
	if benchmark_camera:
		_saved_benchmark_camera_transform = benchmark_camera.transform
		_saved_benchmark_camera_fov = benchmark_camera.fov
		_saved_benchmark_camera_near = benchmark_camera.near
		_saved_benchmark_camera_far = benchmark_camera.far
		_saved_benchmark_camera_current = benchmark_camera.current
		_saved_benchmark_camera_process_mode = benchmark_camera.process_mode

	var benchmark_light := _get_legacy_benchmark_light()
	if benchmark_light:
		_saved_benchmark_light_transform = benchmark_light.transform
		_saved_benchmark_light_visible = benchmark_light.visible
		_saved_benchmark_light_process_mode = benchmark_light.process_mode

	var fixture_camera := get_node_or_null(fixture_camera_path) as Camera3D
	if fixture_camera:
		_saved_fixture_camera_current = fixture_camera.current
		_saved_fixture_camera_process_mode = fixture_camera.process_mode

	var fixture_light := get_node_or_null(fixture_light_path) as DirectionalLight3D
	if fixture_light:
		_saved_fixture_light_visible = fixture_light.visible
		_saved_fixture_light_process_mode = fixture_light.process_mode

	var fixture_environment := get_node_or_null(fixture_environment_path) as WorldEnvironment
	if fixture_environment:
		_saved_fixture_environment = fixture_environment.environment

	_scene_state_saved = true


func _restore_scene_state() -> void:
	_restore_diagnostic_state()
	_remove_active_lighting_rig()
	if not _scene_state_saved:
		return

	if _window_size_changed and _saved_window_size != Vector2i.ZERO and not _is_embedded_editor_window():
		var window: Window = get_window()
		if window and window.size != _saved_window_size:
			window.size = _saved_window_size
		_window_size_changed = false
	else:
		var viewport: Viewport = get_viewport()
		if viewport and viewport != get_tree().root and _saved_viewport_size != Vector2i.ZERO:
			viewport.size = _saved_viewport_size
	_window_size_changed = false

	var benchmark_camera := get_node_or_null(benchmark_camera_path) as Camera3D
	if benchmark_camera:
		benchmark_camera.transform = _saved_benchmark_camera_transform
		benchmark_camera.fov = _saved_benchmark_camera_fov
		benchmark_camera.near = _saved_benchmark_camera_near
		benchmark_camera.far = _saved_benchmark_camera_far
		benchmark_camera.current = _saved_benchmark_camera_current
		benchmark_camera.process_mode = _saved_benchmark_camera_process_mode

	var benchmark_light := _get_legacy_benchmark_light()
	if benchmark_light:
		benchmark_light.transform = _saved_benchmark_light_transform
		benchmark_light.visible = _saved_benchmark_light_visible
		benchmark_light.process_mode = _saved_benchmark_light_process_mode

	var fixture_camera := get_node_or_null(fixture_camera_path) as Camera3D
	if fixture_camera:
		fixture_camera.current = _saved_fixture_camera_current
		fixture_camera.process_mode = _saved_fixture_camera_process_mode

	var fixture_light := get_node_or_null(fixture_light_path) as DirectionalLight3D
	if fixture_light:
		fixture_light.visible = _saved_fixture_light_visible
		fixture_light.process_mode = _saved_fixture_light_process_mode

	var fixture_environment := get_node_or_null(fixture_environment_path) as WorldEnvironment
	if fixture_environment:
		fixture_environment.environment = _saved_fixture_environment
	_active_resource_case = false


func _is_embedded_editor_window() -> bool:
	if Engine.is_embedded_in_editor():
		return true
	var window: Window = get_window()
	return window != null and window.is_embedded()


func _get_legacy_benchmark_light() -> DirectionalLight3D:
	var configured_light := get_node_or_null(legacy_benchmark_light_path) as DirectionalLight3D
	if configured_light:
		return configured_light
	return get_node_or_null(lighting_rig_path) as DirectionalLight3D


func _set_legacy_benchmark_light_enabled(enabled: bool) -> void:
	var benchmark_light := _get_legacy_benchmark_light()
	if not benchmark_light:
		return
	benchmark_light.visible = enabled
	benchmark_light.process_mode = Node.PROCESS_MODE_INHERIT if enabled else Node.PROCESS_MODE_DISABLED


func _remove_active_lighting_rig() -> void:
	if is_instance_valid(_active_lighting_rig):
		_active_lighting_rig.free()
	_active_lighting_rig = null


func _begin_diagnostic_capture(shader: Shader, replace_head_material: bool) -> bool:
	_restore_diagnostic_state()
	if not _head or groom_catalog.is_empty():
		_record_persistence_failure("Unable to prepare diagnostic capture: no hair head was discovered")
		return false

	_diagnostic_capture_active = true
	for groom_data in groom_catalog:
		var groom: MeshInstance3D = groom_data["node"] as MeshInstance3D
		if not is_instance_valid(groom):
			continue
		_diagnostic_saved_groom_overrides.append({
			"groom": groom,
			"override": groom.material_override,
		})
		var diagnostic_surfaces: Array[Dictionary] = []
		for surface_data in groom_data["surfaces"]:
			var surface_index: int = int(surface_data["surface_index"])
			var current_override: Material = groom.get_surface_override_material(surface_index)
			var active_material: ShaderMaterial = groom.get_active_material(surface_index) as ShaderMaterial
			if not active_material:
				_restore_diagnostic_state()
				_record_persistence_failure("Unable to prepare diagnostic capture: hair surface has no ShaderMaterial")
				return false
			diagnostic_surfaces.append({
				"groom": groom,
				"surface_index": surface_index,
				"override": current_override,
				"source_material": active_material,
			})

		groom.material_override = null
		for diagnostic_surface in diagnostic_surfaces:
			_diagnostic_saved_overrides.append(diagnostic_surface)
			var source_material: ShaderMaterial = diagnostic_surface["source_material"] as ShaderMaterial
			var diagnostic_material: ShaderMaterial = source_material.duplicate() as ShaderMaterial
			if not diagnostic_material:
				_restore_diagnostic_state()
				_record_persistence_failure("Unable to prepare diagnostic capture: material clone failed")
				return false
			diagnostic_material.shader = shader
			groom.set_surface_override_material(int(diagnostic_surface["surface_index"]), diagnostic_material)

	if replace_head_material:
		_diagnostic_saved_head_material = _head.material_override
		_diagnostic_head_material_saved = true
		var black_head_material: StandardMaterial3D = StandardMaterial3D.new()
		black_head_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		black_head_material.albedo_color = Color.BLACK
		_head.material_override = black_head_material
	return true


func _restore_diagnostic_state() -> void:
	if not _diagnostic_capture_active and _diagnostic_saved_overrides.is_empty() and not _diagnostic_head_material_saved:
		return
	for saved_surface in _diagnostic_saved_overrides:
		var groom: MeshInstance3D = saved_surface["groom"] as MeshInstance3D
		if is_instance_valid(groom):
			var surface_index: int = int(saved_surface["surface_index"])
			var original_override: Material = saved_surface["override"] as Material
			groom.set_surface_override_material(surface_index, original_override)
	for saved_groom in _diagnostic_saved_groom_overrides:
		var groom: MeshInstance3D = saved_groom["groom"] as MeshInstance3D
		if is_instance_valid(groom):
			groom.material_override = saved_groom["override"] as Material
	if _diagnostic_head_material_saved and is_instance_valid(_head):
		_head.material_override = _diagnostic_saved_head_material
	_diagnostic_saved_overrides.clear()
	_diagnostic_saved_groom_overrides.clear()
	_diagnostic_saved_head_material = null
	_diagnostic_head_material_saved = false
	_diagnostic_capture_active = false


func _disable_fixture_nodes() -> void:
	var fixture_camera := get_node_or_null(fixture_camera_path) as Camera3D
	if fixture_camera:
		fixture_camera.current = false
		fixture_camera.process_mode = Node.PROCESS_MODE_DISABLED

	var fixture_light := get_node_or_null(fixture_light_path) as DirectionalLight3D
	if fixture_light:
		fixture_light.visible = false
		fixture_light.process_mode = Node.PROCESS_MODE_DISABLED

	var fixture_environment := get_node_or_null(fixture_environment_path) as WorldEnvironment
	if fixture_environment:
		fixture_environment.environment = null

	var benchmark_camera := get_node_or_null(benchmark_camera_path) as Camera3D
	if benchmark_camera:
		benchmark_camera.make_current()
	_set_legacy_benchmark_light_enabled(true)


func _discover_grooms() -> void:
	_head = get_node_or_null(head_path) as MeshInstance3D
	groom_catalog.clear()
	_original_state_saved = false
	if not _head:
		return

	for child in _head.get_children():
		var groom := child as MeshInstance3D
		if not groom or not groom.mesh:
			continue

		var surfaces: Array[Dictionary] = []
		for surface_index in groom.mesh.get_surface_count():
			var original_override := groom.get_surface_override_material(surface_index)
			var source_active_material := groom.get_active_material(surface_index)
			surfaces.append({
				"surface_index": surface_index,
				"original_override": original_override,
				"source_active_material": source_active_material,
			})

		groom_catalog.append({
			"id": groom.get_instance_id(),
			"name": StringName(groom.name),
			"node": groom,
			"original_material_override": groom.material_override,
			"original_visible": groom.visible,
			"surfaces": surfaces,
		})

	_original_state_saved = not groom_catalog.is_empty()


func _apply_shader_variant(shader: Shader) -> void:
	for groom_data in groom_catalog:
		var groom := groom_data["node"] as MeshInstance3D
		if not is_instance_valid(groom):
			continue
		# GeometryInstance3D.material_override wins over every surface override.
		# Clear only the instance override; all source materials are the copies
		# captured during discovery, so mesh/source resources remain untouched.
		groom.material_override = null
		for surface_data in groom_data["surfaces"]:
			var source_material := surface_data["source_active_material"] as Material
			if not source_material:
				continue
			var source_shader_material := source_material as ShaderMaterial
			if not source_shader_material:
				continue

			# Duplicate per surface so the source ShaderMaterial and mesh resource remain untouched.
			var cloned_material := source_shader_material.duplicate() as ShaderMaterial
			cloned_material.shader = shader
			groom.set_surface_override_material(int(surface_data["surface_index"]), cloned_material)


func _apply_display_mode(mode: int) -> void:
	for groom_data in groom_catalog:
		var groom := groom_data["node"] as MeshInstance3D
		if not is_instance_valid(groom):
			continue
		var visible := false
		match mode:
			BenchmarkMode.ALL_GROOMS:
				visible = true
			BenchmarkMode.INDIVIDUAL_GROOM:
				visible = String(groom_data["name"]) == String(_active_individual_groom)
			BenchmarkMode.REPRESENTATIVE_DEFAULT:
				visible = bool(groom_data["original_visible"])
			BenchmarkMode.NO_HAIR:
				visible = false
		groom.visible = visible


func _restore_original_surface_state() -> void:
	_restore_diagnostic_state()
	if not _original_state_saved:
		return
	for groom_data in groom_catalog:
		var groom := groom_data["node"] as MeshInstance3D
		if not is_instance_valid(groom):
			continue
		groom.visible = bool(groom_data["original_visible"])
		for surface_data in groom_data["surfaces"]:
			# Restoration is deliberately limited to surface overrides.
			groom.set_surface_override_material(
				int(surface_data["surface_index"]),
				surface_data["original_override"] as Material
			)
		groom.material_override = groom_data["original_material_override"] as Material


func _advance_timing_state(frame_limit: int, next_state: int) -> void:
	_state_frame += 1
	if _state_frame >= frame_limit:
		benchmark_state = next_state
		_state_frame = 0


func _collect_sample() -> void:
	var viewport_rid: RID = get_viewport().get_viewport_rid()
	# These values are the previous completed frame's viewport measurements.
	var sample := {
		"sample_index": _samples.size(),
		"frame": Engine.get_process_frames(),
		"cpu_ms": RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid),
		"gpu_ms": RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid),
		"visible_objects": _viewport_counter(viewport_rid, RENDER_INFO_VISIBLE, RENDER_INFO_OBJECTS),
		"visible_primitives": _viewport_counter(viewport_rid, RENDER_INFO_VISIBLE, RENDER_INFO_PRIMITIVES),
		"visible_draw_calls": _viewport_counter(viewport_rid, RENDER_INFO_VISIBLE, RENDER_INFO_DRAW_CALLS),
		"shadow_objects": _viewport_counter(viewport_rid, RENDER_INFO_SHADOW, RENDER_INFO_OBJECTS),
		"shadow_primitives": _viewport_counter(viewport_rid, RENDER_INFO_SHADOW, RENDER_INFO_PRIMITIVES),
		"shadow_draw_calls": _viewport_counter(viewport_rid, RENDER_INFO_SHADOW, RENDER_INFO_DRAW_CALLS),
	}
	_samples.append(sample)


func _viewport_counter(viewport_rid: RID, render_info_type: int, render_info: int) -> int:
	return int(RenderingServer.viewport_get_render_info(viewport_rid, render_info_type, render_info))


func _record_capture_provenance(pass_name: String, file_name: String) -> void:
	_active_capture_records.append({
		"pass": pass_name,
		"file": file_name,
		"process_frame": Engine.get_process_frames(),
		"monotonic_timestamp_usec": Time.get_ticks_usec(),
		"time_hash_provenance": "Production TIME-driven Bayer/hash path; temporal hash is recorded, not frozen.",
	})


func _capture_diagnostic_pass(shader: Shader, pass_name: String, file_name: String, replace_head_material: bool, run_token: int) -> bool:
	if not _begin_diagnostic_capture(shader, replace_head_material):
		return false
	# Give the swapped diagnostic materials one completed frame to reach the
	# renderer before reading the actual capture frame. This is outside SAMPLE.
	await RenderingServer.frame_post_draw
	if run_token != _run_token or not is_inside_tree():
		_restore_diagnostic_state()
		return false

	await RenderingServer.frame_post_draw
	if run_token != _run_token or not is_inside_tree():
		_restore_diagnostic_state()
		return false

	_record_capture_provenance(pass_name, file_name)
	var viewport_texture: Texture2D = get_viewport().get_texture()
	if not viewport_texture:
		_restore_diagnostic_state()
		_record_persistence_failure("Unable to access the viewport texture for %s capture" % pass_name)
		return false
	var image: Image = viewport_texture.get_image()
	if not image:
		_restore_diagnostic_state()
		_record_persistence_failure("Unable to read the viewport image for %s capture" % pass_name)
		return false
	var image_error: Error = image.save_png(_run_directory.path_join(file_name))
	if image_error != OK:
		_restore_diagnostic_state()
		_record_persistence_failure("Unable to save %s: %s" % [file_name, image_error])
		return false
	if pass_name == "coverage":
		_active_coverage_metrics = _compute_coverage_metrics(image)
	_restore_diagnostic_state()
	return true


func _compute_coverage_metrics(image: Image) -> Dictionary:
	var image_width: int = image.get_width()
	var image_height: int = image.get_height()
	var total_pixels: int = image_width * image_height
	var white_pixels: int = 0
	var min_x: int = image_width
	var min_y: int = image_height
	var max_x: int = -1
	var max_y: int = -1
	for y in image_height:
		for x in image_width:
			var pixel: Color = image.get_pixel(x, y)
			if pixel.r < COVERAGE_WHITE_THRESHOLD or pixel.g < COVERAGE_WHITE_THRESHOLD or pixel.b < COVERAGE_WHITE_THRESHOLD:
				continue
			white_pixels += 1
			min_x = mini(min_x, x)
			min_y = mini(min_y, y)
			max_x = maxi(max_x, x)
			max_y = maxi(max_y, y)

	var bounding_rect: Array[int] = [0, 0, 0, 0]
	if white_pixels > 0:
		bounding_rect = [min_x, min_y, max_x - min_x + 1, max_y - min_y + 1]
	var white_percentage: float = 0.0 if total_pixels == 0 else float(white_pixels) / float(total_pixels) * 100.0
	return {
		"white_threshold": COVERAGE_WHITE_THRESHOLD,
		"white_threshold_definition": "A pixel qualifies when R, G, and B are each >= 0.95.",
		"white_pixel_count": white_pixels,
		"total_frame_pixels": total_pixels,
		"white_pixel_percentage": white_percentage,
		"bounding_rect": bounding_rect,
	}


func _capture_after_frame_post_draw(run_token: int) -> void:
	if _capture_requested:
		return
	_capture_requested = true
	var capture_succeeded := true
	# Capture is intentionally outside SAMPLE and waits for the rendered frame.
	var capture_count := maxi(_active_capture_frames, 1)
	for capture_index in capture_count:
		await RenderingServer.frame_post_draw
		if run_token != _run_token or not is_inside_tree():
			_capture_requested = false
			return
		if capture_index == capture_count - 1:
			if _active_capture_color:
				_record_capture_provenance("color", "color.png")
				var viewport_texture: Texture2D = get_viewport().get_texture()
				if viewport_texture:
					var image: Image = viewport_texture.get_image()
					if image:
						var image_error: Error = image.save_png(_run_directory.path_join("color.png"))
						if image_error != OK:
							_record_persistence_failure("Unable to save color.png: %s" % image_error)
							capture_succeeded = false
					else:
						_record_persistence_failure("Unable to capture the viewport image")
						capture_succeeded = false
				else:
					_record_persistence_failure("Unable to access the viewport texture")
					capture_succeeded = false

	if not capture_succeeded:
		_handle_run_persistence_failure(run_token)
		return
	if _active_capture_coverage:
		var coverage_captured: bool = await _capture_diagnostic_pass(COVERAGE_MASK_SHADER, "coverage", "coverage.png", true, run_token)
		if not coverage_captured:
			_handle_run_persistence_failure(run_token)
			return
	if bool(_active_case_capture_flags["tangent"]):
		var tangent_captured: bool = await _capture_diagnostic_pass(DEBUG_TANGENT_SHADER, "tangent", "tangent.png", false, run_token)
		if not tangent_captured:
			_handle_run_persistence_failure(run_token)
			return
	if not _write_run_outputs():
		_handle_run_persistence_failure(run_token)
		return
	benchmark_state = BenchmarkState.COMPLETE
	_capture_requested = false
	if _suite_active:
		call_deferred("_advance_suite_after_output", run_token)


func _write_run_outputs() -> bool:
	var mode_name := _mode_name(_active_mode)
	var variant_name := _variant_name(_active_variant)
	var baseline_commit := FileAccess.get_file_as_string("res://benchmark/reference/BASELINE_COMMIT.txt").strip_edges()
	var actual_viewport: Vector2i = get_viewport().size
	var output_files: Array[String] = ["run_manifest.json", "samples.csv", "summary.json"]
	if _active_capture_color:
		output_files.append("color.png")
	if _active_capture_coverage:
		output_files.append("coverage.png")
	if bool(_active_case_capture_flags["tangent"]):
		output_files.append("tangent.png")
	var catalog_manifest: Array = []
	for groom_data in groom_catalog:
		var surface_indices: Array = []
		for surface_data in groom_data["surfaces"]:
			surface_indices.append(int(surface_data["surface_index"]))
		catalog_manifest.append({
			"id": int(groom_data["id"]),
			"name": String(groom_data["name"]),
			"surface_indices": surface_indices,
		})
	var manifest := {
		"schema_version": 1,
		"timestamp": _run_timestamp,
		"suite_id": String(_active_suite_id),
		"suite_display_name": _active_suite_display_name,
		"case_id": String(_active_case_id),
		"case_display_name": _active_case_display_name,
		"repeat": _active_case_repeat,
		"mode": mode_name,
		"mode_value": _active_mode,
		"variant": variant_name,
		"variant_value": _active_variant,
		"individual_groom": String(_active_individual_groom),
		"state_sequence": ["PREWARM", "SETTLE", "SAMPLE", "CAPTURE", "COMPLETE"],
		"prewarm_frames": _active_prewarm_frames,
		"warmup_frames": _active_prewarm_frames,
		"settle_frames": _active_settle_frames,
		"sample_frames": _active_sample_frames,
		"capture_frames": _active_capture_frames,
		"sample_count": _samples.size(),
		"baseline_commit": baseline_commit,
		"grooms": catalog_manifest,
		"viewport_size": [actual_viewport.x, actual_viewport.y],
		"viewport_target": [_active_case_viewport_size.x, _active_case_viewport_size.y],
		"camera_pose": _camera_manifest(),
		"lighting_rig": _lighting_manifest(),
		"capture_flags": _active_case_capture_flags,
		"captures": _active_capture_records,
		"coverage_metrics": _active_coverage_metrics,
		"runtime": _runtime_manifest(),
		"files": output_files,
		"material_state": "Source ShaderMaterials are cloned per surface; selected groom-level material_override values are temporarily cleared so per-surface variant/diagnostic overrides take precedence, then restored alongside surface overrides. Mesh and source material resources are never edited.",
		"comparison_validity": _comparison_validity_manifest(),
	}
	if not _write_text(_run_directory.path_join("run_manifest.json"), JSON.stringify(manifest, "\t")):
		return false

	var csv := "sample_index,frame,cpu_ms,gpu_ms,visible_objects,visible_primitives,visible_draw_calls,shadow_objects,shadow_primitives,shadow_draw_calls\n"
	for sample in _samples:
		csv += "%d,%d,%s,%s,%d,%d,%d,%d,%d,%d\n" % [
			int(sample["sample_index"]),
			int(sample["frame"]),
			String.num(float(sample["cpu_ms"]), 6),
			String.num(float(sample["gpu_ms"]), 6),
			int(sample["visible_objects"]),
			int(sample["visible_primitives"]),
			int(sample["visible_draw_calls"]),
			int(sample["shadow_objects"]),
			int(sample["shadow_primitives"]),
			int(sample["shadow_draw_calls"]),
		]
	if not _write_text(_run_directory.path_join("samples.csv"), csv):
		return false

	var metric_names := [
		"cpu_ms",
		"gpu_ms",
		"visible_objects",
		"visible_primitives",
		"visible_draw_calls",
		"shadow_objects",
		"shadow_primitives",
		"shadow_draw_calls",
	]
	var statistics := {}
	for metric_name in metric_names:
		var values: Array = []
		for sample in _samples:
			values.append(float(sample[metric_name]))
		statistics[metric_name] = {
			"median": _percentile(values, 0.50),
			"p95": _percentile(values, 0.95),
		}

	var summary := {
		"schema_version": 1,
		"timestamp": _run_timestamp,
		"suite_id": String(_active_suite_id),
		"case_id": String(_active_case_id),
		"repeat": _active_case_repeat,
		"mode": mode_name,
		"variant": variant_name,
		"sample_count": _samples.size(),
		"captures": _active_capture_records,
		"coverage_metrics": _active_coverage_metrics,
		"comparison_validity": _comparison_validity_manifest(),
		"statistics": statistics,
	}
	if not _write_text(_run_directory.path_join("summary.json"), JSON.stringify(summary, "\t")):
		return false
	return true


func _write_suite_manifest() -> bool:
	var manifest := {
		"schema_version": 1,
		"timestamp": _suite_timestamp,
		"suite_id": String(_resource_string_name(_suite_resource, &"id", &"")),
		"display_name": _resource_string(_suite_resource, &"display_name", ""),
		"output_subdirectory": _resource_string(_suite_resource, &"output_subdirectory", ""),
		"case_count": _suite_cases.size(),
		"completed_runs": _suite_results.size(),
		"cases": _suite_results,
		"runtime": _runtime_manifest(),
		"comparison_validity": _comparison_validity_manifest(),
		"files": ["suite_manifest.json"],
	}
	return _write_text(_suite_directory.path_join("suite_manifest.json"), JSON.stringify(manifest, "\t"))


func _camera_manifest() -> Dictionary:
	var benchmark_camera := get_node_or_null(benchmark_camera_path) as Camera3D
	if not benchmark_camera:
		return {
			"id": String(_active_case_camera_id),
		}
	return {
		"id": String(_active_case_camera_id),
		"transform": _transform_manifest(benchmark_camera.transform),
		"fov": benchmark_camera.fov,
		"near": benchmark_camera.near,
		"far": benchmark_camera.far,
	}


func _lighting_manifest() -> Dictionary:
	return {
		"id": String(_active_case_lighting_id),
		"name": _active_case_lighting_name,
		"notes": _active_case_lighting_notes,
		"instantiated": is_instance_valid(_active_lighting_rig),
	}


func _transform_manifest(value: Transform3D) -> Dictionary:
	return {
		"basis": [
			[value.basis.x.x, value.basis.x.y, value.basis.x.z],
			[value.basis.y.x, value.basis.y.y, value.basis.y.z],
			[value.basis.z.x, value.basis.z.y, value.basis.z.z],
		],
		"origin": [value.origin.x, value.origin.y, value.origin.z],
	}


func _runtime_manifest() -> Dictionary:
	var version_info: Dictionary = Engine.get_version_info()
	return {
		"godot_version": String(version_info.get("string", "unknown")),
		"render_method": String(ProjectSettings.get_setting("rendering/renderer/rendering_method", "unknown")),
		"gpu_adapter": RenderingServer.get_video_adapter_name(),
		"gpu_api": RenderingServer.get_video_adapter_api_version(),
		"driver": String(ProjectSettings.get_setting("rendering/driver/driver_name", "unknown")),
		"os": OS.get_name(),
	}


func _comparison_validity_manifest() -> Dictionary:
	return {
		"schema": COMPARISON_VALIDITY_SCHEMA,
		"marker": COMPARISON_VALIDITY_MARKER,
		"status": "valid_for_variant_comparison",
		"material_override_precedence_repaired": true,
	}


func _ensure_output_directory(path: String) -> bool:
	var directory_error: Error = DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path))
	if directory_error == OK or directory_error == ERR_ALREADY_EXISTS:
		return true
	_record_persistence_failure("Unable to create output directory '%s': %s" % [path, directory_error])
	return false


func _write_text(path: String, contents: String) -> bool:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_record_persistence_failure("Unable to open output file '%s': %s" % [path, FileAccess.get_open_error()])
		return false
	file.store_string(contents)
	var write_error: Error = file.get_error()
	file.close()
	if write_error != OK:
		_record_persistence_failure("Unable to write output file '%s': %s" % [path, write_error])
		return false
	return true


func _record_persistence_failure(message: String) -> void:
	last_persistence_error = message
	push_warning(message)
	persistence_failed.emit(message)


func _handle_run_persistence_failure(run_token: int) -> void:
	if run_token != _run_token:
		return
	_capture_requested = false
	if _suite_resource and _suite_active:
		_fail_active_suite()
	else:
		_restore_failed_resource_run()
	benchmark_state = BenchmarkState.COMPLETE


func _restore_failed_resource_run() -> void:
	_capture_requested = false
	_restore_original_surface_state()
	_restore_scene_state()
	_restore_benchmark_environment()
	_suite_active = false
	_suite_resource = null
	_suite_cases.clear()
	_suite_results.clear()
	_reset_case_metadata()


func _fail_active_suite() -> void:
	if not _suite_active or _suite_resource == null or _suite_terminal_emitted:
		return
	var failed_suite_id: StringName = _resource_string_name(_suite_resource, &"id", &"")
	_suite_terminal_emitted = true
	_restore_original_surface_state()
	_restore_scene_state()
	_restore_benchmark_environment()
	suite_completed.emit(false, failed_suite_id)
	_suite_active = false
	_suite_resource = null
	_suite_cases.clear()
	_suite_results.clear()
	_reset_case_metadata()


func _percentile(values: Array, percentile: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted: Array = values.duplicate()
	sorted.sort()
	var index := clampi(int(ceil(float(sorted.size() - 1) * percentile)), 0, sorted.size() - 1)
	return float(sorted[index])


func _make_run_timestamp() -> String:
	var date_time := Time.get_datetime_string_from_system(true).replace(":", "-").replace("T", "_")
	return "%s_%d" % [date_time, Time.get_ticks_msec()]


func _mode_name(mode: int) -> String:
	return MODE_NAMES[clampi(mode, 0, MODE_NAMES.size() - 1)]


func _variant_name(variant_id: int) -> String:
	return VARIANT_NAMES[clampi(variant_id, 0, VARIANT_NAMES.size() - 1)]
