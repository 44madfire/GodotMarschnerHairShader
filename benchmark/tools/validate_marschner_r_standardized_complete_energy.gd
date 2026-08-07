extends SceneTree

## Fresnel-weighted complete-R validator for the fp32-safe standardized-Q LUT
## diagnostic. Unlike the earlier MN-only matrix, eta participates in the
## integrand through the exact Fast/baseline Schlick Fresnel term:
##
##   R = M_R * N_R * F(cos(theta_d) * cos(phi/2), eta)
##
## The candidate mirrors hair_marschner_fast_r_standardized_body.gdshaderinc:
## beta<=0.015 uses the asymptotic Q limit, beta 0.015..0.03 blends into the
## LUT, and direct Bessel evaluation is reserved for high-beta geometric/
## out-of-domain fallbacks. Reports both MN-only and complete-R errors plus
## disjoint branch sample/energy attribution.

const LUT_PATH := "res://benchmark/resources/luts/fast_marschner_r_standardized_lut_256x256x128.res"
const Data := preload("res://benchmark/resources/fast_marschner_r_standardized_lut_data.gd")
const Reference := preload("res://benchmark/reference/fast_marschner_r_standardized_kernel_reference.gd")

const SCHEMA := "standardized_r_complete_energy_v2"
const THETA_I_DEG := [-60.0, -30.0, 0.0, 30.0, 60.0]
const GRID_DEFAULT := 128
const PHI_GRID_DEFAULT := 64
const BETA_M_DEFAULT := 0.2
const CUTICLE_DEFAULT := 0.087
const ETA_DEFAULT := 1.55
const LOW_BETA_BLEND := Vector2(0.015, 0.03)
const C_PHI_SEAM_EPSILON := 1e-6
const REL_EPSILON := 1e-12
const Q_TAILS := [8.0, 10.0, 12.0, 16.0]

var _grid := GRID_DEFAULT
var _phi_grid := PHI_GRID_DEFAULT
var _beta_m := BETA_M_DEFAULT
var _cuticle := CUTICLE_DEFAULT
var _eta := ETA_DEFAULT
var _lut: Resource
var _finite_ok := true

func _initialize() -> void:
	if not _parse_args():
		quit(1)
		return
	_lut = load(LUT_PATH)
	if _lut == null:
		push_error("failed to load %s" % LUT_PATH)
		quit(1)
		return
	var validation: PackedStringArray = _lut.validation_errors()
	if not validation.is_empty():
		push_error("LUT validation failed: %s" % "; ".join(validation))
		quit(1)
		return
	var report := _integrate()
	print(JSON.stringify(report, "\t"))
	if not _finite_ok:
		push_error("non-finite value encountered")
		quit(1)
		return
	print("FAST_MARSCHNER_R_STANDARDIZED_COMPLETE_ENERGY_OK")
	quit(0)

func _parse_args() -> bool:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--grid="):
			_grid = int(argument.trim_prefix("--grid="))
		elif argument.begins_with("--phi-grid="):
			_phi_grid = int(argument.trim_prefix("--phi-grid="))
		elif argument.begins_with("--beta-m="):
			_beta_m = float(argument.trim_prefix("--beta-m="))
		elif argument.begins_with("--cuticle="):
			_cuticle = float(argument.trim_prefix("--cuticle="))
		elif argument.begins_with("--eta="):
			_eta = float(argument.trim_prefix("--eta="))
		elif argument == "--contract=report":
			pass
		else:
			push_error("unknown/unsupported argument: %s" % argument)
			return false
	if _grid < 4 or _grid > 1024 or _phi_grid < 4 or _phi_grid > 2048:
		push_error("grid sizes out of range")
		return false
	if not is_finite(_beta_m) or _beta_m <= 0.0 or not is_finite(_cuticle) or not is_finite(_eta) or _eta <= 0.0:
		push_error("non-finite/invalid material parameter")
		return false
	return true

