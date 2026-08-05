extends SceneTree

## Phase 4 integrated-energy validator: baseline reference Marschner vs the
## Tier-2 Fast Marschner model, deterministic CPU angular integration.
##
## Scope (see .slim/deepwork/tier2-energy-correction.md, Phase 4):
##   - Compares the current reference baseline equations
##     (benchmark/reference/hair.gdshaderinc: energy-conserving d'Eon 2011
##     longitudinal with log-I0 Bessel approximation, non-separable d'Eon 2014
##     lobe widths/tilts, approximate h_TRT = 0.91 cross-section offset)
##     against the current Fast equations
##     (assets/hair/materials/shaders/hair_marschner_fast.gdshaderinc:
##     theta_h-space variance Gaussian, Unity-style fixed-h TT/TRT
##     attenuation, outgoing-Snell cos_theta_t) using IDENTICAL parameters.
##   - Shared terms replicated on both sides: Chiang et al. (2016)
##     albedo-to-absorption sigma_a = (ln(albedo)/c(beta_N))^2 with the raw
##     artist-facing beta_N, the reparameterized roughness polynomial
##     (seed 0.5 -> mix(0.8, 1.2, seed) == 1.0, deterministic), the logistic
##     azimuthal distributions and the Schlick Fresnel terms.
##   - No LUT, no dual-scatter, no environment, no exposure compensation:
##     comparison exposure gain = 1, lobe scales = vec3(1).
##
## Measure / Jacobian:
##   Outgoing directions are parameterized on the full sphere in strand space
##   (phi_i = 0 WLOG): omega_o = (sin theta_o, cos theta_o cos phi,
##   cos theta_o sin phi), theta_o in [-pi/2, pi/2], phi in [0, 2*pi]. The
##   sphere area element is domega = cos theta_o * dtheta_o * dphi, so the
##   reported per-lobe energies are the projected solid-angle integrals
##       E_p = INT INT f_p(theta_i, theta_o, phi) * cos theta_o dtheta_o dphi,
##   i.e. the BRDF-albedo-like quantity the light loop integrates implicitly
##   (LIGHT_COLOR = ATTENUATION = specular = exposure = 1; single scattering
##   has no /PI factor in either shader). Energies are RGB (the Beer-Lambert
##   attenuation is RGB); scalar totals/ratios sum the three channels.
##   Quadrature is a deterministic midpoint rule with GRID_THETA x GRID_PHI
##   cells; a coarse-grid drift probe documents quadrature convergence. The
##   midpoint domain is theta_o in [-pi/2, pi/2] x phi in [0, 2*pi], sampled
##   at cell centers ((m + 0.5) * d_theta, (n + 0.5) * d_phi).
##   Ratio masking policy (diagnostic only, NOT an acceptance gate): a
##   per-theta_i entry is marked baseline_ratio_valid = false and excluded
##   from the ratio_audit statistics when its baseline total is not greater
##   than BASELINE_RATIO_EPSILON * max_baseline_total, so near-zero baseline
##   grazing angles cannot pollute the audit; the aggregate acceptance gate
##   below is unmasked and unchanged.
##
## Notes / limitations:
##   - CPU port uses double precision; the GPU shaders use fp32. Differences
##     are far below the reported energy ratios.
##   - The Fast theta_h Gaussian is normalized in theta_h space; since
##     theta_h = 0.5*(theta_i + theta_o), its integral over theta_o is ~2
##     (factor 2), while the baseline d'Eon function is normalized to ~1 in
##     the projected measure. Structural model difference; the acceptance
##     line reflects it honestly (no forced pass).
##   - Karis multiple scattering is representable consistently only for
##     ATTENUATION = 1 (both shader variants then reduce to the identical
##     closed form; the render path also shares the /PI on DIFFUSE_LIGHT, so
##     it cancels in the ratio). The integrated Karis parity is a harness
##     self-check, NOT the energy gate: image-space Karis screenshots are
##     modulated by coverage, alpha hashing, tone mapping, and shadow
##     ATTENUATION, so screenshot ratios cannot gate BSDF energy.
##   - Default single parameter set (Blowout clone material, eta 1.55), with
##     CLI-selectable material inputs (--eta, --beta-m, --beta-n, --albedo,
##     --cuticle) whose defaults are identical; any non-default material makes
##     --contract=regression inapplicable. The five theta_i values required by
##     Phase 4.
##   - --decomposition=full|m|n|a|mn|ma subsets the per-lobe M*N*A factors
##     (m = longitudinal, n = azimuthal distribution, a = RGB attenuation;
##     R has n = cosine distribution and a = Fresnel) as diagnostic/report-only
##     measurements. "full" reproduces the shipping byte-for-byte; non-full
##     decompositions never pass --contract=regression.
##
## Run with (Windows Godot only, never the Linux binary):
##   /mnt/c/Tools/Godot/godot.exe --headless \
##     --path "//wsl.localhost/Ubuntu/home/jeffreymwang/godot-hair-shader" \
##     --script res://benchmark/tools/validate_fast_marschner_energy.gd
## Optional user args: --grid=512 (fine grid per axis), --coarse=128,
## --cuticle=<radians> (runtime cuticle tilt; default CUTICLE_TILT, pass 0.0
## for the alpha=0 control run without editing the source),
## --eta=<float> (runtime refractive index; default 1.55),
## --beta-m=<float>, --beta-n=<float> (runtime artist-facing roughnesses;
## defaults 0.2 and 0.75),
## --albedo=r,g,b (runtime RGB base color; default
## 0.24774602,0.12215338,0.09630052),
## --decomposition=full|m|n|a|mn|ma (per-lobe factor subset; default full =
## shipping M*N*A byte-equivalent. m = longitudinal only (N=1, A=1), n =
## azimuthal distribution only (M=1, A=1), a = RGB attenuation only (M=1,
## N=1), mn = M*N (A=1), ma = M*A (N=1). R's n is its scalar Fresnel/cosine
## lobe and a = 1; TT/TRT split the logistic distribution from the RGB
## attenuation before combining. Diagnostic/report-only: any non-full
## decomposition fails --contract=regression as inapplicable),
## --longitudinal=unity|baseline (fast longitudinal model; default unity =
## FM_LONGITUDINAL_MODE 0 theta_h Gaussian, baseline = FM_LONGITUDINAL_MODE 1
## baseline-compatible separable sin(theta_o) cone Gaussian diagnostic),
## --r-longitudinal=standard|nonseparable (fast R longitudinal model; default
## standard = FM_R_LONGITUDINAL_MODE 0 shared longitudinal R path, nonseparable
## = FM_R_LONGITUDINAL_MODE 1 cheap non-separable R-only diagnostic override,
## NOT the full d'Eon 2014 non-separable baseline; no compensation),
## --azimuthal=fixed_h|baseline_h (fast azimuthal cross-section model for the
## CPU analytic port; default fixed_h = FM_AZIMUTHAL_MODE 0 shipping fixed-h
## logistic analytic approximation with h_TT = 0 and h_TRT = sqrt(3)/2,
## baseline_h = FM_AZIMUTHAL_MODE 1 diagnostic with the baseline dynamic
## h_TT = sign(sin_phi_half) * cos_phi_half / sqrt(1 + eta_prime_inv * (1 -
## 2 * eta_prime_inv * abs(sin_phi_half))) and h_TRT = 0.91. Diagnostic/
## report-only: baseline_h makes --contract=regression inapplicable. The LUT is
## out of this CPU comparison (no LUT path exists in the harness) and
## attenuation keeps the shipping fixed-h family in both modes),
## --r-study=current|unity_fresnel|unity_nf|baseline_m_unity_nf|unity_exact
## (benchmark-only R-lobe attribution study; non-current modes require
## --contract=report and never alter TT/TRT),
## --contract=parity|regression|report (acceptance gate; default regression =
## compare the current run against the checked-in JSON reference
## benchmark/reference/fast_marschner_energy_contract_v1.json, pass when the
## measured total/R/TT/TRT ratios match expected within ratio_absolute and the
## grid drift is <= grid_drift_max, nonzero exit on mismatch or invalid
## execution; parity = the strict Phase-4 bands below with a nonzero exit on
## failure; report = run and report, always exit 0 when execution/report
## generation succeeds, with the parity fields reported unweakened),
## --reference=<path> (regression reference override; default the checked-in
## contract v1 file). Regression mode additionally verifies the reference's
## model contract selectors/parameters against the running configuration
## (longitudinal_mode 0/unity, r_longitudinal_mode 0/standard, azimuthal_mode
## fixed_h, cuticle convention 0/baseline, attenuation unity_fixed_h, eta 1.55,
## raw beta M/N 0.2/0.75, cuticle 0.087, default albedo, unit exposure/lobe
## scales, no compensation), so unsupported CLI overrides
## (--longitudinal=baseline, --r-longitudinal=nonseparable,
## --azimuthal=baseline_h, --cuticle != 0.087, --eta != 1.55,
## --beta-m != 0.2, --beta-n != 0.75, --albedo != default,
## --decomposition != full) FAIL clearly as inapplicable instead of silently
## accepting a different shader mode.

# --- Shared material / model parameters (Blowout clone, deterministic) ---
# These constants are the SHIPPING DEFAULTS: the runtime vars below (_eta,
# _albedo, _beta_m_raw, _beta_n_raw, _cuticle_tilt, ...) are seeded from them
# and the CLI-selectable ones can be overridden. Every port, derivation and
# report reads the runtime vars, never the constants, so a non-default
# material propagates everywhere and --contract=regression stays pinned to
# the default reference configuration.
const ETA := 1.55
const ALBEDO := Vector3(0.24774602, 0.12215338, 0.09630052)
const BETA_M_RAW := 0.2   # longitudinal_roughness (artist-facing)
const BETA_N_RAW := 0.75  # azimuthal_roughness (artist-facing)
const CUTICLE_TILT := 0.087 # cuticle_tilt_offset (radians)
const SPECULAR := 1.0
const LOBE_SCALES := Vector3(1.0, 1.0, 1.0)
const EXPOSURE_GAIN := 1.0
## mix(0.8, 1.2, seed) == 1.0 makes the roughness reparameterization exact.
const SEED := 0.5
const THETA_I_DEG: Array = [-60, -30, 0, 30, 60]
const GRID_THETA := 512
const GRID_PHI := 512
const GRID_COARSE := 128

# --- Baseline model constants (hair.gdshaderinc shipped defines) ---
const H_TRT_BASELINE := 0.91 # USE_APPROXIMATE_TRT_CROSS_SECTION_OFFSET
# --- Fast model constants (hair_marschner_fast.gdshaderinc) ---
const H_TRT_FAST := 0.5 * sqrt(3.0) # FM_H_TRT
const H_TT_FAST := 0.0              # FM_H_TT

# --- Provisional Phase-4 linear-energy acceptance bands ---
# Total (R+TT+TRT, RGB summed) projected energy ratio must land in
# [0.98, 1.02]; per-lobe ratios (RGB summed) in [0.95, 1.05]. These are
# intentionally NOT relaxed: the validator reports an honest FAIL when the
# measured models disagree.
const TOTAL_RATIO_MIN := 0.98
const TOTAL_RATIO_MAX := 1.02
const LOBE_RATIO_MIN := 0.95
const LOBE_RATIO_MAX := 1.05

# --- Regression contract (checked-in JSON reference) ---
## Contract version of benchmark/reference/fast_marschner_energy_contract_v1.json.
const CONTRACT_VERSION := "fast_marschner_energy_contract_v1"
## Default regression reference; override with --reference=<path>.
const DEFAULT_REFERENCE_PATH := "res://benchmark/reference/fast_marschner_energy_contract_v1.json"
## Accepted --contract modes; unknown values fall back to the shipping default
## (regression) so a typo can never silently select a different gate.
const CONTRACT_MODES: Array = ["parity", "regression", "report"]
## Accepted --decomposition modes; unknown values fall back to the shipping
## default (full) so a typo can never silently run a different factor subset.
const DECOMPOSITION_MODES: Array = ["full", "m", "n", "a", "mn", "ma"]
## Accepted --azimuthal modes; unknown values fall back to the shipping
## default (fixed_h) so a typo can never silently run a different model.
const AZIMUTHAL_MODES: Array = ["fixed_h", "baseline_h"]
## Benchmark-only R-lobe attribution modes. These never select shipping shader
## behavior; they substitute CPU reference factors for the R lobe only.
const R_STUDY_MODES: Array = ["current", "unity_fresnel", "unity_nf", "baseline_m_unity_nf", "unity_exact"]
const UNITY_H_STEP := 0.1
const UNITY_H_SAMPLES := 20
const UNITY_SQRT_PI_OVER_8 := 0.6266570686577501
## Shipping shader selectors the regression reference is pinned to (hardcoded
## in this harness; compared against the JSON so a reference can never be
## silently applied to a different shader mode).
const CUTICLE_CONVENTION := 0             # FM_CUTICLE_TILT_CONVENTION (baseline convention)
const ATTENUATION_MODE := "unity_fixed_h" # FM_ATTENUATION_MODEL_UNITY fixed-h branch

