@tool
extends DirectionalLight3D

var _is_controller_enabled := false :
	set(value):
		_is_controller_enabled = value
		$SpotlightBody.visible = value
		environment.glow_enabled = value

		if _camera_is_idle():
			Input.set_default_cursor_shape(Input.CURSOR_CROSS if value else Input.CURSOR_ARROW)

@onready var viewport: Variant = Engine.get_singleton(&'EditorInterface').get_editor_viewport_3d(0) if Engine.is_editor_hint() else get_viewport()
@onready var camera: Camera3D = viewport.get_camera_3d()
@onready var environment := get_world_3d().environment
@onready var camera_transform_prev := camera.global_transform

func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&'move_spotlight') and _camera_is_idle():
		_is_controller_enabled = true
	elif event.is_action_released(&'move_spotlight'):
		_is_controller_enabled = false


func _process(delta: float) -> void:
	# --- Dynamic Shadow Distance ---
	# FIXME: Not a good solution to hair shadows lmao
	if camera.global_transform != camera_transform_prev:
		var origin := camera.global_position
		directional_shadow_max_distance = origin.length() + origin.distance_to(camera_transform_prev.origin) + 0.1
		camera_transform_prev = camera.global_transform

	if Engine.is_editor_hint(): return

	# --- Changing Orientation ---
	if not _camera_is_idle():
		_is_controller_enabled = false
	elif _is_controller_enabled:
		# Basic orbit controller implementation
		var offset := Vector2.RIGHT * (ImGui.GetWindowWidth() + DebugManager.IMGUI_WINDOW_MARGIN_PX) * float(camera.projection != Camera3D.PROJECTION_PERSPECTIVE)
		var size: Vector2 = viewport.get_visible_rect().size - offset
		var center := size*0.5 + offset
		var displacement: Vector2 = viewport.get_mouse_position() - center

		# NOTE: We clamp beyond a certain theta to prevent controls from becoming too unintutive.
		var theta := minf(displacement.length() / minf(size.x, size.y), 2.0/3.0) * PI
		var perp := displacement.normalized() * sin(theta)
		look_at(global_position + camera.global_basis * Vector3(perp.x, -perp.y, -cos(theta)))


## The benchmark temporarily makes a plain Camera3D current. Treat cameras
## without the debug-camera state machine as idle instead of dereferencing the
## debug-only _current_mode/Mode members every frame.
func _camera_is_idle() -> bool:
	if not is_instance_valid(camera) or camera.get_script() == null:
		return true
	var current_mode: Variant = camera.get(&"_current_mode")
	return current_mode == null or int(current_mode) == 0


func _notification(what: int) -> void:
	if what == NOTIFICATION_EDITOR_PRE_SAVE:
		directional_shadow_max_distance = 1.0
