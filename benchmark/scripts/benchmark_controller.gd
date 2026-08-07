extends Node

## First-slice benchmark controller for the ten direct hair children in main.tscn.
## The controller never edits a mesh material resource. Variant materials are per-surface
## ShaderMaterial clones installed through set_surface_override_material().

signal suite_completed(success: bool, suite_id: StringName)
signal start_failed(message: String)
signal persistence_failed(message: String)
signal benchmark_state_changed(state: int)
signal preview_applied(success: bool)

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
	BUILTIN_ALPHA_HASH_CONTROL,
	FAST_MARSCHNER_ANALYTIC,
	FAST_MARSCHNER_LUT,
	FAST_MARSCHNER_DUAL_SCATTER,
	FAST_MARSCHNER_ENVIRONMENT,
	FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED,
	FAST_MARSCHNER_R_STANDARDIZED_LUT,
}

const MODE_NAMES := ["NO_HAIR", "INDIVIDUAL_GROOM", "ALL_GROOMS", "REPRESENTATIVE_DEFAULT"]
const VARIANT_NAMES := ["NO_HAIR", "COVERAGE_CONTROL", "CURRENT_MARSCHNER_BASELINE", "APPROX_KAJIYA_KAY", "BUILTIN_ALPHA_HASH_CONTROL", "FAST_MARSCHNER_ANALYTIC", "FAST_MARSCHNER_LUT", "FAST_MARSCHNER_DUAL_SCATTER", "FAST_MARSCHNER_ENVIRONMENT", "FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED", "FAST_MARSCHNER_R_STANDARDIZED_LUT"]
const STATE_NAMES := ["IDLE", "PREWARM", "SETTLE", "SAMPLE", "CAPTURE", "COMPLETE"]

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
## Preview-only variant of the baseline shader: identical rendering code and
## interface plus the opt-in freeze_bayer_phase uniform. Timed runs keep using
## CURRENT_MARSCHNER_SHADER so the timed reference stays byte-identical.
const BASELINE_PREVIEW_SHADER: Shader = preload("res://benchmark/reference/baseline_hair_preview.gdshader")
const APPROX_KAJIYA_KAY_SHADER: Shader = preload("res://assets/hair/materials/shaders/hair_approx.gdshader")
const FAST_MARSCHNER_SHADER: Shader = preload("res://assets/hair/materials/shaders/hair_marschner_fast.gdshader")
## Committed azimuthal LUT data for the FAST_MARSCHNER_LUT variant (see
## benchmark/tools/generate_marschner_azimuthal_lut.gd).
const FAST_MARSCHNER_LUT_DATA: Resource = preload("res://benchmark/resources/luts/fast_marschner_azimuthal_lut_64.res")
## Committed Stage-B preintegrated dual-scatter LUT data for the
## FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED variant (see
## benchmark/tools/generate_marschner_dual_scatter_lut.gd and
## validate_marschner_dual_scatter_lut.gd).
const FAST_MARSCHNER_DUAL_SCATTER_LUT_DATA: Resource = preload("res://benchmark/resources/luts/fast_marschner_dual_scatter_lut_64.res")
## Diagnostic wrapper for the Phase 4 standardized projected-R LUT path
## (FM_R_STANDARDIZED_LUT_MODE 1): shares the same body include as the
## shipping fast wrapper, so the material contract is identical.
const FAST_MARSCHNER_R_STANDARDIZED_LUT_SHADER: Shader = preload("res://assets/hair/materials/shaders/hair_marschner_fast_r_standardized_lut.gdshader")
## Committed 256x256x128 RGBAF standardized projected-R kernel LUT data for
## the FAST_MARSCHNER_R_STANDARDIZED_LUT variant (see
## benchmark/tools/generate_marschner_r_standardized_lut.gd and
## benchmark/reference/fast_marschner_r_standardized_kernel_reference.gd).
const FAST_MARSCHNER_R_STANDARDIZED_LUT_DATA: Resource = preload("res://benchmark/resources/luts/fast_marschner_r_standardized_lut_256x256x128.res")
## The committed azimuthal LUT is numerically validated only for azimuthal
## roughness >= this value (validate_marschner_azimuthal_lut.gd's realistic
## gate). FAST_MARSCHNER_LUT rejects lower values at the application seam;
## FAST_MARSCHNER_ANALYTIC is unrestricted.
const LUT_MIN_AZIMUTHAL_ROUGHNESS := 0.3
## Committed equirectangular environment stand-in (GradientTexture2D: dark
## zenith, warm horizon, cool sky) for the FAST_MARSCHNER_ENVIRONMENT variant.
const FAST_MARSCHNER_ENVIRONMENT_TEXTURE: Texture2D = preload("res://benchmark/resources/textures/environment_gradient.tres")
const COVERAGE_WHITE_THRESHOLD: float = 0.95

## Benchmark time scale during runs. A tiny positive scale keeps Godot shader TIME
## effectively frozen while the engine frame delta stays positive: with an exact
## zero scale the imgui-godot addon's NewFrame delta is 0 and it logs an IM_ASSERT
## error every frame. At this scale the production TIME*500 Bayer coordinate offset
## only advances one integer texel every ~33 minutes of real time, so the hash
## pattern is constant for normal benchmark durations.
const BENCHMARK_TIME_SCALE: float = 1e-6
## The production hash shaders offset their Bayer pattern by TIME * 500 texels
## (see hair.gdshader / hair_coverage_control.gdshader discard id).
const HASH_BAYER_TIME_FACTOR: float = 500.0
## Scene-counter metrics whose stability across the sample window gates run
## validity: the scene is static and TIME is effectively frozen, so any variance
## in these counters indicates an unstable or mismatched run.
const STABILITY_METRIC_NAMES := [
	"visible_objects",
	"visible_primitives",
	"visible_draw_calls",
	"shadow_objects",
	"shadow_primitives",
	"shadow_draw_calls",
]
const WINDOW_MODE_NAMES := ["windowed", "minimized", "maximized", "fullscreen", "exclusive_fullscreen"]
const VSYNC_MODE_NAMES := ["disabled", "enabled", "adaptive", "mailbox"]
## Resource-backed catalog of stable groom definitions (display metadata source).
const GROOM_CATALOG_RESOURCE_PATH := "res://benchmark/resources/grooms/hair_groom_catalog.tres"
## Material adapter script; the const shadows the class_name so parsing never
## depends on the global class cache being regenerated.
const HairMaterialAdapter := preload("res://benchmark/scripts/hair_material_adapter.gd")

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
@export_enum("NO_HAIR", "COVERAGE_CONTROL", "CURRENT_MARSCHNER_BASELINE", "APPROX_KAJIYA_KAY", "BUILTIN_ALPHA_HASH_CONTROL", "FAST_MARSCHNER_ANALYTIC", "FAST_MARSCHNER_LUT", "FAST_MARSCHNER_DUAL_SCATTER", "FAST_MARSCHNER_ENVIRONMENT", "FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED", "FAST_MARSCHNER_R_STANDARDIZED_LUT") var benchmark_variant: int = BenchmarkVariant.CURRENT_MARSCHNER_BASELINE
@export var auto_start_smoke: bool = false
@export_range(0, 100000, 1) var prewarm_frames: int = PREWARM_DEFAULT
@export_range(0, 100000, 1) var settle_frames: int = SETTLE_DEFAULT
@export_range(1, 100000, 1) var sample_frames: int = SAMPLE_DEFAULT
@export_range(1, 100, 1) var capture_frames: int = CAPTURE_DEFAULT
@export_dir var output_root: String = "user://hair_benchmarks"

## Public catalog: one dictionary per direct MeshInstance3D child of Head.
## Each dictionary contains the transient instance id, stable groom_id/name,
## display metadata, node, original_visible, and surfaces.
var groom_catalog: Array[Dictionary] = []
var benchmark_state: int = BenchmarkState.IDLE

var _head: MeshInstance3D
var _original_state_saved := false
var _active_mode := BenchmarkMode.REPRESENTATIVE_DEFAULT
var _active_variant := BenchmarkVariant.CURRENT_MARSCHNER_BASELINE
var _active_individual_groom: StringName = &"Blowout"
var _active_case_profile_id: StringName = &"source_current"
var _groom_metadata_cache: Dictionary = {}
var _material_adapter: HairMaterialAdapter
var _time_scale_saved := false
var _saved_time_scale := 1.0
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
				_set_benchmark_state(BenchmarkState.CAPTURE)
				_state_frame = 0
				_capture_after_frame_post_draw(_run_token)
		BenchmarkState.CAPTURE, BenchmarkState.COMPLETE, BenchmarkState.IDLE:
			pass


