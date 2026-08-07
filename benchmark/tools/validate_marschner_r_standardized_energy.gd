extends SceneTree

## Phase 3 CPU-only integrated-energy validator for the standardized projected
## R kernel (the full R product M_R * N_R).
##
## Loads the committed 256x256x128 standardized R Q-LUT
## (res://benchmark/resources/luts/fast_marschner_r_standardized_lut_256x256x128.res),
## the kernel reference
## (benchmark/reference/fast_marschner_r_standardized_kernel_reference.gd) and
## the LUT data script, then integrates the R product
##     f(theta_i, theta_o, phi) = M_R * N_R,   N_R = 0.25 * cos(phi/2),
## over the physical outgoing hemisphere theta_o in [-PI/2, PI/2] x phi in
## [-PI, PI] with deterministic midpoint quadrature and the projected measure
## cos(theta_o) * dtheta_o * dphi (the BRDF-albedo-like integral the light
## loop performs implicitly).
##
## For every sample the direct reference
##     Reference.direct_r_mn(theta_i, theta_o, 0.5 * (theta_o - theta_i),
##                           max(cos(phi/2), 0), cuticle, beta_m)
## is compared against the LUT reconstruction path:
##     Reference.derive_r_coordinates(...) gives (c_phi, theta_cone, beta_r);
## when c_phi is at or below C_PHI_SEAM_EPSILON the sample is counted as an
## exact seam sample and the direct value is used (the stored Q cannot
## represent beta_r -> 0, and the direct reference resolves the 0 * infinity
## form of the naive product via the asymptotic branch); otherwise
##     q = (theta_o - theta_cone) / beta_r,
## both decoders (linear Q, log2 Q) are sampled with
## sample_q_fallback(..., FALLBACK_OUTSIDE) and the product is reconstructed
## with Reference.direct_r_mn_from_q. Every sample is classified into exactly
## one disjoint bucket, in priority order:
##   exact_c_phi_seam   c_phi <= C_PHI_SEAM_EPSILON (direct evaluation; the
##                      q LUT coordinate is degenerate)
##   q_beta_fallback    q, theta_cone or beta_r outside the rectangular LUT
##                      support (checked FIRST, so out-of-support samples are
##                      never mislabeled as grazing or cone-pole)
##   cone_pole_fallback theta_cone in the outer two Y-axis texel bands (the
##                      sampler's documented pole seam)
##   grazing_fallback   physical footprint that requires_reference_fallback
##                      flags (trilinear footprint or grazing margin straddles
##                      the outgoing-angle boundary)
##   lut_interior       everything else
## with the invariant total == lut_interior + q_beta_fallback +
## grazing_fallback + cone_pole_fallback + exact_c_phi_seam.
## asymptotic_beta_branch is a diagnostic sub-count of q_beta_fallback
## (non-seam samples with beta_r <= BETA_NUMERIC_EPSILON; beta_r <= eps <
## beta_min is always out of rectangular support, so it can never land in the
## pole, grazing or interior buckets). It is not part of the partition.
##
## Errors are measured per sample (RMS absolute/relative over all samples)
## and on the totals (absolute/relative) per theta_i and aggregated. eta and
## albedo are metadata only: the R lobe has no absorption path, so they never
## enter the integrand and are reported in `configuration` for provenance.
##
## Contract: --contract=report is the only accepted mode (schema
## standardized_r_energy_v1, contract REPORT); any other value is rejected
## with a nonzero exit. Malformed/non-finite CLI values, an invalid or
## out-of-contract LUT resource, out-of-contract texel data or non-finite
## computed values all fail with a nonzero exit.
##
## Pole seam policy: the LUT resource routes the outer two theta_cone texel
## bands to the direct/asymptotic reference (counted as cone_pole_fallback).
## This avoids reconstructing a pole-clamped cone with the exact
## cos(theta_cone) denominator while retaining the finite, unweakened energy
## report.
##
## Diagnostics (report-only, no acceptance gate): `diagnostics` carries a
## support-renormalized interior-mass correction factor (direct-vs-decoded
## projected mass over the actual LUT-interior subset; NO raw-M
## unit-normalization claim), an asymptotic branch probe at beta_r in
## {0, 0.5*eps, eps, 2*eps} around BETA_NUMERIC_EPSILON, and
## direct-fallback totals/branch counts.
##
## Run with (Windows Godot 4.7, UNC project path):
##   /mnt/c/Tools/Godot/godot.exe --headless \
##     --path "//wsl.localhost/Ubuntu/home/jeffreymwang/godot-hair-shader" \
##     --script res://benchmark/tools/validate_marschner_r_standardized_energy.gd \
##     -- --grid=32 --phi-grid=64 --contract=report
## Optional user args: --grid=32 (theta_o cells; default 32),
## --phi-grid=64 (phi cells; default 64), --beta-m=<float> (default 0.2),
## --cuticle=<float> (default 0.087), --eta=<float> (default 1.55, metadata
## only), --albedo=r,g,b (default 0.24774602,0.12215338,0.09630052, metadata
## only), --contract=report (only accepted value).

