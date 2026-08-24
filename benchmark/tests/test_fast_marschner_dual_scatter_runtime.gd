extends SceneTree

## Focused runtime test for the FAST_MARSCHNER_DUAL_SCATTER preview variant
## (enum 7, analytic Stage A) and the FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED
## preview variant (enum 9, Stage-B LUT slice).
##
## Runnable directly with the normal (windowed) Godot binary via --script:
##
##   godot.exe --path <project> --script res://benchmark/tests/test_fast_marschner_dual_scatter_runtime.gd
##
## Asserts: apply_preview accepts both dual variants; the selected surface
## override is the fast Marschner shader with use_dual_scatter=true and the
## profile-driven strength/density controls bound; the Stage-B variant also
## forces use_preintegrated_dual_scatter=true, keeps use_azimuthal_lut=false
## and use_environment=false, and binds a valid 64x64 committed LUT texture
## with the resource metadata propagated to the IOR guard
## (dual_scatter_lut_eta ~= 1.55) and the U-axis domain guard
## (dual_scatter_lut_tau_max == 4.0, so the runtime never silently claims a
## wider domain); both previews render non-black output with a frozen Bayer
## phase (freeze_bayer_phase, deterministic preview contract); a deterministic
## CPU directional proof reconstructs the four LUT channels with the
## per-direction path responses and colored absorption, showing the
## forward/backward split survives at the alignment endpoints c = -1 / 0 / +1
## while the pure-forward endpoint matches the naive summed reconstruction;
## and variant identity is authoritative — the analytic/LUT/environment/
## Stage-A variants force the preintegrated flag off regardless of the
## profile, while the Stage-B variant forces dual+preintegrated on and
## azimuthal LUT/environment off.

const INDIVIDUAL_GROOM := 1
const FAST_MARSCHNER_ANALYTIC := 5
const FAST_MARSCHNER_LUT := 6
const FAST_MARSCHNER_DUAL_SCATTER := 7
const FAST_MARSCHNER_ENVIRONMENT := 8
const FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED := 9
const EXPECTED_SHADER_PATH := "res://assets/hair/materials/shaders/hair_marschner_fast.gdshader"
const EXPECTED_LUT_PATH := "res://benchmark/resources/luts/fast_marschner_dual_scatter_lut_64.res"
const PHASE_MOVE_FRAMES := 30
const MIN_NONBLACK_PIXELS := 20000
const MIN_IMAGE_DIMENSION := 256
const LIT_LUMINANCE_THRESHOLD := 0.18

var _failures: PackedStringArray = []


func _initialize() -> void:
	var debug_manager: Node = root.get_node_or_null("DebugManager")
	if debug_manager:
		debug_manager.set(&"should_render_imgui", false)
	call_deferred("_run")