func _fresnel(cos_theta: float, eta: float) -> float:
	var f0 := (1.0 - eta) * (1.0 - eta) / ((1.0 + eta) * (1.0 + eta))
	var p := 1.0 - clampf(cos_theta, 0.0, 1.0)
	var p_sq := p * p
	var schlick_tail := p_sq * p_sq * p
	return lerpf(schlick_tail, 1.0, f0)

func _new_metric() -> Dictionary:
	return {
		"direct": 0.0,
		"linear": 0.0,
		"log": 0.0,
		"linear_sq_abs": 0.0,
		"log_sq_abs": 0.0,
		"linear_sq_rel": 0.0,
		"log_sq_rel": 0.0,
		"sample_count": 0,
		"weight_sum": 0.0,
	}

func _new_branch_stats() -> Dictionary:
	var result := {}
	for name in ["lut_interior", "lut_transition", "low_beta_asymptotic", "q_outside", "beta_above_domain", "cone_pole_fallback", "grazing_fallback", "exact_c_phi_seam"]:
		result[name] = {"samples": 0, "complete_r_direct_energy": 0.0}
	result["expensive_direct_samples"] = 0
	result["expensive_direct_complete_r_energy"] = 0.0
	return result

func _candidate_q(theta_o: float, theta_cone: float, beta_r: float, q: float, decode: int) -> Dictionary:
	var blend_low := LOW_BETA_BLEND.x
	var blend_high := LOW_BETA_BLEND.y
	var asym := Reference.asymptotic_q_value(theta_o, theta_cone, maxf(beta_r, Reference.BETA_NUMERIC_EPSILON))
	var bucket := "lut_interior"
	var direct_expensive := false

	if beta_r <= Reference.BETA_NUMERIC_EPSILON:
		return {"q": asym, "bucket": "exact_c_phi_seam", "direct_expensive": false}
	if beta_r <= blend_low:
		return {"q": asym, "bucket": "low_beta_asymptotic", "direct_expensive": false}

	var q_outside := q < _lut.q_min or q > _lut.q_max or theta_cone < _lut.theta_cone_min or theta_cone > _lut.theta_cone_max
	var beta_above := beta_r > _lut.beta_max
	var pole := false
	var grazing := false
	if not q_outside and not beta_above:
		pole = _lut.requires_pole_band_fallback(theta_cone)
		if not pole:
			# Probe geometric footprint at the actual beta when inside the LUT
			# domain, otherwise at beta_min during the low-beta blend.
			var footprint_beta := clampf(beta_r, _lut.beta_min, _lut.beta_max)
			grazing = _lut.requires_reference_fallback(q, theta_cone, footprint_beta)

	if q_outside:
		bucket = "q_outside"
	elif beta_above:
		bucket = "beta_above_domain"
	elif pole:
		bucket = "cone_pole_fallback"
	elif grazing:
		bucket = "grazing_fallback"
	elif beta_r < blend_high:
		bucket = "lut_transition"
	else:
		bucket = "lut_interior"

	var geometry_fallback := q_outside or beta_above or pole or grazing
	if geometry_fallback:
		if beta_r < blend_high:
			return {"q": asym, "bucket": bucket, "direct_expensive": false}
		direct_expensive = true
		return {"q": Reference.direct_q_value(theta_o, theta_cone, beta_r), "bucket": bucket, "direct_expensive": true}

	var sampled := _lut.sample_q(q, theta_cone, maxf(beta_r, _lut.beta_min), decode)
	if beta_r < blend_high:
		var t := smoothstep(blend_low, blend_high, beta_r)
		sampled = lerpf(asym, sampled, t)
	return {"q": sampled, "bucket": bucket, "direct_expensive": direct_expensive}