## Starts the configured smoke run. This is intentionally public for programmatic starts.
func start_smoke() -> void:
	start_benchmark(benchmark_mode, benchmark_variant, individual_groom)


## Selects and applies a non-timed preview. This is the public bridge for tools
## that need to compare variants without entering PREWARM/SAMPLE or writing any
## benchmark artifacts. Material construction remains entirely in apply_variant().
## Selects and applies a non-timed preview. This is the public bridge for tools
## that need to compare variants without entering PREWARM/SAMPLE or writing any
## benchmark artifacts. The optional settings dictionary drives the UI's single
## FAST_MARSCHNER entry (variant 5): canonical-shader combinations are applied
## directly to the live fast overrides; all existing 3-argument callers and the
## internal timed benchmark paths are unchanged.
func apply_preview(requested_mode: int, requested_variant: int, requested_groom: StringName = &"", settings: Dictionary = {}) -> bool:
	if _is_timed_state():
		_record_start_failure("Preview changes are disabled while a benchmark is running.")
		preview_applied.emit(false)
		return false

	_active_mode = clampi(requested_mode, BenchmarkMode.NO_HAIR, BenchmarkMode.REPRESENTATIVE_DEFAULT)
	_active_variant = clampi(requested_variant, BenchmarkVariant.NO_HAIR, BenchmarkVariant.FAST_MARSCHNER_R_STANDARDIZED_LUT)
	if requested_groom != &"":
		_active_individual_groom = requested_groom
	last_start_error = ""
	last_persistence_error = ""
	var applied := apply_variant(_active_variant, true)
	# Settings-driven preview seam: the UI's FAST_MARSCHNER entry applies the
	# canonical fast shader (variant 5) and then settings directly on the live
	# overrides. A failure restores the original surface state.
	if applied and _active_variant == BenchmarkVariant.FAST_MARSCHNER_ANALYTIC and not settings.is_empty():
		applied = _apply_preview_settings(settings)
		if not applied:
			_restore_original_surface_state()
	# Interactive previews freeze the Bayer phase of every TIME-discard shader
	# (custom coverage control, the frozen Marschner baseline, and all
	# FAST_MARSCHNER_* tier-2 variants) so the strand pattern is deterministic
	# while previewing. Timed runs re-apply fresh clones from the source
	# materials (uniform default false), so benchmark behavior and timing
	# semantics are unchanged.
	if applied and _variant_freezes_preview_bayer():
		_freeze_preview_bayer_phase()
	_set_benchmark_state(BenchmarkState.IDLE)
	if applied:
		# A completed timed run is no longer the active state after a manual preview.
		# The completed samples remain available to the existing benchmark output
		# path, but the UI correctly labels this selection as a fresh preview.
		pass
	preview_applied.emit(applied)
	return applied


## Applies a preview settings dictionary directly to the live
## FAST_MARSCHNER_ANALYTIC overrides (the UI settings seam). Supported keys:
## use_azimuthal_lut, use_dual_scatter, use_preintegrated_dual_scatter,
## use_environment, dual_scatter_strength, dual_scatter_density,
## environment_strength. use_preintegrated_dual_scatter implies
## use_dual_scatter=true. Requested LUTs/textures are built through the
## adapter's cached builders; if any requested resource cannot be built the
## method records a clear start failure and returns false so the caller
## restores the original surface state. Strength/density values are clamped to
## their shader hint ranges.
func _apply_preview_settings(settings: Dictionary) -> bool:
	var use_lut := bool(settings.get(&"use_azimuthal_lut", false))
	var use_dual := bool(settings.get(&"use_dual_scatter", false))
	var use_preintegrated := bool(settings.get(&"use_preintegrated_dual_scatter", false))
	var use_environment := bool(settings.get(&"use_environment", false))
	if use_preintegrated:
		use_dual = true

	var lut_texture: Texture3D = null
	if use_lut:
		lut_texture = _material_adapter.azimuthal_lut_texture(FAST_MARSCHNER_LUT_DATA)
		if lut_texture == null:
			_record_start_failure("Preview settings could not be applied: the azimuthal LUT failed to build a texture.")
			return false
	var dual_lut_texture: Texture2D = null
	if use_preintegrated:
		dual_lut_texture = _material_adapter.dual_scatter_lut_texture(FAST_MARSCHNER_DUAL_SCATTER_LUT_DATA)
		if dual_lut_texture == null:
			_record_start_failure("Preview settings could not be applied: the preintegrated dual-scatter LUT failed to build a texture.")
			return false
	if use_environment and (FAST_MARSCHNER_ENVIRONMENT_TEXTURE == null or FAST_MARSCHNER_ENVIRONMENT_TEXTURE.get_width() <= 0):
		_record_start_failure("Preview settings could not be applied: the environment texture failed to bind.")
		return false

	var dual_strength := clampf(float(settings.get(&"dual_scatter_strength", 0.5)), 0.0, 2.0)
	var dual_density := clampf(float(settings.get(&"dual_scatter_density", 0.5)), 0.0, 1.0)
	var env_strength := clampf(float(settings.get(&"environment_strength", 1.0)), 0.0, 2.0)

	for groom_data in groom_catalog:
		var groom := groom_data["node"] as MeshInstance3D
		if not is_instance_valid(groom):
			continue
		for surface_data in groom_data["surfaces"]:
			if not bool(surface_data["selected"]):
				continue
			var override_material := groom.get_surface_override_material(int(surface_data["surface_index"])) as ShaderMaterial
			if not override_material:
				continue
			override_material.set(&"shader_parameter/use_azimuthal_lut", use_lut)
			override_material.set(&"shader_parameter/use_dual_scatter", use_dual)
			override_material.set(&"shader_parameter/use_preintegrated_dual_scatter", use_preintegrated)
			override_material.set(&"shader_parameter/use_environment", use_environment)
			override_material.set(&"shader_parameter/dual_scatter_strength", dual_strength)
			override_material.set(&"shader_parameter/dual_scatter_density", dual_density)
			override_material.set(&"shader_parameter/environment_strength", env_strength)
			if lut_texture:
				override_material.set(&"shader_parameter/azimuthal_lut", lut_texture)
				override_material.set(&"shader_parameter/azimuthal_lut_eta", float(FAST_MARSCHNER_LUT_DATA.get(&"eta")))
			if dual_lut_texture:
				override_material.set(&"shader_parameter/dual_scatter_lut", dual_lut_texture)
				override_material.set(&"shader_parameter/dual_scatter_lut_eta", float(FAST_MARSCHNER_DUAL_SCATTER_LUT_DATA.get(&"eta")))
				# U-axis tau_max metadata: the runtime maps the LUT domain with
				# the resource's own tau_max so it never silently claims the
				# wider legacy 16-wide domain.
				var dual_scatter_tau_max: Variant = FAST_MARSCHNER_DUAL_SCATTER_LUT_DATA.get(&"tau_max")
				if dual_scatter_tau_max is float and float(dual_scatter_tau_max) > 0.0:
					override_material.set(&"shader_parameter/dual_scatter_lut_tau_max", dual_scatter_tau_max)
			if use_environment:
				override_material.set(&"shader_parameter/environment_texture", FAST_MARSCHNER_ENVIRONMENT_TEXTURE)
	return true


## Returns true when the active variant's live overrides carry the opt-in
## freeze_bayer_phase preview uniform: COVERAGE_CONTROL, the frozen
## CURRENT_MARSCHNER_BASELINE preview shader, and every FAST_MARSCHNER_* tier-2
## variant share the same TIME-driven Bayer discard. The Kajiya and built-in
## alpha-hash variants are not frozen.
func _variant_freezes_preview_bayer() -> bool:
	match _active_variant:
		BenchmarkVariant.COVERAGE_CONTROL, \
		BenchmarkVariant.CURRENT_MARSCHNER_BASELINE, \
		BenchmarkVariant.FAST_MARSCHNER_ANALYTIC, \
		BenchmarkVariant.FAST_MARSCHNER_LUT, \
		BenchmarkVariant.FAST_MARSCHNER_DUAL_SCATTER, \
		BenchmarkVariant.FAST_MARSCHNER_ENVIRONMENT, \
		BenchmarkVariant.FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED, \
		BenchmarkVariant.FAST_MARSCHNER_R_STANDARDIZED_LUT:
			return true
		_:
			return false


