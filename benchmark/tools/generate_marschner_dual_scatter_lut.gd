extends SceneTree

## Offline generator for the FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED LUT.
##
## Produces the committed RGBAF 2D LUT data resource (default 64x64 at
## res://benchmark/resources/luts/fast_marschner_dual_scatter_lut_64.res; the
## --size=N user argument reparameterizes the output path and size) holding the
## scalar one-/three-event aggregate event weights of the Stage-B local
## dual-scattering slice (Contract B: scalar density/event weights, never RGB
## optical depth):
##
##   P1 = 1 - exp(-tau)
##   P3 = 1 - exp(-1.5 * tau)
##   R = one-event forward weight:  0.5 * (1 + c) * (1 - F0)^2 * P1
##   G = one-event backward weight: 0.5 * (1 - c) * (1 - F0)^2 * P1
##   B = three-event forward weight: 0.5 * (1 + c) * (1 - F0)^2 * F0 * P3
##   A = three-event backward weight: 0.5 * (1 - c) * (1 - F0)^2 * F0 * P3
## with F0 = ((1 - eta) / (1 + eta))^2 baked at eta = 1.55 (matching the
## azimuthal LUT). P1/P3 are aggregate event weights: zero density produces
## zero secondary energy and increasing density saturates toward the available
## one-/three-event energy. The runtime samples the LUT once at the scalar
## tau_d = 4 * local_density and applies the RGB absorption separately as
## T1 = exp(-sigma_a) and T3 = exp(-1.5 * sigma_a), so the LUT never bakes one
## hair color.
##
## Axes (all in [0, 1] texture space; the first/last texels represent exact
## domain endpoints):
##   U = scalar density/event proxy tau_d = 4 * local_density in [0, 16]
##   V = scattering cosine c in [-1, 1] (texel center -1 + (y + 0.5) / N * 2)
##
## Run with: godot --headless --path <project> --script res://benchmark/tools/generate_marschner_dual_scatter_lut.gd

const LUT_SIZE := 64
const LUT_PATH := "res://benchmark/resources/luts/fast_marschner_dual_scatter_lut_%d.res" % LUT_SIZE
## Preload shadow so parsing never depends on the global class cache.
const FastMarschnerDualLUTData := preload("res://benchmark/resources/fast_marschner_dual_lut_data.gd")
const ETA := 1.55
const TAU_MAX := 16.0
## Scalar event-weight exponents: P1 uses ONE_EVENT_PATH, P3 uses
## THREE_EVENT_PATH (1.5x the one-event weight's tau response, so the
## three-event aggregate saturates faster).
const ONE_EVENT_PATH := 1.0
const THREE_EVENT_PATH := 1.5


func _initialize() -> void:
	var requested_size := 0
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--size="):
			requested_size = int(argument.trim_prefix("--size=").strip_edges())
	var lut_size: int = maxi(requested_size, 2) if requested_size > 0 else LUT_SIZE
	var lut_path: String = LUT_PATH
	if requested_size > 0 and requested_size != LUT_SIZE:
		lut_path = "res://benchmark/resources/luts/fast_marschner_dual_scatter_lut_%d.res" % lut_size
	var texel_count := lut_size * lut_size
	var floats := PackedFloat32Array()
	floats.resize(texel_count * 4)
	var float_index := 0
	var f0 := (1.0 - ETA) * (1.0 - ETA) / ((1.0 + ETA) * (1.0 + ETA))
	var one_event_fresnel := (1.0 - f0) * (1.0 - f0)
	var three_event_fresnel := one_event_fresnel * f0
	for y in lut_size:
		var cosine: float = -1.0 + float(y) / float(lut_size - 1) * 2.0
		var forward_lobe: float = 0.5 * (1.0 + cosine)
		var backward_lobe: float = 0.5 * (1.0 - cosine)
		for x in lut_size:
			var tau: float = float(x) / float(lut_size - 1) * TAU_MAX
			var one_event_energy: float = 1.0 - exp(-ONE_EVENT_PATH * tau)
			var three_event_energy: float = 1.0 - exp(-THREE_EVENT_PATH * tau)

			floats[float_index] = forward_lobe * one_event_fresnel * one_event_energy
			floats[float_index + 1] = backward_lobe * one_event_fresnel * one_event_energy
			floats[float_index + 2] = forward_lobe * three_event_fresnel * three_event_energy
			floats[float_index + 3] = backward_lobe * three_event_fresnel * three_event_energy
			float_index += 4

	var bytes := floats.to_byte_array()
	# Godot 4.7's ResourceSaver cannot self-contain an ImageTexture (stub .res /
	# data-less .tres), so the committed artifact is the raw RGBAF data in a
	# FastMarschnerDualLUTData resource; the adapter constructs the ImageTexture
	# at runtime with Image.create_from_data / ImageTexture.create_from_image.
	var lut_data: FastMarschnerDualLUTData = FastMarschnerDualLUTData.new()
	lut_data.size = lut_size
	lut_data.format = Image.FORMAT_RGBAF
	lut_data.eta = ETA
	lut_data.notes = "%dx%d RGBAF scalar density/event-proxy dual-scatter weights for FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED (eta %.2f, tau_d [0, %.0f], P1=1-exp(-tau_d), P3=1-exp(-1.5*tau_d)). U=scalar density/event proxy tau_d=4*local_density, V=scattering cosine c; endpoints are represented exactly by the first/last texels; channels R=one-event forward, G=one-event backward, B=three-event forward, A=three-event backward. Runtime samples once at scalar tau_d and applies RGB T1=exp(-sigma_a), T3=exp(-1.5*sigma_a) separately, so no hair color is baked in." % [lut_size, lut_size, ETA, TAU_MAX]
	lut_data.data = bytes
	var save_error: Error = ResourceSaver.save(lut_data, lut_path)
	if save_error != OK:
		push_error("ResourceSaver.save failed: %s" % save_error)
		quit(1)
		return
	var reloaded: FastMarschnerDualLUTData = load(lut_path) as FastMarschnerDualLUTData
	if reloaded == null or reloaded.data.size() != bytes.size():
		push_error("LUT round-trip verification failed")
		quit(1)
		return
	print("LUT_GENERATED path=%s size=%dx%d format=RGBAF bytes=%d" % [lut_path, lut_size, lut_size, bytes.size()])
	print("LUT_SAMPLE (tau_d=1/%d, c=-1+1/%d): R=%.6f G=%.6f B=%.6f A=%.6f" % [lut_size * 2, lut_size, floats[0], floats[1], floats[2], floats[3]])
	quit(0)