func _run() -> void:
	var packed: PackedScene = load("res://benchmark/BenchmarkHarness.tscn")
	if packed == null:
		_fail("BenchmarkHarness.tscn failed to load")
		_finish()
		return
	var harness: Node = packed.instantiate()
	root.add_child(harness)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	var overlay: Control = harness.get_node_or_null("PreviewUILayer/BenchmarkPreviewOverlay")
	if overlay:
		overlay.visible = false
		print("EVIDENCE preview_overlay=hidden")

	var controller: Node = harness.get_node_or_null("BenchmarkController")
	if controller == null:
		_fail("BenchmarkController not found in the harness")
		_finish()
		return

	var groom: MeshInstance3D = null
	for groom_entry in controller.get(&"groom_catalog"):
		if String(groom_entry.get("groom_id", "")) == "Blowout":
			groom = groom_entry.get("node") as MeshInstance3D
			break
	if groom == null or not is_instance_valid(groom):
		_fail("Blowout groom not found in groom_catalog")
		_finish()
		return

	# 1) Stage-A dual variant (7): accepted, flag on, controls bound.
	var applied: bool = bool(controller.call(&"apply_preview", INDIVIDUAL_GROOM, FAST_MARSCHNER_DUAL_SCATTER, &"Blowout"))
	if not applied:
		_fail("apply_preview(INDIVIDUAL_GROOM, FAST_MARSCHNER_DUAL_SCATTER, Blowout) returned false")
		_finish()
		return
	print("EVIDENCE apply_preview=accepted variant=FAST_MARSCHNER_DUAL_SCATTER time_scale=%s" % Engine.time_scale)

	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	var override_material: Material = groom.get_surface_override_material(0)
	if not (override_material is ShaderMaterial):
		_fail("selected surface override is %s, expected ShaderMaterial" % override_material.get_class())
		_finish()
		return
	var shader_material := override_material as ShaderMaterial
	var shader_path := "none"
	if shader_material.shader:
		shader_path = shader_material.shader.resource_path
	print("EVIDENCE shader_path=%s" % shader_path)
	if shader_path != EXPECTED_SHADER_PATH:
		_fail("shader path is '%s', expected '%s'" % [shader_path, EXPECTED_SHADER_PATH])

	var dual_flag: Variant = shader_material.get(&"shader_parameter/use_dual_scatter")
	var preintegrated_flag: Variant = shader_material.get(&"shader_parameter/use_preintegrated_dual_scatter")
	var strength: Variant = shader_material.get(&"shader_parameter/dual_scatter_strength")
	var density: Variant = shader_material.get(&"shader_parameter/dual_scatter_density")
	var lut_flag: Variant = shader_material.get(&"shader_parameter/use_azimuthal_lut")
	var env_flag: Variant = shader_material.get(&"shader_parameter/use_environment")
	print("EVIDENCE stage_a use_dual_scatter=%s use_preintegrated_dual_scatter=%s dual_scatter_strength=%s dual_scatter_density=%s use_azimuthal_lut=%s use_environment=%s" % [dual_flag, preintegrated_flag, strength, density, lut_flag, env_flag])
	if dual_flag != true:
		_fail("use_dual_scatter must be true on the dual variant, got %s" % dual_flag)
	if preintegrated_flag != false:
		_fail("use_preintegrated_dual_scatter must stay false on the Stage-A variant, got %s" % preintegrated_flag)
	if not (strength is float) or float(strength) <= 0.0:
		_fail("dual_scatter_strength must be bound to the profile value (> 0), got %s" % strength)
	if not (density is float) or not (float(density) > 0.0):
		_fail("dual_scatter_density must be bound to the profile value (> 0), got %s" % density)
	if lut_flag != false:
		_fail("use_azimuthal_lut must stay false on the dual variant, got %s" % lut_flag)
	if env_flag != false:
		_fail("use_environment must stay false on the dual variant, got %s" % env_flag)

	# 2) Non-black output and deterministic preview (Stage A).
	var stage_a_frame_a: Image = root.get_texture().get_image()
	if stage_a_frame_a == null:
		_fail("viewport image capture failed")
		_finish()
		return
	var width := stage_a_frame_a.get_width()
	var height := stage_a_frame_a.get_height()
	if width < MIN_IMAGE_DIMENSION or height < MIN_IMAGE_DIMENSION:
		_fail("viewport image too small: %dx%d" % [width, height])
	var stage_a_lit := _count_lit_pixels(stage_a_frame_a)
	print("EVIDENCE stage_a frame_size=%dx%d lit_pixels=%d" % [width, height, stage_a_lit])
	if stage_a_lit < MIN_NONBLACK_PIXELS:
		_fail("dual preview has only %d lit pixels (threshold %d)" % [stage_a_lit, MIN_NONBLACK_PIXELS])

	# Second capture after enough preview frames for the Bayer TIME phase to
	# move: interactive previews freeze the Bayer phase (freeze_bayer_phase,
	# applied by apply_preview for every FAST_MARSCHNER_* variant), so the
	# hashed strand pattern must stay byte-identical. A nonzero diff would mean
	# the preview freeze regressed; the lit-pixel check above proves the
	# variant is rendering (a flat fallback has no lit pixels).
	var stage_a_freeze: Variant = shader_material.get(&"shader_parameter/freeze_bayer_phase")
	print("EVIDENCE stage_a preview_freeze_bayer_phase=%s" % stage_a_freeze)
	if stage_a_freeze != true:
		_fail("apply_preview did not freeze the Bayer phase for FAST_MARSCHNER_DUAL_SCATTER (got %s)" % stage_a_freeze)
	for wait_frame in PHASE_MOVE_FRAMES:
		await RenderingServer.frame_post_draw
	var stage_a_frame_b: Image = root.get_texture().get_image()
	var stage_a_diff := _byte_diff(stage_a_frame_a, stage_a_frame_b)
	print("EVIDENCE stage_a frame_diff_bytes_after_%d_frames=%d" % [PHASE_MOVE_FRAMES, stage_a_diff])
	if stage_a_diff > 0:
		_fail("frame diff is %d after %d frames: the dual preview Bayer phase should be frozen (freeze_bayer_phase)" % [stage_a_diff, PHASE_MOVE_FRAMES])

	# 3) Stage-B preintegrated variant (9): accepted, dual+preintegrated flags
	# on, azimuthal LUT/environment forced off, committed LUT bound.
	var preintegrated_applied: bool = bool(controller.call(&"apply_preview", INDIVIDUAL_GROOM, FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED, &"Blowout"))
	if not preintegrated_applied:
		_fail("apply_preview(INDIVIDUAL_GROOM, FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED, Blowout) returned false")
		_finish()
		return
	print("EVIDENCE apply_preview=accepted variant=FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED time_scale=%s" % Engine.time_scale)

	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	var preintegrated_material := groom.get_surface_override_material(0) as ShaderMaterial
	var pre_dual: Variant = preintegrated_material.get(&"shader_parameter/use_dual_scatter")
	var pre_flag: Variant = preintegrated_material.get(&"shader_parameter/use_preintegrated_dual_scatter")
	var pre_lut_flag: Variant = preintegrated_material.get(&"shader_parameter/use_azimuthal_lut")
	var pre_env_flag: Variant = preintegrated_material.get(&"shader_parameter/use_environment")
	var pre_lut_value: Variant = preintegrated_material.get(&"shader_parameter/dual_scatter_lut")
	var pre_lut := pre_lut_value as Texture2D
	var pre_strength: Variant = preintegrated_material.get(&"shader_parameter/dual_scatter_strength")
	var pre_density: Variant = preintegrated_material.get(&"shader_parameter/dual_scatter_density")
	var pre_eta: Variant = preintegrated_material.get(&"shader_parameter/dual_scatter_lut_eta")
	var pre_tau_max: Variant = preintegrated_material.get(&"shader_parameter/dual_scatter_lut_tau_max")
	print("EVIDENCE stage_b use_dual_scatter=%s use_preintegrated_dual_scatter=%s use_azimuthal_lut=%s use_environment=%s dual_scatter_strength=%s dual_scatter_density=%s" % [pre_dual, pre_flag, pre_lut_flag, pre_env_flag, pre_strength, pre_density])
	if pre_dual != true:
		_fail("use_dual_scatter must be true on the preintegrated variant, got %s" % pre_dual)
	if pre_flag != true:
		_fail("use_preintegrated_dual_scatter must be true on the preintegrated variant, got %s" % pre_flag)
	if pre_lut_flag != false:
		_fail("use_azimuthal_lut must stay false on the preintegrated variant, got %s" % pre_lut_flag)
	if pre_env_flag != false:
		_fail("use_environment must stay false on the preintegrated variant, got %s" % pre_env_flag)
	if pre_lut == null:
		_fail("dual_scatter_lut is not bound to a Texture2D on the preintegrated variant")
	else:
		print("EVIDENCE stage_b dual_scatter_lut=%s %dx%d" % [pre_lut.resource_path, pre_lut.get_width(), pre_lut.get_height()])
		if pre_lut.get_width() != 64 or pre_lut.get_height() != 64:
			_fail("dual_scatter_lut must be the committed 64x64 LUT, got %dx%d" % [pre_lut.get_width(), pre_lut.get_height()])
	# The IOR guard and the U-axis domain guard must carry the committed
	# resource metadata: eta ~= 1.55 (so the LUT branch is active at the
	# default runtime IOR) and tau_max == 4.0 (the reachable domain, so the
	# runtime never silently claims a wider baked domain).
	if not (pre_eta is float) or absf(float(pre_eta) - 1.55) > 0.0005:
		_fail("dual_scatter_lut_eta must be the resource's baked eta ~= 1.55, got %s" % pre_eta)
	if not (pre_tau_max is float) or float(pre_tau_max) != 4.0:
		_fail("dual_scatter_lut_tau_max must be the resource's tau_max == 4.0, got %s" % pre_tau_max)
	if not (pre_strength is float) or float(pre_strength) <= 0.0:
		_fail("dual_scatter_strength must be bound to the profile value (> 0), got %s" % pre_strength)
	if not (pre_density is float) or not (float(pre_density) > 0.0):
		_fail("dual_scatter_density must be bound to the profile value (> 0), got %s" % pre_density)

	# 4) Non-black output and deterministic preview (Stage B).
	var stage_b_frame_a: Image = root.get_texture().get_image()
	var stage_b_lit := _count_lit_pixels(stage_b_frame_a)
	print("EVIDENCE stage_b frame_size=%dx%d lit_pixels=%d" % [stage_b_frame_a.get_width(), stage_b_frame_a.get_height(), stage_b_lit])
	if stage_b_lit < MIN_NONBLACK_PIXELS:
		_fail("preintegrated dual preview has only %d lit pixels (threshold %d)" % [stage_b_lit, MIN_NONBLACK_PIXELS])

	# Second capture after enough preview frames for the Bayer TIME phase to
	# move: interactive previews freeze the Bayer phase (freeze_bayer_phase,
	# applied by apply_preview for every FAST_MARSCHNER_* variant), so the
	# hashed strand pattern must stay byte-identical. A nonzero diff would mean
	# the preview freeze regressed; the lit-pixel check above proves the
	# variant is rendering (a flat fallback has no lit pixels).
	var stage_b_freeze: Variant = preintegrated_material.get(&"shader_parameter/freeze_bayer_phase")
	print("EVIDENCE stage_b preview_freeze_bayer_phase=%s" % stage_b_freeze)
	if stage_b_freeze != true:
		_fail("apply_preview did not freeze the Bayer phase for FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED (got %s)" % stage_b_freeze)
	for wait_frame in PHASE_MOVE_FRAMES:
		await RenderingServer.frame_post_draw
	var stage_b_frame_b: Image = root.get_texture().get_image()
	var stage_b_diff := _byte_diff(stage_b_frame_a, stage_b_frame_b)
	print("EVIDENCE stage_b frame_diff_bytes_after_%d_frames=%d" % [PHASE_MOVE_FRAMES, stage_b_diff])
	if stage_b_diff > 0:
		_fail("frame diff is %d after %d frames: the preintegrated dual preview Bayer phase should be frozen (freeze_bayer_phase)" % [stage_b_diff, PHASE_MOVE_FRAMES])

	# 5) Deterministic directional proof (CPU side, no rendering dependency):
	# the Stage-B runtime reconstructs the four LUT channels separately with
	# the per-direction path responses and colored absorption, so the
	# forward/backward split the committed LUT stores must survive at the
	# alignment endpoints c = -1 / 0 / +1, while the pure-forward endpoint
	# c = +1 must reproduce the naive summed R+G / B+A reconstruction exactly.
	# This replicates the shader's bilinear sampling and Contract B math over
	# the committed data bytes.
	var lut_data: Resource = load(EXPECTED_LUT_PATH)
	if lut_data == null:
		_fail("committed dual LUT data failed to load for the directional proof")
	else:
		var data_bytes: Variant = lut_data.get(&"data")
		var size_value: Variant = lut_data.get(&"size")
		var eta_value: Variant = lut_data.get(&"eta")
		var tau_max_value: Variant = lut_data.get(&"tau_max")
		var contract_value: Variant = lut_data.get(&"contract")
		print("EVIDENCE directional_proof lut=%s size=%s eta=%s tau_max=%s contract=%s" % [EXPECTED_LUT_PATH, size_value, eta_value, tau_max_value, contract_value])
		if not (data_bytes is PackedByteArray) or not (size_value is int):
			_fail("committed dual LUT data resource has an invalid layout for the directional proof")
		elif not (eta_value is float) or absf(float(eta_value) - 1.55) > 0.0005:
			_fail("committed dual LUT metadata eta must be ~= 1.55, got %s" % eta_value)
		elif not (tau_max_value is float) or float(tau_max_value) != 4.0:
			_fail("committed dual LUT metadata tau_max must be 4.0 (reachable domain), got %s" % tau_max_value)
		elif String(contract_value) != "dual_scatter_contract_b_v2":
			_fail("committed dual LUT contract identifier must be dual_scatter_contract_b_v2, got %s" % contract_value)
		else:
			_directional_proof(data_bytes, size_value)

	# 6) Variant identity is authoritative: with a profile that enables every
	# opt-in mode, the analytic variant forces all off, the LUT variant forces
	# LUT on and the rest off, the Stage-A dual variant forces dual on and the
	# Stage-B preintegrated path off, the environment variant forces
	# environment on and the rest off, and the Stage-B variant forces
	# dual+preintegrated on and azimuthal LUT/environment off. The committed
	# profile is mutated only in memory and restored.
	var profile: Resource = load("res://benchmark/resources/profiles/source_current.tres")
	var saved_lut_flag: Variant = profile.get(&"use_azimuthal_lut")
	var saved_dual_flag: Variant = profile.get(&"use_dual_scatter")
	var saved_env_flag: Variant = profile.get(&"use_environment")
	var saved_lut_data: Variant = profile.get(&"azimuthal_lut_data")
	var saved_preintegrated_flag: Variant = profile.get(&"use_preintegrated_dual_scatter")
	var saved_dual_lut_data: Variant = profile.get(&"dual_scatter_lut_data")
	# A LUT-enabled profile must carry valid LUT data to pass profile validation.
	profile.set(&"azimuthal_lut_data", load("res://benchmark/resources/luts/fast_marschner_azimuthal_lut_64.res"))
	profile.set(&"use_azimuthal_lut", true)
	profile.set(&"use_dual_scatter", true)
	profile.set(&"use_environment", true)
	profile.set(&"environment_texture", load("res://benchmark/resources/textures/environment_gradient.tres"))
	profile.set(&"dual_scatter_lut_data", load(EXPECTED_LUT_PATH))
	profile.set(&"use_preintegrated_dual_scatter", true)

	var analytic_applied: bool = bool(controller.call(&"apply_preview", INDIVIDUAL_GROOM, FAST_MARSCHNER_ANALYTIC, &"Blowout"))
	if not analytic_applied:
		_fail("apply_preview(FAST_MARSCHNER_ANALYTIC) returned false")
		_finish()
		return
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var analytic_material := groom.get_surface_override_material(0) as ShaderMaterial
	var analytic_dual: Variant = analytic_material.get(&"shader_parameter/use_dual_scatter")
	var analytic_lut: Variant = analytic_material.get(&"shader_parameter/use_azimuthal_lut")
	var analytic_pre: Variant = analytic_material.get(&"shader_parameter/use_preintegrated_dual_scatter")
	var analytic_env: Variant = analytic_material.get(&"shader_parameter/use_environment")
	print("EVIDENCE identity_analytic use_dual_scatter=%s use_azimuthal_lut=%s use_preintegrated_dual_scatter=%s use_environment=%s" % [analytic_dual, analytic_lut, analytic_pre, analytic_env])
	# Analytic identity is authoritative: all modes forced off.
	if analytic_dual != false or analytic_lut != false or analytic_pre != false or analytic_env != false:
		_fail("analytic variant must force lut=false, dual=false, preintegrated=false, environment=false regardless of the profile, got %s/%s/%s/%s" % [analytic_lut, analytic_dual, analytic_pre, analytic_env])
	print("EVIDENCE identity_analytic all_flags_forced=false")

	# LUT variant: LUT forced on, dual and preintegrated forced off.
	var lut_applied: bool = bool(controller.call(&"apply_preview", INDIVIDUAL_GROOM, FAST_MARSCHNER_LUT, &"Blowout"))
	if not lut_applied:
		_fail("apply_preview(FAST_MARSCHNER_LUT) returned false")
		_finish()
		return
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var lut_material := groom.get_surface_override_material(0) as ShaderMaterial
	var lut_identity_lut: Variant = lut_material.get(&"shader_parameter/use_azimuthal_lut")
	var lut_identity_dual: Variant = lut_material.get(&"shader_parameter/use_dual_scatter")
	var lut_identity_pre: Variant = lut_material.get(&"shader_parameter/use_preintegrated_dual_scatter")
	var lut_identity_env: Variant = lut_material.get(&"shader_parameter/use_environment")
	print("EVIDENCE identity_lut use_azimuthal_lut=%s use_dual_scatter=%s use_preintegrated_dual_scatter=%s use_environment=%s" % [lut_identity_lut, lut_identity_dual, lut_identity_pre, lut_identity_env])
	if lut_identity_lut != true or lut_identity_dual != false or lut_identity_pre != false or lut_identity_env != false:
		_fail("LUT variant must force lut=true, dual=false, preintegrated=false, environment=false regardless of the profile, got %s/%s/%s/%s" % [lut_identity_lut, lut_identity_dual, lut_identity_pre, lut_identity_env])

	# Stage-A dual variant (7): dual forced on, preintegrated forced off.
	var dual_applied: bool = bool(controller.call(&"apply_preview", INDIVIDUAL_GROOM, FAST_MARSCHNER_DUAL_SCATTER, &"Blowout"))
	if not dual_applied:
		_fail("apply_preview(FAST_MARSCHNER_DUAL_SCATTER) returned false")
		_finish()
		return
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var dual_material := groom.get_surface_override_material(0) as ShaderMaterial
	var dual_identity_dual: Variant = dual_material.get(&"shader_parameter/use_dual_scatter")
	var dual_identity_pre: Variant = dual_material.get(&"shader_parameter/use_preintegrated_dual_scatter")
	var dual_identity_lut: Variant = dual_material.get(&"shader_parameter/use_azimuthal_lut")
	var dual_identity_env: Variant = dual_material.get(&"shader_parameter/use_environment")
	print("EVIDENCE identity_dual_stage_a use_dual_scatter=%s use_preintegrated_dual_scatter=%s use_azimuthal_lut=%s use_environment=%s" % [dual_identity_dual, dual_identity_pre, dual_identity_lut, dual_identity_env])
	if dual_identity_dual != true or dual_identity_pre != false or dual_identity_lut != false or dual_identity_env != false:
		_fail("Stage-A dual variant must force dual=true, preintegrated=false, lut=false, environment=false regardless of the profile, got %s/%s/%s/%s" % [dual_identity_dual, dual_identity_pre, dual_identity_lut, dual_identity_env])

	# Environment variant (8): environment forced on, dual/preintegrated/LUT off.
	var env_applied: bool = bool(controller.call(&"apply_preview", INDIVIDUAL_GROOM, FAST_MARSCHNER_ENVIRONMENT, &"Blowout"))
	if not env_applied:
		_fail("apply_preview(FAST_MARSCHNER_ENVIRONMENT) returned false")
		_finish()
		return
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var env_material := groom.get_surface_override_material(0) as ShaderMaterial
	var env_identity_env: Variant = env_material.get(&"shader_parameter/use_environment")
	var env_identity_dual: Variant = env_material.get(&"shader_parameter/use_dual_scatter")
	var env_identity_pre: Variant = env_material.get(&"shader_parameter/use_preintegrated_dual_scatter")
	var env_identity_lut: Variant = env_material.get(&"shader_parameter/use_azimuthal_lut")
	print("EVIDENCE identity_environment use_environment=%s use_dual_scatter=%s use_preintegrated_dual_scatter=%s use_azimuthal_lut=%s" % [env_identity_env, env_identity_dual, env_identity_pre, env_identity_lut])
	if env_identity_env != true or env_identity_dual != false or env_identity_pre != false or env_identity_lut != false:
		_fail("environment variant must force environment=true, dual=false, preintegrated=false, lut=false regardless of the profile, got %s/%s/%s/%s" % [env_identity_env, env_identity_dual, env_identity_pre, env_identity_lut])

	# Stage-B preintegrated variant (9): dual+preintegrated forced on, LUT and
	# environment forced off, committed LUT bound.
	var pre_applied: bool = bool(controller.call(&"apply_preview", INDIVIDUAL_GROOM, FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED, &"Blowout"))
	if not pre_applied:
		_fail("apply_preview(FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED) returned false")
		_finish()
		return
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var pre_material := groom.get_surface_override_material(0) as ShaderMaterial
	var pre_identity_dual: Variant = pre_material.get(&"shader_parameter/use_dual_scatter")
	var pre_identity_flag: Variant = pre_material.get(&"shader_parameter/use_preintegrated_dual_scatter")
	var pre_identity_lut: Variant = pre_material.get(&"shader_parameter/use_azimuthal_lut")
	var pre_identity_env: Variant = pre_material.get(&"shader_parameter/use_environment")
	var pre_identity_texture := pre_material.get(&"shader_parameter/dual_scatter_lut") as Texture2D
	print("EVIDENCE identity_dual_stage_b use_dual_scatter=%s use_preintegrated_dual_scatter=%s use_azimuthal_lut=%s use_environment=%s" % [pre_identity_dual, pre_identity_flag, pre_identity_lut, pre_identity_env])
	if pre_identity_dual != true or pre_identity_flag != true or pre_identity_lut != false or pre_identity_env != false:
		_fail("Stage-B dual variant must force dual=true, preintegrated=true, lut=false, environment=false regardless of the profile, got %s/%s/%s/%s" % [pre_identity_dual, pre_identity_flag, pre_identity_lut, pre_identity_env])
	if pre_identity_texture == null or pre_identity_texture.get_width() != 64 or pre_identity_texture.get_height() != 64:
		_fail("Stage-B dual variant must bind the committed 64x64 LUT texture, got %s" % pre_identity_texture)

	# Restore the profile (in-memory mutations only, matching the controller's
	# load() caching so later runs see the committed defaults again).
	profile.set(&"use_azimuthal_lut", saved_lut_flag)
	profile.set(&"use_dual_scatter", saved_dual_flag)
	profile.set(&"use_environment", saved_env_flag)
	profile.set(&"environment_texture", null)
	profile.set(&"azimuthal_lut_data", saved_lut_data)
	profile.set(&"use_preintegrated_dual_scatter", saved_preintegrated_flag)
	profile.set(&"dual_scatter_lut_data", saved_dual_lut_data)

	_finish()


