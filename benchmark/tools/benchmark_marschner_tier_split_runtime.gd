extends SceneTree

## Local GPU timing study for the new quality split.
## Compares the same Blowout groom/viewport across:
##   analytic high-tier baseline
##   current Fast analytic
##   Unity Standard-style Fast
##   energy-conserving Cinematic LUT
## LUT resources must be generated before running this script.

const GROOM_ID := &"Blowout"
const INDIVIDUAL_GROOM := 1
const CURRENT_BASELINE := 2
const CURRENT_FAST := 5
const PREWARM := 180
const SETTLE := 30
const SAMPLE := 600

const ExistingAdapter := preload("res://benchmark/scripts/hair_material_adapter.gd")
const TierAdapter := preload("res://benchmark/scripts/hair_marschner_tier_lut_adapter.gd")
const UNITY_SHADER: Shader = preload("res://assets/hair/materials/shaders/hair_marschner_unity_fast.gdshader")
const CINEMATIC_SHADER: Shader = preload("res://assets/hair/materials/shaders/hair_marschner_cinematic.gdshader")

var _failures := PackedStringArray()

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var tier_adapter := TierAdapter.new()
	var missing := tier_adapter.missing_resource_instructions()
	if not missing.is_empty():
		for message in missing:
			push_error(message)
		quit(1)
		return

	var packed: PackedScene = load("res://benchmark/BenchmarkHarness.tscn")
	if packed == null:
		push_error("BenchmarkHarness.tscn failed to load")
		quit(1)
		return
	var harness := packed.instantiate()
	root.add_child(harness)
	for i in 4:
		await RenderingServer.frame_post_draw
	var controller: Node = harness.get_node_or_null("BenchmarkController")
	if controller == null:
		push_error("BenchmarkController missing")
		quit(1)
		return
	var groom: MeshInstance3D
	for entry in controller.get(&"groom_catalog"):
		if String(entry.get("groom_id", "")) == String(GROOM_ID):
			groom = entry.get("node") as MeshInstance3D
			break
	if groom == null:
		push_error("Blowout groom missing")
		quit(1)
		return

	var base_adapter := ExistingAdapter.new()
	var profile: Resource = base_adapter.resolve_profile(&"source_current")
	if profile == null:
		push_error("source_current profile missing")
		quit(1)
		return

	var source := groom.material_override as ShaderMaterial
	if source == null:
		source = groom.get_surface_override_material(0) as ShaderMaterial
	if source == null and groom.mesh:
		source = groom.mesh.surface_get_material(0) as ShaderMaterial
	if source == null:
		push_error("Blowout source ShaderMaterial missing")
		quit(1)
		return
	var unity_material := base_adapter.make_shader_variant_material(source, UNITY_SHADER, profile)
	var cinematic_material := base_adapter.make_shader_variant_material(source, CINEMATIC_SHADER, profile)
	if unity_material == null or cinematic_material == null:
		push_error("failed to construct tier materials")
		quit(1)
		return
	if not tier_adapter.bind_unity_fast(unity_material):
		push_error("failed to bind Unity Fast LUT")
		quit(1)
		return
	if not tier_adapter.bind_cinematic(cinematic_material):
		push_error("failed to bind Cinematic LUT")
		quit(1)
		return
	_pin_material(unity_material)
	_pin_material(cinematic_material)

	var viewport_rid := root.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport_rid, true)
	var results := []
	results.append(await _measure_controller_variant(controller, groom, CURRENT_BASELINE, "CURRENT_MARSCHNER_BASELINE", viewport_rid))
	results.append(await _measure_controller_variant(controller, groom, CURRENT_FAST, "FAST_MARSCHNER_ANALYTIC", viewport_rid))
	results.append(await _measure_custom_variant(controller, groom, unity_material, "UNITY_STANDARD_FAST", viewport_rid))
	results.append(await _measure_custom_variant(controller, groom, cinematic_material, "ENERGY_CONSERVING_CINEMATIC", viewport_rid))

	var payload := {
		"schema": "marschner_tier_split_runtime_v1",
		"groom": String(GROOM_ID),
		"prewarm_frames": PREWARM,
		"settle_frames": SETTLE,
		"sample_frames": SAMPLE,
		"results": results,
		"notes": [
			"All variants use the same harness, groom, camera, and lighting state.",
			"show_hair_cards=true, exposure=1, lobe_scales=1, Bayer phase frozen where supported.",
			"GPU time is RenderingServer viewport measured render time; run multiple process-level repeats for promotion decisions."
		]
	}
	print(JSON.stringify(payload, "\t"))
	print("MARSCHNER_TIER_SPLIT_RUNTIME_BENCHMARK_OK")
	quit(0)

func _measure_controller_variant(controller: Node, groom: MeshInstance3D, variant: int, label: String, viewport_rid: RID) -> Dictionary:
	if not bool(controller.call(&"apply_preview", INDIVIDUAL_GROOM, variant, GROOM_ID)):
		return {"name": label, "error": "apply_preview failed"}
	for surface in groom.get_surface_override_material_count():
		var material := groom.get_surface_override_material(surface) as ShaderMaterial
		_pin_material(material)
	return await _measure(label, viewport_rid)

func _measure_custom_variant(controller: Node, groom: MeshInstance3D, material: ShaderMaterial, label: String, viewport_rid: RID) -> Dictionary:
	# Use the current Fast selector only to establish identical groom visibility/camera state,
	# then replace its surface override with the explicit tier shader.
	if not bool(controller.call(&"apply_preview", INDIVIDUAL_GROOM, CURRENT_FAST, GROOM_ID)):
		return {"name": label, "error": "visibility setup failed"}
	groom.set_surface_override_material(0, material)
	return await _measure(label, viewport_rid)

func _measure(label: String, viewport_rid: RID) -> Dictionary:
	for i in PREWARM:
		await RenderingServer.frame_post_draw
	for i in SETTLE:
		await RenderingServer.frame_post_draw
	var gpu: Array[float] = []
	var cpu: Array[float] = []
	for i in SAMPLE:
		await RenderingServer.frame_post_draw
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid))
		cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid))
	gpu.sort()
	cpu.sort()
	return {
		"name": label,
		"gpu_median_ms": _percentile(gpu, 0.5),
		"gpu_p95_ms": _percentile(gpu, 0.95),
		"cpu_median_ms": _percentile(cpu, 0.5),
		"cpu_p95_ms": _percentile(cpu, 0.95),
		"sample_count": gpu.size(),
	}

func _pin_material(material: ShaderMaterial) -> void:
	if material == null:
		return
	_set_if_declared(material, &"show_hair_cards", true)
	_set_if_declared(material, &"freeze_bayer_phase", true)
	_set_if_declared(material, &"comparison_exposure_gain", 1.0)
	_set_if_declared(material, &"lobe_scales", Vector3.ONE)
	_set_if_declared(material, &"use_area_light_multipliers", true)

func _set_if_declared(material: ShaderMaterial, name: StringName, value: Variant) -> void:
	if material.shader == null:
		return
	for info in material.shader.get_shader_uniform_list():
		if StringName(info.get(&"name", "")) == name:
			material.set_shader_parameter(name, value)
			return

func _percentile(values: Array[float], fraction: float) -> float:
	if values.is_empty():
		return 0.0
	var index := clampi(int(round(fraction * float(values.size() - 1))), 0, values.size() - 1)
	return values[index]
