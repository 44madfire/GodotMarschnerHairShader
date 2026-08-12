extends SceneTree

## Runtime benchmark for the four production HairMaterialProfile tiers plus
## common-card, synthetic ALU, and synthetic 3D-LUT sensitivity controls.
##
## IMPORTANT: run this with a real display/rendering device, not --headless.
## Use Godot's --gpu-index option to target a specific Forward+/Mobile GPU.

const GROOM_ID := &"Blowout"
const MODE_NO_HAIR := 0
const MODE_INDIVIDUAL_GROOM := 1
const VARIANT_NO_HAIR := 0
const VARIANT_APPROX := 3

const TIER_APPROX := 0
const TIER_FAST := 1
const TIER_CINEMATIC := 2
const TIER_REFERENCE := 3
const TIER_NAMES := ["APPROX_KAJIYA_KAY", "FAST_MARSCHNER", "CINEMATIC_MARSCHNER", "REFERENCE_MARSCHNER"]

const DEFAULT_RESOLUTION := Vector2i(1920, 1080)
const DEFAULT_PREWARM := 120
const DEFAULT_SETTLE := 30
const DEFAULT_SAMPLE := 300
const FROZEN_TIME_SCALE := 1e-6

const ProfileTemplate: Resource = preload("res://demos/resources/hair_material_profile_demo.tres")
const GroomData: Resource = preload("res://demos/resources/blowout_groom_data.tres")
const LUTAdapterScript := preload("res://assets/hair/materials/HairMarschnerLUTAdapter.gd")
const CARD_CONTROL_SHADER: Shader = preload("res://benchmark/shaders/hair_card_cost_control.gdshader")
const ALU_PROBE_SHADER: Shader = preload("res://benchmark/shaders/hair_alu_cost_probe.gdshader")
const LUT_PROBE_SHADER: Shader = preload("res://benchmark/shaders/hair_lut_cost_probe.gdshader")

