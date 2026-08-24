extends Camera3D
## A camera controller similar to the one used in the Godot 3D editor.
## Source: https://github.com/godotengine/godot/blob/4.5/editor/scene/3d/node_3d_editor_plugin.cpp

const PITCH_MAX = PI/2.0 * 0.992
const DEFAULT_ORBIT_DISTANCE = 0.45

@export_category('Navigation Feel')
@export_group('Orbit')
## The mouse sensitivity to use when orbiting.
@export_range(0.01, 20, 0.001, 'hide_slider', 'radians_as_degrees') var orbit_sensitivity := deg_to_rad(0.25)
## The inertia to use when orbiting. Higher values make the camera start and stop slower, which looks smoother but adds latency.
@export_range(0, 1, 0.001, 'hide_slider') var orbit_inertia := 0.0


@export_group('Zoom')
## The mouse sensitivity to use when zooming.
@export_range(0.01, 20, 0.001, 'hide_slider') var zoom_sensitivity := 1.0
## The inertia to use when zooming. Higher values make the camera start and stop slower, which looks smoother but adds latency.
@export_range(0, 1, 0.001, 'hide_slider') var zoom_inertia := 0.05

## The current movement mode. Mode prescedence is based on enum int value.
enum Mode { MODE_IDLE, MODE_ORBIT, MODE_ZOOM }

var _smoothed_orbit_distance := DEFAULT_ORBIT_DISTANCE
var _orbit_distance := DEFAULT_ORBIT_DISTANCE :
	set(value): _orbit_distance = clampf(value, get_min_speed(), get_max_speed())

var _mouse_motion: Vector2
var _smoothed_rotation: Vector3 :
	set(value):
		value.y = rotation.x - clamp(rotation.x - value.y, -PITCH_MAX, PITCH_MAX) # Clamp pitch to (-pi/2..pi/2)
		_smoothed_rotation = value
var _current_mode: Mode :
	set(new_mode):
		Input.set_default_cursor_shape(Input.CURSOR_POINTING_HAND if new_mode != Mode.MODE_IDLE else Input.CURSOR_ARROW)
		_current_mode = new_mode

func get_min_speed() -> float:
	return minf(self.near * 4.0, self.far / 4.0)

func get_max_speed() -> float:
	return maxf(self.near * 4.0, self.far / 4.0)


func _refresh_current_mode() -> void:
	var new_mode := Mode.MODE_IDLE
	if Input.is_mouse_button_pressed(MouseButton.MOUSE_BUTTON_MIDDLE) and Input.is_key_pressed(Key.KEY_CTRL):
		new_mode = Mode.MODE_ZOOM
	elif Input.is_mouse_button_pressed(MouseButton.MOUSE_BUTTON_MIDDLE) or Input.is_mouse_button_pressed(MouseButton.MOUSE_BUTTON_RIGHT):
		new_mode = Mode.MODE_ORBIT

	if new_mode != _current_mode:
		_current_mode = new_mode


func _input(event: InputEvent) -> void:
	if ImGui.IsWindowHovered(ImGui.HoveredFlags_AnyWindow) or ImGui.IsAnyItemActive(): return

	if event is InputEventMouseButton:
		match event.button_index:
			MouseButton.MOUSE_BUTTON_RIGHT, MouseButton.MOUSE_BUTTON_MIDDLE:
				_refresh_current_mode()
			MouseButton.MOUSE_BUTTON_WHEEL_UP, MouseButton.MOUSE_BUTTON_WHEEL_DOWN:
				var factor := 1.08 if event.button_index == MouseButton.MOUSE_BUTTON_WHEEL_DOWN else 1.0 / 1.08
				_orbit_distance *= factor

	elif event is InputEventMouseMotion:
		if _current_mode == Mode.MODE_IDLE: return

		var viewport := get_viewport()
		var viewport_size_wrapped := viewport.get_visible_rect().size - Vector2.ONE*2.0
		var mouse_pos := viewport.get_mouse_position()
		var mouse_pos_wrapped := (mouse_pos - Vector2.ONE).posmodv(viewport_size_wrapped) + Vector2.ONE

		# Reasonable check to filter out input events caused by the cursor wrapping around viewport.
		var has_warped_check: Vector2 = event.screen_relative.abs() / viewport_size_wrapped

		if mouse_pos != mouse_pos_wrapped:
			# Wrap cursor around to otherside of viewport if it reaches the end (infinite drag).
			Input.warp_mouse(mouse_pos_wrapped)
		elif has_warped_check.x < 0.5 and has_warped_check.y < 0.5:
			_mouse_motion += event.screen_relative


func _process(delta: float) -> void:
	if _current_mode == Mode.MODE_ZOOM or not is_equal_approx(_smoothed_orbit_distance, _orbit_distance):
		_nav_zoom(delta)
	if _current_mode == Mode.MODE_ORBIT or not _smoothed_rotation.is_equal_approx(Vector3.ZERO):
		_nav_orbit(delta)

	_mouse_motion = Vector2.ZERO


func _nav_zoom(delta: float) -> void:
	var mouse_motion := _mouse_motion * (zoom_sensitivity / 80.0) if _current_mode == Mode.MODE_ZOOM else Vector2.ZERO

	var factor := 1.0 + mouse_motion.y if mouse_motion.y >= 0.0 else 1.0 / (1.0 - mouse_motion.y)
	_orbit_distance *= factor

	var previous_orbit_distance := _smoothed_orbit_distance
	_smoothed_orbit_distance = lerpf(_smoothed_orbit_distance, _orbit_distance, _get_inertia_factor(zoom_inertia, delta));
	global_position += global_basis.z * (_smoothed_orbit_distance - previous_orbit_distance)


func _nav_orbit(delta: float) -> void:
	var mouse_motion := _mouse_motion * orbit_sensitivity if _current_mode == Mode.MODE_ORBIT else Vector2.ZERO

	_smoothed_rotation = _smoothed_rotation.lerp(Vector3(mouse_motion.x, mouse_motion.y, 0), _get_inertia_factor(orbit_inertia, delta))

	var orbit_offset := global_basis.z * _smoothed_orbit_distance
	var rotated_offset := Quaternion(Vector3.UP, -_smoothed_rotation.x) * Quaternion(global_basis.x, -_smoothed_rotation.y) * orbit_offset
	var pivot := global_position - orbit_offset
	look_at_from_position(pivot + rotated_offset, pivot, Vector3.UP)


func _get_inertia_factor(inertia: float, delta: float) -> float:
	const DECAY_RATE = 7.0
	return maxf(0.01, 1.0 - pow(inertia, delta*DECAY_RATE))