# --- Ratio audit diagnostics (additional evidence, NOT an acceptance gate) ---
## Masking threshold for the per-theta_i ratio audit, as a fraction of the
## maximum per-incoming-angle baseline total: an entry is
## baseline_ratio_valid only when baseline_total > BASELINE_RATIO_EPSILON *
## max_baseline_total. Near-zero baseline totals (grazing angles) are masked
## so their unstable ratios cannot pollute the audit statistics.
const BASELINE_RATIO_EPSILON := 1e-3

var _beta_m := 0.0 # reparameterized longitudinal roughness (used by widths)
var _beta_n := 0.0 # reparameterized azimuthal roughness (used by logistic)
var _sigma_a := Vector3.ZERO
var _cuticle_tilt := CUTICLE_TILT # runtime cuticle tilt (radians), --cuticle= override
# Runtime material inputs (CLI-selectable where noted; shipping defaults from
# the consts above, so existing behavior is unchanged with no overrides). All
# ports, derivations and reports read these runtime vars.
var _eta := ETA                     # --eta=<float>
var _albedo := ALBEDO               # --albedo=r,g,b
var _beta_m_raw := BETA_M_RAW       # --beta-m=<float>
var _beta_n_raw := BETA_N_RAW       # --beta-n=<float>
var _specular := SPECULAR           # (not CLI-selectable)
var _lobe_scales := LOBE_SCALES     # (not CLI-selectable)
var _exposure_gain := EXPOSURE_GAIN # (not CLI-selectable)
var _seed := SEED                   # (not CLI-selectable)
var _decomposition := "full" # --decomposition=full|m|n|a|mn|ma (shipping default: full)
var _longitudinal_mode := "unity" # fast longitudinal model, --longitudinal=unity|baseline
var _r_longitudinal_mode := "standard" # fast R longitudinal model, --r-longitudinal=standard|nonseparable
var _azimuthal_mode := "fixed_h" # fast azimuthal cross-section model, --azimuthal=fixed_h|baseline_h
var _r_study_mode := "current" # benchmark-only R attribution, --r-study=...
var _contract_mode := "regression" # --contract=parity|regression|report (shipping default: regression)
var _reference_path := DEFAULT_REFERENCE_PATH # --reference=<path> override
var _unity_r_n_cache: Dictionary = {}