const LUT_PATH := "res://benchmark/resources/luts/fast_marschner_r_standardized_lut_256x256x128.res"
const LUT_CONTRACT_ID := "standardized_r_projected_q_v1"
const LUT_CHANNELS := "R=linear_Q,G=log2_Q,B=0,A=1"
const SCHEMA := "standardized_r_energy_v1"
const CONTRACT_MODE := "REPORT"
## c_phi = cos(phi/2) at or below this is the exact azimuthal seam: beta_r =
## sqrt(2) * c_phi * beta_m collapses toward the asymptotic branch and the
## q = (theta_o - theta_cone) / beta_r LUT coordinate is degenerate, so the
## sample is counted as exact_c_phi_seam and evaluated directly (the direct
## reference resolves the 0 * infinity form of the naive product).
const C_PHI_SEAM_EPSILON := 1e-6
## Epsilon-safe denominator floor for relative errors (same style as the
## Phase 4 energy validator's drift probe).
const RELATIVE_EPSILON := 1e-12
const GRID_THETA_DEFAULT := 32
const GRID_PHI_DEFAULT := 64
const GRID_MIN := 1
const GRID_MAX := 1024
## Phase 3 required incoming angles (degrees).
const THETA_I_DEG: Array = [-60, -30, 0, 30, 60]
const ETA_DEFAULT := 1.55
const ALBEDO_DEFAULT: Array = [0.24774602, 0.12215338, 0.09630052]
const BETA_M_DEFAULT := 0.2
const CUTICLE_DEFAULT := 0.087
## Fixed geometry for the report-only asymptotic branch probe. theta_o ==
## theta_cone (delta = 0) so q = 0 at every probe point and the geometry is
## identical across the probe: the probe isolates the reference branch seam
## from the outgoing-angle offset.
const PROBE_THETA_O := 0.1
const PROBE_THETA_CONE := 0.1
## beta_r multipliers around Reference.BETA_NUMERIC_EPSILON (0, 0.5*eps, eps,
## 2*eps) for the asymptotic branch probe.
const PROBE_BETA_MULTIPLIERS: Array = [0.0, 0.5, 1.0, 2.0]

const Data := preload("res://benchmark/resources/fast_marschner_r_standardized_lut_data.gd")
const Reference := preload("res://benchmark/reference/fast_marschner_r_standardized_kernel_reference.gd")

var _lut = null
var _grid_theta := GRID_THETA_DEFAULT
var _grid_phi := GRID_PHI_DEFAULT
var _beta_m := BETA_M_DEFAULT
var _cuticle := CUTICLE_DEFAULT
var _eta := ETA_DEFAULT
var _albedo: Array = ALBEDO_DEFAULT
var _contract_mode := "report"
var _finite_ok := true


func _initialize() -> void:
	if not _parse_args():
		_fail("invalid command-line arguments (see errors above)")
		return
	if not _load_lut():
		_fail("LUT resource failed validation")
		return
	if not _check_texels():
		_fail("LUT texel data failed validation")
		return
	var report := _run_integration()
	print(JSON.stringify(report, "\t"))
	if not _finite_ok:
		_fail("non-finite values encountered during integration")
		return
	print("FAST_MARSCHNER_R_STANDARDIZED_ENERGY_OK")
	quit(0)


# ---------------------------------------------------------------------------
# CLI argument parsing. Every value is validated; malformed or non-finite
# values and unknown arguments/contract modes fail the run with exit 1.
# ---------------------------------------------------------------------------

