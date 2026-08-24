extends SceneTree

## Per-process GPU benchmark for hair-card coverage strategies.
## Uses the Blowout groom and the shared card-preparation path with trivial
## unshaded output so the measured delta is dominated by coverage handling.

const GROOM_ID := &"Blowout"
const MODE_NO_HAIR := 0
const MODE_INDIVIDUAL_GROOM := 1
const VARIANT_NO_HAIR := 0
const VARIANT_APPROX := 3
const TAA_PHASE_COUNT := 16

const DEFAULT_RESOLUTION := Vector2i(1920, 1080)
const DEFAULT_PREWARM := 120
const DEFAULT_SETTLE := 30
const DEFAULT_SAMPLE := 300

const ProfileTemplate: Resource = preload("res://demos/resources/hair_material_profile_demo.tres")
const GroomData: Resource = preload("res://demos/resources/blowout_groom_data.tres")
const LEGACY_SHADER: Shader = preload("res://benchmark/shaders/hair_card_cost_control.gdshader")
const BAYER_SHADER: Shader = preload("res://benchmark/shaders/hair_coverage_bayer_probe.gdshader")
const HASH_SHADER: Shader = preload("res://benchmark/shaders/hair_coverage_alpha_hash_probe.gdshader")
const A2C_SHADER: Shader = preload("res://benchmark/shaders/hair_coverage_a2c_probe.gdshader")

var _options := {
	"mode": "static_bayer",
	"taa": false,
	"msaa": 0,
	"resolution": DEFAULT_RESOLUTION,
	"prewarm": DEFAULT_PREWARM,
	"settle": DEFAULT_SETTLE,
	"sample": DEFAULT_SAMPLE,
}
var _material: ShaderMaterial
var _phase_counter := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_parse_options()
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		push_error("Coverage benchmark requires a real Forward+/Mobile RenderingDevice")
		quit(1)
		return

	root.size = _options["resolution"]
	root.use_taa = bool(_options["taa"])
	root.msaa_3d = _msaa_value(int(_options["msaa"]))

	var packed: PackedScene = load("res://benchmark/BenchmarkHarness.tscn")
	if packed == null:
		push_error("BenchmarkHarness.tscn failed to load")
		quit(1)
		return
	var harness := packed.instantiate()
	root.add_child(harness)
	for _i in 12:
		await RenderingServer.frame_post_draw

	var controller: Node = harness.get_node_or_null("BenchmarkController")
	var groom := _find_groom(controller, GROOM_ID)
	if controller == null or groom == null:
		push_error("Coverage benchmark could not resolve controller/groom")
		quit(1)
		return

	_material = _build_material()
	if _material == null:
		quit(1)
		return

	var viewport_rid := root.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport_rid, true)
	for _i in 12:
		await RenderingServer.frame_post_draw

	var no_hair := await _measure_no_hair(controller, viewport_rid)
	_set_shader_parameter(&"show_hair_cards", true)
	var cards := await _measure_material(controller, groom, "CARDS_PIPELINE_CONTROL", viewport_rid)
	_set_shader_parameter(&"show_hair_cards", false)
	_phase_counter = 0
	var coverage := await _measure_material(controller, groom, "COVERAGE", viewport_rid)

	coverage["incremental_vs_cards_ms"] = float(coverage.get("gpu_median_ms", 0.0)) - float(cards.get("gpu_median_ms", 0.0))
	coverage["incremental_vs_no_hair_ms"] = float(coverage.get("gpu_median_ms", 0.0)) - float(no_hair.get("gpu_median_ms", 0.0))

	var payload := {
		"schema": "hair_coverage_runtime_v1",
		"mode": _options["mode"],
		"taa_requested": _options["taa"],
		"taa_effective_property": root.use_taa,
		"msaa_3d": int(root.msaa_3d),
		"msaa_requested_samples": _options["msaa"],
		"resolution": {"x": root.size.x, "y": root.size.y},
		"taa_phase_policy": _phase_policy(),
		"taa_phase_count": TAA_PHASE_COUNT if String(_options["mode"]) == "taa_bayer" else 0,
		"sampling": {"prewarm": _options["prewarm"], "settle": _options["settle"], "sample": _options["sample"]},
		"gpu": {"name": RenderingServer.get_video_adapter_name(), "vendor": RenderingServer.get_video_adapter_vendor(), "api": RenderingServer.get_video_adapter_api_version()},
		"results": [no_hair, cards, coverage],
	}
	print("HAIR_COVERAGE_BENCHMARK_JSON:" + JSON.stringify(payload))
	print("HAIR_COVERAGE_RUNTIME_BENCHMARK_OK")
	quit(0)


func _parse_options() -> void:
	for value in OS.get_cmdline_user_args():
		var arg := String(value)
		if arg.begins_with("--mode="):
			_options["mode"] = arg.trim_prefix("--mode=")
		elif arg.begins_with("--taa="):
			_options["taa"] = int(arg.trim_prefix("--taa=")) != 0
		elif arg.begins_with("--msaa="):
			_options["msaa"] = int(arg.trim_prefix("--msaa="))
		elif arg.begins_with("--resolution="):
			var parts := arg.trim_prefix("--resolution=").to_lower().split("x")
			if parts.size() == 2:
				_options["resolution"] = Vector2i(maxi(int(parts[0]), 64), maxi(int(parts[1]), 64))
		elif arg.begins_with("--prewarm="):
			_options["prewarm"] = maxi(int(arg.trim_prefix("--prewarm=")), 0)
		elif arg.begins_with("--settle="):
			_options["settle"] = maxi(int(arg.trim_prefix("--settle=")), 0)
		elif arg.begins_with("--sample="):
			_options["sample"] = maxi(int(arg.trim_prefix("--sample=")), 1)

	var valid_modes := ["legacy_time_bayer", "static_bayer", "taa_bayer", "alpha_hash", "a2c"]
	if not valid_modes.has(String(_options["mode"])):
		push_error("Unsupported --mode: %s" % _options["mode"])
		quit(2)


