extends Node

const IMGUI_WINDOW_MARGIN_PX := 20

enum DenoisingMode { DENOISING_MODE_NONE, DENOISING_MODE_TAA, DENOISING_MODE_FSR2 }

var should_render_imgui := not Engine.is_editor_hint()
var _denoising_mode := DenoisingMode.DENOISING_MODE_FSR2
var _render_scales: PackedFloat32Array
var _current_hairstyle := [1]
var _lobe_scales := Vector3.ONE
var _lobe_enabled := Vector3i.ONE

@onready var viewport: Variant = Engine.get_singleton(&'EditorInterface').get_editor_viewport_3d(0) if Engine.is_editor_hint() else get_viewport()
@onready var camera: Camera3D = viewport.get_camera_3d() if viewport else null
@onready var fixture_main: Node = _resolve_fixture_main()
@onready var light_node: DirectionalLight3D = fixture_main.get_node_or_null(^'DirectionalLight3D') as DirectionalLight3D if fixture_main else null
@onready var head_node: MeshInstance3D = fixture_main.get_node_or_null(^'Head') as MeshInstance3D if fixture_main else null
@onready var hairstyle_names: Array[String] = _get_hairstyle_names()
@onready var tris_counts: Array[String] = _get_tris_counts()


func _resolve_fixture_main() -> Node:
	var active_scene := get_tree().current_scene
	if active_scene and active_scene.name == &'Main':
		return active_scene
	if active_scene:
		return active_scene.get_node_or_null(^'TestSceneHost/Main') as Node
	return null


func _get_hairstyle_names() -> Array[String]:
	var names: Array[String] = []
	if not head_node:
		return names
	for child in head_node.get_children():
		names.append(String(child.name))
	return names


func _get_tris_counts() -> Array[String]:
	var counts: Array[String] = []
	if not head_node or not head_node.mesh:
		return counts

	# Precompute the amount of loaded triangles since its quite a slow operation.
	# FIXME: Wouldn't hurt to just use total rendered triangles instead: Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	for child in head_node.get_children():
		var hairstyle := child as MeshInstance3D
		if not hairstyle or not hairstyle.mesh:
			counts.append('0 tris')
			continue
		var tris := str((hairstyle.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX].size() + head_node.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX].size()) / 3)
		counts.append('%s,%s tris' % [tris.left(tris.length() - 3), tris.right(3)])
	return counts

func _ready() -> void:
	if not fixture_main:
		fixture_main = _resolve_fixture_main()
		if fixture_main:
			light_node = fixture_main.get_node_or_null(^'DirectionalLight3D') as DirectionalLight3D
			head_node = fixture_main.get_node_or_null(^'Head') as MeshInstance3D
			hairstyle_names = _get_hairstyle_names()
			tris_counts = _get_tris_counts()

	_render_scales.resize(len(DenoisingMode))
	_render_scales.fill(1.0)
	_render_scales[DenoisingMode.DENOISING_MODE_FSR2] = 0.5

	change_denoising_mode(_denoising_mode, _render_scales[_denoising_mode])
	if head_node:
		change_hairstyle(_current_hairstyle[0])


func _process(delta: float) -> void:
	if should_render_imgui: _render_imgui(delta)


func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&'toggle_imgui'):
		should_render_imgui = not should_render_imgui
		if not should_render_imgui and camera: # Reset camera frustum to center
			camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	elif event.is_action_pressed(&'next_hairstyle'):
		if not head_node or head_node.get_child_count() == 0:
			return
		_current_hairstyle[0] = (_current_hairstyle[0] + 1) % head_node.get_child_count()
		change_hairstyle(_current_hairstyle[0])
	elif event.is_action_pressed(&'previous_hairstyle'):
		if not head_node or head_node.get_child_count() == 0:
			return
		_current_hairstyle[0] = (_current_hairstyle[0] - 1 + head_node.get_child_count()) % head_node.get_child_count()
		change_hairstyle(_current_hairstyle[0])


