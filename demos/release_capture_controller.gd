extends Node3D

## Deterministic Movie Maker capture controller for release/demo media.
##
## The camera orbit reuses the original GodotHair demo camera convention:
## the starting camera transform is the same one used by the demo and the orbit
## pivot is reconstructed from its 0.45 m default orbit distance. This keeps the
## release videos visually comparable to the interactive demo while avoiding
## input-driven camera motion during offline recording.

const CAPTURE_QUALITY: String = "quality"
const CAPTURE_WETNESS: String = "wetness"
const CAPTURE_WETNESS_STATE: String = "wetness_state"

# Release media compares only the three shipped quality tiers. Reference
# Marschner stays a development/validation tier and is intentionally not part
# of the release-capture surface (its behavior is documented separately).
const QUALITY_NAMES: Array[String] = [
	"Approx / Kajiya-Kay",
	"Fast Marschner",
	"Cinematic Marschner",
]

const QUALITY_ALIASES := {
	"approx": 0,
	"kajiya-kay": 0,
	"fast": 1,
	"fast-marschner": 1,
	"cinematic": 2,
	"cinematic-marschner": 2,
}

const STATIC_BAYER_MODE: int = 1
const ORBIT_DISTANCE: float = 0.45
const QUALITY_SEGMENT_SECONDS: float = 6.0
const QUALITY_SWITCH_HOLD_SECONDS: float = 0.5
const WETNESS_DRY_HOLD_SECONDS: float = 1.0
const WETNESS_RAMP_SECONDS: float = 8.0
const WETNESS_WET_HOLD_SECONDS: float = 1.0

@onready var _presentation: Node = $Presentation
@onready var _camera: Camera3D = $Presentation/Camera3D
@onready var _title_label: Label = $Overlay/Title
@onready var _attribution_label: Label = $Overlay/Attribution

var _profile: Resource
var _capture_mode: String = CAPTURE_QUALITY
var _wetness_tier: int = 1
var _wetness_state_value: float = 0.0
var _elapsed: float = 0.0
var _active_quality_tier: int = -1
var _orbit_pivot: Vector3
var _initial_orbit_offset: Vector3
var _finished: bool = false


func _ready() -> void:
	_parse_user_args()

	var source_profile: Resource = _presentation.get(&"material_profile") as Resource
	if source_profile == null:
		_fail("HairReleaseCapture requires Presentation.material_profile")
		return

	_profile = source_profile.duplicate(true)
	if _profile == null:
		_fail("Could not duplicate the demo HairMaterialProfile")
		return

	# Presentation media should be stable across frames. Coverage policy itself is
	# validated separately; release videos use deterministic Static Bayer.
	_profile.set(&"coverage_mode", STATIC_BAYER_MODE)
	_presentation.set(&"material_profile", _profile)

	_initial_orbit_offset = _camera.global_basis.z * ORBIT_DISTANCE
	_orbit_pivot = _camera.global_position - _initial_orbit_offset
	_set_orbit_angle(0.0)

	_attribution_label.text = "Demo groom: CT2Hair / GodotHair — CC BY-NC 4.0"

	match _capture_mode:
		CAPTURE_QUALITY:
			_set_quality_tier(0)
			_update_quality_label(0)
		CAPTURE_WETNESS:
			_set_quality_tier(_wetness_tier)
			_profile.set(&"wetness", 0.0)
			_refresh_presentation()
			_update_wetness_label(0.0)
		CAPTURE_WETNESS_STATE:
			_set_quality_tier(_wetness_tier)
			_profile.set(&"wetness", _wetness_state_value)
			_refresh_presentation()
			_update_wetness_state_label()
		_:
			_fail("Unsupported capture mode: %s" % _capture_mode)


func _process(delta: float) -> void:
	if _finished:
		return

	_elapsed += delta
	match _capture_mode:
		CAPTURE_QUALITY:
			_tick_quality_capture()
		CAPTURE_WETNESS:
			_tick_wetness_capture()
		CAPTURE_WETNESS_STATE:
			_tick_wetness_state_capture()


func _tick_quality_capture() -> void:
	var total_seconds: float = QUALITY_SEGMENT_SECONDS * float(QUALITY_NAMES.size())
	if _elapsed >= total_seconds:
		_finish_capture()
		return

	var tier: int = mini(int(floor(_elapsed / QUALITY_SEGMENT_SECONDS)), QUALITY_NAMES.size() - 1)
	var local_time: float = _elapsed - float(tier) * QUALITY_SEGMENT_SECONDS
	if tier != _active_quality_tier:
		_set_quality_tier(tier)

	var orbit_time: float = maxf(local_time - QUALITY_SWITCH_HOLD_SECONDS, 0.0)
	var orbit_duration: float = QUALITY_SEGMENT_SECONDS - QUALITY_SWITCH_HOLD_SECONDS
	var orbit_progress: float = clampf(orbit_time / orbit_duration, 0.0, 1.0)
	_set_orbit_angle(TAU * orbit_progress)
	_update_quality_label(tier)


