extends Node

## First-slice benchmark controller for the ten direct hair children in main.tscn.
## The controller never edits a mesh material resource. Variant materials are per-surface
## ShaderMaterial clones installed through set_surface_override_material().

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

const COVERAGE_CONTROL_SHADER: Shader = preload("res://benchmark/shaders/hair_coverage_control.gdshader")
const CURRENT_MARSCHNER_SHADER: Shader = preload("res://benchmark/reference/baseline_hair.gdshader")
const APPROX_KAJIYA_KAY_SHADER: Shader = preload("res://assets/hair/materials/shaders/hair_approx.gdshader")

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
@export var world_environment_path: NodePath = NodePath("../WorldEnvironment")
@export var fixture_camera_path: NodePath = NodePath("../TestSceneHost/Main/Camera3D")
@export var fixture_light_path: NodePath = NodePath("../TestSceneHost/Main/DirectionalLight3D")
@export var fixture_environment_path: NodePath = NodePath("../TestSceneHost/Main/WorldEnvironment")

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
var _viewport_quality_saved := false
var _saved_viewport_use_taa := false
var _saved_viewport_scaling_3d_mode := Viewport.Scaling3DMode.SCALING_3D_MODE_BILINEAR
var _saved_viewport_scaling_3d_scale := 1.0
var _debug_manager: Node
var _debug_manager_overlay_saved := false
var _debug_manager_overlay_state_saved := false
var _benchmark_environment_active := false


func _ready() -> void:
	_configure_benchmark_environment()
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_disable_fixture_nodes()
	_discover_grooms()
	if auto_start_smoke:
		call_deferred("start_smoke")


func _process(_delta: float) -> void:
	_lock_benchmark_environment()
	match benchmark_state:
		BenchmarkState.PREWARM:
			_advance_timing_state(prewarm_frames, BenchmarkState.SETTLE)
		BenchmarkState.SETTLE:
			_advance_timing_state(settle_frames, BenchmarkState.SAMPLE)
		BenchmarkState.SAMPLE:
			# RenderingServer returns the completed/previous viewport frame here.
			_collect_sample()
			_state_frame += 1
			if _state_frame >= sample_frames:
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
	_configure_benchmark_environment()
	_run_token += 1
	_capture_requested = false
	_restore_original_surface_state()
	_discover_grooms()

	_active_mode = benchmark_mode if requested_mode < 0 else clampi(requested_mode, 0, BenchmarkMode.REPRESENTATIVE_DEFAULT)
	_active_variant = benchmark_variant if requested_variant < 0 else clampi(requested_variant, 0, BenchmarkVariant.APPROX_KAJIYA_KAY)
	_active_individual_groom = individual_groom if requested_groom == &"" else requested_groom
	apply_variant(_active_variant)
	_apply_display_mode(BenchmarkMode.NO_HAIR if _active_variant == BenchmarkVariant.NO_HAIR else _active_mode)

	_samples.clear()
	_state_frame = 0
	_run_timestamp = _make_run_timestamp()
	_run_directory = output_root.path_join(_run_timestamp)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_run_directory))
	benchmark_state = BenchmarkState.PREWARM


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


## Restores original visibility and every saved surface override, then stops any run.
func reset_benchmark() -> void:
	_run_token += 1
	_capture_requested = false
	benchmark_state = BenchmarkState.IDLE
	_state_frame = 0
	_restore_original_surface_state()
	_restore_benchmark_environment()


func _exit_tree() -> void:
	_run_token += 1
	_capture_requested = false
	_restore_original_surface_state()
	_restore_benchmark_environment()


func _configure_benchmark_environment() -> void:
	if _benchmark_environment_active:
		_lock_benchmark_environment()
		return

	var viewport := get_viewport()
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
	var viewport := get_viewport()
	if viewport:
		viewport.use_taa = false
		viewport.scaling_3d_mode = Viewport.Scaling3DMode.SCALING_3D_MODE_BILINEAR
		viewport.scaling_3d_scale = 1.0
	if _debug_manager_overlay_state_saved and is_instance_valid(_debug_manager):
		_debug_manager.set(&'should_render_imgui', false)


func _restore_benchmark_environment() -> void:
	_benchmark_environment_active = false
	var viewport := get_viewport()
	if _viewport_quality_saved and viewport:
		viewport.use_taa = _saved_viewport_use_taa
		viewport.scaling_3d_mode = _saved_viewport_scaling_3d_mode
		viewport.scaling_3d_scale = _saved_viewport_scaling_3d_scale
	_viewport_quality_saved = false

	if _debug_manager_overlay_state_saved and is_instance_valid(_debug_manager):
		_debug_manager.set(&'should_render_imgui', _debug_manager_overlay_saved)
	_debug_manager_overlay_state_saved = false


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
			"original_visible": groom.visible,
			"surfaces": surfaces,
		})

	_original_state_saved = not groom_catalog.is_empty()


func _apply_shader_variant(shader: Shader) -> void:
	for groom_data in groom_catalog:
		var groom := groom_data["node"] as MeshInstance3D
		if not is_instance_valid(groom):
			continue
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


func _advance_timing_state(frame_limit: int, next_state: int) -> void:
	_state_frame += 1
	if _state_frame >= frame_limit:
		benchmark_state = next_state
		_state_frame = 0


func _collect_sample() -> void:
	var viewport_rid := get_viewport().get_viewport_rid()
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


func _capture_after_frame_post_draw(run_token: int) -> void:
	if _capture_requested:
		return
	_capture_requested = true
	# Capture is intentionally outside SAMPLE and waits for the rendered frame.
	var capture_count := maxi(capture_frames, 1)
	for capture_index in capture_count:
		await RenderingServer.frame_post_draw
		if run_token != _run_token or not is_inside_tree():
			return
		if capture_index == capture_count - 1:
			var viewport_texture := get_viewport().get_texture()
			if viewport_texture:
				var image := viewport_texture.get_image()
				if image:
					image.save_png(_run_directory.path_join("color.png"))

	_write_run_outputs()
	benchmark_state = BenchmarkState.COMPLETE
	_capture_requested = false


func _write_run_outputs() -> void:
	var mode_name := _mode_name(_active_mode)
	var variant_name := _variant_name(_active_variant)
	var baseline_commit := FileAccess.get_file_as_string("res://benchmark/reference/BASELINE_COMMIT.txt").strip_edges()
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
		"mode": mode_name,
		"variant": variant_name,
		"individual_groom": String(_active_individual_groom),
		"state_sequence": ["PREWARM", "SETTLE", "SAMPLE", "CAPTURE", "COMPLETE"],
		"prewarm_frames": prewarm_frames,
		"settle_frames": settle_frames,
		"sample_frames": sample_frames,
		"capture_frames": capture_frames,
		"sample_count": _samples.size(),
		"baseline_commit": baseline_commit,
		"grooms": catalog_manifest,
		"viewport_size": [get_viewport().size.x, get_viewport().size.y],
		"files": ["run_manifest.json", "samples.csv", "summary.json", "color.png"],
		"material_state": "Source ShaderMaterials are cloned per surface; only surface overrides are replaced and restored.",
	}
	_write_text(_run_directory.path_join("run_manifest.json"), JSON.stringify(manifest, "\t"))

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
	_write_text(_run_directory.path_join("samples.csv"), csv)

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
		"mode": mode_name,
		"variant": variant_name,
		"sample_count": _samples.size(),
		"statistics": statistics,
	}
	_write_text(_run_directory.path_join("summary.json"), JSON.stringify(summary, "\t"))


func _write_text(path: String, contents: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(contents)


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