var _options := {
	"resolution": DEFAULT_RESOLUTION,
	"extra_lights": 0,
	"coverage_mode": "cards",
	"prewarm": DEFAULT_PREWARM,
	"settle": DEFAULT_SETTLE,
	"sample": DEFAULT_SAMPLE,
	"repeat_index": 0,
	"include_probes": true,
}
var _failures := PackedStringArray()
var _saved_time_scale := 1.0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_parse_options()
	_saved_time_scale = Engine.time_scale
	Engine.time_scale = FROZEN_TIME_SCALE

	var rd: RenderingDevice = RenderingServer.get_rendering_device()
	if rd == null:
		_fail("No global RenderingDevice is available. Do not run the GPU benchmark with --headless or gl_compatibility.")
		_finish_failure()
		return

	var lut_adapter: RefCounted = LUTAdapterScript.new()
	var missing: PackedStringArray = lut_adapter.call(&"missing_default_resources")
	if not missing.is_empty():
		for message in missing:
			_fail(String(message))
		_finish_failure()
		return

	var packed: PackedScene = load("res://benchmark/BenchmarkHarness.tscn")
	if packed == null:
		_fail("BenchmarkHarness.tscn failed to load")
		_finish_failure()
		return
	var harness: Node = packed.instantiate()
	root.add_child(harness)
	root.size = _options["resolution"]
	for _i in 8:
		await RenderingServer.frame_post_draw

	var controller: Node = harness.get_node_or_null("BenchmarkController")
	if controller == null:
		_fail("BenchmarkController missing")
		_finish_failure()
		return
	var groom: MeshInstance3D = _find_groom(controller, GROOM_ID)
	if groom == null:
		_fail("Blowout groom missing from benchmark catalog")
		_finish_failure()
		return

	var extra_lights: Array[DirectionalLight3D] = _install_extra_lights(harness, int(_options["extra_lights"]))
	var production_materials: Dictionary = _build_production_materials()
	if production_materials.size() != 4:
		_finish_failure()
		return
	var probe_materials: Dictionary = _build_probe_materials(lut_adapter)
	if bool(_options["include_probes"]) and probe_materials.size() != 3:
		_finish_failure()
		return

	var viewport_rid: RID = root.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport_rid, true)
	for _i in 12:
		await RenderingServer.frame_post_draw

	var results: Array[Dictionary] = []
	var baseline: Dictionary = await _measure_no_hair(controller, viewport_rid)
	results.append(baseline)
	var baseline_gpu: float = float(baseline.get("gpu_median_ms", 0.0))

	var card_control_gpu := 0.0
	if bool(_options["include_probes"]):
		var card_result: Dictionary = await _measure_material(controller, groom, probe_materials["CARD_CONTROL"], "CARD_CONTROL", viewport_rid)
		card_result["incremental_vs_no_hair_ms"] = float(card_result.get("gpu_median_ms", 0.0)) - baseline_gpu
		card_control_gpu = float(card_result.get("gpu_median_ms", 0.0))
		results.append(card_result)

		var alu_result: Dictionary = await _measure_material(controller, groom, probe_materials["ALU_PROBE_96"], "ALU_PROBE_96", viewport_rid)
		alu_result["incremental_vs_no_hair_ms"] = float(alu_result.get("gpu_median_ms", 0.0)) - baseline_gpu
		alu_result["incremental_vs_card_control_ms"] = float(alu_result.get("gpu_median_ms", 0.0)) - card_control_gpu
		results.append(alu_result)

		var lut_result: Dictionary = await _measure_material(controller, groom, probe_materials["LUT_PROBE_16"], "LUT_PROBE_16", viewport_rid)
		lut_result["incremental_vs_no_hair_ms"] = float(lut_result.get("gpu_median_ms", 0.0)) - baseline_gpu
		lut_result["incremental_vs_card_control_ms"] = float(lut_result.get("gpu_median_ms", 0.0)) - card_control_gpu
		results.append(lut_result)

	var tier_order: Array[int] = _tier_order_for_repeat(int(_options["repeat_index"]))
	for tier in tier_order:
		var label: String = TIER_NAMES[tier]
		var tier_result: Dictionary = await _measure_material(controller, groom, production_materials[tier], label, viewport_rid)
		tier_result["tier"] = tier
		tier_result["incremental_vs_no_hair_ms"] = float(tier_result.get("gpu_median_ms", 0.0)) - baseline_gpu
		if bool(_options["include_probes"]):
			tier_result["incremental_vs_card_control_ms"] = float(tier_result.get("gpu_median_ms", 0.0)) - card_control_gpu
		results.append(tier_result)

	var payload := {
		"schema": "production_hair_tier_runtime_v2",
		"groom": String(GROOM_ID),
		"gpu": _gpu_metadata(rd),
		"workload": {
			"requested_resolution": _vector2i_json(_options["resolution"]),
			"actual_viewport_size": _vector2i_json(root.size),
			"coverage_mode": _options["coverage_mode"],
			"show_hair_cards": _show_cards(),
			"base_directional_lights": 1,
			"extra_directional_lights": extra_lights.size(),
			"total_directional_lights": 1 + extra_lights.size(),
			"extra_light_shadows": false,
			"time_scale": Engine.time_scale,
		},
		"sampling": {
			"prewarm_frames": int(_options["prewarm"]),
			"settle_frames": int(_options["settle"]),
			"sample_frames": int(_options["sample"]),
			"repeat_index": int(_options["repeat_index"]),
			"tier_order": tier_order,
		},
		"results": results,
		"interpretation": {
			"card_control": "Shared groom/card preparation with trivial unshaded output.",
			"alu_probe": "Shared card preparation plus a fixed 96-iteration dependent arithmetic chain. This calibrates device ALU sensitivity; it is not a production instruction count.",
			"lut_probe": "Shared card preparation plus 16 dependent trilinear 3D LUT samples. This calibrates texture/LUT sensitivity; it is not a decomposition of a production tier.",
			"production": "Full production shader timings. Compare process-level repeats, resolution scaling, and light-count scaling rather than attributing exact milliseconds to individual source operations."
		},
	}
	print("HAIR_BENCHMARK_JSON:" + JSON.stringify(payload))
	print("PRODUCTION_HAIR_TIER_RUNTIME_BENCHMARK_OK")
	Engine.time_scale = _saved_time_scale
	quit(0)


func _parse_options() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--resolution="):
			var value := argument.trim_prefix("--resolution=").to_lower().split("x")
			if value.size() == 2:
				_options["resolution"] = Vector2i(maxi(int(value[0]), 64), maxi(int(value[1]), 64))
		elif argument.begins_with("--extra-lights="):
			_options["extra_lights"] = clampi(int(argument.trim_prefix("--extra-lights=")), 0, 15)
		elif argument.begins_with("--coverage="):
			var mode := argument.trim_prefix("--coverage=").to_lower()
			_options["coverage_mode"] = mode if mode == "coverage" else "cards"
		elif argument.begins_with("--prewarm="):
			_options["prewarm"] = maxi(int(argument.trim_prefix("--prewarm=")), 0)
		elif argument.begins_with("--settle="):
			_options["settle"] = maxi(int(argument.trim_prefix("--settle=")), 0)
		elif argument.begins_with("--sample="):
			_options["sample"] = maxi(int(argument.trim_prefix("--sample=")), 1)
		elif argument.begins_with("--repeat-index="):
			_options["repeat_index"] = maxi(int(argument.trim_prefix("--repeat-index=")), 0)
		elif argument == "--no-probes":
			_options["include_probes"] = false