func _tick_wetness_capture() -> void:
	var total_seconds: float = WETNESS_DRY_HOLD_SECONDS + WETNESS_RAMP_SECONDS + WETNESS_WET_HOLD_SECONDS
	if _elapsed >= total_seconds:
		_finish_capture()
		return

	var wetness_value: float = 0.0
	var orbit_progress: float = 0.0
	if _elapsed >= WETNESS_DRY_HOLD_SECONDS:
		var ramp_time: float = minf(_elapsed - WETNESS_DRY_HOLD_SECONDS, WETNESS_RAMP_SECONDS)
		orbit_progress = clampf(ramp_time / WETNESS_RAMP_SECONDS, 0.0, 1.0)
		wetness_value = orbit_progress

	_profile.set(&"wetness", wetness_value)
	# Refresh in the same frame so the displayed numeric label and shader uniform
	# cannot drift by one frame if process ordering changes.
	_refresh_presentation()
	_set_orbit_angle(TAU * orbit_progress)
	_update_wetness_label(wetness_value)


func _tick_wetness_state_capture() -> void:
	# Fixed-wetness full-orbit capture: wetness stays constant while the camera
	# completes one 360-degree orbit over the same 6 s used by each quality
	# segment. Each tier/wetness clip is kept individual; the GIF generator
	# downscales every clip separately with its own in-frame tier/wetness label.
	if _elapsed >= QUALITY_SEGMENT_SECONDS:
		_finish_capture()
		return

	var orbit_progress: float = clampf(_elapsed / QUALITY_SEGMENT_SECONDS, 0.0, 1.0)
	_set_orbit_angle(TAU * orbit_progress)
	_update_wetness_state_label()


func _set_quality_tier(tier: int) -> void:
	_active_quality_tier = clampi(tier, 0, QUALITY_NAMES.size() - 1)
	_profile.set(&"quality_tier", _active_quality_tier)
	_profile.set(&"wetness", 0.0)
	_refresh_presentation()
	_set_orbit_angle(0.0)


func _refresh_presentation() -> void:
	# HairMaterialProfilePreview exposes this editor/runtime refresh helper. Use it
	# for tier changes and capture-time wetness updates to keep output deterministic.
	if _presentation.has_method(&"_refresh_preview"):
		_presentation.call(&"_refresh_preview")


func _set_orbit_angle(angle: float) -> void:
	var rotated_offset: Vector3 = Quaternion(Vector3.UP, angle) * _initial_orbit_offset
	_camera.global_position = _orbit_pivot + rotated_offset
	_camera.look_at(_orbit_pivot, Vector3.UP)


func _update_quality_label(tier: int) -> void:
	_title_label.text = "%s\nDry comparison — wetness 0.00" % QUALITY_NAMES[tier]


func _update_wetness_label(wetness_value: float) -> void:
	_title_label.text = "%s\nWetness %.2f" % [QUALITY_NAMES[_wetness_tier], wetness_value]


func _update_wetness_state_label() -> void:
	_title_label.text = "%s\nWetness %.2f" % [QUALITY_NAMES[_wetness_tier], _wetness_state_value]


func _parse_user_args() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture="):
			_capture_mode = argument.trim_prefix("--capture=").to_lower()
		elif argument.begins_with("--tier="):
			var alias: String = argument.trim_prefix("--tier=").to_lower()
			if QUALITY_ALIASES.has(alias):
				_wetness_tier = int(QUALITY_ALIASES[alias])
			else:
				push_warning("Unknown --tier=%s; defaulting to Fast Marschner" % alias)
		elif argument.begins_with("--wetness="):
			var raw: String = argument.trim_prefix("--wetness=")
			if raw.is_valid_float():
				_wetness_state_value = clampf(raw.to_float(), 0.0, 1.0)
			else:
				push_warning("Unknown --wetness=%s; defaulting to 0.0" % raw)


func _finish_capture() -> void:
	_finished = true
	set_process(false)
	print(
		"HAIR_RELEASE_CAPTURE_OK mode=%s tier=%s wetness=%.2f"
		% [_capture_mode, QUALITY_NAMES[_wetness_tier], _wetness_state_value]
	)
	# SceneTree.quit() lets MovieWriter finalize the output container cleanly.
	get_tree().quit(0)


func _fail(message: String) -> void:
	_finished = true
	set_process(false)
	push_error(message)
	print("HAIR_RELEASE_CAPTURE_FAILED")
	get_tree().quit(1)