## Sets freeze_bayer_phase on the live preview surface overrides so the
## interactive preview's alpha-coverage pattern is deterministic. Only selected
## surfaces are touched; the uniform exists solely on the TIME-discard preview
## shaders (coverage control, the frozen baseline, and every FAST_MARSCHNER_*
## tier-2 variant; Kajiya and built-in alpha hash are not frozen; timed runs
## leave it at the shader default).
func _freeze_preview_bayer_phase() -> void:
	for groom_data in groom_catalog:
		var groom := groom_data["node"] as MeshInstance3D
		if not is_instance_valid(groom):
			continue
		for surface_data in groom_data["surfaces"]:
			if not bool(surface_data["selected"]):
				continue
			var override_material := groom.get_surface_override_material(int(surface_data["surface_index"])) as ShaderMaterial
			if override_material:
				override_material.set(&"shader_parameter/freeze_bayer_phase", true)


## Binds the committed azimuthal LUT to the live FAST_MARSCHNER_LUT surface
## overrides: sets use_azimuthal_lut=true and the Texture3D built from the
## committed data (declaration-gated: only the fast shader declares these
## parameters). Timed runs that select this variant keep the same binding; the
## analytic variant never enables it.
## Returns false (recording a start failure) when the committed LUT data
## cannot be built into a usable texture, so apply_preview()/benchmark starts
## reject the LUT variant instead of silently continuing.
func _apply_fast_lut_binding() -> bool:
	# The LUT is validated only for azimuthal_roughness >=
	# LUT_MIN_AZIMUTHAL_ROUGHNESS; reject any selected surface below that range
	# (or with an invalid parameter) so apply_preview/start_case restore the
	# original state instead of sampling out-of-range LUT cells. The check runs
	# on the live clones, after profile/source parameters were applied.
	for groom_data in groom_catalog:
		var groom := groom_data["node"] as MeshInstance3D
		if not is_instance_valid(groom):
			continue
		for surface_data in groom_data["surfaces"]:
			if not bool(surface_data["selected"]):
				continue
			var override_material := groom.get_surface_override_material(int(surface_data["surface_index"])) as ShaderMaterial
			if not override_material:
				continue
			var roughness_value: Variant = override_material.get(&"shader_parameter/azimuthal_roughness")
			if not (roughness_value is float or roughness_value is int):
				_record_start_failure(
					"FAST_MARSCHNER_LUT could not be applied: groom '%s' surface %d has an invalid azimuthal_roughness (%s)."
					% [String(groom_data["name"]), int(surface_data["surface_index"]), roughness_value]
				)
				return false
			var roughness: float = float(roughness_value)
			if roughness < LUT_MIN_AZIMUTHAL_ROUGHNESS:
				_record_start_failure(
					"FAST_MARSCHNER_LUT could not be applied: groom '%s' surface %d azimuthal_roughness %.3f is below the supported minimum %.1f (the LUT is validated for roughness >= 0.3; use FAST_MARSCHNER_ANALYTIC instead)."
					% [String(groom_data["name"]), int(surface_data["surface_index"]), roughness, LUT_MIN_AZIMUTHAL_ROUGHNESS]
				)
				return false
	var lut_texture: Texture3D = _material_adapter.azimuthal_lut_texture(FAST_MARSCHNER_LUT_DATA)
	if lut_texture == null:
		_record_start_failure("FAST_MARSCHNER_LUT could not be applied: the committed LUT data failed to build a texture.")
		return false
	for groom_data in groom_catalog:
		var groom := groom_data["node"] as MeshInstance3D
		if not is_instance_valid(groom):
			continue
		for surface_data in groom_data["surfaces"]:
			if not bool(surface_data["selected"]):
				continue
			var override_material := groom.get_surface_override_material(int(surface_data["surface_index"])) as ShaderMaterial
			if override_material:
				# Variant identity is authoritative: the LUT mode never combines
				# with dual scattering, regardless of profile fields.
				override_material.set(&"shader_parameter/use_azimuthal_lut", true)
				override_material.set(&"shader_parameter/use_dual_scatter", false)
				override_material.set(&"shader_parameter/use_preintegrated_dual_scatter", false)
				override_material.set(&"shader_parameter/use_environment", false)
				override_material.set(&"shader_parameter/azimuthal_lut", lut_texture)
				override_material.set(&"shader_parameter/azimuthal_lut_eta", float(FAST_MARSCHNER_LUT_DATA.get(&"eta")))
	return true


## Enables the Phase 4 standardized projected-R LUT path on the live
## FAST_MARSCHNER_R_STANDARDIZED_LUT surface overrides: binds the committed
## 256x256x128 Texture3D built from the standardized-R LUT data, sets
## r_standardized_lut_log_decode=false (the linear-Q decode is the default
## contract; the runtime test toggles it on the live clone), and forces
## use_azimuthal_lut=false / use_dual_scatter=false /
## use_preintegrated_dual_scatter=false / use_environment=false (variant
## identity is authoritative: the standardized-R diagnostic never combines
## with the azimuthal LUT, dual scattering, or the environment slice).
## Returns false (recording a start failure) when the committed LUT data
## cannot be built into a usable Texture3D, so apply_preview()/benchmark
## starts reject the variant instead of silently sampling an empty texture.
func _apply_r_standardized_lut_binding() -> bool:
	var lut_texture: Texture3D = _material_adapter.standardized_r_lut_texture(FAST_MARSCHNER_R_STANDARDIZED_LUT_DATA)
	if lut_texture == null:
		_record_start_failure("FAST_MARSCHNER_R_STANDARDIZED_LUT could not be applied: the committed LUT data failed to build a texture.")
		return false
	for groom_data in groom_catalog:
		var groom := groom_data["node"] as MeshInstance3D
		if not is_instance_valid(groom):
			continue
		for surface_data in groom_data["surfaces"]:
			if not bool(surface_data["selected"]):
				continue
			var override_material := groom.get_surface_override_material(int(surface_data["surface_index"])) as ShaderMaterial
			if override_material:
				# Variant identity is authoritative: the standardized-R
				# diagnostic never combines with any other opt-in slice.
				override_material.set(&"shader_parameter/use_azimuthal_lut", false)
				override_material.set(&"shader_parameter/use_dual_scatter", false)
				override_material.set(&"shader_parameter/use_preintegrated_dual_scatter", false)
				override_material.set(&"shader_parameter/use_environment", false)
				override_material.set(&"shader_parameter/r_standardized_lut", lut_texture)
				override_material.set(&"shader_parameter/r_standardized_lut_log_decode", false)
	return true


## Enables the local dual-scattering slice on the live FAST_MARSCHNER_DUAL_SCATTER
## surface overrides: sets use_dual_scatter=true and forces use_azimuthal_lut=
## false and use_preintegrated_dual_scatter=false (variant identity is
## authoritative: variant 7 is the analytic Stage-A slice and never enables the
## Stage-B preintegrated path; the profile-driven strength and density are
## applied by the adapter's declaration-gated mapping). The analytic and LUT
## variants never enable dual scattering.
func _apply_dual_scatter_binding() -> bool:
	for groom_data in groom_catalog:
		var groom := groom_data["node"] as MeshInstance3D
		if not is_instance_valid(groom):
			continue
		for surface_data in groom_data["surfaces"]:
			if not bool(surface_data["selected"]):
				continue
			var override_material := groom.get_surface_override_material(int(surface_data["surface_index"])) as ShaderMaterial
			if override_material:
				override_material.set(&"shader_parameter/use_dual_scatter", true)
				override_material.set(&"shader_parameter/use_preintegrated_dual_scatter", false)
				override_material.set(&"shader_parameter/use_azimuthal_lut", false)
				override_material.set(&"shader_parameter/use_environment", false)
	return true