func _parse_args() -> bool:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--grid="):
			_grid_theta = _parse_int(argument.trim_prefix("--grid=").strip_edges(), "grid", GRID_MIN, GRID_MAX)
		elif argument.begins_with("--phi-grid="):
			_grid_phi = _parse_int(argument.trim_prefix("--phi-grid=").strip_edges(), "phi-grid", GRID_MIN, GRID_MAX)
		elif argument.begins_with("--beta-m="):
			_beta_m = _parse_float(argument.trim_prefix("--beta-m=").strip_edges(), "beta-m", 0.0, INF)
		elif argument.begins_with("--cuticle="):
			_cuticle = _parse_float(argument.trim_prefix("--cuticle=").strip_edges(), "cuticle", -INF, INF)
		elif argument.begins_with("--eta="):
			_eta = _parse_float(argument.trim_prefix("--eta=").strip_edges(), "eta", 0.0, INF)
		elif argument.begins_with("--albedo="):
			_albedo = _parse_albedo(argument.trim_prefix("--albedo=").strip_edges())
		elif argument.begins_with("--contract="):
			_contract_mode = argument.trim_prefix("--contract=").strip_edges()
		else:
			push_error("Unknown user argument: %s" % argument)
			return false
	if _grid_theta < GRID_MIN or _grid_phi < GRID_MIN:
		return false
	if is_nan(_beta_m) or is_nan(_cuticle) or is_nan(_eta) \
			or is_nan(_albedo[0]) or is_nan(_albedo[1]) or is_nan(_albedo[2]):
		return false
	if _beta_m <= 0.0:
		push_error("--beta-m must be > 0")
		return false
	# REPORT is the only implemented contract; reject everything else so a
	# typo can never silently select a different gate.
	if _contract_mode != "report":
		push_error("Unknown contract mode '%s'; accepted: report" % _contract_mode)
		return false
	return true


func _parse_int(text: String, name: String, min_value: int, max_value: int) -> int:
	if not text.is_valid_int():
		push_error("--%s: '%s' is not a valid integer" % [name, text])
		return -1
	var value := int(text)
	if value < min_value or value > max_value:
		push_error("--%s: %d outside [%d, %d]" % [name, value, min_value, max_value])
		return -1
	return value


func _parse_float(text: String, name: String, min_value: float, max_value: float) -> float:
	if not text.is_valid_float():
		push_error("--%s: '%s' is not a valid float" % [name, text])
		return NAN
	var value := float(text)
	if not is_finite(value) or value < min_value or value > max_value:
		push_error("--%s: '%s' is not a finite float in [%s, %s]" % [name, text, str(min_value), str(max_value)])
		return NAN
	return value


func _parse_albedo(text: String) -> Array:
	var parts := text.split(",")
	if parts.size() != 3:
		push_error("--albedo: '%s' must be r,g,b" % text)
		return [NAN, NAN, NAN]
	var r := _parse_float(parts[0].strip_edges(), "albedo", 0.0, INF)
	var g := _parse_float(parts[1].strip_edges(), "albedo", 0.0, INF)
	var b := _parse_float(parts[2].strip_edges(), "albedo", 0.0, INF)
	if is_nan(r) or is_nan(g) or is_nan(b):
		return [NAN, NAN, NAN]
	# Kept as double-precision floats (Array, not Vector3) so the report's
	# albedo matches the CLI argument exactly: Vector3 stores float32 and
	# would quantize the provenance metadata.
	return [r, g, b]


# ---------------------------------------------------------------------------
# LUT resource loading and data validation. Malformed resources, contract or
# channel mismatches, a cubic resolution, a claimed raw-M unit normalization
# or any non-finite/out-of-contract texel fail the run with exit 1.
# ---------------------------------------------------------------------------