func _initialize() -> void:
	var grid_theta := GRID_THETA
	var grid_phi := GRID_PHI
	var coarse := GRID_COARSE
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--grid="):
			grid_theta = int(argument.trim_prefix("--grid=").strip_edges())
			grid_phi = grid_theta
		elif argument.begins_with("--coarse="):
			coarse = int(argument.trim_prefix("--coarse=").strip_edges())
		elif argument.begins_with("--cuticle="):
			_cuticle_tilt = float(argument.trim_prefix("--cuticle=").strip_edges())
		elif argument.begins_with("--eta="):
			_eta = float(argument.trim_prefix("--eta=").strip_edges())
		elif argument.begins_with("--beta-m="):
			_beta_m_raw = float(argument.trim_prefix("--beta-m=").strip_edges())
		elif argument.begins_with("--beta-n="):
			_beta_n_raw = float(argument.trim_prefix("--beta-n=").strip_edges())
		elif argument.begins_with("--albedo="):
			var albedo_parts := argument.trim_prefix("--albedo=").strip_edges().split(",")
			if albedo_parts.size() == 3:
				_albedo = Vector3(float(albedo_parts[0]), float(albedo_parts[1]), float(albedo_parts[2]))
		elif argument.begins_with("--decomposition="):
			_decomposition = argument.trim_prefix("--decomposition=").strip_edges()
		elif argument.begins_with("--longitudinal="):
			_longitudinal_mode = argument.trim_prefix("--longitudinal=").strip_edges()
		elif argument.begins_with("--r-longitudinal="):
			_r_longitudinal_mode = argument.trim_prefix("--r-longitudinal=").strip_edges()
		elif argument.begins_with("--azimuthal="):
			_azimuthal_mode = argument.trim_prefix("--azimuthal=").strip_edges()
		elif argument.begins_with("--r-study="):
			_r_study_mode = argument.trim_prefix("--r-study=").strip_edges()
		elif argument.begins_with("--contract="):
			_contract_mode = argument.trim_prefix("--contract=").strip_edges()
		elif argument.begins_with("--reference="):
			_reference_path = argument.trim_prefix("--reference=").strip_edges()
	# Unknown values fall back to the shipping default (unity/standard) so a
	# typo can never silently run a different model.
	if _longitudinal_mode != "unity" and _longitudinal_mode != "baseline":
		_longitudinal_mode = "unity"
	if _r_longitudinal_mode != "standard" and _r_longitudinal_mode != "nonseparable":
		_r_longitudinal_mode = "standard"
	# Unknown azimuthal values fall back to the shipping default (fixed_h) so a
	# typo can never silently run a different model.
	if not AZIMUTHAL_MODES.has(_azimuthal_mode):
		_azimuthal_mode = "fixed_h"
	if not R_STUDY_MODES.has(_r_study_mode):
		push_error("Unknown --r-study mode: %s" % _r_study_mode)
		quit(1)
		return
	# Unknown decomposition values fall back to the shipping default (full) so
	# a typo can never silently run a different factor subset.
	if not DECOMPOSITION_MODES.has(_decomposition):
		_decomposition = "full"
	# Unknown contract modes fall back to the shipping default (regression) so
	# a typo can never silently select a different acceptance gate.
	if not CONTRACT_MODES.has(_contract_mode):
		_contract_mode = "regression"
	if _r_study_mode != "current" and _contract_mode != "report":
		push_error("--r-study=%s is report-only; use --contract=report" % _r_study_mode)
		quit(1)
		return
	if _r_study_mode != "current" and (_longitudinal_mode != "unity" or _r_longitudinal_mode != "standard" or _azimuthal_mode != "fixed_h"):
		push_error("--r-study=%s requires --longitudinal=unity --r-longitudinal=standard --azimuthal=fixed_h" % _r_study_mode)
		quit(1)
		return

	# Shared material derivation, identical on both sides. Uses the runtime
	# material inputs so non-default --eta/--beta-m/--beta-n/--albedo
	# propagate into every port, report and the sigma derivation.
	_beta_m = maxf(1e-3, 1.0 * (0.726 * _beta_m_raw + 0.812 * _beta_m_raw * _beta_m_raw
		+ 3.7 * pow(_beta_m_raw, 20.0)))
	_beta_n = maxf(1e-3, 1.0 * (0.265 * _beta_n_raw + 1.194 * _beta_n_raw * _beta_n_raw
		+ 5.372 * pow(_beta_n_raw, 22.0)))
	_sigma_a = _sigma_from_albedo(_albedo, _beta_n_raw)

	var report := {}
	report["tool"] = "validate_fast_marschner_energy"
	report["scope"] = "Phase 4 integrated-energy comparison, no LUT/dual/environment/compensation"
	report["longitudinal_mode"] = _longitudinal_mode
	report["r_longitudinal_mode"] = _r_longitudinal_mode
	report["azimuthal_mode"] = _azimuthal_mode
	report["r_study_mode"] = _r_study_mode
	report["r_study"] = _r_study_description()
	report["r_study"]["unity_no_beer_lambert_for_r"] = true
	report["r_study"]["unity_h_samples"] = UNITY_H_SAMPLES
	report["r_study"]["unity_h_step"] = UNITY_H_STEP
	report["r_study"]["unity_radial_roughness_input"] = _beta_n_raw
	report["parameters"] = {
		"eta": _eta,
		"albedo": [_albedo.x, _albedo.y, _albedo.z],
		"longitudinal_roughness_raw": _beta_m_raw,
		"azimuthal_roughness_raw": _beta_n_raw,
		"longitudinal_roughness_reparameterized": _beta_m,
		"azimuthal_roughness_reparameterized": _beta_n,
		"cuticle_tilt_alpha": _cuticle_tilt,
		"longitudinal_mode": _longitudinal_mode,
		"fast_longitudinal_model": ("theta_h Gaussian (FM_LONGITUDINAL_MODE 0, Unity-standard, shipping default)"
			if _longitudinal_mode == "unity" else
			"separable sin(theta_o) Gaussian (FM_LONGITUDINAL_MODE 1, baseline-compatible diagnostic, not the full non-separable baseline)"),
		"r_longitudinal_mode": _r_longitudinal_mode,
		"fast_r_longitudinal_model": ("shared longitudinal R path (FM_R_LONGITUDINAL_MODE 0, shipping default)"
			if _r_longitudinal_mode == "standard" else
			"cheap non-separable R diagnostic (FM_R_LONGITUDINAL_MODE 1, R-only override after the shared longitudinal call: z_r = cos_phi_half, beta_r = sqrt(2)*z_r*beta_m with a positive floor, sin_theta_cone_r = clamp(-sin_theta_i + 2*z_r*cuticle_tilt, -1, 1) in sin(theta_o) space; NOT the full d'Eon 2014 non-separable baseline, no compensation)"),
		"azimuthal_mode": _azimuthal_mode,
		"r_study_mode": _r_study_mode,
		"fast_azimuthal_model": ("fixed-h logistic analytic approximation (FM_AZIMUTHAL_MODE 0 / FM_AZIMUTHAL_FIXED_H_ANALYTIC, shipping default: h_TT = 0, h_TRT = sqrt(3)/2)"
			if _azimuthal_mode == "fixed_h" else
			"baseline cross-section diagnostic for the ANALYTIC BSDF only (FM_AZIMUTHAL_MODE 1 / FM_AZIMUTHAL_BASELINE_H_ANALYTIC: dynamic h_TT = sign(sin_phi_half) * cos_phi_half / sqrt(1 + eta_prime_inv * (1 - 2 * eta_prime_inv * abs(sin_phi_half))), h_TRT = 0.91; LUT sampling and the fixed-h attenuation family unchanged)"),
		"decomposition": _decomposition,
		"specular": _specular,
		"lobe_scales": [_lobe_scales.x, _lobe_scales.y, _lobe_scales.z],
		"comparison_exposure_gain": _exposure_gain,
		"roughness_seed": _seed,
		"absorption_formula": "sigma_a = (ln(albedo) / c(beta_n_raw))^2 (Chiang 2016)",
		"sigma_a": [_sigma_a.x, _sigma_a.y, _sigma_a.z],
		"baseline_alpha_passed_to_bsdf": -_cuticle_tilt,
		"fast_lobe_alpha": [_cuticle_tilt, -0.5 * _cuticle_tilt, -1.5 * _cuticle_tilt],
		"fast_lobe_variance_stddev": [1.0 * _beta_m, 0.5 * _beta_m, 2.0 * _beta_m],
		"baseline_h_trt": H_TRT_BASELINE,
		"fast_h_trt": H_TRT_FAST,
	}
	report["runtime_parameters"] = {
		"eta": _eta,
		"albedo": [_albedo.x, _albedo.y, _albedo.z],
		"beta_m_raw": _beta_m_raw,
		"beta_n_raw": _beta_n_raw,
		"cuticle_tilt_alpha": _cuticle_tilt,
		"specular": _specular,
		"lobe_scales": [_lobe_scales.x, _lobe_scales.y, _lobe_scales.z],
		"exposure_gain": _exposure_gain,
		"roughness_seed": _seed,
		"longitudinal_mode": _longitudinal_mode,
		"r_longitudinal_mode": _r_longitudinal_mode,
		"azimuthal_mode": _azimuthal_mode,
		"r_study_mode": _r_study_mode,
		"decomposition": _decomposition,
		"cli_overridable": ["--eta", "--albedo", "--beta-m", "--beta-n", "--cuticle",
			"--decomposition", "--longitudinal", "--r-longitudinal", "--azimuthal", "--r-study"],
		"note": "Runtime material/model inputs; shipping defaults match the reference material exactly. --contract=regression verifies these against the reference, so any non-default value makes the reference inapplicable (FAIL, never a silent pass).",
	}
	report["decomposition"] = {
		"mode": _decomposition,
		"semantics": "per-lobe M*N*A factor subsets: m = longitudinal only (N=1, A=1); n = azimuthal distribution only (M=1, A=1); a = attenuation only (M=1, N=1); mn = M*N (A=1); ma = M*A (N=1); full = M*N*A",
		"per_lobe_factors": "R: m = longitudinal, n = 0.25*cos(phi/2) cosine distribution, a = scalar Fresnel replicated to RGB. TT/TRT: m = longitudinal, n = logistic distribution, a = RGB attenuation (logistic split from attenuation before combining). The lobe scale multiplies the longitudinal m factor in every mode; scalar factors are replicated to RGB explicitly (results stay Vector3 per lobe).",
		"full_byte_equivalent": _decomposition == "full",
		"note": "Diagnostic/report-only: non-full decompositions measure factor subsets, change every reported energy and NEVER pass --contract=regression (they fail it as inapplicable). Integration, ratio audit and contract JSON keep working for every mode; the Karis check is unchanged.",
	}
	report["measure"] = {
		"integral": "E_p = INT INT f_p(theta_i, theta_o, phi) * cos(theta_o) dtheta_o dphi (projected solid angle, RGB)",
		"theta_o_range": [-PI / 2.0, PI / 2.0],
		"phi_range": [0.0, TAU],
		"jacobian": "domega = cos(theta_o) dtheta_o dphi on the full strand-space sphere (phi_i = 0 WLOG)",
		"quadrature": "deterministic midpoint rule on the theta_o in [-pi/2, pi/2] x phi in [0, 2*pi] domain, sampled at cell centers ((m + 0.5) * d_theta, (n + 0.5) * d_phi)",
		"grid_theta": grid_theta,
		"grid_phi": grid_phi,
		"grid_coarse": coarse,
		"note": "Fast longitudinal normalization depends on the selected --longitudinal mode: the theta_h Gaussian (unity, FM_LONGITUDINAL_MODE 0) is normalized in theta_h = 0.5*(theta_i + theta_o) space, so its theta_o integral is ~2, while the separable sin(theta_o) cone Gaussian (baseline, FM_LONGITUDINAL_MODE 1) integrates like the baseline's sin-space function (~1 in the projected measure) without the non-separable widths/tilts. --r-longitudinal=nonseparable additionally overrides ONLY the fast R lobe with the FM_R_LONGITUDINAL_MODE 1 cheap non-separable diagnostic (z_r = cos_phi_half width/tilt coupling; R-only, no compensation, not the full d'Eon 2014 baseline); TT/TRT and the baseline equations are unchanged. The fast azimuthal cross-section model follows --azimuthal: fixed_h (FM_AZIMUTHAL_MODE 0, shipping default) keeps the fixed h_TT = 0 / h_TRT = sqrt(3)/2 angular offsets; baseline_h (FM_AZIMUTHAL_MODE 1 diagnostic) swaps in the baseline dynamic h_TT = sign(sin_phi_half) * cos_phi_half / sqrt(1 + eta_prime_inv * (1 - 2 * eta_prime_inv * abs(sin_phi_half))) and h_TRT = 0.91 for the fast analytic port only. The LUT is out of this CPU comparison (the harness has no LUT path) and attenuation keeps the shipping fixed-h family in both modes. Scalar totals/ratios sum the RGB channels.",
		"ratio_masking": "diagnostic only, NOT an acceptance gate: per-theta_i entries with baseline_total <= BASELINE_RATIO_EPSILON * max_baseline_total are flagged baseline_ratio_valid = false and excluded from the ratio_audit statistics; the aggregate acceptance gate is unmasked.",
	}
	report["contract"] = {
		"mode": _contract_mode,
		"decomposition": _decomposition,
		"azimuthal_mode": _azimuthal_mode,
		"reference_path": _reference_path,
		"reference_file_exists": FileAccess.file_exists(_reference_path),
		"expected_contract_version": CONTRACT_VERSION,
	}

	# Per-theta_i integration. Per-lobe energies are RGB; aggregate per-lobe
	# Vector3s sum over the theta_i set.
	var per_theta_i: Array = []
	var agg_base := [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
	var agg_fast := [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
	var agg_k_base := Vector3.ZERO
	var agg_k_fast := Vector3.ZERO
	for deg in THETA_I_DEG:
		var theta_i := deg_to_rad(float(deg))
		var e_base := _integrate_baseline(theta_i, grid_theta, grid_phi)
		var e_fast := _integrate_fast(theta_i, grid_theta, grid_phi)
		var k_base := _integrate_karis(theta_i, grid_theta, grid_phi, false)
		var k_fast := _integrate_karis(theta_i, grid_theta, grid_phi, true)
		for lobe in 3:
			agg_base[lobe] += e_base[lobe]
			agg_fast[lobe] += e_fast[lobe]
		agg_k_base += k_base
		agg_k_fast += k_fast
		per_theta_i.append(_theta_i_entry(float(deg), e_base, e_fast, k_base, k_fast))

	# Ratio audit (additional evidence, NOT an acceptance gate): annotate each
	# per-theta_i entry with its baseline-ratio validity mask and absolute/
	# relative total errors, then summarize over the valid entries.
	var max_baseline_total := 0.0
	for entry in per_theta_i:
		max_baseline_total = maxf(max_baseline_total, entry["baseline_total"])
	var mask_threshold := BASELINE_RATIO_EPSILON * max_baseline_total
	for entry in per_theta_i:
		var base_total: float = entry["baseline_total"]
		var fast_total: float = entry["fast_total"]
		var abs_err := absf(fast_total - base_total)
		entry["baseline_ratio_valid"] = base_total > mask_threshold
		entry["absolute_error_total"] = abs_err
		# Same epsilon-safe denominator as the grid-drift probe (maxf(_, 1e-12)).
		entry["relative_error_total"] = abs_err / maxf(base_total, 1e-12)
	report["per_theta_i"] = per_theta_i

	var ratio_audit := {}
	ratio_audit["epsilon"] = BASELINE_RATIO_EPSILON
	ratio_audit["max_baseline_total"] = max_baseline_total
	var valid_entries: Array = []
	for entry in per_theta_i:
		if entry["baseline_ratio_valid"]:
			valid_entries.append(entry)
	ratio_audit["valid_count"] = valid_entries.size()
	if valid_entries.is_empty():
		# Safe fallbacks: no measured errors -> 0.0; undefined ratios -> INF.
		ratio_audit["valid_ratio_min"] = INF
		ratio_audit["valid_ratio_max"] = -INF
		ratio_audit["rms_absolute_error_total"] = 0.0
		ratio_audit["max_absolute_error_total"] = 0.0
		ratio_audit["baseline_energy_weighted_ratio"] = INF
	else:
		var ratio_min := INF
		var ratio_max := -INF
		var sum_sq_abs_err := 0.0
		var max_abs_err := 0.0
		var sum_fast := 0.0
		var sum_base := 0.0
		for entry in valid_entries:
			var r: float = entry["ratio_total"]
			ratio_min = minf(ratio_min, r)
			ratio_max = maxf(ratio_max, r)
			sum_sq_abs_err += entry["absolute_error_total"] * entry["absolute_error_total"]
			max_abs_err = maxf(max_abs_err, entry["absolute_error_total"])
			sum_fast += entry["fast_total"]
			sum_base += entry["baseline_total"]
		ratio_audit["valid_ratio_min"] = ratio_min
		ratio_audit["valid_ratio_max"] = ratio_max
		ratio_audit["rms_absolute_error_total"] = sqrt(sum_sq_abs_err / float(valid_entries.size()))
		ratio_audit["max_absolute_error_total"] = max_abs_err
		ratio_audit["baseline_energy_weighted_ratio"] = _safe_div(sum_fast, sum_base)
	ratio_audit["note"] = "Diagnostic only, not an acceptance gate. Entries with baseline_total <= epsilon * max_baseline_total are masked (baseline_ratio_valid = false). When no entries are valid: valid_ratio_min/max and baseline_energy_weighted_ratio are INF, rms/max absolute errors are 0.0."
	report["ratio_audit"] = ratio_audit

	# Aggregate ratios and max deviations.
	var agg_entry := {}
	agg_entry["baseline_total"] = _total_energy(agg_base)
	agg_entry["fast_total"] = _total_energy(agg_fast)
	agg_entry["ratio_total"] = _safe_div(agg_entry["fast_total"], agg_entry["baseline_total"])
	var lobes := {}
	var lobe_names := ["R", "TT", "TRT"]
	for i in 3:
		lobes[lobe_names[i]] = {
			"baseline": _vec3_to_array(agg_base[i]),
			"fast": _vec3_to_array(agg_fast[i]),
			"baseline_sum": _sum_rgb(agg_base[i]),
			"fast_sum": _sum_rgb(agg_fast[i]),
			"ratio": _safe_div(_sum_rgb(agg_fast[i]), _sum_rgb(agg_base[i])),
			"ratio_rgb": _rgb_ratio(agg_fast[i], agg_base[i]),
		}
	agg_entry["lobes"] = lobes
	agg_entry["max_relative_deviation_total"] = absf(agg_entry["ratio_total"] - 1.0)
	agg_entry["max_relative_deviation_lobes"] = maxf(
		absf(lobes["R"]["ratio"] - 1.0),
		maxf(absf(lobes["TT"]["ratio"] - 1.0), absf(lobes["TRT"]["ratio"] - 1.0)))
	agg_entry["karis"] = {
		"baseline": _vec3_to_array(agg_k_base),
		"fast": _vec3_to_array(agg_k_fast),
		"ratio": _safe_div(_sum_rgb(agg_k_fast), _sum_rgb(agg_k_base)),
		"note": "ATTENUATION = 1 idealization; both render paths share the /PI diffuse factor. Image-space Karis ratios are NOT the energy gate.",
	}
	report["aggregate"] = agg_entry

	# Grid convergence probe (coarse vs fine totals, both models combined).
	var drift := 0.0
	for deg in THETA_I_DEG:
		var theta_i := deg_to_rad(float(deg))
		var fine_total := _total_energy(_integrate_baseline(theta_i, grid_theta, grid_phi)) \
			+ _total_energy(_integrate_fast(theta_i, grid_theta, grid_phi))
		var coarse_total := _total_energy(_integrate_baseline(theta_i, coarse, coarse)) \
			+ _total_energy(_integrate_fast(theta_i, coarse, coarse))
		drift = maxf(drift, absf(coarse_total - fine_total) / maxf(fine_total, 1e-12))
	report["grid_convergence"] = {"coarse": coarse, "fine": grid_theta, "max_relative_drift": drift}

	# Acceptance (honest, never forced).
	var total_ok: bool = float(agg_entry["ratio_total"]) >= TOTAL_RATIO_MIN and float(agg_entry["ratio_total"]) <= TOTAL_RATIO_MAX
	var lobes_ok := true
	var failing_lobes: Array = []
	for name in lobe_names:
		var r: float = lobes[name]["ratio"]
		if r < LOBE_RATIO_MIN or r > LOBE_RATIO_MAX:
			lobes_ok = false
			failing_lobes.append("%s=%.4f" % [name, r])
	var passed: bool = total_ok and lobes_ok
	report["acceptance"] = {
		"total_ratio_band": [TOTAL_RATIO_MIN, TOTAL_RATIO_MAX],
		"lobe_ratio_band": [LOBE_RATIO_MIN, LOBE_RATIO_MAX],
		"total_ok": total_ok,
		"lobes_ok": lobes_ok,
		"passed": passed,
		"reason": ("" if passed else (
			"total ratio %.4f outside [%.3f, %.3f]" % [agg_entry["ratio_total"], TOTAL_RATIO_MIN, TOTAL_RATIO_MAX]
			+ ("" if failing_lobes.is_empty() else ("; lobe ratios outside band: " + ", ".join(failing_lobes))))),
	}
	report["result"] = "PASS" if passed else "FAIL"

	# Contract gate: exit semantics follow contract_result/contract_reason. The
	# strict parity acceptance fields (acceptance, result) stay in the payload
	# as diagnostic data in every mode and are never weakened.
	var contract_result := "PASS"
	var contract_reason := ""
	if _contract_mode == "report":
		contract_result = "REPORT"
		contract_reason = ("report-only mode: execution and report generation succeeded, exit 0; "
			+ "strict parity acceptance fields reported unweakened (acceptance.passed=%s)" % str(passed))
	elif _contract_mode == "parity":
		contract_result = "PASS" if passed else "FAIL"
		contract_reason = "strict parity bands: " + str(report["acceptance"]["reason"])
	else: # regression (shipping default)
		var regression := _evaluate_regression(agg_entry, drift, grid_theta, grid_phi, coarse)
		report["regression"] = regression["details"]
		report["contract"]["reference_valid"] = regression["reference_valid"]
		if regression["contract_version"] != "":
			report["contract"]["loaded_contract_version"] = regression["contract_version"]
		contract_result = regression["result"]
		contract_reason = regression["reason"]
	report["contract_result"] = contract_result
	report["contract_reason"] = contract_reason

	# Human-readable lines, then the JSON payload, then the result line.
	print("ENERGY_VALIDATION longitudinal_mode=%s (%s)" % [_longitudinal_mode,
		"Unity-standard theta_h Gaussian (FM_LONGITUDINAL_MODE 0, shipping default)"
		if _longitudinal_mode == "unity" else
		"baseline-compatible separable sin(theta_o) Gaussian (FM_LONGITUDINAL_MODE 1, diagnostic)"])
	print("ENERGY_VALIDATION r_longitudinal_mode=%s (%s)" % [_r_longitudinal_mode,
		"shared longitudinal R path (FM_R_LONGITUDINAL_MODE 0, shipping default)"
		if _r_longitudinal_mode == "standard" else
		"cheap non-separable R diagnostic (FM_R_LONGITUDINAL_MODE 1, R-only override, not the full d'Eon 2014 baseline, no compensation)"])
	print("ENERGY_VALIDATION azimuthal_mode=%s (%s)" % [_azimuthal_mode,
		"fixed-h logistic analytic approximation (FM_AZIMUTHAL_MODE 0, shipping default: h_TT = 0, h_TRT = sqrt(3)/2)"
		if _azimuthal_mode == "fixed_h" else
		"baseline cross-section diagnostic for the analytic BSDF only (FM_AZIMUTHAL_MODE 1: dynamic h_TT = sign(sin_phi_half) * cos_phi_half / sqrt(1 + eta_prime_inv * (1 - 2 * eta_prime_inv * abs(sin_phi_half))), h_TRT = 0.91; LUT sampling and fixed-h attenuation unchanged)"])
	var r_study := _r_study_description()
	print("ENERGY_VALIDATION r_study=%s M=%s N=%s A=%s" % [
		_r_study_mode, r_study.get("m_source", ""), r_study.get("n_source", ""), r_study.get("a_source", "")])
	print("ENERGY_VALIDATION material eta=%.4f albedo=(%.6f, %.6f, %.6f) beta_m_raw=%.4f beta_n_raw=%.4f cuticle=%.4f" % [
		_eta, _albedo.x, _albedo.y, _albedo.z, _beta_m_raw, _beta_n_raw, _cuticle_tilt])
	print("ENERGY_VALIDATION decomposition=%s (%s)" % [_decomposition,
		"shipping full M*N*A (byte-equivalent)"
		if _decomposition == "full" else
		"diagnostic factor subset, --contract=regression inapplicable"])
	print("ENERGY_VALIDATION contract_mode=%s reference=%s" % [_contract_mode, _reference_path])
	for entry in per_theta_i:
		print("ENERGY_VALIDATION theta_i_deg=%.1f E_base=%.6f E_fast=%.6f ratio_total=%.4f" % [
			entry["theta_i_deg"], entry["baseline_total"], entry["fast_total"], entry["ratio_total"]])
		print("ENERGY_VALIDATION   lobes R=%.6f/%.6f(%.4f) TT=%.6f/%.6f(%.4f) TRT=%.6f/%.6f(%.4f)" % [
			_sum_array(entry["baseline"]["R"]), _sum_array(entry["fast"]["R"]), entry["ratio"]["R"],
			_sum_array(entry["baseline"]["TT"]), _sum_array(entry["fast"]["TT"]), entry["ratio"]["TT"],
			_sum_array(entry["baseline"]["TRT"]), _sum_array(entry["fast"]["TRT"]), entry["ratio"]["TRT"]])
	print("ENERGY_VALIDATION aggregate E_base=%.6f E_fast=%.6f ratio_total=%.4f" % [
		agg_entry["baseline_total"], agg_entry["fast_total"], agg_entry["ratio_total"]])
	print("ENERGY_VALIDATION lobes_total R=%.6f/%.6f(%.4f) TT=%.6f/%.6f(%.4f) TRT=%.6f/%.6f(%.4f)" % [
		_sum_rgb(agg_base[0]), _sum_rgb(agg_fast[0]), lobes["R"]["ratio"],
		_sum_rgb(agg_base[1]), _sum_rgb(agg_fast[1]), lobes["TT"]["ratio"],
		_sum_rgb(agg_base[2]), _sum_rgb(agg_fast[2]), lobes["TRT"]["ratio"]])
	print("ENERGY_VALIDATION karis baseline=%.6f fast=%.6f ratio=%.6f (parity self-check, not the energy gate)" % [
		_sum_rgb(agg_k_base), _sum_rgb(agg_k_fast),
		_safe_div(_sum_rgb(agg_k_fast), _sum_rgb(agg_k_base))])
	print("ENERGY_VALIDATION grid_drift coarse=%d fine=%d max_relative=%.6f" % [coarse, grid_theta, drift])
	print("ENERGY_VALIDATION ratio_audit valid=%d/%d eps=%s weighted_ratio=%.4f rms_abs_err=%.6f max_abs_err=%.6f ratio_range=[%.4f, %.4f] (diagnostic, not a gate)" % [
		ratio_audit["valid_count"], per_theta_i.size(), str(BASELINE_RATIO_EPSILON),
		ratio_audit["baseline_energy_weighted_ratio"],
		ratio_audit["rms_absolute_error_total"], ratio_audit["max_absolute_error_total"],
		ratio_audit["valid_ratio_min"], ratio_audit["valid_ratio_max"]])
	print(JSON.stringify(report, "\t"))
	print("ENERGY_VALIDATION result=%s reason=%s (strict parity acceptance, diagnostic in every mode)" % [
		report["result"], report["acceptance"]["reason"]])
	print("ENERGY_VALIDATION contract_result=%s reason=%s" % [contract_result, contract_reason])
	quit(0 if contract_result != "FAIL" else 1)


# ---------------------------------------------------------------------------
# Baseline reference BSDF port (benchmark/reference/hair.gdshaderinc, shipped
# defines: energy-conserving longitudinal + Bessel approx, non-separable
# widths/tilts, approximate tilts, approximate h_TRT = 0.91). Each lobe is
# split into its longitudinal m factor, azimuthal distribution n and RGB
# attenuation a, then combined per --decomposition (default full = shipping
# byte-equivalent M*N*A).
# Returns per-lobe RGB energies as Array [R, TT, TRT] of Vector3.
# ---------------------------------------------------------------------------

func _baseline_bsdf(omega_i: Vector3, omega_o: Vector3, cos_phi: float, sin_phi: float) -> Array:
	var sin_theta_i := omega_i.x
	var sin_theta_o := omega_o.x
	var cos_theta_i := Vector2(omega_i.y, omega_i.z).length()
	var cos_theta_o := Vector2(omega_o.y, omega_o.z).length()
	var cos_phi_half := maxf(1e-6, sqrt(0.5 + 0.5 * cos_phi))
	var sin_phi_half := sqrt(0.5 - 0.5 * cos_phi) * signf(sin_phi)
	var cos_theta := clampf(cos_theta_o * cos_theta_i + sin_theta_o * sin_theta_i, -1.0, 1.0)
	var cos_theta_d := sqrt(0.5 + 0.5 * cos_theta)
	var sin_theta_d := sqrt(0.5 - 0.5 * cos_theta) * signf(sin_theta_o * cos_theta_i - cos_theta_o * sin_theta_i)
	# Incoming/light Snell convention (baseline include).
	var cos_theta_t := sqrt(maxf(0.0, 1.0 - sin_theta_i * sin_theta_i / (_eta * _eta)))
	var eta_prime := sqrt(_eta * _eta - sin_theta_d * sin_theta_d) / maxf(cos_theta_d, 1e-6)
	var eta_prime_inv := 1.0 / eta_prime
	var h := _baseline_cross_section_offsets(cos_phi_half, sin_phi_half, eta_prime_inv)
	# Baseline passes alpha = -cuticle_tilt_offset (baseline_hair.gdshader).
	var m := _baseline_longitudinal(cos_theta_i, sin_theta_i, cos_theta_o, sin_theta_o,
		cos_theta_d, sin_theta_d, cos_phi_half, -_cuticle_tilt, _beta_m, h)
	# Per-lobe factor split (decomposition): R = white Fresnel cosine lobe
	# (n = Fresnel * cosine, a = 1); TT/TRT split the logistic distribution
	# (n) from the RGB Beer-Lambert/Fresnel attenuation (a) before combining.
	var factors := _baseline_azimuthal_factors(cos_theta_t, cos_theta_d, cos_phi, sin_phi,
		cos_phi_half, eta_prime_inv, h)
	return [
		_apply_decomposition(m.x, factors[0]["n"], factors[0]["a"], _lobe_scales.x, "vector"),
		_apply_decomposition(m.y, factors[1]["n"], factors[1]["a"], _lobe_scales.y, "vector"),
		_apply_decomposition(m.z, factors[2]["n"], factors[2]["a"], _lobe_scales.z, "vector"),
	]


func _baseline_cross_section_offsets(cos_phi_half: float, sin_phi_half: float, eta_prime_inv: float) -> Vector3:
	var h := Vector3(-sin_phi_half, 0.0, H_TRT_BASELINE)
	h.y = signf(sin_phi_half) * cos_phi_half / sqrt(1.0 + eta_prime_inv * (1.0 - 2.0 * eta_prime_inv * absf(sin_phi_half)))
	return h


## Approximation of ln(I0(x)) used by the baseline (d'Eon 2011) longitudinal.
func _log_bessel_zero(x: float) -> float:
	var x_sq := x * x
	var c := (0.564187 + 1.01298 / (x_sq + 2.32434)) * (1.0 / sqrt(sqrt(x_sq * 0.25 + 1.0))) \
		* (exp(-2.0 * absf(x)) * 0.5 + 0.5)
	return log(c) + x


## Baseline longitudinal scattering (d'Eon 2011 energy-conserving + d'Eon 2014
## non-separable widths and approximate tilts). Faithful port including the
## shipped z_prime = sqrt(ETA^2 - k_sq) * vec3(R, TT, TRT) quirk: z_prime is 0
## for R, 1x for TT, 2x for TRT.
func _baseline_longitudinal(cos_theta_i: float, sin_theta_i: float, cos_theta_o: float,
		sin_theta_o: float, cos_theta_d: float, sin_theta_d: float, cos_phi_half: float,
		alpha: float, beta: float, h: Vector3) -> Vector3:
	var k_sq := Vector3(
		sin_theta_d * sin_theta_d + cos_theta_d * cos_theta_d * h.x * h.x,
		sin_theta_d * sin_theta_d + cos_theta_d * cos_theta_d * h.y * h.y,
		sin_theta_d * sin_theta_d + cos_theta_d * cos_theta_d * h.z * h.z)
	var z := Vector3(sqrt(1.0 - k_sq.x), sqrt(1.0 - k_sq.y), sqrt(1.0 - k_sq.z))
	var z_prime := Vector3(0.0, sqrt(_eta * _eta - k_sq.y), 2.0 * sqrt(_eta * _eta - k_sq.z))
	# d'Eon 2014 non-separable lobe widths.
	var beta_m := Vector3(beta, beta, beta)
	beta_m.x *= sqrt(2.0) * cos_phi_half
	beta_m.y *= (z.y + 0.5 * z_prime.y) / cos_theta_d
	beta_m.z *= 2.0 * sqrt(_eta * _eta - sin_theta_d * sin_theta_d) / cos_theta_d - 1.0
	# Approximate tilts: sin_theta_cone = -sin_theta_i + (2*z' - 2*z)*alpha.
	var sin_cone := Vector3(
		clampf(-sin_theta_i + (2.0 * z_prime.x - 2.0 * z.x) * alpha, -1.0, 1.0),
		clampf(-sin_theta_i + (2.0 * z_prime.y - 2.0 * z.y) * alpha, -1.0, 1.0),
		clampf(-sin_theta_i + (2.0 * z_prime.z - 2.0 * z.z) * alpha, -1.0, 1.0))
	var v_inv := Vector3(1.0 / (beta_m.x * beta_m.x), 1.0 / (beta_m.y * beta_m.y), 1.0 / (beta_m.z * beta_m.z))
	var cos_cone := Vector3(sqrt(1.0 - sin_cone.x * sin_cone.x), sqrt(1.0 - sin_cone.y * sin_cone.y), sqrt(1.0 - sin_cone.z * sin_cone.z))
	# Energy-conserving longitudinal scattering function (d'Eon 2011).
	return Vector3(
		exp((sin_cone.x * sin_theta_o - 1.0) * v_inv.x + _log_bessel_zero(cos_cone.x * cos_theta_o * v_inv.x)) * v_inv.x / cos_theta_o,
		exp((sin_cone.y * sin_theta_o - 1.0) * v_inv.y + _log_bessel_zero(cos_cone.y * cos_theta_o * v_inv.y)) * v_inv.y / cos_theta_o,
		exp((sin_cone.z * sin_theta_o - 1.0) * v_inv.z + _log_bessel_zero(cos_cone.z * cos_theta_o * v_inv.z)) * v_inv.z / cos_theta_o)


## Baseline unclamped Schlick Fresnel (no cos clamp in the reference include).
func _baseline_fresnel(cos_theta: float) -> float:
	var f0 := (1.0 - _eta) * (1.0 - _eta) / ((1.0 + _eta) * (1.0 + _eta))
	var p := 1.0 - cos_theta
	var p_sq := p * p
	return lerp(p_sq * p_sq * p, 1.0, f0)


## Baseline logistic (no input clamp; sqrt guarded for fp safety only).
func _baseline_logistic(offset: float, s_inv: float) -> float:
	var phi := sqrt(maxf(0.0, 1.0 - offset)) * (1.5707288 + offset * (-0.2121144 + offset * 0.0742610))
	var eta_prime_inv := exp(-phi * s_inv)
	var b := exp(-2.0 * sqrt(TAU) * s_inv)
	var c := 1.0 + eta_prime_inv
	return minf(1.0, s_inv * eta_prime_inv * (1.0 + b) / ((1.0 - b) * c * c))


## Shared d'Eon azimuthal angular offset cos(phi - Phi(p, h)).
func _angular_offset(mode: int, cos_phi: float, sin_phi: float, eta_prime_inv: float, h: float) -> float:
	var gamma := (2.126 * h * eta_prime_inv + PI) * float(mode)
	var a := 1.0 - 2.0 * h * h
	var b := 2.0 * h * sqrt(1.0 - h * h)
	var c := cos(gamma)
	var s := sin(gamma)
	return cos_phi * (c * a + s * b) + sin_phi * (s * a - c * b)


## Baseline attenuation family: (1-F)^2 * F^(mode-1) * Beer-Lambert with
## path factor 4 * (1 - eta'^-2 * h^2) * mode (RGB transmittance).
func _baseline_attenuation(mode: int, cos_theta_t: float, cos_theta_d: float, eta_prime_inv: float, h: float) -> Vector3:
	var f := _baseline_fresnel(cos_theta_d * sqrt(maxf(0.0, 1.0 - h * h)))
	var path := 4.0 * (1.0 - eta_prime_inv * eta_prime_inv * h * h) * float(mode)
	var trans := _exp3(-_sigma_a / maxf(cos_theta_t, 1e-4) * path)
	var one_minus_f := 1.0 - f
	if mode == 1:
		return trans * (one_minus_f * one_minus_f)
	return trans * (one_minus_f * one_minus_f * f)


## Baseline azimuthal factors per lobe, split into the scalar azimuthal
## distribution n and the RGB attenuation a (decomposition): R = white Fresnel
## cosine lobe (n = Fresnel * cosine, a = Vector3(1,1,1)), TT/TRT = logistic
## distribution (n) x Beer-Lambert/Fresnel RGB attenuation (a). The combining
## happens in _baseline_bsdf via _apply_decomposition so every --decomposition
## subset can be measured.
## Returns Array [R, TT, TRT] of {n: float, a: Vector3} dictionaries.
func _baseline_azimuthal_factors(cos_theta_t: float, cos_theta_d: float, cos_phi: float, sin_phi: float,
		cos_phi_half: float, eta_prime_inv: float, h: Vector3) -> Array:
	var r_n := 0.25 * cos_phi_half
	var r_fresnel := _baseline_fresnel(cos_theta_d * cos_phi_half)
	var r_a := Vector3(r_fresnel, r_fresnel, r_fresnel)
	var tt_n := _baseline_logistic(_angular_offset(1, cos_phi, sin_phi, eta_prime_inv, h.y), sqrt(2.0) / _beta_n)
	var tt_a := _baseline_attenuation(1, cos_theta_t, cos_theta_d, eta_prime_inv, h.y)
	var trt_n := _baseline_logistic(_angular_offset(2, cos_phi, sin_phi, eta_prime_inv, h.z), 0.5 * sqrt(2.0) / _beta_n)
	var trt_a := _baseline_attenuation(2, cos_theta_t, cos_theta_d, eta_prime_inv, h.z)
	return [{"n": r_n, "a": r_a}, {"n": tt_n, "a": tt_a}, {"n": trt_n, "a": trt_a}]


# ---------------------------------------------------------------------------
# Fast BSDF port (hair_marschner_fast.gdshaderinc shipping defaults: theta_h
# variance Gaussian via the FM_LONGITUDINAL_MODE selector, Unity-style
# fixed-h attenuation, outgoing Snell). The longitudinal model follows
# --longitudinal (unity = mode 0 theta_h Gaussian, the default; baseline =
# mode 1 separable sin(theta_o) cone Gaussian diagnostic). Each lobe is
# split into its longitudinal m factor, azimuthal distribution n and RGB
# attenuation a, then combined per --decomposition (default full = shipping
# byte-equivalent M*N*A).
# Returns per-lobe RGB energies as Array [R, TT, TRT] of Vector3.
# ---------------------------------------------------------------------------

func _fast_bsdf(omega_i: Vector3, omega_o: Vector3, cos_phi: float, sin_phi: float, unity_r_n: float = -1.0) -> Array:
	var sin_theta_i := omega_i.x
	var sin_theta_o := omega_o.x
	var cos_theta_i := Vector2(omega_i.y, omega_i.z).length()
	var cos_theta_o := Vector2(omega_o.y, omega_o.z).length()
	var cos_phi_half := maxf(1e-6, sqrt(0.5 + 0.5 * cos_phi))
	var cos_theta := clampf(cos_theta_o * cos_theta_i + sin_theta_o * sin_theta_i, -1.0, 1.0)
	var cos_theta_d := sqrt(0.5 + 0.5 * cos_theta)
	var sin_theta_d := sqrt(0.5 - 0.5 * cos_theta) * signf(sin_theta_o * cos_theta_i - cos_theta_o * sin_theta_i)
	# Outgoing/view Snell convention (FM_ATTENUATION_MODEL_UNITY branch).
	var cos_theta_t := sqrt(maxf(0.0, 1.0 - sin_theta_o * sin_theta_o / (_eta * _eta)))
	var eta_prime := sqrt(maxf(_eta * _eta - sin_theta_d * sin_theta_d, 1e-6)) / maxf(cos_theta_d, 1e-6)
	var eta_prime_inv := 1.0 / eta_prime
	# Fixed representative cross-section offsets: h_TT = 0, h_TRT = sqrt(3)/2
	# (shipping FM_AZIMUTHAL_MODE 0). --azimuthal=baseline_h matches the
	# shader's FM_AZIMUTHAL_MODE 1 diagnostic for the ANALYTIC BSDF only:
	# dynamic h_TT from the baseline cross-section formula and h_TRT = 0.91
	# (H_TRT_BASELINE). Attenuation keeps the shipping fixed-h family in both
	# modes (fm_att_fixed_h reads H_TT_FAST/H_TRT_FAST directly) and the LUT is
	# out of this CPU comparison.
	var h_tt := H_TT_FAST
	var h_trt := H_TRT_FAST
	if _azimuthal_mode == "baseline_h":
		var sin_phi_half := sqrt(0.5 - 0.5 * cos_phi) * signf(sin_phi)
		h_tt = signf(sin_phi_half) * cos_phi_half / sqrt(1.0 + eta_prime_inv * (1.0 - 2.0 * eta_prime_inv * absf(sin_phi_half)))
		h_trt = H_TRT_BASELINE
	var h := Vector3(0.0, h_tt, h_trt)
	# Hoisted lobe setup from fragment() under the shipping baseline cuticle-tilt
	# convention (FM_CUTICLE_TILT_CONVENTION = 0): centers (+a, -0.5a, -1.5a),
	# variances (1, 0.5, 2)^2 * beta_M^2.
	var lobe_alpha := Vector3(1.0, -0.5, -1.5) * _cuticle_tilt
	var lobe_variance := Vector3(1.0, 0.5, 2.0) * _beta_m
	lobe_variance.x *= lobe_variance.x
	lobe_variance.y *= lobe_variance.y
	lobe_variance.z *= lobe_variance.z
	var theta_i := asin(clampf(sin_theta_i, -0.999999, 0.999999))
	var theta_o := asin(clampf(sin_theta_o, -0.999999, 0.999999))
	var m := _fast_longitudinal(theta_i, theta_o, lobe_alpha, lobe_variance)
	if _r_study_mode == "baseline_m_unity_nf":
		m.x = _baseline_longitudinal(cos_theta_i, sin_theta_i, cos_theta_o, sin_theta_o,
			cos_theta_d, sin_theta_d, cos_phi_half, -_cuticle_tilt, _beta_m, _baseline_cross_section_offsets(
				cos_phi_half, sqrt(0.5 - 0.5 * cos_phi) * signf(sin_phi), eta_prime_inv)).x
	elif _r_study_mode == "unity_exact":
		m.x = _unity_standard_m_r(theta_i, theta_o, _beta_m_raw, _cuticle_tilt)
	# --r-longitudinal=nonseparable matches the shader's FM_R_LONGITUDINAL_MODE 1
	# diagnostic: overrides ONLY the R lobe after the shared longitudinal call
	# (cheap non-separable R in sin(theta_o) space, z_r = cos_phi_half; NOT the
	# full d'Eon 2014 non-separable baseline, no compensation). TT/TRT and the
	# baseline equations are unchanged.
	if _r_longitudinal_mode == "nonseparable":
		m.x = _r_nonseparable_gaussian(sin_theta_i, sin_theta_o, cos_phi_half, _cuticle_tilt, _beta_m)
	var s_tt := sqrt(2.0) / _beta_n
	var s_trt := 0.5 * sqrt(2.0) / _beta_n
	var b_tt := exp(-2.0 * sqrt(TAU) * s_tt)
	var b_trt := exp(-2.0 * sqrt(TAU) * s_trt)
	# Per-lobe factor split (decomposition): R is a white scalar lobe, so n is
	# its scalar Fresnel cosine lobe and a = 1; TT/TRT split the logistic
	# distribution (n) from the Unity-style fixed-h RGB attenuation (a) before
	# combining.
	var r_n := 0.25 * cos_phi_half
	var r_fresnel := _fm_fresnel(cos_theta_d * cos_phi_half)
	if _r_study_mode == "unity_nf" or _r_study_mode == "baseline_m_unity_nf" or _r_study_mode == "unity_exact":
		r_n = unity_r_n
	if _r_study_mode == "unity_fresnel" or _r_study_mode == "unity_nf" or _r_study_mode == "baseline_m_unity_nf" or _r_study_mode == "unity_exact":
		r_fresnel = _unity_r_fresnel(omega_i, omega_o)
	var r_a := Vector3(r_fresnel, r_fresnel, r_fresnel)
	var tt_n := _fm_logistic(_angular_offset(1, cos_phi, sin_phi, eta_prime_inv, h.y), s_tt, b_tt)
	var tt_a := _att_fixed_h(1, cos_theta_o, cos_theta_d, cos_theta_t, eta_prime)
	var trt_n := _fm_logistic(_angular_offset(2, cos_phi, sin_phi, eta_prime_inv, h.z), s_trt, b_trt)
	var trt_a := _att_fixed_h(2, cos_theta_o, cos_theta_d, cos_theta_t, eta_prime)
	return [
		_apply_decomposition(m.x, r_n, r_a, _lobe_scales.x, "vector"),
		_apply_decomposition(m.y, tt_n, tt_a, _lobe_scales.y, "vector"),
		_apply_decomposition(m.z, trt_n, trt_a, _lobe_scales.z, "vector"),
	]


## Normalized variance-form Gaussian in theta_h space.
func _theta_h_gaussian(theta_i: float, theta_o: float, lobe_alpha: Vector3, lobe_variance: Vector3) -> Vector3:
	var theta_h := 0.5 * (theta_i + theta_o)
	var d := Vector3(theta_h - lobe_alpha.x, theta_h - lobe_alpha.y, theta_h - lobe_alpha.z)
	return Vector3(
		exp(-0.5 * d.x * d.x / lobe_variance.x) * (1.0 / sqrt(TAU * lobe_variance.x)),
		exp(-0.5 * d.y * d.y / lobe_variance.y) * (1.0 / sqrt(TAU * lobe_variance.y)),
		exp(-0.5 * d.z * d.z / lobe_variance.z) * (1.0 / sqrt(TAU * lobe_variance.z)))


## Fast longitudinal scattering for the selected --longitudinal mode:
## "unity" (default) = theta_h Gaussian (FM_LONGITUDINAL_MODE 0, shipping
## default); "baseline" = separable sin(theta_o) cone Gaussian
## (FM_LONGITUDINAL_MODE 1 diagnostic, same formula as the shader's mode-1
## branch of fm_longitudinal_scattering).
func _fast_longitudinal(theta_i: float, theta_o: float, lobe_alpha: Vector3, lobe_variance: Vector3) -> Vector3:
	if _longitudinal_mode == "baseline":
		return _sin_cone_gaussian(theta_i, theta_o, _cuticle_tilt, _beta_m)
	return _theta_h_gaussian(theta_i, theta_o, lobe_alpha, lobe_variance)


## Mode-1 separable sin(theta_o)-space Gaussian (FM_LONGITUDINAL_MODE 1
## diagnostic): cone rotations vec3(-2, 1, 3) * cuticle_tilt with
## sin_theta_cone = -cos(theta_i)*sin(rotation) - sin(theta_i)*cos(rotation),
## and standard deviations vec3(1.5, 0.75, 3.0) * beta_m squared to variances
## with the same positive floor (1e-6) as fm_gaussian_variance. Separable
## diagnostic approximation, NOT the full non-separable baseline. Uses the
## already-derived beta_M and the runtime cuticle tilt exactly like the
## shader's hoisted lobe_cuticle_tilt/lobe_beta_m varyings.
func _sin_cone_gaussian(theta_i: float, theta_o: float, cuticle_tilt: float, beta_m: float) -> Vector3:
	var rotation := Vector3(-2.0, 1.0, 3.0) * cuticle_tilt
	var cos_theta_i := cos(theta_i)
	var sin_theta_i := sin(theta_i)
	var sin_cone := Vector3(
		-cos_theta_i * sin(rotation.x) - sin_theta_i * cos(rotation.x),
		-cos_theta_i * sin(rotation.y) - sin_theta_i * cos(rotation.y),
		-cos_theta_i * sin(rotation.z) - sin_theta_i * cos(rotation.z))
	var stddev := Vector3(1.5, 0.75, 3.0) * maxf(beta_m, 0.0)
	var variance := Vector3(
		maxf(stddev.x * stddev.x, 1e-6),
		maxf(stddev.y * stddev.y, 1e-6),
		maxf(stddev.z * stddev.z, 1e-6))
	var sin_o := sin(theta_o)
	var d := Vector3(sin_o - sin_cone.x, sin_o - sin_cone.y, sin_o - sin_cone.z)
	return Vector3(
		exp(-0.5 * d.x * d.x / variance.x) * (1.0 / sqrt(TAU * variance.x)),
		exp(-0.5 * d.y * d.y / variance.y) * (1.0 / sqrt(TAU * variance.y)),
		exp(-0.5 * d.z * d.z / variance.z) * (1.0 / sqrt(TAU * variance.z)))


## Mode-1 cheap non-separable R diagnostic (FM_R_LONGITUDINAL_MODE 1, the
## --r-longitudinal=nonseparable fast R model): same formula as the shader's
## fm_r_longitudinal_nonseparable, in sin(theta_o) space:
##   z_r = cos_phi_half
##   beta_r = sqrt(2.0) * z_r * beta_m, floored at 1e-3 (matching the shader's
##           beta floor; the 1e-6 variance floor below mirrors
##           fm_gaussian_variance)
##   sin_theta_cone_r = clamp(-sin_theta_i + 2.0 * z_r * cuticle_tilt, -1, 1)
##   result = exp(-0.5 * (sin_theta_o - sin_theta_cone_r)^2 / beta_r^2)
##            / sqrt(TAU * beta_r^2)
## The width/tilt coupling through z_r = cos_phi_half makes it non-separable.
## Cheap diagnostic approximation of the baseline R cone, NOT the full
## non-separable d'Eon 2014 baseline (no full widths/tilts, no derived
## compensation). R-only: TT/TRT keep the shared path.
func _r_nonseparable_gaussian(sin_theta_i: float, sin_theta_o: float, cos_phi_half: float, cuticle_tilt: float, beta_m: float) -> float:
	var z_r := cos_phi_half
	var beta_r := maxf(sqrt(2.0) * z_r * maxf(beta_m, 0.0), 1e-3)
	var sin_cone := clampf(-sin_theta_i + 2.0 * z_r * cuticle_tilt, -1.0, 1.0)
	var variance := maxf(beta_r * beta_r, 1e-6)
	var d := sin_theta_o - sin_cone
	return exp(-0.5 * d * d / variance) * (1.0 / sqrt(TAU * variance))


## Fast clamped Schlick Fresnel.
func _fm_fresnel(cos_theta: float) -> float:
	var f0 := (1.0 - _eta) * (1.0 - _eta) / ((1.0 + _eta) * (1.0 + _eta))
	var p := 1.0 - clampf(cos_theta, 0.0, 1.0)
	var p_sq := p * p
	return lerp(p_sq * p_sq * p, 1.0, f0)


func _unity_r_fresnel(omega_i: Vector3, omega_o: Vector3) -> float:
	var lv := clampf(omega_i.dot(omega_o), -1.0, 1.0)
	var cos_half_lv := sqrt(maxf(0.0, 0.5 + 0.5 * lv))
	return _fm_fresnel(cos_half_lv)


func _unity_standard_m_r(theta_i: float, theta_o: float, raw_longitudinal_roughness: float, cuticle_angle: float) -> float:
	var theta_h := 0.5 * (theta_i + theta_o)
	var variance_r := maxf(raw_longitudinal_roughness * raw_longitudinal_roughness, 1e-5)
	var delta := theta_h - (-cuticle_angle)
	return exp(-0.5 * delta * delta / variance_r) / sqrt(TAU * variance_r)


func _unity_logistic_scale_from_beta(beta: float) -> float:
	return UNITY_SQRT_PI_OVER_8 * (0.265 * beta + 1.194 * beta * beta + 5.372 * pow(absf(beta), 22.0))


func _unity_logistic(x: float, s: float) -> float:
	var safe_s := maxf(s, 1e-6)
	var ax := absf(x)
	var e := exp(-ax / safe_s)
	return e / (safe_s * (1.0 + e) * (1.0 + e))


func _unity_logistic_cdf(x: float, s: float) -> float:
	return 1.0 / (1.0 + exp(-x / maxf(s, 1e-6)))


func _unity_trimmed_logistic(x: float, s: float) -> float:
	var safe_s := maxf(s, 1e-6)
	var normalization := _unity_logistic_cdf(PI, safe_s) - _unity_logistic_cdf(-PI, safe_s)
	return _unity_logistic(x, safe_s) / maxf(normalization, 1e-9)


func _wrap_pi(x: float) -> float:
	return fposmod(x + PI, TAU) - PI


func _unity_r_azimuthal_direct(phi: float, raw_radial_roughness: float) -> float:
	# Unity's preintegration uses its raw perceptual roughness axis; this study
	# keeps the project's safe open interval at [0.001, 0.99] for the direct
	# reference and documents the upper-edge deviation from the source LUT.
	var beta := clampf(raw_radial_roughness, 1e-3, 0.99)
	var s := maxf(_unity_logistic_scale_from_beta(beta), 1e-6)
	var total := 0.0
	for sample_index in UNITY_H_SAMPLES:
		var h := -1.0 + float(sample_index) * UNITY_H_STEP
		var gamma_o := asin(clampf(h, -1.0, 1.0))
		var direction_r := -2.0 * gamma_o
		total += _unity_trimmed_logistic(_wrap_pi(phi - direction_r), s) * UNITY_H_STEP
	return 0.5 * total


func _unity_r_n_cache_key(grid_phi: int) -> String:
	return "%d:%.9f" % [grid_phi, _beta_n_raw]


func _build_unity_r_n_table(grid_phi: int) -> PackedFloat64Array:
	var key := _unity_r_n_cache_key(grid_phi)
	if _unity_r_n_cache.has(key):
		return _unity_r_n_cache[key]
	var table := PackedFloat64Array()
	table.resize(grid_phi)
	var d_phi := TAU / float(grid_phi)
	for phi_index in grid_phi:
		var phi := (float(phi_index) + 0.5) * d_phi
		table[phi_index] = _unity_r_azimuthal_direct(_wrap_pi(phi), _beta_n_raw)
	_unity_r_n_cache[key] = table
	return table


func _r_study_description() -> Dictionary:
	match _r_study_mode:
		"current":
			return {"mode": "current", "m_source": "current fast theta_h Gaussian", "n_source": "0.25*cos(phi/2)", "a_source": "current Fresnel argument cos(theta_d)*cos(phi/2)"}
		"unity_fresnel":
			return {"mode": "unity_fresnel", "m_source": "current fast theta_h Gaussian", "n_source": "0.25*cos(phi/2)", "a_source": "Unity half-vector Fresnel"}
		"unity_nf":
			return {"mode": "unity_nf", "m_source": "current fast theta_h Gaussian", "n_source": "Unity direct preintegrated N_R", "a_source": "Unity half-vector Fresnel"}
		"baseline_m_unity_nf":
			return {"mode": "baseline_m_unity_nf", "m_source": "high-tier baseline M_R", "n_source": "Unity direct preintegrated N_R", "a_source": "Unity half-vector Fresnel"}
		"unity_exact":
			return {"mode": "unity_exact", "m_source": "Unity standard Gaussian M_R", "n_source": "Unity direct preintegrated N_R", "a_source": "Unity half-vector Fresnel"}
	return {"mode": _r_study_mode}


## Fast logistic with clamped input and precomputed normalization b_pre.
func _fm_logistic(offset: float, s_inv: float, b_pre: float) -> float:
	var safe := clampf(offset, -1.0, 1.0)
	var phi := sqrt(maxf(0.0, 1.0 - safe)) * (1.5707288 + safe * (-0.2121144 + safe * 0.0742610))
	var eta_prime_inv := exp(-phi * s_inv)
	var c := 1.0 + eta_prime_inv
	return minf(1.0, s_inv * eta_prime_inv * (1.0 + b_pre) / ((1.0 - b_pre) * c * c))


## Unity-style fixed-h attenuation (FM_ATTENUATION_UNITY_FIXED_H shipping
## branch): h_TT = 0, h_TRT = sqrt(3)/2; Fresnel at cos_theta_o * sqrt(1-h^2);
## Beer-Lambert path 2 * cos_gamma_t per traversal, squared for TRT (RGB).
func _att_fixed_h(mode: int, cos_theta_o: float, cos_theta_d: float, cos_theta_t: float, eta_prime: float) -> Vector3:
	var h := H_TRT_FAST if mode == 2 else H_TT_FAST
	var h2 := h * h
	var cos_gamma_o := sqrt(maxf(0.0, 1.0 - h2))
	var f := _fm_fresnel(clampf(cos_theta_o * cos_gamma_o, 0.0, 1.0))
	var safe_eta_prime := maxf(eta_prime, 1e-4)
	var sin_gamma_t := clampf(h / safe_eta_prime, -0.999999, 0.999999)
	var cos_gamma_t := sqrt(maxf(0.0, 1.0 - sin_gamma_t * sin_gamma_t))
	var trans := _exp3(-_sigma_a * (2.0 * cos_gamma_t / maxf(cos_theta_t, 1e-4)))
	var one_minus_f := 1.0 - f
	if mode == 1:
		return trans * (one_minus_f * one_minus_f)
	return trans * trans * (one_minus_f * one_minus_f * f)


# ---------------------------------------------------------------------------
# Karis multiple scattering parity (ATTENUATION = 1 idealization; both shader
# variants reduce to the identical closed form, so the integrated ratio is a
# harness self-check, not the energy gate).
# ---------------------------------------------------------------------------

func _karis_energy(omega_i: Vector3, omega_o: Vector3, fast: bool) -> Vector3:
	var yz_norm := Vector2(omega_o.y, omega_o.z)
	if yz_norm.length_squared() > 1e-8:
		yz_norm = yz_norm.normalized()
	else:
		yz_norm = Vector2(0.0, 1.0)
	var view_align := omega_i.y * yz_norm.x + omega_i.z * yz_norm.y
	var luminance := _albedo.dot(Vector3(0.299, 0.587, 0.114))
	var atten := 1.0
	var sqrt_albedo := Vector3(sqrt(_albedo.x), sqrt(_albedo.y), sqrt(_albedo.z))
	var result := Vector3.ZERO
	if fast:
		# fm_karis_multiple_scattering with guards (never trigger at our params).
		var safe_lum := maxf(luminance, 1e-4)
		result = 0.25 * sqrt_albedo * (view_align + 1.0) * Vector3(
			pow(maxf(_albedo.x / safe_lum, 1e-4), atten),
			pow(maxf(_albedo.y / safe_lum, 1e-4), atten),
			pow(maxf(_albedo.z / safe_lum, 1e-4), atten))
		return result * smoothstep(-0.5, 1.0, atten)
	result = 0.25 * sqrt_albedo * (view_align + 1.0) * Vector3(
		pow(_albedo.x / luminance, atten),
		pow(_albedo.y / luminance, atten),
		pow(_albedo.z / luminance, atten))
	return result * smoothstep(-0.5, 1.0, atten)


# ---------------------------------------------------------------------------
# Quadrature drivers
# ---------------------------------------------------------------------------

## Integrates one model over the full outgoing sphere for fixed theta_i.
## Returns per-lobe projected RGB energies as Array [R, TT, TRT].
func _integrate_model(theta_i: float, grid_theta: int, grid_phi: int, fast: bool) -> Array:
	var sin_theta_i := sin(theta_i)
	var cos_theta_i := cos(theta_i)
	var omega_i := Vector3(sin_theta_i, cos_theta_i, 0.0)
	var d_theta := PI / float(grid_theta)
	var d_phi := TAU / float(grid_phi)
	var measure := d_theta * d_phi
	var cos_phi_col := PackedFloat64Array()
	var sin_phi_col := PackedFloat64Array()
	var unity_r_n_table := PackedFloat64Array()
	var needs_unity_r_n := fast and (_r_study_mode == "unity_nf" or _r_study_mode == "baseline_m_unity_nf" or _r_study_mode == "unity_exact")
	if needs_unity_r_n:
		unity_r_n_table = _build_unity_r_n_table(grid_phi)
	cos_phi_col.resize(grid_phi)
	sin_phi_col.resize(grid_phi)
	for n in grid_phi:
		var phi := (float(n) + 0.5) * d_phi
		# Relative azimuth with phi_i = 0; same clamp semantics as both shaders.
		cos_phi_col[n] = clampf(cos(phi), -0.9999, 0.9999)
		sin_phi_col[n] = clampf(sin(phi), -0.9999, 0.9999)
	var energy := [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
	for m in grid_theta:
		var theta_o := -PI * 0.5 + (float(m) + 0.5) * d_theta
		var sin_o := sin(theta_o)
		var cos_o := cos(theta_o)
		var omega_o := Vector3(sin_o, 0.0, 0.0)
		for n in grid_phi:
			omega_o.y = cos_o * cos_phi_col[n]
			omega_o.z = cos_o * sin_phi_col[n]
			var unity_r_n := unity_r_n_table[n] if needs_unity_r_n else -1.0
			var f := _fast_bsdf(omega_i, omega_o, cos_phi_col[n], sin_phi_col[n], unity_r_n) \
				if fast else _baseline_bsdf(omega_i, omega_o, cos_phi_col[n], sin_phi_col[n])
			var weight := cos_o * measure
			for lobe in 3:
				energy[lobe] += f[lobe] * weight
	return energy


func _integrate_baseline(theta_i: float, grid_theta: int, grid_phi: int) -> Array:
	return _integrate_model(theta_i, grid_theta, grid_phi, false)


func _integrate_fast(theta_i: float, grid_theta: int, grid_phi: int) -> Array:
	return _integrate_model(theta_i, grid_theta, grid_phi, true)


func _integrate_karis(theta_i: float, grid_theta: int, grid_phi: int, fast: bool) -> Vector3:
	var sin_theta_i := sin(theta_i)
	var cos_theta_i := cos(theta_i)
	var omega_i := Vector3(sin_theta_i, cos_theta_i, 0.0)
	var d_theta := PI / float(grid_theta)
	var d_phi := TAU / float(grid_phi)
	var measure := d_theta * d_phi
	var energy := Vector3.ZERO
	for m in grid_theta:
		var theta_o := -PI * 0.5 + (float(m) + 0.5) * d_theta
		var sin_o := sin(theta_o)
		var cos_o := cos(theta_o)
		var omega_o := Vector3(sin_o, 0.0, 0.0)
		for n in grid_phi:
			var phi := (float(n) + 0.5) * d_phi
			omega_o.y = cos_o * cos(phi)
			omega_o.z = cos_o * sin(phi)
			energy += _karis_energy(omega_i, omega_o, fast) * (cos_o * measure)
	return energy


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

## Chiang et al. (2016) albedo-to-absorption, identical in both shaders.
func _sigma_from_albedo(base_color: Vector3, beta_n: float) -> Vector3:
	var c := 5.969 + beta_n * (-0.215 + beta_n * (2.532 + beta_n * (-10.73 + beta_n * (5.574 + beta_n * 0.245))))
	var safe := Vector3(maxf(base_color.x, 1e-4), maxf(base_color.y, 1e-4), maxf(base_color.z, 1e-4))
	var sigma := Vector3(log(safe.x), log(safe.y), log(safe.z)) / maxf(c, 1e-4)
	return Vector3(sigma.x * sigma.x, sigma.y * sigma.y, sigma.z * sigma.z)


func _exp3(v: Vector3) -> Vector3:
	return Vector3(exp(v.x), exp(v.y), exp(v.z))


func _safe_div(a: float, b: float) -> float:
	return a / b if b != 0.0 else INF


func _sum_rgb(v: Vector3) -> float:
	return v.x + v.y + v.z


func _sum_array(a: Array) -> float:
	var total := 0.0
	for v in a:
		total += float(v)
	return total


## Total energy of a per-lobe RGB Array [R, TT, TRT]: sum of all 9 components.
func _total_energy(per_lobe: Array) -> float:
	var total := 0.0
	for lobe in 3:
		total += _sum_rgb(per_lobe[lobe])
	return total


func _vec3_to_array(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


func _rgb_ratio(fast: Vector3, base: Vector3) -> Array:
	return [
		_safe_div(fast.x, base.x),
		_safe_div(fast.y, base.y),
		_safe_div(fast.z, base.z),
	]


## Combines one lobe's factors according to the selected --decomposition mode.
## Every lobe is the product of a longitudinal factor m (scalar), an azimuthal
## distribution n (scalar; R = Fresnel cosine lobe, TT/TRT = logistic) and an
## RGB attenuation a (Vector3; R has A = 1). The lobe scale multiplies the m
## factor in every mode, and scalar factors are replicated to RGB explicitly so
## results stay Vector3 per lobe (vector semantics preserved).
## Modes: m = longitudinal only (N=1, A=1); n = azimuthal only (M=1, A=1);
## a = attenuation only (M=1, N=1); mn = M*N (A=1); ma = M*A (N=1);
## full = M*N*A.
## full_order preserves the byte-equivalent shipping multiply order of the
## originating port: "scalar" (fast R: ((n * m) * scale)) or "vector" (baseline
## R and every TT/TRT in both ports: (n * a) * (m * scale)). For R, a = 1 so
## the extra multiply is an exact no-op in either order.
func _apply_decomposition(m: float, n: float, a: Vector3, scale: float, full_order: String) -> Vector3:
	var ms := m * scale
	if _decomposition == "m": # longitudinal only (N=1, A=1)
		return Vector3(ms, ms, ms)
	if _decomposition == "n": # azimuthal distribution only (M=1, A=1)
		return Vector3(n, n, n)
	if _decomposition == "a": # attenuation only (M=1, N=1); R stays Vector3(1,1,1)
		return a
	if _decomposition == "mn": # M*N (A=1)
		var mn := ms * n
		return Vector3(mn, mn, mn)
	if _decomposition == "ma": # M*A (N=1)
		return Vector3(ms * a.x, ms * a.y, ms * a.z)
	# "full": M*N*A, byte-equivalent to the shipping per-port orders.
	if full_order == "scalar":
		var nm := n * m
		return Vector3(nm * scale, nm * scale, nm * scale)
	return Vector3(n * a.x * ms, n * a.y * ms, n * a.z * ms)


## Builds one per-theta_i report entry with per-lobe RGB energies and ratios.
func _theta_i_entry(deg: float, e_base: Array, e_fast: Array, k_base: Vector3, k_fast: Vector3) -> Dictionary:
	var base_total := _total_energy(e_base)
	var fast_total := _total_energy(e_fast)
	return {
		"theta_i_deg": deg,
		"baseline": {
			"R": _vec3_to_array(e_base[0]),
			"TT": _vec3_to_array(e_base[1]),
			"TRT": _vec3_to_array(e_base[2]),
		},
		"fast": {
			"R": _vec3_to_array(e_fast[0]),
			"TT": _vec3_to_array(e_fast[1]),
			"TRT": _vec3_to_array(e_fast[2]),
		},
		"ratio": {
			"R": _safe_div(_sum_rgb(e_fast[0]), _sum_rgb(e_base[0])),
			"TT": _safe_div(_sum_rgb(e_fast[1]), _sum_rgb(e_base[1])),
			"TRT": _safe_div(_sum_rgb(e_fast[2]), _sum_rgb(e_base[2])),
		},
		"baseline_total": base_total,
		"fast_total": fast_total,
		"ratio_total": _safe_div(fast_total, base_total),
		"karis": {
			"baseline": _vec3_to_array(k_base),
			"fast": _vec3_to_array(k_fast),
			"ratio": _safe_div(_sum_rgb(k_fast), _sum_rgb(k_base)),
		},
	}


# ---------------------------------------------------------------------------
# Regression contract evaluation (--contract=regression, shipping default)
# ---------------------------------------------------------------------------

## Evaluates the regression contract against the checked-in JSON reference.
## Returns {result, reason, reference_valid, contract_version, details}.
## result is "PASS" only when the reference loads and validates, the model
## contract selectors/parameters match the running configuration, the measured
## total/R/TT/TRT ratios match expected within ratio_absolute, and the grid
## drift is <= grid_drift_max. Anything else is "FAIL" with a clear reason
## (missing/invalid reference, version mismatch, inapplicable model override,
## invalid execution, or out-of-tolerance measurement).
func _evaluate_regression(agg_entry: Dictionary, drift: float,
		grid_theta: int, grid_phi: int, coarse: int) -> Dictionary:
	var out := {
		"result": "PASS",
		"reason": "",
		"reference_valid": false,
		"contract_version": "",
		"details": {},
	}
	var details: Dictionary = {}
	out["details"] = details
	details["mode"] = "regression"
	details["reference_path"] = _reference_path
	details["reference_file_exists"] = FileAccess.file_exists(_reference_path)
	details["run_grid"] = {"grid_theta": grid_theta, "grid_phi": grid_phi, "grid_coarse": coarse,
		"theta_i_deg": THETA_I_DEG}
	if not details["reference_file_exists"]:
		out["result"] = "FAIL"
		out["reason"] = "regression reference file not found: %s" % _reference_path
		return out
	var text: String = FileAccess.get_file_as_string(_reference_path)
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null or not (parsed is Dictionary):
		out["result"] = "FAIL"
		out["reason"] = "regression reference is not a valid JSON object: %s" % _reference_path
		return out
	var ref: Dictionary = parsed
	out["reference_valid"] = true
	if str(ref.get("contract_version", "<missing>")) != CONTRACT_VERSION:
		out["result"] = "FAIL"
		out["reason"] = "regression reference contract version mismatch: expected %s, got %s" % [
			CONTRACT_VERSION, str(ref.get("contract_version", "<missing>"))]
		return out
	out["contract_version"] = CONTRACT_VERSION
	details["contract_version"] = CONTRACT_VERSION
	details["reference_grid"] = ref.get("configuration", {})
	var run_grid_matches := float(details["reference_grid"].get("grid_theta", NAN)) == float(grid_theta) \
		and float(details["reference_grid"].get("grid_phi", NAN)) == float(grid_phi) \
		and float(details["reference_grid"].get("grid_coarse", NAN)) == float(coarse)
	details["run_grid_matches_reference"] = run_grid_matches
	if not run_grid_matches:
		details["grid_note"] = ("Run grid differs from the reference configuration; expected values "
			+ "were measured at the reference grid and the tolerances still apply.")

	# Decomposition subsets are diagnostic/report-only: the regression contract
	# is pinned to the shipping full M*N*A model, so any other decomposition
	# makes the reference inapplicable (clear FAIL, never a silent pass).
	details["decomposition"] = _decomposition
	if _decomposition != "full":
		out["result"] = "FAIL"
		out["reason"] = ("reference inapplicable: decomposition=%s is diagnostic/report-only; "
			+ "the regression contract only applies to the shipping full M*N*A decomposition"
			% _decomposition)
		return out

	# Azimuthal cross-section diagnostics are report-only: the regression
	# contract is pinned to the shipping fixed-h analytic model
	# (FM_AZIMUTHAL_MODE 0), so any other azimuthal mode makes the reference
	# inapplicable (clear FAIL, never a silent pass).
	details["azimuthal_mode"] = _azimuthal_mode
	if _azimuthal_mode != "fixed_h":
		out["result"] = "FAIL"
		out["reason"] = ("reference inapplicable: azimuthal_mode=%s is diagnostic/report-only; "
			+ "the regression contract only applies to the shipping fixed-h analytic model "
			+ "(FM_AZIMUTHAL_MODE 0)" % _azimuthal_mode)
		return out

	details["r_study_mode"] = _r_study_mode
	if _r_study_mode != "current":
		out["result"] = "FAIL"
		out["reason"] = ("reference inapplicable: r-study=%s is diagnostic/report-only; "
			+ "the regression contract only applies to --r-study=current" % _r_study_mode)
		return out

	# Model contract verification: the reference only applies to the shipping
	# selectors/parameters. Any mismatch (including unsupported CLI overrides)
	# makes the reference inapplicable and fails the contract clearly.
	var model: Dictionary = ref.get("model", {})
	var checks: Array = []
	checks.append(_contract_check("longitudinal_mode", model.get("longitudinal_mode", null),
		(0 if _longitudinal_mode == "unity" else 1), "FM_LONGITUDINAL_MODE"))
	checks.append(_contract_check("longitudinal_label", model.get("longitudinal_label", null),
		_longitudinal_mode, "FM_LONGITUDINAL_MODE label"))
	checks.append(_contract_check("r_longitudinal_mode", model.get("r_longitudinal_mode", null),
		(0 if _r_longitudinal_mode == "standard" else 1), "FM_R_LONGITUDINAL_MODE"))
	checks.append(_contract_check("r_longitudinal_label", model.get("r_longitudinal_label", null),
		_r_longitudinal_mode, "FM_R_LONGITUDINAL_MODE label"))
	checks.append(_contract_check("cuticle_convention", model.get("cuticle_convention", null),
		CUTICLE_CONVENTION, "FM_CUTICLE_TILT_CONVENTION"))
	checks.append(_contract_check("attenuation_mode", model.get("attenuation_mode", null),
		ATTENUATION_MODE, "FM attenuation branch"))
	checks.append(_contract_check("eta", model.get("eta", null), _eta, "material eta"))
	checks.append(_contract_check("beta_m_raw", model.get("beta_m_raw", null), _beta_m_raw,
		"artist longitudinal roughness"))
	checks.append(_contract_check("beta_n_raw", model.get("beta_n_raw", null), _beta_n_raw,
		"artist azimuthal roughness"))
	checks.append(_contract_check("cuticle_tilt_alpha", model.get("cuticle_tilt_alpha", null),
		_cuticle_tilt, "runtime cuticle tilt"))
	checks.append(_contract_check("specular", model.get("specular", null), _specular, "specular"))
	checks.append(_contract_check("exposure_gain", model.get("exposure_gain", null),
		_exposure_gain, "comparison exposure gain"))
	checks.append(_contract_check("lobe_scales", model.get("lobe_scales", null), _lobe_scales,
		"lobe scales"))
	# Albedo is not pinned in the reference JSON; the contract is tied to the
	# shipping default material, so any non-default albedo is inapplicable.
	checks.append(_contract_check("albedo", ALBEDO, _albedo, "material albedo (shipping default)"))
	checks.append(_contract_check("no_compensation", model.get("no_compensation", null), true,
		"no compensation"))
	details["model_contract_checks"] = checks
	var failed_checks: Array = []
	for check in checks:
		if not check["ok"]:
			failed_checks.append("%s (expected %s, got %s)" % [
				check["field"], str(check["expected"]), str(check["measured"])])
	if not failed_checks.is_empty():
		out["result"] = "FAIL"
		out["reason"] = ("reference inapplicable: model contract mismatch on %s; unsupported CLI "
			+ "mode/parameter overrides cannot be validated against this reference"
			% ", ".join(failed_checks))
		return out
	details["model_contract_ok"] = true

	# Expected values and tolerances from the reference.
	var expected: Dictionary = ref.get("expected", {})
	var tolerances: Dictionary = ref.get("tolerances", {})
	var ratio_tol: float = _float_field(tolerances, "ratio_absolute", -1.0)
	var drift_tol: float = _float_field(tolerances, "grid_drift_max", -1.0)
	if ratio_tol <= 0.0 or drift_tol <= 0.0:
		out["result"] = "FAIL"
		out["reason"] = ("regression reference has invalid tolerances: expected ratio_absolute > 0 "
			+ "and grid_drift_max > 0")
		return out
	details["tolerances"] = {"ratio_absolute": ratio_tol, "grid_drift_max": drift_tol}

	# Ratio comparison: |measured - expected| <= ratio_absolute per ratio.
	var measured_ratios := {
		"ratio_total": float(agg_entry["ratio_total"]),
		"ratio_R": float(agg_entry["lobes"]["R"]["ratio"]),
		"ratio_TT": float(agg_entry["lobes"]["TT"]["ratio"]),
		"ratio_TRT": float(agg_entry["lobes"]["TRT"]["ratio"]),
	}
	var ratio_checks := {}
	var missing_expected := false
	var invalid_execution := false
	for key in ["ratio_total", "ratio_R", "ratio_TT", "ratio_TRT"]:
		var expected_val: float = _float_field(expected, key, NAN)
		var measured_val: float = measured_ratios[key]
		var delta := absf(measured_val - expected_val)
		var ok := false
		if is_nan(expected_val):
			missing_expected = true
		elif is_nan(measured_val) or is_inf(measured_val):
			invalid_execution = true
		else:
			ok = delta <= ratio_tol
		ratio_checks[key] = {
			"expected": expected_val,
			"measured": measured_val,
			"absolute_delta": delta,
			"tolerance": ratio_tol,
			"ok": ok,
		}
	details["ratio_checks"] = ratio_checks

	# Grid drift comparison: measured drift <= grid_drift_max (absolute bound).
	var expected_drift: float = _float_field(expected, "grid_max_relative_drift", NAN)
	var drift_ok := false
	if is_nan(expected_drift):
		missing_expected = true
	elif is_nan(drift) or is_inf(drift):
		invalid_execution = true
	else:
		drift_ok = drift <= drift_tol
	details["drift_check"] = {
		"expected": expected_drift,
		"measured": drift,
		"absolute_delta": absf(drift - expected_drift),
		"tolerance": drift_tol,
		"ok": drift_ok,
	}
	if missing_expected:
		out["result"] = "FAIL"
		out["reason"] = "regression reference is missing expected values"
		return out
	if invalid_execution:
		out["result"] = "FAIL"
		out["reason"] = "invalid execution: measured regression values are not finite"
		return out
	var failures: Array = []
	for key in ["ratio_total", "ratio_R", "ratio_TT", "ratio_TRT"]:
		if not ratio_checks[key]["ok"]:
			failures.append("%s (expected %.4f, measured %.4f, |delta|=%.4f > %.4f)" % [
				key, ratio_checks[key]["expected"], ratio_checks[key]["measured"],
				ratio_checks[key]["absolute_delta"], ratio_tol])
	if not drift_ok:
		failures.append("grid_max_relative_drift (measured %.6f > %.4f)" % [drift, drift_tol])
	if not failures.is_empty():
		out["result"] = "FAIL"
		out["reason"] = "regression mismatch: " + "; ".join(failures)
		return out
	out["result"] = "PASS"
	out["reason"] = "regression contract satisfied: total/R/TT/TRT ratios within ratio_absolute=%.4f of expected and grid drift <= %.4f" % [ratio_tol, drift_tol]
	return out


## One model-contract verification entry: expected comes from the reference
## JSON, measured from the running configuration.
func _contract_check(field: String, expected: Variant, measured: Variant, context: String) -> Dictionary:
	return {
		"field": field,
		"context": context,
		"expected": expected,
		"measured": measured,
		"ok": expected != null and _contract_values_close(expected, measured),
	}


func _contract_values_close(a: Variant, b: Variant) -> bool:
	if a is Array and b is Array:
		return _arrays_close(a, b)
	if a is Vector3 and b is Vector3:
		return _num_close(a.x, b.x) and _num_close(a.y, b.y) and _num_close(a.z, b.z)
	if a is Array and b is Vector3:
		return a.size() == 3 and _num_close(float(a[0]), b.x) and _num_close(float(a[1]), b.y) \
			and _num_close(float(a[2]), b.z)
	if a is Vector3 and b is Array:
		return b.size() == 3 and _num_close(a.x, float(b[0])) and _num_close(a.y, float(b[1])) \
			and _num_close(a.z, float(b[2]))
	if (a is float or a is int) and (b is float or b is int):
		return _num_close(float(a), float(b))
	return str(a) == str(b)


func _arrays_close(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if not _num_close(float(a[i]), float(b[i])):
			return false
	return true


func _num_close(a: float, b: float, eps := 1e-9) -> bool:
	return absf(a - b) <= eps


## Reads a numeric field from a Dictionary; returns fallback when missing or
## not a number.
func _float_field(d: Dictionary, key: String, fallback: float) -> float:
	var v: Variant = d.get(key, fallback)
	return float(v) if (v is float or v is int) else fallback