func _find_groom(controller: Node, groom_id: StringName) -> MeshInstance3D:
	for entry_value in controller.get(&"groom_catalog"):
		var entry: Dictionary = entry_value
		if StringName(entry.get("groom_id", &"")) == groom_id:
			return entry.get("node") as MeshInstance3D
	return null


func _build_production_materials() -> Dictionary:
	var materials: Dictionary = {}
	for tier in 4:
		var profile: Resource = ProfileTemplate.duplicate(true)
		profile.set(&"quality_tier", tier)
		var material: ShaderMaterial = profile.call(&"create_material", GroomData) as ShaderMaterial
		if material == null or material.shader == null:
			_fail("Failed to create production material for tier %d" % tier)
			continue
		if not bool(profile.call(&"apply_to", material, GroomData)):
			_fail("Failed to bind profile/groom/LUT for tier %d" % tier)
			continue
		_pin_material(material)
		materials[tier] = material
	return materials


func _build_probe_materials(lut_adapter: RefCounted) -> Dictionary:
	var materials: Dictionary = {}
	var card_control := _make_probe_material(CARD_CONTROL_SHADER)
	var alu_probe := _make_probe_material(ALU_PROBE_SHADER)
	var lut_probe := _make_probe_material(LUT_PROBE_SHADER)
	if card_control == null or alu_probe == null or lut_probe == null:
		_fail("Failed to construct one or more benchmark probe materials")
		return materials

	var cinematic_data: Resource = lut_adapter.call(&"load_default_cinematic_data") as Resource
	var lut_texture: Texture3D = lut_adapter.call(&"texture3d_from_resource", cinematic_data) as Texture3D
	if lut_texture == null:
		_fail("Failed to reconstruct Cinematic Texture3D for LUT sampling probe")
		return materials
	lut_probe.set_shader_parameter(&"probe_lut", lut_texture)

	materials["CARD_CONTROL"] = card_control
	materials["ALU_PROBE_96"] = alu_probe
	materials["LUT_PROBE_16"] = lut_probe
	return materials


func _make_probe_material(shader: Shader) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter(&"coords_texture", GroomData.get(&"coords_texture"))
	material.set_shader_parameter(&"attributes_texture", GroomData.get(&"attributes_texture"))
	material.set_shader_parameter(&"albedo", ProfileTemplate.get(&"albedo"))
	material.set_shader_parameter(&"longitudinal_roughness", ProfileTemplate.get(&"longitudinal_roughness"))
	_pin_material(material)
	return material


func _pin_material(material: ShaderMaterial) -> void:
	if material == null or material.shader == null:
		return
	_set_if_declared(material, &"show_hair_cards", _show_cards())
	_set_if_declared(material, &"show_hashed_strands", false)
	_set_if_declared(material, &"freeze_bayer_phase", true)
	_set_if_declared(material, &"comparison_exposure_gain", 1.0)
	_set_if_declared(material, &"lobe_scales", Vector3.ONE)
	_set_if_declared(material, &"use_area_light_multipliers", true)


func _show_cards() -> bool:
	return String(_options["coverage_mode"]) == "cards"


func _set_if_declared(material: ShaderMaterial, parameter_name: StringName, value: Variant) -> void:
	for info_value in material.shader.get_shader_uniform_list():
		var info: Dictionary = info_value
		if StringName(info.get("name", "")) == parameter_name:
			material.set_shader_parameter(parameter_name, value)
			return


func _install_extra_lights(harness: Node, count: int) -> Array[DirectionalLight3D]:
	var result: Array[DirectionalLight3D] = []
	var host: Node3D = harness.get_node_or_null("CaseLightingRigHost") as Node3D
	if host == null:
		_fail("CaseLightingRigHost missing")
		return result
	for i in count:
		var light := DirectionalLight3D.new()
		light.name = "CostLight%02d" % i
		light.shadow_enabled = false
		light.light_specular = 1.0
		light.light_intensity_lux = 12000.0
		light.rotation_degrees = Vector3(-30.0 + float(i % 3) * 17.0, float(i) * 47.0, float(i % 2) * 13.0)
		host.add_child(light)
		result.append(light)
	return result


func _measure_no_hair(controller: Node, viewport_rid: RID) -> Dictionary:
	if not bool(controller.call(&"apply_preview", MODE_NO_HAIR, VARIANT_NO_HAIR, GROOM_ID)):
		return {"name": "NO_HAIR", "error": "apply_preview failed"}
	return await _measure("NO_HAIR", viewport_rid)


func _measure_material(controller: Node, groom: MeshInstance3D, material: ShaderMaterial, label: String, viewport_rid: RID) -> Dictionary:
	if not bool(controller.call(&"apply_preview", MODE_INDIVIDUAL_GROOM, VARIANT_APPROX, GROOM_ID)):
		return {"name": label, "error": "visibility setup failed"}
	for surface in groom.get_surface_override_material_count():
		groom.set_surface_override_material(surface, material)
	for _i in 4:
		await RenderingServer.frame_post_draw
	return await _measure(label, viewport_rid)