## Enables the Stage-B preintegrated (LUT-backed) dual-scattering slice on the
## live FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED surface overrides: forces
## use_dual_scatter=true and use_preintegrated_dual_scatter=true (variant
## identity is authoritative) and use_azimuthal_lut=false / use_environment=false,
## then binds the committed 2D LUT texture built from the raw data resource.
## Returns false (recording a start failure) when the committed LUT data
## cannot be built into a usable texture, so apply_preview()/benchmark starts
## reject the variant instead of silently continuing.
func _apply_preintegrated_dual_scatter_binding() -> bool:
	var lut_texture: Texture2D = _material_adapter.dual_scatter_lut_texture(FAST_MARSCHNER_DUAL_SCATTER_LUT_DATA)
	if lut_texture == null:
		_record_start_failure("FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED could not be applied: the committed LUT data failed to build a texture.")
		return false
	for groom_data in groom_catalog:
		var groom := groom_data["node"] as MeshInstance3D
		if not is_instance_valid(groom):
			continue
		for surface_data in groom_data["surfaces"]:
			if not bool(surface_data["selected"]):
				continue
			var override_material := groom.get_surface_override_material(int(surface_data["surface_index"])) as ShaderMaterial
			if override_material:
				override_material.set(&"shader_parameter/use_dual_scatter", true)
				override_material.set(&"shader_parameter/use_preintegrated_dual_scatter", true)
				override_material.set(&"shader_parameter/use_azimuthal_lut", false)
				override_material.set(&"shader_parameter/use_environment", false)
				override_material.set(&"shader_parameter/dual_scatter_lut", lut_texture)
				override_material.set(&"shader_parameter/dual_scatter_lut_eta", float(FAST_MARSCHNER_DUAL_SCATTER_LUT_DATA.get(&"eta")))
				# U-axis tau_max metadata: the runtime maps the LUT domain with
				# the resource's own tau_max so it never silently claims the
				# wider legacy 16-wide domain.
				var dual_scatter_tau_max: Variant = FAST_MARSCHNER_DUAL_SCATTER_LUT_DATA.get(&"tau_max")
				if dual_scatter_tau_max is float and float(dual_scatter_tau_max) > 0.0:
					override_material.set(&"shader_parameter/dual_scatter_lut_tau_max", dual_scatter_tau_max)
	return true


## Forces the full reference identity on live FAST_MARSCHNER_ANALYTIC surface
## overrides: use_azimuthal_lut=false, use_dual_scatter=false,
## use_preintegrated_dual_scatter=false, and use_environment=false. Variant
## identity is authoritative — profiles can provide fields, but they must never
## override these variant decisions.
func _apply_analytic_flag_binding() -> void:
	for groom_data in groom_catalog:
		var groom := groom_data["node"] as MeshInstance3D
		if not is_instance_valid(groom):
			continue
		for surface_data in groom_data["surfaces"]:
			if not bool(surface_data["selected"]):
				continue
			var override_material := groom.get_surface_override_material(int(surface_data["surface_index"])) as ShaderMaterial
			if override_material:
				override_material.set(&"shader_parameter/use_azimuthal_lut", false)
				override_material.set(&"shader_parameter/use_dual_scatter", false)
				override_material.set(&"shader_parameter/use_preintegrated_dual_scatter", false)
				override_material.set(&"shader_parameter/use_environment", false)


## Enables the fragment-stage environment response on the live
## FAST_MARSCHNER_ENVIRONMENT surface overrides: forces use_environment=true
## and use_azimuthal_lut=false / use_dual_scatter=false /
## use_preintegrated_dual_scatter=false (variant identity is authoritative),
## and binds the committed equirectangular environment texture.
## Returns false with a clear start failure if the texture cannot bind.
func _apply_environment_binding() -> bool:
	if FAST_MARSCHNER_ENVIRONMENT_TEXTURE == null or FAST_MARSCHNER_ENVIRONMENT_TEXTURE.get_width() <= 0:
		_record_start_failure("FAST_MARSCHNER_ENVIRONMENT could not be applied: the committed environment texture failed to bind.")
		return false
	for groom_data in groom_catalog:
		var groom := groom_data["node"] as MeshInstance3D
		if not is_instance_valid(groom):
			continue
		for surface_data in groom_data["surfaces"]:
			if not bool(surface_data["selected"]):
				continue
			var override_material := groom.get_surface_override_material(int(surface_data["surface_index"])) as ShaderMaterial
			if override_material:
				override_material.set(&"shader_parameter/use_environment", true)
				override_material.set(&"shader_parameter/use_azimuthal_lut", false)
				override_material.set(&"shader_parameter/use_dual_scatter", false)
				override_material.set(&"shader_parameter/use_preintegrated_dual_scatter", false)
				override_material.set(&"shader_parameter/environment_texture", FAST_MARSCHNER_ENVIRONMENT_TEXTURE)
	return true


## Returns true for the timed Fast Marschner variants that pin the shared-body
## material contract: FAST_MARSCHNER_ANALYTIC, FAST_MARSCHNER_LUT,
## FAST_MARSCHNER_DUAL_SCATTER, FAST_MARSCHNER_ENVIRONMENT,
## FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED, and
## FAST_MARSCHNER_R_STANDARDIZED_LUT all use the shared
## hair_marschner_fast_body.gdshaderinc body (the diagnostic wrapper only
## overrides the R-longitudinal selector), so the pinned preview/timing
## uniforms exist on every one of them.
func _variant_uses_timed_material_contract(variant_id: int) -> bool:
	match variant_id:
		BenchmarkVariant.FAST_MARSCHNER_ANALYTIC, \
		BenchmarkVariant.FAST_MARSCHNER_LUT, \
		BenchmarkVariant.FAST_MARSCHNER_DUAL_SCATTER, \
		BenchmarkVariant.FAST_MARSCHNER_ENVIRONMENT, \
		BenchmarkVariant.FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED, \
		BenchmarkVariant.FAST_MARSCHNER_R_STANDARDIZED_LUT:
			return true
		_:
			return false


## Pins the timed-material contract on the live FAST_MARSCHNER surface
## overrides: comparison_exposure_gain=1.0, lobe_scales=Vector3.ONE, and
## use_area_light_multipliers=true (the shared body's defaults, made explicit so
## benchmark artifacts prove unit exposure and lobe scales; the values mirror
## validate_fast_marschner_energy.gd's reference contract). Only selected
## surfaces are touched. Preview-only flows never call this: the visual
## comparison chooses its own presentation gain.
func _apply_timed_material_contract() -> void:
	for groom_data in groom_catalog:
		var groom := groom_data["node"] as MeshInstance3D
		if not is_instance_valid(groom):
			continue
		for surface_data in groom_data["surfaces"]:
			if not bool(surface_data["selected"]):
				continue
			var override_material := groom.get_surface_override_material(int(surface_data["surface_index"])) as ShaderMaterial
			if not override_material:
				continue
			override_material.set(&"shader_parameter/comparison_exposure_gain", 1.0)
			override_material.set(&"shader_parameter/lobe_scales", Vector3.ONE)
			override_material.set(&"shader_parameter/use_area_light_multipliers", true)


## Records the timed-material contract in run_manifest.json: the values pinned
## by _apply_timed_material_contract() on timed FAST_MARSCHNER runs, plus the
## "applied" flag so artifacts distinguish contract-pinned runs from variants
## that never receive the values (non-fast variants, preview-only flows).
func _timed_material_contract_manifest() -> Dictionary:
	return {
		"applied": _variant_uses_timed_material_contract(_active_variant),
		"comparison_exposure_gain": 1.0,
		"lobe_scales": [1.0, 1.0, 1.0],
		"use_area_light_multipliers": true,
		"note": "Timed FAST_MARSCHNER runs explicitly pin the shared-body preview/timing uniforms to their unit defaults (comparison_exposure_gain 1.0, lobe_scales 1.0, use_area_light_multipliers true) so benchmark artifacts prove unit exposure and lobe scales. Preview-only flows and non-fast variants never apply the contract; the standalone visual comparison chooses its own presentation gain.",
	}


## Returns the stable groom entries used by the preview selector. The returned
## dictionaries are metadata only; callers never receive material resources.
func get_preview_grooms() -> Array[Dictionary]:
	if groom_catalog.is_empty():
		_discover_grooms()
	var preview_grooms: Array[Dictionary] = []
	for groom_data in groom_catalog:
		preview_grooms.append({
			"groom_id": StringName(groom_data.get("groom_id", groom_data.get("name", &""))),
			"display_name": String(groom_data.get("display_name", groom_data.get("name", ""))),
			"category": String(groom_data.get("category", "")),
		})
	return preview_grooms