func _load_lut() -> bool:
	var lut = load(LUT_PATH)
	if lut == null or not (lut is Data):
		push_error("failed to load standardized R LUT: %s" % LUT_PATH)
		return false
	var errors: PackedStringArray = lut.validation_errors()
	if not errors.is_empty():
		push_error("LUT resource invalid: %s" % "; ".join(errors))
		return false
	if lut.contract != LUT_CONTRACT_ID:
		push_error("LUT contract '%s' must be '%s'" % [lut.contract, LUT_CONTRACT_ID])
		return false
	if lut.channels != LUT_CHANNELS:
		push_error("LUT channels '%s' must be '%s'" % [lut.channels, LUT_CHANNELS])
		return false
	if lut.raw_m_unit_normalization_claimed:
		push_error("LUT must not claim raw-M unit normalization")
		return false
	if lut.size_x == lut.size_y and lut.size_y == lut.size_z:
		push_error("LUT resolution must be non-cubic (got %dx%dx%d)" % [lut.size_x, lut.size_y, lut.size_z])
		return false
	_lut = lut
	print("LUT_METADATA size=%dx%dx%d contract=%s channels=%s q=[%s,%s] cone=[%s,%s] beta=[%s,%s] raw_m_unit_normalization_gate=false" % [
		_lut.size_x, _lut.size_y, _lut.size_z, _lut.contract, _lut.channels,
		_lut.q_min, _lut.q_max, _lut.theta_cone_min, _lut.theta_cone_max, _lut.beta_min, _lut.beta_max])
	return true


func _check_texels() -> bool:
	var data: PackedByteArray = _lut.data
	var size_x: int = _lut.size_x
	var size_y: int = _lut.size_y
	var size_z: int = _lut.size_z
	var texel_count := size_x * size_y * size_z
	for z in size_z:
		for y in size_y:
			for x in size_x:
				var base := ((z * size_y + y) * size_x + x) * 16
				var r := data.decode_float(base)
				var g := data.decode_float(base + 4)
				var b := data.decode_float(base + 8)
				var a := data.decode_float(base + 12)
				if not is_finite(r) or not is_finite(g) or not is_finite(b) or not is_finite(a) \
						or r < 0.0 or g < _lut.log_value_floor or b != 0.0 or a != 1.0:
					push_error("out-of-contract texel (%d,%d,%d): R=%s G=%.6f B=%.6f A=%.6f" % [
						x, y, z, String.num_scientific(r), g, b, a])
					return false
	print("LUT_DATA texels=%d finite_and_in_contract=true" % texel_count)
	return true


# ---------------------------------------------------------------------------
# Energy integration. Direct reference vs both LUT decoders per sample, with
# the projected midpoint measure cos(theta_o) * dtheta_o * dphi.
# ---------------------------------------------------------------------------