func _measure(label: String, viewport_rid: RID) -> Dictionary:
	for _i in int(_options["prewarm"]):
		await RenderingServer.frame_post_draw
	for _i in int(_options["settle"]):
		await RenderingServer.frame_post_draw

	var gpu: Array[float] = []
	var cpu: Array[float] = []
	for _i in int(_options["sample"]):
		await RenderingServer.frame_post_draw
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid))
		cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid))
	gpu.sort()
	cpu.sort()
	var result := _distribution(label, gpu, cpu)
	result["render_info"] = _render_info(viewport_rid)
	return result


func _distribution(label: String, gpu: Array[float], cpu: Array[float]) -> Dictionary:
	var gpu_median := _percentile(gpu, 0.5)
	var deviations: Array[float] = []
	for value in gpu:
		deviations.append(abs(value - gpu_median))
	deviations.sort()
	return {
		"name": label,
		"gpu_median_ms": gpu_median,
		"gpu_p90_ms": _percentile(gpu, 0.90),
		"gpu_p95_ms": _percentile(gpu, 0.95),
		"gpu_p99_ms": _percentile(gpu, 0.99),
		"gpu_mean_ms": _mean(gpu),
		"gpu_stddev_ms": _stddev(gpu),
		"gpu_mad_ms": _percentile(deviations, 0.5),
		"gpu_min_ms": gpu.front() if not gpu.is_empty() else 0.0,
		"gpu_max_ms": gpu.back() if not gpu.is_empty() else 0.0,
		"cpu_median_ms": _percentile(cpu, 0.5),
		"cpu_p95_ms": _percentile(cpu, 0.95),
		"sample_count": gpu.size(),
	}


func _render_info(viewport_rid: RID) -> Dictionary:
	return {
		"visible_objects": RenderingServer.viewport_get_render_info(viewport_rid, 0, 0),
		"visible_primitives": RenderingServer.viewport_get_render_info(viewport_rid, 0, 1),
		"visible_draw_calls": RenderingServer.viewport_get_render_info(viewport_rid, 0, 2),
		"shadow_objects": RenderingServer.viewport_get_render_info(viewport_rid, 1, 0),
		"shadow_primitives": RenderingServer.viewport_get_render_info(viewport_rid, 1, 1),
		"shadow_draw_calls": RenderingServer.viewport_get_render_info(viewport_rid, 1, 2),
	}


func _tier_order_for_repeat(repeat_index: int) -> Array[int]:
	var base: Array[int] = [TIER_APPROX, TIER_FAST, TIER_CINEMATIC, TIER_REFERENCE]
	if repeat_index % 2 == 1:
		base.reverse()
	var offset := repeat_index % base.size()
	var result: Array[int] = []
	for i in base.size():
		result.append(base[(i + offset) % base.size()])
	return result


func _gpu_metadata(rd: RenderingDevice) -> Dictionary:
	var adapter_type: int = RenderingServer.get_video_adapter_type()
	return {
		"name": RenderingServer.get_video_adapter_name(),
		"vendor": RenderingServer.get_video_adapter_vendor(),
		"api_version": RenderingServer.get_video_adapter_api_version(),
		"device_type": adapter_type,
		"device_type_name": _device_type_name(adapter_type),
		"rd_name": rd.get_device_name(),
		"rd_vendor": rd.get_device_vendor_name(),
		"pipeline_cache_uuid": rd.get_device_pipeline_cache_uuid(),
	}


func _device_type_name(device_type: int) -> String:
	match device_type:
		1: return "integrated_gpu"
		2: return "discrete_gpu"
		3: return "virtual_gpu"
		4: return "cpu"
		_: return "other"


func _vector2i_json(value: Variant) -> Dictionary:
	var v: Vector2i = value
	return {"x": v.x, "y": v.y, "pixels": v.x * v.y}


func _percentile(values: Array[float], fraction: float) -> float:
	if values.is_empty():
		return 0.0
	var index := clampi(int(round(fraction * float(values.size() - 1))), 0, values.size() - 1)
	return values[index]


func _mean(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for value in values:
		total += value
	return total / float(values.size())


func _stddev(values: Array[float]) -> float:
	if values.size() < 2:
		return 0.0
	var average := _mean(values)
	var sum_sq := 0.0
	for value in values:
		var delta := value - average
		sum_sq += delta * delta
	return sqrt(sum_sq / float(values.size() - 1))


func _fail(message: String) -> void:
	_failures.append(message)
	push_error(message)


func _finish_failure() -> void:
	Engine.time_scale = _saved_time_scale
	print("PRODUCTION_HAIR_TIER_RUNTIME_BENCHMARK_FAILED")
	quit(1)