## Lightweight status snapshot for the optional preview UI. It reads renderer
## counters in memory only; it never opens files or touches the timed sample
## collection path. When a completed run exists, its last sample and validation
## are exposed as available benchmark evidence. Otherwise the values are live
## renderer telemetry and explicitly marked as preview-only.
func get_preview_status() -> Dictionary:
	var metrics := _preview_render_metrics()
	var has_benchmark_measurement := benchmark_state == BenchmarkState.COMPLETE and not _samples.is_empty()
	if has_benchmark_measurement:
		metrics = _samples.back().duplicate()
	var validation := {
		"status": "VALID" if has_benchmark_measurement and bool(_validation_result().get("valid", false)) else "PREVIEW ONLY",
		"valid": has_benchmark_measurement and bool(_validation_result().get("valid", false)),
		"notes": _validation_result().get("validation_notes", []) if has_benchmark_measurement else ["Preview timing is not a benchmark sample."],
	}
	return {
		"state": benchmark_state,
		"state_name": STATE_NAMES[clampi(benchmark_state, 0, STATE_NAMES.size() - 1)],
		"mode": _active_mode,
		"mode_name": _mode_name(_active_mode),
		"variant": _active_variant,
		"variant_name": _variant_name(_active_variant),
		"groom_id": String(_active_individual_groom),
		"groom_name": _preview_groom_name(_active_individual_groom),
		"profile_id": String(_active_case_profile_id),
		"profile_name": String(_active_case_profile_id),
		"metrics": metrics,
		"metrics_source": "benchmark sample" if has_benchmark_measurement else "live preview telemetry",
		"validation": validation,
		"start_error": last_start_error,
	}


## Starts one run with explicit mode, variant, and optional groom selection.
func start_benchmark(requested_mode: int = -1, requested_variant: int = -1, requested_groom: StringName = &"") -> void:
	_begin_manual_run()

	_active_mode = benchmark_mode if requested_mode < 0 else clampi(requested_mode, 0, BenchmarkMode.REPRESENTATIVE_DEFAULT)
	_active_variant = benchmark_variant if requested_variant < 0 else clampi(requested_variant, 0, BenchmarkVariant.FAST_MARSCHNER_R_STANDARDIZED_LUT)
	_active_individual_groom = individual_groom if requested_groom == &"" else requested_groom
	if not apply_variant(_active_variant):
		_set_benchmark_state(BenchmarkState.IDLE)
		_record_start_failure("Unable to start benchmark: variant %s could not be applied." % _variant_name(_active_variant))
		_restore_benchmark_environment()
		return
	_apply_display_mode(BenchmarkMode.NO_HAIR if _active_variant == BenchmarkVariant.NO_HAIR else _active_mode)

	_samples.clear()
	_state_frame = 0
	_run_timestamp = _make_run_timestamp()
	_run_directory = output_root.path_join(_run_timestamp)
	if not _ensure_output_directory(_run_directory):
		_set_benchmark_state(BenchmarkState.IDLE)
		_restore_benchmark_environment()
		return
	_set_benchmark_state(BenchmarkState.PREWARM)


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
## Returns false (and restores the original surface state) when a variant
## cannot be applied, for example when a source attributes texture is missing
## or the case's profile_id cannot be resolved.
## preview_only selects the preview-only baseline shader variant for
## CURRENT_MARSCHNER_BASELINE; timed paths keep CURRENT_MARSCHNER_SHADER.
func apply_variant(variant_id: int, preview_only: bool = false) -> bool:
	if groom_catalog.is_empty():
		_discover_grooms()
	if _material_adapter == null:
		_material_adapter = HairMaterialAdapter.new()
	var selected_variant := clampi(variant_id, 0, BenchmarkVariant.FAST_MARSCHNER_R_STANDARDIZED_LUT)
	var display_mode := _active_mode
	_restore_original_surface_state()
	_active_variant = selected_variant
	var applied := true

	# Material variants resolve the case's canonical profile; NO_HAIR needs none.
	var profile: Resource = null
	if selected_variant != BenchmarkVariant.NO_HAIR:
		profile = _material_adapter.resolve_profile(_active_case_profile_id)
		if profile == null:
			_record_start_failure(
				"Unable to apply variant %s: profile '%s' could not be resolved (missing or unreadable profile resource)."
				% [_variant_name(selected_variant), String(_active_case_profile_id)]
			)
			applied = false
		elif profile.has_method(&"validation_errors"):
			var profile_errors: PackedStringArray = profile.call(&"validation_errors")
			if not profile_errors.is_empty():
				_record_start_failure(
					"Unable to apply variant %s: profile '%s' is invalid: %s"
					% [_variant_name(selected_variant), String(_active_case_profile_id), "; ".join(profile_errors)]
				)
				applied = false

	if applied:
		match selected_variant:
			BenchmarkVariant.NO_HAIR:
				_apply_display_mode(BenchmarkMode.NO_HAIR)
			BenchmarkVariant.COVERAGE_CONTROL:
				_apply_shader_variant(COVERAGE_CONTROL_SHADER, profile)
				_apply_display_mode(display_mode)
			BenchmarkVariant.CURRENT_MARSCHNER_BASELINE:
				_apply_shader_variant(BASELINE_PREVIEW_SHADER if preview_only else CURRENT_MARSCHNER_SHADER, profile)
				_apply_display_mode(display_mode)
			BenchmarkVariant.APPROX_KAJIYA_KAY:
				_apply_shader_variant(APPROX_KAJIYA_KAY_SHADER, profile)
				_apply_display_mode(display_mode)
			BenchmarkVariant.FAST_MARSCHNER_ANALYTIC:
				_apply_shader_variant(FAST_MARSCHNER_SHADER, profile)
				_apply_analytic_flag_binding()
				_apply_display_mode(display_mode)
			BenchmarkVariant.FAST_MARSCHNER_LUT:
				# Same shared fast shader; the LUT path is enabled explicitly by
				# this variant (the analytic variant keeps the default-off flag).
				_apply_shader_variant(FAST_MARSCHNER_SHADER, profile)
				applied = _apply_fast_lut_binding()
				_apply_display_mode(display_mode)
			BenchmarkVariant.FAST_MARSCHNER_DUAL_SCATTER:
				# Same shared fast shader; the local dual-scattering slice is
				# enabled explicitly by this variant (the analytic/LUT variants
				# keep the default-off flag and their Karis reference path).
				# Variant 7 is the analytic Stage-A slice; it never enables the
				# Stage-B preintegrated path.
				_apply_shader_variant(FAST_MARSCHNER_SHADER, profile)
				applied = _apply_dual_scatter_binding()
				_apply_display_mode(display_mode)
			BenchmarkVariant.FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED:
				# Same shared fast shader; the Stage-B preintegrated
				# (LUT-backed) slice is enabled explicitly by this variant,
				# which forces dual=true, preintegrated=true, azimuthal
				# LUT=false, and environment=false (variant identity is
				# authoritative) and binds the committed 2D LUT.
				_apply_shader_variant(FAST_MARSCHNER_SHADER, profile)
				applied = _apply_preintegrated_dual_scatter_binding()
				_apply_display_mode(display_mode)
			BenchmarkVariant.FAST_MARSCHNER_R_STANDARDIZED_LUT:
				# Phase 4 diagnostic wrapper (FM_R_STANDARDIZED_LUT_MODE 1):
				# the same shared body as the shipping fast shader, with the
				# R-longitudinal product reconstructed from the committed
				# standardized projected-R 3D LUT. The variant binds the
				# Texture3D and forces every other opt-in slice off
				# (identity authoritative); log decode stays false by
				# default (the runtime test toggles it on the live clone).
				_apply_shader_variant(FAST_MARSCHNER_R_STANDARDIZED_LUT_SHADER, profile)
				applied = _apply_r_standardized_lut_binding()
				_apply_display_mode(display_mode)
			BenchmarkVariant.FAST_MARSCHNER_ENVIRONMENT:
				# Same shared fast shader; the fragment-stage environment
				# response is enabled explicitly by this variant and forces the
				# LUT/dual modes off (variant identity is authoritative).
				_apply_shader_variant(FAST_MARSCHNER_SHADER, profile)
				applied = _apply_environment_binding()
				_apply_display_mode(display_mode)
			BenchmarkVariant.BUILTIN_ALPHA_HASH_CONTROL:
				applied = _apply_builtin_alpha_hash_variant(profile)
				_apply_display_mode(display_mode)
	# Timed FAST_MARSCHNER runs pin the shared-body preview/timing uniforms to
	# their unit contract (comparison_exposure_gain 1.0, lobe_scales 1, and the
	# default area-light multipliers) so benchmark artifacts prove unit exposure
	# and lobe scales. Preview-only flows deliberately skip the contract: the
	# visual comparison chooses its own presentation gain.
	if applied and not preview_only and _variant_uses_timed_material_contract(selected_variant):
		_apply_timed_material_contract()
	if not applied:
		_restore_original_surface_state()
	return applied


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
	_active_variant = clampi(_resource_int(case, &"variant", BenchmarkVariant.CURRENT_MARSCHNER_BASELINE), 0, BenchmarkVariant.FAST_MARSCHNER_R_STANDARDIZED_LUT)
	_active_individual_groom = _resource_string_name(case, &"groom_id", &"")
	_active_case_profile_id = _resource_string_name(case, &"profile_id", &"source_current")
	if not apply_variant(_active_variant):
		_abort_resource_case("variant %s could not be applied" % _variant_name(_active_variant))
		return false
	_apply_display_mode(BenchmarkMode.NO_HAIR if _active_variant == BenchmarkVariant.NO_HAIR else _active_mode)

	_run_timestamp = _make_run_timestamp()
	_run_directory = output_directory.path_join(_safe_path_component(String(_active_case_id), "case"))
	_run_directory = _run_directory.path_join("repeat_%03d" % _active_case_repeat)
	if not _ensure_output_directory(_run_directory):
		_abort_resource_case("Unable to prepare run output directory")
		return false
	_samples.clear()
	_state_frame = 0
	_set_benchmark_state(BenchmarkState.PREWARM)
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
	_set_benchmark_state(BenchmarkState.IDLE)
	_restore_original_surface_state()
	_restore_scene_state()
	_restore_benchmark_environment()