func _update_metric(metric: Dictionary, direct: float, linear: float, logarithmic: float, domega: float) -> void:
	var direct_e := direct * domega
	var linear_e := linear * domega
	var log_e := logarithmic * domega
	metric["direct"] += direct_e
	metric["linear"] += linear_e
	metric["log"] += log_e
	var lin_abs := linear - direct
	var log_abs := logarithmic - direct
	var denom := maxf(absf(direct), REL_EPSILON)
	metric["linear_sq_abs"] += lin_abs * lin_abs * domega
	metric["log_sq_abs"] += log_abs * log_abs * domega
	metric["linear_sq_rel"] += (lin_abs / denom) * (lin_abs / denom) * domega
	metric["log_sq_rel"] += (log_abs / denom) * (log_abs / denom) * domega
	metric["weight_sum"] += domega
	metric["sample_count"] += 1

func _finalize_metric(metric: Dictionary) -> Dictionary:
	var direct: float = metric["direct"]
	var weight_sum := maxf(float(metric["weight_sum"]), REL_EPSILON)
	return {
		"direct_total": direct,
		"linear_total": metric["linear"],
		"log_total": metric["log"],
		"linear_absolute_error": absf(float(metric["linear"]) - direct),
		"log_absolute_error": absf(float(metric["log"]) - direct),
		"linear_relative_error": absf(float(metric["linear"]) - direct) / maxf(absf(direct), REL_EPSILON),
		"log_relative_error": absf(float(metric["log"]) - direct) / maxf(absf(direct), REL_EPSILON),
		"linear_rms_absolute": sqrt(float(metric["linear_sq_abs"]) / weight_sum),
		"log_rms_absolute": sqrt(float(metric["log_sq_abs"]) / weight_sum),
		"linear_rms_relative": sqrt(float(metric["linear_sq_rel"]) / weight_sum),
		"log_rms_relative": sqrt(float(metric["log_sq_rel"]) / weight_sum),
		"sample_count": metric["sample_count"],
	}