func _count_lit_pixels(image: Image) -> int:
	var count := 0
	for y in image.get_height():
		for x in image.get_width():
			var pixel: Color = image.get_pixel(x, y)
			if pixel.r + pixel.g + pixel.b > LIT_LUMINANCE_THRESHOLD:
				count += 1
	return count


func _byte_diff(image_a: Image, image_b: Image) -> int:
	if image_a == null or image_b == null or image_a.get_size() != image_b.get_size():
		return -1
	var bytes_a: PackedByteArray = image_a.get_data()
	var bytes_b: PackedByteArray = image_b.get_data()
	var differing := 0
	for byte_index in bytes_a.size():
		if bytes_a[byte_index] != bytes_b[byte_index]:
			differing += 1
	return differing


## Deterministic CPU directional proof of the Stage-B four-path contract over
## the committed LUT bytes (no rendering dependency): bilinearly samples the
## LUT exactly like the shader (half-texel inset, edge clamp, tau_max domain)
## at the alignment endpoints c = -1 / 0 / +1 at a mid-domain tau_d = 2.0,
## applies the four per-direction path responses with the colored sigma_a
## (0.02, 0.15, 0.6, matching the validator's probe), and verifies:
##   - the four-path energy differs between c = +1 and c = -1 and c = 0 is
##     distinct from both endpoints (directional non-cancellation);
##   - at c = -1 the four-path reconstruction differs from the naive summed
##     R+G / B+A reconstruction (the split is not cancelled at runtime);
##   - at c = +1 the four-path reconstruction equals the summed reconstruction
##     exactly (only the forward channels are active there);
##   - the forward channels dominate at c = +1 and the backward channels at
##     c = -1.
func _directional_proof(data_bytes: PackedByteArray, size: int) -> void:
	var tau := 2.0
	var sigma_a := Vector3(0.02, 0.15, 0.6)
	var t1_forward := Vector3(exp(-sigma_a.x), exp(-sigma_a.y), exp(-sigma_a.z))
	var t1_backward := Vector3(exp(-0.5 * sigma_a.x), exp(-0.5 * sigma_a.y), exp(-0.5 * sigma_a.z))
	var t3_forward := Vector3(exp(-1.5 * sigma_a.x), exp(-1.5 * sigma_a.y), exp(-1.5 * sigma_a.z))
	var t3_backward := Vector3(exp(-0.75 * sigma_a.x), exp(-0.75 * sigma_a.y), exp(-0.75 * sigma_a.z))
	var directional_by_cosine := {}
	var summed_by_cosine := {}
	for cosine in [-1.0, 0.0, 1.0]:
		var events := Vector4(
			_sample_lut_channel(data_bytes, size, tau, cosine, 0),
			_sample_lut_channel(data_bytes, size, tau, cosine, 1),
			_sample_lut_channel(data_bytes, size, tau, cosine, 2),
			_sample_lut_channel(data_bytes, size, tau, cosine, 3))
		var directional := events.x * t1_forward + events.y * t1_backward \
			+ events.z * t3_forward + events.w * t3_backward
		var summed := (events.x + events.y) * t1_forward + (events.z + events.w) * t3_forward
		directional_by_cosine[cosine] = directional
		summed_by_cosine[cosine] = summed
		print("EVIDENCE directional_proof tau_d=%.1f c=%+.1f four_path=(%.6f %.6f %.6f) summed=(%.6f %.6f %.6f)" % [tau, cosine, directional.x, directional.y, directional.z, summed.x, summed.y, summed.z])
	var forward_energy: Vector3 = directional_by_cosine[1.0]
	var backward_energy: Vector3 = directional_by_cosine[-1.0]
	var zero_energy: Vector3 = directional_by_cosine[0.0]
	if forward_energy.distance_to(backward_energy) < 1e-3:
		_fail("four-path energy must differ between c=+1 and c=-1 at tau_d=%.1f (forward %s, backward %s)" % [tau, forward_energy, backward_energy])
	if zero_energy.distance_to(forward_energy) < 1e-3 or zero_energy.distance_to(backward_energy) < 1e-3:
		_fail("four-path energy at c=0 must differ from both endpoints at tau_d=%.1f (c=0 %s)" % [tau, zero_energy])
	var summed_backward: Vector3 = summed_by_cosine[-1.0]
	if backward_energy.distance_to(summed_backward) < 1e-3:
		_fail("four-path reconstruction must differ from the summed R+G / B+A reconstruction at c=-1 (four_path %s, summed %s)" % [backward_energy, summed_backward])
	var summed_forward: Vector3 = summed_by_cosine[1.0]
	if forward_energy.distance_to(summed_forward) > 1e-6:
		_fail("four-path reconstruction must equal the summed reconstruction at the pure-forward endpoint c=+1 (four_path %s, summed %s)" % [forward_energy, summed_forward])
	var forward_events := Vector4(
		_sample_lut_channel(data_bytes, size, tau, 1.0, 0),
		_sample_lut_channel(data_bytes, size, tau, 1.0, 1),
		_sample_lut_channel(data_bytes, size, tau, 1.0, 2),
		_sample_lut_channel(data_bytes, size, tau, 1.0, 3))
	var backward_events := Vector4(
		_sample_lut_channel(data_bytes, size, tau, -1.0, 0),
		_sample_lut_channel(data_bytes, size, tau, -1.0, 1),
		_sample_lut_channel(data_bytes, size, tau, -1.0, 2),
		_sample_lut_channel(data_bytes, size, tau, -1.0, 3))
	if forward_events.x < forward_events.y - 1e-6 or forward_events.z < forward_events.w - 1e-6:
		_fail("forward channels must dominate at c=+1 at tau_d=%.1f (%s)" % [tau, forward_events])
	if backward_events.y < backward_events.x - 1e-6 or backward_events.w < backward_events.z - 1e-6:
		_fail("backward channels must dominate at c=-1 at tau_d=%.1f (%s)" % [tau, backward_events])
	print("EVIDENCE directional_proof ok=true")