func _restore_failed_resource_start() -> void:
	_restore_failed_resource_run()
	_set_benchmark_state(BenchmarkState.IDLE)


func _advance_suite_after_output(expected_token: int) -> void:
	if expected_token != _run_token or not _suite_active:
		return

	_suite_results.append({
		"case_id": String(_active_case_id),
		"case_display_name": _active_case_display_name,
		"repeat": _active_case_repeat,
		"directory": _run_directory,
		"sample_count": _samples.size(),
		"validation": _validation_result(),
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
		_set_benchmark_state(BenchmarkState.COMPLETE)
		return
	_restore_original_surface_state()
	_restore_scene_state()
	_restore_benchmark_environment()
	_suite_active = false
	_set_benchmark_state(BenchmarkState.COMPLETE)
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
	_set_benchmark_state(BenchmarkState.IDLE)
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
	_freeze_benchmark_time()
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
	_freeze_benchmark_time()
	_disable_fixture_nodes()
	_discover_grooms()
	last_start_error = ""
	last_persistence_error = ""


func _cancel_current_request() -> void:
	_fail_active_suite()
	_run_token += 1
	_capture_requested = false
	_set_benchmark_state(BenchmarkState.IDLE)
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
	_active_case_profile_id = &"source_current"
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


## Effectively freezes Godot shader TIME for the duration of a benchmark run: the
## prior Engine.time_scale is saved and set to BENCHMARK_TIME_SCALE (a tiny
## positive scale) before benchmark rendering starts. TIME therefore advances at
## one millionth of real time, so the production TIME*500 integer Bayer coordinate
## stays constant for normal benchmark durations (the hash stability budget is
## ~33 minutes; see HASH_BAYER_TIME_FACTOR). The controller's state machine
## advances by frame counters, not by delta time, so PREWARM/SETTLE/SAMPLE/CAPTURE
## still complete. Idempotent per run.
func _freeze_benchmark_time() -> void:
	if _time_scale_saved:
		return
	_saved_time_scale = Engine.time_scale
	Engine.time_scale = BENCHMARK_TIME_SCALE
	_time_scale_saved = true


## Restores the Engine.time_scale saved by _freeze_benchmark_time(). Idempotent;
## a no-op when no benchmark freeze is active. Called from
## _restore_benchmark_environment() so every completion, failure, cancellation,
## and exit path restores the prior value.
func _restore_benchmark_time() -> void:
	if not _time_scale_saved:
		return
	Engine.time_scale = _saved_time_scale
	_time_scale_saved = false


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
	_restore_benchmark_time()
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
			# Use the source material saved at discovery time, not the currently
			# active material: the active variant may be a built-in
			# StandardMaterial3D (BUILTIN_ALPHA_HASH_CONTROL) that cannot be cast.
			var source_material_value: Variant = surface_data["source_active_material"]
			var active_material: ShaderMaterial = source_material_value as ShaderMaterial
			if not active_material:
				_restore_diagnostic_state()
				_record_persistence_failure("Unable to prepare diagnostic capture: hair surface has no source ShaderMaterial")
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

	var groom_metadata := _groom_metadata_lookup()
	for child in _head.get_children():
		var groom := child as MeshInstance3D
		if not groom or not groom.mesh:
			continue

		var groom_id := StringName(groom.name)
		var metadata: Dictionary = groom_metadata.get(groom_id, {})
		# Explicit per-groom surface selection from hair_groom_catalog.tres.
		# Only selected surfaces receive benchmark overrides; non-selected
		# surfaces remain untouched. Grooms without a catalog definition keep
		# every surface selected (backward-compatible fallback).
		var surface_selection: Array = metadata.get("hair_surface_indices", [])
		var selection_is_explicit := not surface_selection.is_empty()
		var surfaces: Array[Dictionary] = []
		for surface_index in groom.mesh.get_surface_count():
			var original_override := groom.get_surface_override_material(surface_index)
			var source_active_material := groom.get_active_material(surface_index)
			var selected := true
			if selection_is_explicit:
				selected = surface_selection.has(surface_index)
			surfaces.append({
				"surface_index": surface_index,
				"selected": selected,
				"original_override": original_override,
				"source_active_material": source_active_material,
			})

		groom_catalog.append({
			# Transient per-process identity; never used for case selection.
			"id": groom.get_instance_id(),
			# Stable identity: groom node name under Head, matching case groom_id
			# and the resource-backed hair_groom_catalog definitions.
			"groom_id": groom_id,
			"name": groom_id,
			"display_name": String(metadata.get("display_name", String(groom_id))),
			"category": String(metadata.get("category", "")),
			"node": groom,
			"original_material_override": groom.material_override,
			"original_visible": groom.visible,
			"surfaces": surfaces,
		})

	_original_state_saved = not groom_catalog.is_empty()


## Loads the resource-backed groom catalog once and returns a lookup keyed by
## groom_id with display metadata. Returns an empty dictionary when the catalog
## resource is absent or unreadable; the controller then falls back to groom
## node names as display names. Never modifies scene materials.
func _groom_metadata_lookup() -> Dictionary:
	if not _groom_metadata_cache.is_empty():
		return _groom_metadata_cache
	var catalog_resource: Resource = load(GROOM_CATALOG_RESOURCE_PATH)
	if catalog_resource:
		var definitions_value: Variant = catalog_resource.get(&"groom_definitions")
		if definitions_value is Array:
			var definitions: Array = definitions_value
			for definition_value in definitions:
				var definition := definition_value as Resource
				if not definition:
					continue
				var groom_id_value: Variant = definition.get(&"groom_id")
				if not (groom_id_value is StringName or groom_id_value is String):
					continue
				var groom_id := StringName(groom_id_value)
				if String(groom_id).strip_edges().is_empty():
					continue
				var surface_indices: Array = []
				var surface_indices_value: Variant = definition.get(&"hair_surface_indices")
				if surface_indices_value is Array:
					surface_indices = surface_indices_value
				_groom_metadata_cache[groom_id] = {
					"display_name": String(definition.get(&"display_name")),
					"category": String(definition.get(&"category")),
					"hair_surface_indices": surface_indices,
				}
	return _groom_metadata_cache


## Applies a benchmark Shader variant to every selected hair surface via the
## material adapter: per-surface clones of the source ShaderMaterial with the
## benchmark shader and the active profile's parameters. Non-selected surfaces
## are never touched. Groom-level material_override is cleared so the per-surface
## overrides take precedence; _restore_original_surface_state() restores it
## exactly.
func _apply_shader_variant(shader: Shader, profile: Resource) -> void:
	for groom_data in groom_catalog:
		var groom := groom_data["node"] as MeshInstance3D
		if not is_instance_valid(groom):
			continue
		# GeometryInstance3D.material_override wins over every surface override.
		# Clear only the instance override; all source materials are the copies
		# captured during discovery, so mesh/source resources remain untouched.
		groom.material_override = null
		for surface_data in groom_data["surfaces"]:
			if not bool(surface_data["selected"]):
				continue
			var source_material := surface_data["source_active_material"] as Material
			if not source_material:
				continue
			var source_shader_material := source_material as ShaderMaterial
			if not source_shader_material:
				continue
			var cloned_material: ShaderMaterial = _material_adapter.make_shader_variant_material(source_shader_material, shader, profile)
			if cloned_material == null:
				continue
			groom.set_surface_override_material(int(surface_data["surface_index"]), cloned_material)


## Applies the built-in StandardMaterial3D alpha-hash control to every selected
## hair surface via the material adapter. Missing or empty attributes textures
## fail with a clear start failure instead of crashing. Non-selected surfaces
## are never touched.
func _apply_builtin_alpha_hash_variant(profile: Resource) -> bool:
	for groom_data in groom_catalog:
		var groom := groom_data["node"] as MeshInstance3D
		if not is_instance_valid(groom):
			continue
		# Groom-level material_override wins over surface overrides, so it must be
		# cleared while applying; _restore_original_surface_state() restores the
		# exact original value afterwards.
		groom.material_override = null
		for surface_data in groom_data["surfaces"]:
			if not bool(surface_data["selected"]):
				continue
			var source_material_value: Variant = surface_data["source_active_material"]
			var source_material: ShaderMaterial = source_material_value as ShaderMaterial
			if not source_material:
				_record_start_failure(
					"BUILTIN_ALPHA_HASH_CONTROL could not be applied: groom '%s' surface %d has no source ShaderMaterial."
					% [String(groom_data["name"]), int(surface_data["surface_index"])]
				)
				return false
			var alpha_hash_material: StandardMaterial3D = _material_adapter.make_builtin_alpha_hash_material(source_material, profile)
			if alpha_hash_material == null:
				_record_start_failure(
					"BUILTIN_ALPHA_HASH_CONTROL could not be applied: groom '%s' surface %d attributes_texture is missing or empty."
					% [String(groom_data["name"]), int(surface_data["surface_index"])]
				)
				return false
			groom.set_surface_override_material(int(surface_data["surface_index"]), alpha_hash_material)
	return true


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


func _set_benchmark_state(next_state: int) -> void:
	if benchmark_state == next_state:
		return
	benchmark_state = next_state
	benchmark_state_changed.emit(next_state)


func _is_timed_state() -> bool:
	return benchmark_state >= BenchmarkState.PREWARM and benchmark_state <= BenchmarkState.CAPTURE


func _preview_render_metrics() -> Dictionary:
	var viewport_rid: RID = get_viewport().get_viewport_rid()
	return {
		"cpu_ms": RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid),
		"gpu_ms": RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid),
		"visible_objects": _viewport_counter(viewport_rid, RENDER_INFO_VISIBLE, RENDER_INFO_OBJECTS),
		"visible_primitives": _viewport_counter(viewport_rid, RENDER_INFO_VISIBLE, RENDER_INFO_PRIMITIVES),
		"visible_draw_calls": _viewport_counter(viewport_rid, RENDER_INFO_VISIBLE, RENDER_INFO_DRAW_CALLS),
		"shadow_objects": _viewport_counter(viewport_rid, RENDER_INFO_SHADOW, RENDER_INFO_OBJECTS),
		"shadow_primitives": _viewport_counter(viewport_rid, RENDER_INFO_SHADOW, RENDER_INFO_PRIMITIVES),
		"shadow_draw_calls": _viewport_counter(viewport_rid, RENDER_INFO_SHADOW, RENDER_INFO_DRAW_CALLS),
	}