func _integrate() -> Dictionary:
	var aggregate_mn := _new_metric()
	var aggregate_r := _new_metric()
	var branches := _new_branch_stats()
	var per_theta: Array = []
	var q_tail_energy := {}
	for threshold in Q_TAILS:
		q_tail_energy[str(threshold)] = 0.0
	var dtheta := PI / float(_grid)
	var dphi := TAU / float(_phi_grid)

	for theta_i_deg in THETA_I_DEG:
		var theta_i := deg_to_rad(theta_i_deg)
		var theta_mn := _new_metric()
		var theta_r := _new_metric()
		for theta_index in _grid:
			var theta_o := -0.5 * PI + (float(theta_index) + 0.5) * dtheta
			var cos_theta_o := cos(theta_o)
			var domega_theta := cos_theta_o * dtheta * dphi
			for phi_index in _phi_grid:
				var phi := -PI + (float(phi_index) + 0.5) * dphi
				# Match the shader's relative-azimuth clamp before deriving c_phi.
				var cos_phi := clampf(cos(phi), -0.9999, 0.9999)
				var c_phi := sqrt(maxf(0.0, 0.5 + 0.5 * cos_phi))
				var theta_d := 0.5 * (theta_o - theta_i)
				var coordinates := Reference.derive_r_coordinates(theta_i, theta_o, theta_d, c_phi, _cuticle, _beta_m)
				var theta_cone: float = coordinates["theta_cone"]
				var beta_r: float = coordinates["beta_r"]
				var q: float = coordinates["q"]
				var direct_mn := Reference.direct_r_mn(theta_i, theta_o, theta_d, c_phi, _cuticle, _beta_m)
				var linear_q_info := _candidate_q(theta_o, theta_cone, beta_r, q, Data.DECODE_LINEAR)
				var log_q_info := _candidate_q(theta_o, theta_cone, beta_r, q, Data.DECODE_LOG)
				var linear_mn := Reference.direct_r_mn_from_q(float(linear_q_info["q"]), theta_o, theta_cone, _beta_m)
				var log_mn := Reference.direct_r_mn_from_q(float(log_q_info["q"]), theta_o, theta_cone, _beta_m)
				var fresnel := _fresnel(cos(theta_d) * c_phi, _eta)
				var direct_r := direct_mn * fresnel
				var linear_r := linear_mn * fresnel
				var log_r := log_mn * fresnel
				if not is_finite(direct_r) or not is_finite(linear_r) or not is_finite(log_r):
					_finite_ok = false
				_update_metric(theta_mn, direct_mn, linear_mn, log_mn, domega_theta)
				_update_metric(theta_r, direct_r, linear_r, log_r, domega_theta)
				_update_metric(aggregate_mn, direct_mn, linear_mn, log_mn, domega_theta)
				_update_metric(aggregate_r, direct_r, linear_r, log_r, domega_theta)

				var bucket: String = linear_q_info["bucket"]
				branches[bucket]["samples"] += 1
				branches[bucket]["complete_r_direct_energy"] += direct_r * domega_theta
				if bool(linear_q_info["direct_expensive"]):
					branches["expensive_direct_samples"] += 1
					branches["expensive_direct_complete_r_energy"] += direct_r * domega_theta
				for threshold in Q_TAILS:
					if absf(q) > threshold:
						q_tail_energy[str(threshold)] += direct_r * domega_theta
		per_theta.append({
			"theta_i_deg": theta_i_deg,
			"mn_only": _finalize_metric(theta_mn),
			"complete_r": _finalize_metric(theta_r),
		})

	var aggregate_r_final := _finalize_metric(aggregate_r)
	var total_samples := int(aggregate_r["sample_count"])
	var total_r_energy := maxf(float(aggregate_r_final["direct_total"]), REL_EPSILON)
	for name in ["lut_interior", "lut_transition", "low_beta_asymptotic", "q_outside", "beta_above_domain", "cone_pole_fallback", "grazing_fallback", "exact_c_phi_seam"]:
		branches[name]["sample_share"] = float(branches[name]["samples"]) / float(maxi(total_samples, 1))
		branches[name]["complete_r_energy_share"] = float(branches[name]["complete_r_direct_energy"]) / total_r_energy
	branches["expensive_direct_sample_share"] = float(branches["expensive_direct_samples"]) / float(maxi(total_samples, 1))
	branches["expensive_direct_complete_r_energy_share"] = float(branches["expensive_direct_complete_r_energy"]) / total_r_energy
	var q_tail_report := {}
	for threshold in Q_TAILS:
		q_tail_report[str(threshold)] = {
			"direct_complete_r_energy": q_tail_energy[str(threshold)],
			"energy_share": float(q_tail_energy[str(threshold)]) / total_r_energy,
		}

	return {
		"schema": SCHEMA,
		"contract": "REPORT",
		"configuration": {
			"grid_theta": _grid,
			"grid_phi": _phi_grid,
			"theta_i_deg": THETA_I_DEG,
			"beta_m": _beta_m,
			"cuticle": _cuticle,
			"eta": _eta,
			"low_beta_blend": [LOW_BETA_BLEND.x, LOW_BETA_BLEND.y],
			"lut_path": LUT_PATH,
			"lut_contract": _lut.contract,
			"lut_dimensions": [_lut.size_x, _lut.size_y, _lut.size_z],
			"lut_q_range": [_lut.q_min, _lut.q_max],
			"lut_beta_range": [_lut.beta_min, _lut.beta_max],
		},
		"mn_only": _finalize_metric(aggregate_mn),
		"complete_r": aggregate_r_final,
		"per_theta_i": per_theta,
		"branch_statistics": branches,
		"q_tail_complete_r": q_tail_report,
		"notes": [
			"complete_r includes the exact Fast/baseline Schlick Fresnel, so eta affects the integrand",
			"low beta uses the asymptotic Q path and never invokes direct Bessel below the 0.03 blend high bound",
			"the shipping Fast wrapper is not modified by this diagnostic validator",
		],
	}