func _msaa_value(samples: int) -> int:
	match samples:
		2:
			return Viewport.MSAA_2X
		4:
			return Viewport.MSAA_4X
		8:
			return Viewport.MSAA_8X
		_:
			return Viewport.MSAA_DISABLED


func _find_groom(controller: Node, groom_id: StringName) -> MeshInstance3D:
	if controller == null:
		return null
	for entry_value in controller.get(&"groom_catalog"):
		var entry: Dictionary = entry_value
		if StringName(entry.get("groom_id", &"")) == groom_id:
			return entry.get("node") as MeshInstance3D
	return null


func _build_material() -> ShaderMaterial:
	var shader: Shader
	match String(_options["mode"]):
		"legacy_time_bayer":
			shader = LEGACY_SHADER
		"static_bayer", "taa_bayer":
			shader = BAYER_SHADER
		"alpha_hash":
			shader = HASH_SHADER
		"a2c":
			shader = A2C_SHADER
	if shader == null:
		push_error("Coverage probe shader is null")
		return null

	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter(&"coords_texture", GroomData.get(&"coords_texture"))
	material.set_shader_parameter(&"attributes_texture", GroomData.get(&"attributes_texture"))
	material.set_shader_parameter(&"albedo", ProfileTemplate.get(&"albedo"))
	material.set_shader_parameter(&"longitudinal_roughness", ProfileTemplate.get(&"longitudinal_roughness"))
	_set_if_declared(material, &"show_hashed_strands", false)
	_set_if_declared(material, &"show_hair_cards", false)
	if String(_options["mode"]) == "legacy_time_bayer":
		_set_if_declared(material, &"freeze_bayer_phase", false)
	if String(_options["mode"]) == "static_bayer":
		_set_if_declared(material, &"bayer_phase_index", 0)
	return material


func _set_shader_parameter(name: StringName, value: Variant) -> void:
	_set_if_declared(_material, name, value)


func _set_if_declared(material: ShaderMaterial, name: StringName, value: Variant) -> void:
	if material == null or material.shader == null:
		return
	for info_value in material.shader.get_shader_uniform_list():
		var info: Dictionary = info_value
		if StringName(info.get("name", "")) == name:
			material.set_shader_parameter(name, value)
			return


func _before_render_frame() -> void:
	if String(_options["mode"]) == "taa_bayer":
		_set_shader_parameter(&"bayer_phase_index", _phase_counter & (TAA_PHASE_COUNT - 1))
		_phase_counter += 1


func _measure_no_hair(controller: Node, viewport_rid: RID) -> Dictionary:
	if not bool(controller.call(&"apply_preview", MODE_NO_HAIR, VARIANT_NO_HAIR, GROOM_ID)):
		return {"name": "NO_HAIR", "error": "apply_preview failed"}
	return await _measure("NO_HAIR", viewport_rid)


func _measure_material(controller: Node, groom: MeshInstance3D, label: String, viewport_rid: RID) -> Dictionary:
	if not bool(controller.call(&"apply_preview", MODE_INDIVIDUAL_GROOM, VARIANT_APPROX, GROOM_ID)):
		return {"name": label, "error": "visibility setup failed"}
	for surface in groom.get_surface_override_material_count():
		groom.set_surface_override_material(surface, _material)
	for _i in 4:
		_before_render_frame()
		await RenderingServer.frame_post_draw
	return await _measure(label, viewport_rid)


func _measure(label: String, viewport_rid: RID) -> Dictionary:
	for _i in int(_options["prewarm"]):
		_before_render_frame()
		await RenderingServer.frame_post_draw
	for _i in int(_options["settle"]):
		_before_render_frame()
		await RenderingServer.frame_post_draw
	var gpu: Array[float] = []
	for _i in int(_options["sample"]):
		_before_render_frame()
		await RenderingServer.frame_post_draw
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid))
	gpu.sort()
	return {
		"name": label,
		"gpu_median_ms": _percentile(gpu, 0.5),
		"gpu_p95_ms": _percentile(gpu, 0.95),
		"gpu_p99_ms": _percentile(gpu, 0.99),
		"gpu_min_ms": gpu.front() if not gpu.is_empty() else 0.0,
		"gpu_max_ms": gpu.back() if not gpu.is_empty() else 0.0,
		"sample_count": gpu.size(),
	}


func _phase_policy() -> String:
	match String(_options["mode"]):
		"legacy_time_bayer":
			return "TIME*500 legacy animation"
		"static_bayer":
			return "fixed phase 0"
		"taa_bayer":
			return "one 0..15 phase per rendered frame; period matched to Godot 4.7 TAA"
	return "not applicable"


func _percentile(values: Array[float], fraction: float) -> float:
	if values.is_empty():
		return 0.0
	var index := clampi(int(round(fraction * float(values.size() - 1))), 0, values.size() - 1)
	return values[index]