func _preview_groom_name(groom_id: StringName) -> String:
	for groom_data in groom_catalog:
		if StringName(groom_data.get("groom_id", groom_data.get("name", &""))) == groom_id:
			return String(groom_data.get("display_name", groom_data.get("name", String(groom_id))))
	return String(groom_id)


func _advance_timing_state(frame_limit: int, next_state: int) -> void:
	_state_frame += 1
	if _state_frame >= frame_limit:
		_set_benchmark_state(next_state)
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
		"time_hash_provenance": "Production TIME-driven Bayer/hash path; Engine.time_scale is set to 1e-06 for the run, so shader TIME advances at one millionth of real time and the TIME*500 integer Bayer coordinate stays constant for normal benchmark durations (effectively frozen, not exactly zero; ~33 minute stability budget). The prior Engine.time_scale is restored on every completion, failure, cancellation, and exit path.",
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
	_set_benchmark_state(BenchmarkState.COMPLETE)
	_capture_requested = false
	if _suite_active:
		call_deferred("_advance_suite_after_output", run_token)


func _write_run_outputs() -> bool:
	var mode_name := _mode_name(_active_mode)
	var variant_name := _variant_name(_active_variant)
	var baseline_commit := FileAccess.get_file_as_string("res://benchmark/reference/BASELINE_COMMIT.txt").strip_edges()
	var actual_viewport: Vector2i = get_viewport().size
	var validation := _validation_result()
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
			"groom_id": String(groom_data["groom_id"]),
			"name": String(groom_data["name"]),
			"display_name": String(groom_data["display_name"]),
			"category": String(groom_data["category"]),
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
		"profile_id": String(_active_case_profile_id),
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
		"validation": validation,
		"runtime": _runtime_manifest(),
		"files": output_files,
		"material_state": "Source ShaderMaterials are cloned per surface; selected groom-level material_override values are temporarily cleared so per-surface variant/diagnostic overrides take precedence, then restored alongside surface overrides. Mesh and source material resources are never edited.",
		"comparison_validity": _comparison_validity_manifest(),
		"timed_material_contract": _timed_material_contract_manifest(),
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

	var metric_names := ["cpu_ms", "gpu_ms"]
	metric_names.append_array(STABILITY_METRIC_NAMES)
	var statistics := {}
	for metric_name in metric_names:
		var values: Array = []
		for sample in _samples:
			values.append(float(sample[metric_name]))
		var mean_value := _mean(values)
		var variance_value := _variance(values, mean_value)
		statistics[metric_name] = {
			"count": values.size(),
			"min": _percentile(values, 0.0),
			"max": _percentile(values, 1.0),
			"mean": mean_value,
			"median": _percentile(values, 0.50),
			"stddev": sqrt(variance_value),
			"variance": variance_value,
			"p90": _percentile(values, 0.90),
			"p95": _percentile(values, 0.95),
			"p99": _percentile(values, 0.99),
			"trimmed_mean_5pct": _trimmed_mean(values, 0.05),
			"spread": _percentile(values, 1.0) - _percentile(values, 0.0),
		}

	var summary := {
		"schema_version": 1,
		"timestamp": _run_timestamp,
		"suite_id": String(_active_suite_id),
		"case_id": String(_active_case_id),
		"repeat": _active_case_repeat,
		"mode": mode_name,
		"variant": variant_name,
		"profile_id": String(_active_case_profile_id),
		"sample_count": _samples.size(),
		"captures": _active_capture_records,
		"coverage_metrics": _active_coverage_metrics,
		"validation": validation,
		"comparison_validity": _comparison_validity_manifest(),
		"runtime": _runtime_manifest(),
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
	var viewport: Viewport = get_viewport()
	return {
		"godot_version": String(version_info.get("string", "unknown")),
		"git_commit": _git_commit(),
		"build": {
			"debug_build": OS.is_debug_build(),
			"editor_build": Engine.is_editor_hint(),
		},
		"render_method": String(ProjectSettings.get_setting("rendering/renderer/rendering_method", "unknown")),
		"gpu_adapter": RenderingServer.get_video_adapter_name(),
		"gpu_api": RenderingServer.get_video_adapter_api_version(),
		"driver": String(ProjectSettings.get_setting("rendering/driver/driver_name", "unknown")),
		"os": OS.get_name(),
		"os_distribution": _os_distribution_name(),
		"display": {
			"window_mode": _window_mode_name(DisplayServer.window_get_mode()),
			"window_mode_value": int(DisplayServer.window_get_mode()),
			"window_size": _vector2i_manifest(DisplayServer.window_get_size()),
			"vsync_mode": _vsync_mode_name(DisplayServer.window_get_vsync_mode()),
			"vsync_mode_value": int(DisplayServer.window_get_vsync_mode()),
			"max_fps": Engine.max_fps,
		},
		"viewport": {
			# These are the harness-locked run values (TAA off, scaling forced to
			# bilinear 1.0); the caller's originals are restored after the run.
			"scaling_3d_mode": int(viewport.scaling_3d_mode) if viewport else -1,
			"scaling_3d_scale": viewport.scaling_3d_scale if viewport else 1.0,
			"msaa_3d": int(viewport.msaa_3d) if viewport else 0,
			"use_taa": viewport.use_taa if viewport else false,
		},
		"shadows": {
			"directional_shadow_size": _project_setting("rendering/lights_and_shadows/directional_shadow/size"),
			"directional_shadow_16_bits": _project_setting("rendering/lights_and_shadows/directional_shadow/16_bits"),
			"directional_soft_shadow_filter_quality": _project_setting("rendering/lights_and_shadows/directional_shadow/soft_shadow_filter_quality"),
			"positional_soft_shadow_filter_quality": _project_setting("rendering/lights_and_shadows/positional_shadow/soft_shadow_filter_quality"),
			"use_physical_light_units": _project_setting("rendering/lights_and_shadows/use_physical_light_units"),
		},
		"anti_aliasing": {
			"use_debanding": _project_setting("rendering/anti_aliasing/quality/use_debanding"),
			"screen_space_roughness_limiter_enabled": _project_setting("rendering/anti_aliasing/quality/screen_space_roughness_limiter/enabled"),
		},
		"environment_resource_path": _environment_resource_path(),
		"hash_time": {
			"strategy": "Engine.time_scale is saved and set to BENCHMARK_TIME_SCALE (1e-06) before benchmark rendering starts so Godot shader TIME advances at one millionth of real time; the controller's frame-count state machine still advances. The prior value is restored on every completion, failure, cancellation, and exit path.",
			"benchmark_time_scale": BENCHMARK_TIME_SCALE,
			"engine_time_scale": Engine.time_scale,
			"effectively_frozen": _time_scale_saved,
			"hash_bayer_time_factor": HASH_BAYER_TIME_FACTOR,
			"hash_stability_budget_seconds": 1.0 / (HASH_BAYER_TIME_FACTOR * BENCHMARK_TIME_SCALE),
			"phase": "Effectively frozen (TIME advances at 1e-06x real time) for the entire run: PREWARM, SETTLE, SAMPLE, CAPTURE.",
		},
	}


## Safe ProjectSettings lookup: returns the setting value, or the string "unset"
## when the project does not define it. Never fails on missing keys.
func _project_setting(setting_name: String) -> Variant:
	if ProjectSettings.has_setting(setting_name):
		return ProjectSettings.get_setting(setting_name)
	return "unset"


## Best-effort Git commit discovery: reads res://.git/HEAD and the referenced ref
## file directly (no shell calls, no file writes). Returns "unknown" when the
## repository is absent, packed away, or unreadable.
func _git_commit() -> String:
	var head_file: FileAccess = FileAccess.open("res://.git/HEAD", FileAccess.READ)
	if head_file == null:
		return "unknown"
	var head_text: String = head_file.get_as_text().strip_edges()
	if head_text.begins_with("ref:"):
		var ref_path := head_text.trim_prefix("ref:").strip_edges()
		var ref_file: FileAccess = FileAccess.open("res://.git/%s" % ref_path, FileAccess.READ)
		if ref_file == null:
			return "unknown"
		return ref_file.get_as_text().strip_edges()
	if head_text.length() == 40 or head_text.length() == 64:
		return head_text
	return "unknown"


func _os_distribution_name() -> String:
	var distribution_name: String = OS.get_distribution_name()
	return distribution_name if not distribution_name.is_empty() else "unknown"


func _window_mode_name(mode: int) -> String:
	return WINDOW_MODE_NAMES[clampi(mode, 0, WINDOW_MODE_NAMES.size() - 1)]


func _vsync_mode_name(mode: int) -> String:
	return VSYNC_MODE_NAMES[clampi(mode, 0, VSYNC_MODE_NAMES.size() - 1)]


func _vector2i_manifest(value: Vector2i) -> Array:
	return [value.x, value.y]


## Path of the environment currently active in the run viewport; "none" when no
## environment is set, "embedded (no resource path)" for in-scene resources.
func _environment_resource_path() -> String:
	var viewport: Viewport = get_viewport()
	if not viewport:
		return "unknown"
	var world_environment: Environment = viewport.get_world_3d().environment
	if not world_environment:
		return "none"
	var resource_path: String = world_environment.resource_path
	if resource_path.is_empty():
		return "embedded (no resource path)"
	return resource_path


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
	_set_benchmark_state(BenchmarkState.COMPLETE)


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


func _mean(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var sum := 0.0
	for value in values:
		sum += float(value)
	return sum / float(values.size())


## Population variance (sum of squared deviations divided by n). Returns 0.0 for
## fewer than two samples.
func _variance(values: Array, mean_value: float) -> float:
	if values.size() < 2:
		return 0.0
	var sum_squares := 0.0
	for value in values:
		var difference := float(value) - mean_value
		sum_squares += difference * difference
	return sum_squares / float(values.size())


## Mean after excluding the lowest and highest trim_fraction of samples. Falls
## back to the plain mean when the trim would remove every sample (small windows)
## or when the trim fraction is not positive.
func _trimmed_mean(values: Array, trim_fraction: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted: Array = values.duplicate()
	sorted.sort()
	var trim_count := int(floor(float(sorted.size()) * trim_fraction))
	if trim_count <= 0 or trim_count * 2 >= sorted.size():
		return _mean(values)
	return _mean(sorted.slice(trim_count, sorted.size() - trim_count))


## Computes the run-validation result. A run is valid when at least one sample was
## collected and every visible/shadow object/primitive/draw-call counter is
## constant across the sample window (the scene is static and TIME is effectively
## frozen, so any counter variance indicates an unstable or mismatched run).
## Intentional short sample windows (pass-count tests) are never rejected; they
## are only noted.
func _validation_result() -> Dictionary:
	var notes: Array = []
	var valid := true
	if _samples.is_empty():
		valid = false
		notes.append("no samples were collected")
	elif _samples.size() < _active_sample_frames:
		valid = false
		notes.append("sample count %d is below the requested %d frames" % [_samples.size(), _active_sample_frames])
	elif _active_sample_frames < SAMPLE_DEFAULT:
		notes.append("intentional short sample window (%d frames, default is %d); statistics are computed on fewer samples" % [_active_sample_frames, SAMPLE_DEFAULT])
	for metric_name in STABILITY_METRIC_NAMES:
		var minimum_value := INF
		var maximum_value := -INF
		for sample in _samples:
			var value := float(sample[metric_name])
			minimum_value = minf(minimum_value, value)
			maximum_value = maxf(maximum_value, value)
		if _samples.is_empty():
			continue
		if minimum_value != maximum_value:
			valid = false
			notes.append("%s is not stable across the sample window: min %d, max %d" % [metric_name, int(minimum_value), int(maximum_value)])
	return {
		"valid": valid,
		"validation_notes": notes,
	}


func _make_run_timestamp() -> String:
	var date_time := Time.get_datetime_string_from_system(true).replace(":", "-").replace("T", "_")
	return "%s_%d" % [date_time, Time.get_ticks_msec()]


func _mode_name(mode: int) -> String:
	return MODE_NAMES[clampi(mode, 0, MODE_NAMES.size() - 1)]


func _variant_name(variant_id: int) -> String:
	return VARIANT_NAMES[clampi(variant_id, 0, VARIANT_NAMES.size() - 1)]