func _run_integration() -> Dictionary:
	var d_theta := PI / float(_grid_theta)
	var d_phi := TAU / float(_grid_phi)
	var measure := d_theta * d_phi
	var aggregate_direct := 0.0
	var aggregate_linear := 0.0
	var aggregate_log := 0.0
	var linear_sum_sq_abs := 0.0
	var linear_sum_sq_rel := 0.0
	var log_sum_sq_abs := 0.0
	var log_sum_sq_rel := 0.0
	var total_samples := 0
	var lut_interior := 0
	var q_beta_fallback := 0
	var grazing_fallback := 0
	var cone_pole_fallback := 0
	var asymptotic_beta_branch := 0
	var exact_c_phi_seam := 0
	# Support-renormalized diagnostic: projected mass over the actual
	# LUT-interior subset only (no fallback samples) per decoder.
	var interior_count := 0
	var interior_direct_mass := 0.0
	var interior_linear_mass := 0.0
	var interior_log_mass := 0.0
	# Direct-fallback diagnostic: totals over the samples evaluated through
	# the direct/asymptotic reference (seam + q/beta + cone-pole + grazing).
	var fallback_count := 0
	var fallback_direct_total := 0.0
	var fallback_linear_total := 0.0
	var fallback_log_total := 0.0
	var fallback_q_beta := 0
	var fallback_grazing := 0
	var fallback_cone_pole := 0
	var fallback_seam := 0
	var per_theta_i: Array = []
	for deg in THETA_I_DEG:
		var theta_i := deg_to_rad(float(deg))
		var e_direct := 0.0
		var e_linear := 0.0
		var e_log := 0.0
		for m in _grid_theta:
			var theta_o := -PI * 0.5 + (float(m) + 0.5) * d_theta
			var cos_o := cos(theta_o)
			for n in _grid_phi:
				var phi := -PI + (float(n) + 0.5) * d_phi
				var cos_phi_half := maxf(cos(phi * 0.5), 0.0)
				var theta_d := 0.5 * (theta_o - theta_i)
				var direct: float = Reference.direct_r_mn(theta_i, theta_o, theta_d, cos_phi_half, _cuticle, _beta_m)
				var coords: Dictionary = Reference.derive_r_coordinates(theta_i, theta_o, theta_d, cos_phi_half, _cuticle, _beta_m)
				var c_phi: float = coords["c_phi"]
				var theta_cone: float = coords["theta_cone"]
				var beta_r: float = coords["beta_r"]
				total_samples += 1
				var linear_recon := direct
				var log_recon := direct
				# Disjoint sample classification, in priority order:
				# seam > q/beta out-of-support > cone-pole band > grazing
				# footprint > LUT interior. asymptotic_beta_branch is a
				# diagnostic sub-count of q_beta_fallback (see header).
				var bucket := "interior"
				if c_phi <= C_PHI_SEAM_EPSILON:
					# Exact azimuthal seam: beta_r collapses toward zero and
					# the q LUT coordinate is degenerate; the direct reference
					# (asymptotic branch) resolves the 0 * infinity form.
					exact_c_phi_seam += 1
					bucket = "seam"
				else:
					var q := (theta_o - theta_cone) / beta_r
					if beta_r <= Reference.BETA_NUMERIC_EPSILON:
						# beta_r <= eps < beta_min is always out of the
						# rectangular support, so these land in q_beta_fallback
						# below and never in the pole/grazing/interior buckets.
						asymptotic_beta_branch += 1
					if not _lut_in_rect_support(q, theta_cone, beta_r):
						q_beta_fallback += 1
						bucket = "q_beta"
					elif _lut.requires_pole_band_fallback(theta_cone):
						cone_pole_fallback += 1
						bucket = "cone_pole"
					elif _lut.requires_reference_fallback(q, theta_cone, beta_r):
						# With rectangular support and the pole band already
						# excluded, a true return can only be a grazing
						# footprint straddling the outgoing-angle boundary.
						grazing_fallback += 1
						bucket = "grazing"
					else:
						lut_interior += 1
					var sampled_linear: float = _lut.sample_q_fallback(q, theta_cone, beta_r, Data.DECODE_LINEAR, Data.FALLBACK_OUTSIDE)
					var sampled_log: float = _lut.sample_q_fallback(q, theta_cone, beta_r, Data.DECODE_LOG, Data.FALLBACK_OUTSIDE)
					linear_recon = Reference.direct_r_mn_from_q(sampled_linear, theta_o, theta_cone, _beta_m)
					log_recon = Reference.direct_r_mn_from_q(sampled_log, theta_o, theta_cone, _beta_m)
				if not is_finite(direct) or not is_finite(linear_recon) or not is_finite(log_recon):
					_finite_ok = false
					push_error("non-finite R value at theta_i_deg=%d theta_o=%.6f phi=%.6f c_phi=%s" % [
						deg, theta_o, phi, String.num_scientific(c_phi)])
				var weight := cos_o * measure
				e_direct += direct * weight
				e_linear += linear_recon * weight
				e_log += log_recon * weight
				if bucket == "interior":
					interior_count += 1
					interior_direct_mass += direct * weight
					interior_linear_mass += linear_recon * weight
					interior_log_mass += log_recon * weight
				else:
					fallback_count += 1
					fallback_direct_total += direct * weight
					fallback_linear_total += linear_recon * weight
					fallback_log_total += log_recon * weight
					match bucket:
						"q_beta":
							fallback_q_beta += 1
						"grazing":
							fallback_grazing += 1
						"cone_pole":
							fallback_cone_pole += 1
						"seam":
							fallback_seam += 1
				var abs_linear := absf(linear_recon - direct)
				var abs_log := absf(log_recon - direct)
				var direct_sq := maxf(absf(direct) * absf(direct), RELATIVE_EPSILON * RELATIVE_EPSILON)
				linear_sum_sq_abs += abs_linear * abs_linear
				log_sum_sq_abs += abs_log * abs_log
				linear_sum_sq_rel += abs_linear * abs_linear / direct_sq
				log_sum_sq_rel += abs_log * abs_log / direct_sq
		if not is_finite(e_direct) or not is_finite(e_linear) or not is_finite(e_log):
			_finite_ok = false
			push_error("non-finite total at theta_i_deg=%d" % deg)
		aggregate_direct += e_direct
		aggregate_linear += e_linear
		aggregate_log += e_log
		per_theta_i.append({
			"theta_i_deg": float(deg),
			"direct": e_direct,
			"linear": e_linear,
			"log": e_log,
			"linear_error": _error_entry(e_direct, e_linear),
			"log_error": _error_entry(e_direct, e_log),
			"totals_finite": is_finite(e_direct) and is_finite(e_linear) and is_finite(e_log),
		})
		print("R_ENERGY theta_i_deg=%.1f direct=%.8f linear=%.8f log=%.8f linear_rel=%s log_rel=%s" % [
			float(deg), e_direct, e_linear, e_log,
			String.num_scientific(absf(e_linear - e_direct) / maxf(absf(e_direct), RELATIVE_EPSILON)),
			String.num_scientific(absf(e_log - e_direct) / maxf(absf(e_direct), RELATIVE_EPSILON))])
	if not is_finite(aggregate_direct) or not is_finite(aggregate_linear) or not is_finite(aggregate_log):
		_finite_ok = false

	# Disjoint-partition invariant (asymptotic_beta_branch is a diagnostic
	# sub-count of q_beta_fallback and is intentionally absent from the sum).
	var partition_sum := lut_interior + q_beta_fallback + grazing_fallback + cone_pole_fallback + exact_c_phi_seam
	if partition_sum != total_samples:
		_fail("branch partition invariant violated: total=%d lut_interior=%d q_beta_fallback=%d grazing_fallback=%d cone_pole_fallback=%d exact_c_phi_seam=%d" % [
			total_samples, lut_interior, q_beta_fallback, grazing_fallback, cone_pole_fallback, exact_c_phi_seam])
		return {}
	if asymptotic_beta_branch > q_beta_fallback:
		_fail("asymptotic_beta_branch (%d) must be a diagnostic sub-count of q_beta_fallback (%d)" % [
			asymptotic_beta_branch, q_beta_fallback])
		return {}

	var aggregate := {
		"direct_total": aggregate_direct,
		"linear_total": aggregate_linear,
		"log_total": aggregate_log,
		"linear": _decoder_aggregate(aggregate_direct, aggregate_linear, linear_sum_sq_abs, linear_sum_sq_rel, total_samples),
		"log": _decoder_aggregate(aggregate_direct, aggregate_log, log_sum_sq_abs, log_sum_sq_rel, total_samples),
		"totals_finite": is_finite(aggregate_direct) and is_finite(aggregate_linear) and is_finite(aggregate_log),
	}
	var branch_statistics := {
		"total": total_samples,
		"lut_interior": lut_interior,
		"q_beta_fallback": q_beta_fallback,
		"grazing_fallback": grazing_fallback,
		"cone_pole_fallback": cone_pole_fallback,
		"asymptotic_beta_branch": asymptotic_beta_branch,
		"exact_c_phi_seam": exact_c_phi_seam,
		"invariant": "total == lut_interior + q_beta_fallback + grazing_fallback + cone_pole_fallback + exact_c_phi_seam (disjoint buckets); asymptotic_beta_branch is a diagnostic sub-count of q_beta_fallback and is not part of the partition",
	}
	# Report-only diagnostics (no acceptance gate). The correction factor is
	# derived from direct-vs-decoded projected mass over the actual
	# LUT-interior subset and makes NO raw-M unit-normalization claim.
	var support_renormalized := {
		"samples": interior_count,
		"direct_mass": interior_direct_mass,
		"linear_mass": interior_linear_mass,
		"log_mass": interior_log_mass,
		"linear_correction_factor": interior_direct_mass / interior_linear_mass if interior_linear_mass > 0.0 else 0.0,
		"log_correction_factor": interior_direct_mass / interior_log_mass if interior_log_mass > 0.0 else 0.0,
		"linear_uncorrected_relative_deviation": absf(interior_direct_mass - interior_linear_mass) / maxf(absf(interior_direct_mass), RELATIVE_EPSILON),
		"log_uncorrected_relative_deviation": absf(interior_direct_mass - interior_log_mass) / maxf(absf(interior_direct_mass), RELATIVE_EPSILON),
		"note": "correction factor = direct projected mass / decoded projected mass over the actual LUT-interior subset only (samples classified lut_interior; q/beta out-of-support, cone-pole bands, grazing footprints and the exact c_phi seam are excluded). Multiplying the decoder mass by the factor reproduces the direct mass over that subset. Diagnostic only, no acceptance gate; makes no raw-M unit-normalization claim.",
	}
	var asymptotic_probe := []
	for beta_multiplier in PROBE_BETA_MULTIPLIERS:
		var beta_r: float = beta_multiplier * Reference.BETA_NUMERIC_EPSILON
		# reference_q_value derives theta_o = theta_cone + q * beta_r. With
		# PROBE_THETA_O == PROBE_THETA_CONE, q = 0 reproduces theta_o ==
		# theta_cone at every probe point (no degeneracy at beta_r = 0).
		var q: float = (PROBE_THETA_O - PROBE_THETA_CONE) / beta_r if beta_r > 0.0 else 0.0
		asymptotic_probe.append({
			"beta_r": beta_r,
			"branch": "asymptotic" if beta_r <= Reference.BETA_NUMERIC_EPSILON else "direct",
			"q": q,
			"theta_o_effective": PROBE_THETA_O if beta_r > 0.0 else PROBE_THETA_CONE,
			"reference_q_value": _lut.reference_q_value(q, PROBE_THETA_CONE, beta_r),
			"direct_q_value": Reference.direct_q_value(PROBE_THETA_O, PROBE_THETA_CONE, beta_r),
			"asymptotic_q_value": Reference.asymptotic_q_value(PROBE_THETA_O, PROBE_THETA_CONE, beta_r),
		})
	var direct_fallback := {
		"samples": fallback_count,
		"direct_total": fallback_direct_total,
		"linear_total": fallback_linear_total,
		"log_total": fallback_log_total,
		"branch_counts": {
			"q_beta_fallback": fallback_q_beta,
			"grazing_fallback": fallback_grazing,
			"cone_pole_fallback": fallback_cone_pole,
			"exact_c_phi_seam": fallback_seam,
		},
		"note": "totals over the samples evaluated through the direct/asymptotic reference (exact c_phi seam + q/beta out-of-support + cone-pole bands + grazing footprints). On these samples the decoders equal the direct value by construction, so linear_total == log_total == direct_total modulo float rounding in the log round trip. Diagnostic only, no acceptance gate.",
	}
	var diagnostics := {
		"acceptance_gate": false,
		"support_renormalized": support_renormalized,
		"asymptotic_branch_probe": {
			"theta_o": PROBE_THETA_O,
			"theta_cone": PROBE_THETA_CONE,
			"beta_numeric_epsilon": Reference.BETA_NUMERIC_EPSILON,
			"note": "reference Q probed at beta_r in {0, 0.5*eps, eps, 2*eps} around the direct/asymptotic branch boundary, with theta_o == theta_cone (delta = 0, q = 0) so the geometry is identical at every probe point and the probe isolates the branch seam. The asymptotic form is exact here (Q = 1/sqrt(2*pi), independent of beta) while the direct Bessel approximation is off by ~2-4x in this regime (1.515 at the floored beta, 0.758 just above the threshold, vs 0.399) because of its ~1e-16 * variance_inverse cancellation error -- which is exactly why beta_r <= eps routes to the asymptotic branch. The LUT sampler support is irrelevant here: this probes the reference branch seam, not the LUT. Diagnostic only, no acceptance gate.",
			"probes": asymptotic_probe,
		},
		"direct_fallback": direct_fallback,
	}
	var report := {
		"schema": SCHEMA,
		"contract": CONTRACT_MODE,
		"tool": "validate_marschner_r_standardized_energy",
		"phase": "Phase 3 CPU-only",
		"lut": {
			"path": LUT_PATH,
			"contract": _lut.contract,
			"channels": _lut.channels,
			"resolution": [_lut.size_x, _lut.size_y, _lut.size_z],
			"q_range": [_lut.q_min, _lut.q_max],
			"theta_cone_range": [_lut.theta_cone_min, _lut.theta_cone_max],
			"beta_range": [_lut.beta_min, _lut.beta_max],
		},
		"raw_m_unit_normalization_gate": false,
		"configuration": {
			"grid_theta": _grid_theta,
			"grid_phi": _grid_phi,
			"theta_i_degrees": THETA_I_DEG,
			"beta_m": _beta_m,
			"cuticle_tilt_radians": _cuticle,
			"eta": _eta,
			"albedo": _albedo,
			"theta_d": "0.5 * (theta_o - theta_i)",
			"cos_phi_half": "max(cos(phi / 2), 0)",
			"measure": "projected solid angle: f * cos(theta_o) dtheta_o dphi, theta_o in [-PI/2, PI/2], phi in [-PI, PI]",
			"quadrature": "deterministic midpoint rule at cell centers (theta_o = -PI/2 + (m + 0.5) * d_theta, phi = -PI + (n + 0.5) * d_phi)",
			"integrand": "M_R * N_R with N_R = 0.25 * cos(phi/2) (full scalar R product; R has no absorption)",
			"eta_albedo_are_metadata_only": true,
			"c_phi_seam_epsilon": C_PHI_SEAM_EPSILON,
			"seam_notes": "requires_reference_fallback only guards the outgoing-angle footprint; when sin_cone clamps to +/-1 the sample theta_cone sits at the Y-axis edge (pole) and the clamped trilinear read stores Q with sqrt(cos(cone_texel)) while direct_r_mn_from_q divides by sqrt(cos(theta_cone)) floored at 1e-12, so pole-clamped samples can overestimate M_R*N_R by up to ~sqrt(cos(1.5646)/1e-12) ~ 78000x. This is a real property of the LUT reconstruction seam, reported unweakened. The outer two theta_cone texel bands are classified as cone_pole_fallback and routed to the direct reference.",
		},
		"aggregate": aggregate,
		"per_theta_i": per_theta_i,
		"branch_statistics": branch_statistics,
		"diagnostics": diagnostics,
		"data_finite": _finite_ok,
	}
	print("R_ENERGY aggregate direct=%.8f linear=%.8f log=%.8f" % [aggregate_direct, aggregate_linear, aggregate_log])
	print("R_ENERGY branches total=%d lut_interior=%d q_beta_fallback=%d grazing_fallback=%d cone_pole_fallback=%d asymptotic_beta_branch=%d exact_c_phi_seam=%d" % [
		total_samples, lut_interior, q_beta_fallback, grazing_fallback, cone_pole_fallback, asymptotic_beta_branch, exact_c_phi_seam])
	print("R_ENERGY_DIAGNOSTICS support_renormalized samples=%d direct_mass=%.8f linear_factor=%s log_factor=%s fallback_samples=%d" % [
		interior_count, interior_direct_mass,
		String.num_scientific(support_renormalized["linear_correction_factor"]),
		String.num_scientific(support_renormalized["log_correction_factor"]),
		fallback_count])
	print("R_ENERGY rms_abs linear=%s log=%s rms_rel linear=%s log=%s" % [
		String.num_scientific(aggregate["linear"]["rms_absolute_error"]),
		String.num_scientific(aggregate["log"]["rms_absolute_error"]),
		String.num_scientific(aggregate["linear"]["rms_relative_error"]),
		String.num_scientific(aggregate["log"]["rms_relative_error"])])
	return report