## GPU-matching bilinear sample of one channel over the committed RGBAF data
## bytes: texel centers at (i + 0.5) / N, half-texel inset, edge clamping, and
## the resource tau_max domain (4.0), replicating the shader's sampling.
func _sample_lut_channel(data: PackedByteArray, size: int, tau: float, cosine: float, channel: int) -> float:
	var tau_max := 4.0
	var half: float = 0.5 / float(size)
	var u: float = lerpf(half, 1.0 - half, clampf(tau / tau_max, 0.0, 1.0))
	var v: float = lerpf(half, 1.0 - half, clampf(0.5 + 0.5 * cosine, 0.0, 1.0))
	var pu: float = u * float(size) - 0.5
	var pv: float = v * float(size) - 0.5
	var x0 := int(floor(pu))
	var y0 := int(floor(pv))
	var tx: float = pu - float(x0)
	var ty: float = pv - float(y0)
	var result := 0.0
	for dy in 2:
		for dx in 2:
			var texel_x: int = clampi(x0 + dx, 0, size - 1)
			var texel_y: int = clampi(y0 + dy, 0, size - 1)
			var weight := (tx if dx == 1 else 1.0 - tx) * (ty if dy == 1 else 1.0 - ty)
			result += _texel_channel(data, size, texel_x, texel_y, channel) * weight
	return result


func _texel_channel(data: PackedByteArray, size: int, x: int, y: int, channel: int) -> float:
	var byte_offset := (y * size + x) * 16 + channel * 4
	return data.decode_float(byte_offset)


func _fail(message: String) -> void:
	_failures.append(message)
	push_error(message)


func _finish() -> void:
	if _failures.is_empty():
		print("FAST_MARSCHNER_DUAL_SCATTER_RUNTIME_TEST_OK")
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)
