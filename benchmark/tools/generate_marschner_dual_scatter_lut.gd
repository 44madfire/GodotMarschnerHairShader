extends SceneTree

## Offline generator for the FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED LUT.
##
## Produces the committed RGBAF 2D LUT data resource (default 64x64 at
## res://benchmark/resources/luts/fast_marschner_dual_scatter_lut_64.res; the
## --size=N user argument reparameterizes the output path and size) holding the
## scalar one-/three-event aggregate scattering-energy terms of the Stage-B
## local dual-scattering slice:
##
##   P1 = 1 - exp(-tau)
##   P3 = 1 - exp(-1.5 * tau)
##   R = one-event forward energy:  0.5 * (1 + c) * (1 - F0)^2 * P1
##   G = one-event backward energy: 0.5 * (1 - c) * (1 - F0)^2 * P1
##   B = three-event forward energy: 0.5 * (1 + c) * (1 - F0)^2 * F0 * P3
##   A = three-event backward energy: 0.5 * (1 - c) * (1 - F0)^2 * F0 * P3
## with F0 = ((1 - eta) / (1 + eta))^2, eta = 1.55 (the plan's fixed index of
## refraction, matching the azimuthal LUT). P1/P3 are aggregate local-scattering
## energies: zero density produces zero secondary energy and increasing density
## saturates toward the available one-/three-event energy. The runtime applies
## RGB absorption separately for the one- and three-event path lengths, so the
## LUT never bakes one hair color.
##
## Axes (all in [0, 1] texture space; the first/last texels represent exact
## domain endpoints):
##   U = scalar optical depth tau in [0, 16]
##   V = scattering cosine c in [-1, 1] (texel center -1 + (y + 0.5) / N * 2)
##
## Run with: godot --headless --path <project> --script res://benchmark/tools/generate_marschner_dual_scatter_lut.gd

const LUT_SIZE := 64
const LUT_PATH := "res://benchmark/resources/luts/fast_marschner_dual_scatter_lut_%d.res" % LUT_SIZE
## Preload shadow so parsing never depends on the global class cache.
const FastMarschnerDualLUTData := preload("res://benchmark/resources/fast_marschner_dual_lut_data.gd")
const ETA := 1.55
const TAU_MAX := 16.0
## Scalar path multipliers: one-event passes the fiber once, three-event adds
## one internal reflection with a longer absorbing chord (1.5 passes).
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
	lut_data.notes = "%dx%d RGBAF scalar aggregate one-/three-event dual-scatter energy terms for FAST_MARSCHNER_DUAL_SCATTER_PREINTEGRATED (eta %.2f, tau [0, %.0f], P1=1-exp(-tau), P3=1-exp(-1.5*tau)). U=local scattering optical depth tau, V=scattering cosine c; endpoints are represented exactly by the first/last texels; channels R=one-event forward, G=one-event backward, B=three-event forward, A=three-event backward. Runtime applies RGB absorption per path, so no hair color is baked in." % [lut_size, lut_size, ETA, TAU_MAX]
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
	print("LUT_SAMPLE (tau=1/%d, c=-1+1/%d): R=%.6f G=%.6f B=%.6f A=%.6f" % [lut_size * 2, lut_size, floats[0], floats[1], floats[2], floats[3]])
	quit(0)