## Rectangular (q/theta_cone/beta) LUT support membership, mirroring the range
## checks in sample_q_fallback/requires_reference_fallback but EXCLUDING the
## cone-pole and grazing footprint predicates: q/beta out-of-support is
## classified as q_beta_fallback FIRST, then the outer two theta_cone texel
## bands as cone_pole_fallback, then grazing footprints separately, so the
## buckets stay disjoint.
func _lut_in_rect_support(q: float, theta_cone: float, beta_r: float) -> bool:
	return q >= _lut.q_min and q <= _lut.q_max \
		and theta_cone >= _lut.theta_cone_min and theta_cone <= _lut.theta_cone_max \
		and beta_r >= _lut.beta_min and beta_r <= _lut.beta_max


func _error_entry(direct_total: float, decoder_total: float) -> Dictionary:
	var absolute := absf(decoder_total - direct_total)
	return {
		"absolute_error": absolute,
		"relative_error": absolute / maxf(absf(direct_total), RELATIVE_EPSILON),
	}


func _decoder_aggregate(direct_total: float, decoder_total: float, sum_sq_abs: float, sum_sq_rel: float, count: int) -> Dictionary:
	return {
		"absolute_error": absf(decoder_total - direct_total),
		"relative_error": absf(decoder_total - direct_total) / maxf(absf(direct_total), RELATIVE_EPSILON),
		"rms_absolute_error": sqrt(sum_sq_abs / float(maxi(count, 1))),
		"rms_relative_error": sqrt(sum_sq_rel / float(maxi(count, 1))),
		"sample_count": count,
	}


func _fail(message: String) -> void:
	push_error(message)
	print("FAST_MARSCHNER_R_STANDARDIZED_ENERGY_FAILED %s" % message)
	quit(1)