func _render_imgui(delta: float) -> void:
	if not viewport or not camera or not light_node or not head_node:
		return
	var fps := Engine.get_frames_per_second()
	var window := get_window()
	var render_scale := [_render_scales[_denoising_mode]]
	var fsr_sharpness := [viewport.fsr_sharpness]
	var size: Vector2i = viewport.get_visible_rect().size

	ImGui.PushStyleVar(ImGui.StyleVar_WindowRounding, 6.0)
	ImGui.Begin(' ', [], ImGui.WindowFlags_AlwaysAutoResize | ImGui.WindowFlags_NoMove | ImGui.WindowFlags_NoCollapse | ImGui.WindowFlags_NoScrollbar)
	ImGui.SetWindowPos(Vector2.ONE * IMGUI_WINDOW_MARGIN_PX)
	ImGui.SeparatorText(ProjectSettings.get_setting('application/config/name'))
	ImGui.Text('FPS:                      %d (%s)' % [fps, '%.2fms' % (1.0 / fps*1e3)])
	ImGui.Text('Rendered Primitives:      %s' % tris_counts[_current_hairstyle[0]])
	ImGui.Text('Rendered Size:            %d × %d' % [size.x*render_scale[0], size.y*render_scale[0]])

	ImGui.Text('Denoising Method:         %s' % ('Bilinear' if _denoising_mode == DenoisingMode.DENOISING_MODE_NONE else 'TAA' if _denoising_mode == DenoisingMode.DENOISING_MODE_TAA else 'FSR 2')); ImGui.SameLine()
	ImGui.SetCursorPos(ImGui.GetCursorPos() + Vector2(ImGui.GetContentRegionAvail().x - ImGui.CalcTextSize('Change').x - ImGui.GetStyle().FramePadding.x*2, -2))
	if ImGui.Button('Change'):
		_denoising_mode = (_denoising_mode + 1) % len(DenoisingMode) as DenoisingMode
		change_denoising_mode(_denoising_mode, _render_scales[_denoising_mode])

	ImGui.Text('Render Scale:            '); ImGui.SameLine(); if ImGui.SliderFloatEx(&'##render_scale', render_scale, 0.25, 4.0, '%.1f', ImGui.SliderFlags_AlwaysClamp):
		viewport.scaling_3d_scale = render_scale[0]
		_render_scales[_denoising_mode] = render_scale[0]

	if _denoising_mode == DenoisingMode.DENOISING_MODE_FSR2:
		ImGui.Text('FSR Sharpness:           '); ImGui.SameLine(); if ImGui.SliderFloatEx(&'##fsr_sharpness', fsr_sharpness, 0.0, 2.0, '%.1f', ImGui.SliderFlags_AlwaysClamp):
			viewport.fsr_sharpness = fsr_sharpness[0]

	ImGui.Text('Render Shadows:          '); ImGui.SameLine(); if ImGui.Checkbox(&'##render_shadows', [light_node.shadow_enabled]):
		light_node.shadow_enabled = not light_node.shadow_enabled

	ImGui.SeparatorText(&'Hairstyle Parameters')
	ImGui.Text('Hairstyle:               '); ImGui.SameLine(); if ImGui.Combo(&'##hairstyle', _current_hairstyle, hairstyle_names): change_hairstyle(_current_hairstyle[0])
	var shader_material: ShaderMaterial = head_node.get_child(_current_hairstyle[0]).get_active_material(0)
	var hair_color: Color = shader_material.get_shader_parameter('albedo')

	ImGui.Text('Hairstyle Color:         '); ImGui.SetItemTooltip('The averaged multiple-scattering color of the hair.'); ImGui.SameLine(); if ImGui.ColorButtonEx(&'##hairstyle_color', hair_color, ImGui.ColorEditFlags_Float, Vector2(ImGui.GetColumnWidth(), ImGui.GetFrameHeight())): ImGui.OpenPopup('hairstyle_color_picker')
	if ImGui.BeginPopup('hairstyle_color_picker'):
		var hairstyle_color := [hair_color.r, hair_color.g, hair_color.b]
		if ImGui.ColorPicker3(&'##hairstyle_color_picker', hairstyle_color, ImGui.ColorEditFlags_Float | ImGui.ColorEditFlags_NoSidePreview | ImGui.ColorEditFlags_NoSmallPreview | ImGui.ColorEditFlags_PickerHueWheel | ImGui.ColorEditFlags_DisplayRGB | ImGui.ColorEditFlags_DisplayHex):
			shader_material.set_shader_parameter(&'albedo', Color(hairstyle_color[0], hairstyle_color[1], hairstyle_color[2]))
		ImGui.EndPopup()

	var longitudinal_roughness := [shader_material.get_shader_parameter('longitudinal_roughness')]
	ImGui.Text('Roughness (Longitudinal):'); ImGui.SetItemTooltip('Controls the highlight width (in radians) *along* hair strands.\nEffectively controls the overall *shininess* of the hair.'); ImGui.SameLine(); if ImGui.SliderFloatEx(&'##longitudinal_roughness', longitudinal_roughness, 0.0, 1.0, '%.3f', ImGui.SliderFlags_AlwaysClamp):
		shader_material.set_shader_parameter(&'longitudinal_roughness', longitudinal_roughness[0])

	var azimuthal_roughness := [shader_material.get_shader_parameter('azimuthal_roughness')]
	ImGui.Text('Roughness (Azimuthal):   '); ImGui.SetItemTooltip('Controls the highlight width (in radians) *around* hair strands.\nEffectively controls the overall *softness* of the hair.'); ImGui.SameLine(); if ImGui.SliderFloatEx(&'##azimuthal_roughness', azimuthal_roughness, 0.0, 1.0, '%.3f', ImGui.SliderFlags_AlwaysClamp):
		shader_material.set_shader_parameter(&'azimuthal_roughness', azimuthal_roughness[0])

	var specular := [shader_material.get_shader_parameter('specular')]
	ImGui.Text('Specular:                '); ImGui.SameLine(); if ImGui.SliderFloatEx(&'##specular', specular, 0.0, 1.0, '%.2f'):
		shader_material.set_shader_parameter(&'specular', specular[0])

	var cuticle_tilt_offset := [rad_to_deg(shader_material.get_shader_parameter('cuticle_tilt_offset'))]
	ImGui.Text('Cuticle Tilt Offset:     '); ImGui.SetItemTooltip('Adjusts the angled offset (in radians) of cuticle scales. A positive\nvalue denotes an outward tilt. Increasing causes the highlights of\nlobes to separate.'); ImGui.SameLine(); if ImGui.SliderFloatEx(&'##cuticle_tilt_offset', cuticle_tilt_offset, 0.0, 20.0, '%.1f°'):
		shader_material.set_shader_parameter(&'cuticle_tilt_offset', deg_to_rad(cuticle_tilt_offset[0]))

	ImGui.SeparatorText(&'Lobe Debug Parameters')
	for i in range(3):
		var lobe_name: String = ['R', 'TT', 'TRT'][i]
		var lobe_description: String = [
			'Denotes paths where light rays reflect (R) off the front surface of fiber.',
			'Denotes paths where light rays transmit (T) into fiber,\nthen transmit again (T) out the back.',
			'Denotes paths where light rays transmit (T) into fiber,\nreflect (R) off the back, then transmit again (T) out\nthe front.',
		][i]
		ImGui.Text(('p=%d (%s Lobe):' % [i, lobe_name]).rpad(25)); ImGui.SetItemTooltip(lobe_description); ImGui.SameLine()
		if ImGui.Checkbox(&'##%s_enable' % lobe_name, [_lobe_enabled[i]]):
			_lobe_enabled[i] = ~_lobe_enabled[i] & 0x1
			shader_material.set_shader_parameter(&'lobe_scales', Vector3(_lobe_enabled) * _lobe_scales)

		var lobe_scale := [_lobe_scales[i]]
		ImGui.SameLine(); ImGui.SetNextItemWidth(ImGui.GetColumnWidth()); ImGui.BeginDisabled(not _lobe_enabled[i])
		if ImGui.SliderFloatEx(&'##%s_scale' % lobe_name, lobe_scale, 0.0, 5.0, '%.1f'):
			_lobe_scales[i] = lobe_scale[0]
			shader_material.set_shader_parameter(&'lobe_scales', Vector3(_lobe_enabled) * _lobe_scales)
		ImGui.EndDisabled()

	ImGui.SeparatorText(&'Camera')
	ImGui.Text('Camera Position:          %+.2v' % camera.global_position)
	var camera_fov := [camera.fov]
	ImGui.Text('Camera FOV:              '); ImGui.SameLine(); if ImGui.SliderFloatEx(&'##fov', camera_fov, 20, 170, '%.1f°'): camera.fov = clampf(camera_fov[0], 1, 179)

	ImGui.Dummy(Vector2(0,0)); ImGui.Separator(); ImGui.Dummy(Vector2(0,0))
	ImGui.PushStyleColor(ImGui.Col_Text, Color.WEB_GRAY)
	ImGui.Text('Press %s-H to toggle GUI visibility!' % ('Cmd' if OS.get_name() == 'macOS' else 'Ctrl'))
	if not window.is_embedded() and not Engine.is_embedded_in_editor():
		ImGui.Text('Press %s-F to toggle fullscreen!' % ('Cmd' if OS.get_name() == 'macOS' else 'Ctrl'))
	ImGui.Text('Press Left/Right arrow keys to change hairstyles!')
	ImGui.Text('Hold Shift to reposition the light source!')
	ImGui.PopStyleColor()

	# Offset camera frustum to appear at midpoint between ImGUI window edge and actual window edge...
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED and (ImGui.GetWindowWidth() + IMGUI_WINDOW_MARGIN_PX) / size.x < 0.25:
		# ...unless the window is not windowed and there is sufficient space for the node to appear centered instead.
		camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	else:
		var height := camera.near * tan(deg_to_rad(camera.fov) * 0.5)*2.0
		var offset := Vector2.LEFT * (ImGui.GetWindowWidth() + IMGUI_WINDOW_MARGIN_PX) / size.y * height*0.5
		camera.set_frustum(height, offset, camera.near, camera.far)

	ImGui.End()
	ImGui.PopStyleVar()


func change_hairstyle(index: int) -> void:
	if not head_node or head_node.get_child_count() == 0:
		return
	for i in head_node.get_child_count():
		head_node.get_child(i).visible = i == index

	var shader_material: ShaderMaterial = head_node.get_child(_current_hairstyle[0]).get_active_material(0)
	shader_material.set_shader_parameter(&'lobe_scales', Vector3(_lobe_enabled) * _lobe_scales)

	# Prevent ghosting by disabling anti-aliasing for one frame.
	change_denoising_mode(DenoisingMode.DENOISING_MODE_NONE, 1.0)
	await get_tree().process_frame
	change_denoising_mode(_denoising_mode, _render_scales[_denoising_mode])


func change_denoising_mode(mode: DenoisingMode, scale: float) -> void:
	if not viewport:
		return
	viewport.use_taa = mode == DenoisingMode.DENOISING_MODE_TAA
	viewport.scaling_3d_mode = Viewport.Scaling3DMode.SCALING_3D_MODE_FSR2 if mode == DenoisingMode.DENOISING_MODE_FSR2 else Viewport.Scaling3DMode.SCALING_3D_MODE_BILINEAR
	viewport.scaling_3d_scale = scale
