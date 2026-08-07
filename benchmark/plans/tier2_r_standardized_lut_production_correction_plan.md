# Tier 2 Standardized-R LUT — Production Correction Plan

**Parent commit:** `7d8b6e4c288124389cc5ac64912ca0ee56081966`  
**Status:** diagnostic only; do not promote `FAST_MARSCHNER_R_STANDARDIZED_LUT` to the shipping Tier 2 wrapper until every gate below passes.

## 1. Review summary

The projected-Q representation is mathematically successful. The committed 512×128 CPU matrix shows very small aggregate error against the direct reference, with the linear decoder outperforming log decoding. The remaining blockers are runtime engineering and GPU numerical behavior rather than the coordinate reduction itself.

Current blockers:

1. The GPU direct-Bessel fallback is numerically unsafe in fp32 for low `beta_r` values above `1e-8` but below the LUT domain.
2. Roughly 28% of the designed matrix samples execute a direct/asymptotic fallback, so the candidate has not yet demonstrated a Tier-2 cost advantage.
3. The committed `256×256×128 RGBAF` diagnostic LUT is about 128 MiB of raw texel data and is too large for a production medium-quality tier.
4. The current energy matrix validates `M_R * N_R`, not the complete reflected R term `M_R * N_R * A_R`; therefore the IOR cases are metadata-only and do not exercise Fresnel weighting.
5. No controlled comparative GPU benchmark currently proves the standardized-R candidate is faster than the high-tier baseline or competitive with the current Fast analytic tier.
6. Shader LUT-domain constants are hard-coded instead of being bound from validated resource metadata.

The current shipping wrapper must remain unchanged while these corrections are implemented.

---

# 2. Correct the low-beta GPU path

## Files

- `assets/hair/materials/shaders/hair_marschner_fast.gdshaderinc`
- `assets/hair/materials/shaders/hair_marschner_fast_r_standardized_lut.gdshader`
- `benchmark/reference/fast_marschner_r_standardized_kernel_reference.gd`
- `benchmark/tests/test_fast_marschner_r_standardized_reference.gd`
- `benchmark/tests/test_fast_marschner_standardized_r_lut_runtime.gd`

## Problem

The diagnostic shader currently routes every `beta_r > 1e-8` fallback through the direct rounded-Bessel form. In fp32, the direct expression subtracts terms on the order of `1 / beta_r^2` and becomes inaccurate well before `beta_r == 1e-8`.

The CPU reference uses double precision and therefore cannot prove the corresponding shader branch is stable.

## Required shader change

Split the fallback policy into three numeric regions:

```glsl
const float FM_R_STD_BETA_ASYM_ONLY_MAX = 0.015;
const float FM_R_STD_BETA_LUT_BLEND_MAX = 0.03;
```

For low beta, never evaluate the direct Bessel form:

```glsl
float fm_r_std_low_beta_q(
    float theta_o,
    float theta_cone,
    float beta_r
) {
    return fm_r_std_asymptotic_q(
        theta_o,
        theta_cone,
        beta_r
    );
}
```

For samples inside the LUT's q/cone support:

```glsl
float q_asym = fm_r_std_asymptotic_q(
    theta_o,
    theta_cone,
    max(beta_r, FM_R_STD_BETA_NUMERIC_EPSILON)
);

float lut_weight = smoothstep(
    FM_R_STD_BETA_ASYM_ONLY_MAX,
    FM_R_STD_BETA_LUT_BLEND_MAX,
    beta_r
);

float q_lut = fm_r_std_sample_q(
    q,
    theta_cone,
    max(beta_r, r_standardized_lut_beta_range.x),
    lut_texture,
    log_decode
);

float q_value = mix(q_asym, q_lut, lut_weight);
```

The direct Bessel fallback may still be used for geometrical boundary cases only when:

```text
beta_r >= FM_R_STD_BETA_LUT_BLEND_MAX
```

If a boundary sample has lower beta, use the asymptotic form instead.

Do not retain a branch that evaluates the direct form for `1e-8 < beta_r < 0.015`.

## Add an fp32-emulation CPU test

The reference test must explicitly quantize the relevant intermediate terms to float32 and probe:

```text
beta_r =
0.02
0.01
0.005
0.002
0.001
0.0005
0.0002
0.0001
```

At `theta_o == theta_cone`, compare:

```text
fp32 direct Q
asymptotic Q
CPU double direct Q
```

The test should prove why the shader branch selects the asymptotic path at low beta rather than assuming the double-precision threshold is appropriate for GPU execution.

## Low-beta acceptance gate

For the production candidate:

```text
no NaN
no Inf
nonnegative
continuous through the asymptotic/LUT blend
```

At `beta_r <= 0.015`, the shader must not invoke `fm_r_std_direct_q()`.

---

# 3. Make LUT metadata authoritative at runtime

## Files

- `benchmark/resources/fast_marschner_r_standardized_lut_data.gd`
- `benchmark/scripts/hair_material_adapter.gd`
- `benchmark/scripts/benchmark_controller.gd`
- `assets/hair/materials/shaders/hair_marschner_fast_r_standardized_lut.gdshader`
- `assets/hair/materials/shaders/hair_marschner_fast.gdshaderinc`

## Wrapper uniforms

Add:

```glsl
uniform vec2 r_standardized_lut_q_range = vec2(-12.0, 12.0);
uniform vec2 r_standardized_lut_beta_range = vec2(0.02, 9.0);
uniform vec2 r_standardized_lut_theta_cone_range = vec2(-PI * 0.5, PI * 0.5);
uniform vec2 r_standardized_lut_low_beta_blend = vec2(0.015, 0.03);
```

Replace shader sampling/fallback uses of hard-coded q/beta/cone domain constants with these uniforms.

The numerical safety constants such as `BETA_NUMERIC_EPSILON` and cosine floors may remain compile-time constants.

## Adapter validation

`standardized_r_lut_texture()` must reject a resource unless all of the following are valid:

```text
contract == expected contract id
channels are supported by the selected decoder
format is supported
dimensions >= 2
data byte count matches format × dimensions
q range finite and increasing
theta-cone range finite and increasing
beta range finite, positive, and increasing
raw_m_unit_normalization_claimed == false
```

Do not only validate byte count.

Add a helper such as:

```gdscript
func standardized_r_lut_contract_errors(
        lut_data: Resource
) -> PackedStringArray:
```

and make both the controller and runtime test use it.

## Controller binding

`_apply_r_standardized_lut_binding()` must bind:

```text
r_standardized_lut
r_standardized_lut_log_decode
r_standardized_lut_q_range
r_standardized_lut_beta_range
r_standardized_lut_theta_cone_range
r_standardized_lut_low_beta_blend
```

from the resource/selected production contract.

The run manifest must record the same metadata so benchmark artifacts prove which domain was actually rendered.

---

# 4. Extend the R energy validator to the complete R term

## Files

- `benchmark/tools/validate_marschner_r_standardized_energy.gd`
- `benchmark/tools/run_marschner_r_standardized_matrix.py`
- `benchmark/results/...` regenerated artifacts

## Current limitation

The current validator integrates:

```text
M_R * N_R
```

and therefore `eta` does not affect the integrand.

The production-quality comparison must integrate:

```text
R = M_R * N_R * A_R
```

with the same Fresnel function as the shader:

```text
A_R = fm_fresnel(
    cos(theta_d) * cos(phi / 2),
    eta
)
```

Port the exact current Fast/baseline Fresnel function into the CPU validator; do not substitute a different dielectric approximation.

## Report both attribution and complete-R metrics

Keep two result groups:

```json
{
  "mn_only": {},
  "complete_r": {}
}
```

For each incoming angle and aggregate, report:

```text
direct energy
linear LUT energy
log LUT energy
absolute error
relative error
RMS absolute error
RMS relative error
```

The complete-R group is the promotion gate. `mn_only` remains an attribution diagnostic.

## Fallback energy attribution

For each disjoint branch bucket, record both:

```text
sample_count
complete_R_direct_energy
```

Buckets:

```text
lut_interior
low_beta_asymptotic
q_outside
beta_above_domain
cone_pole_fallback
grazing_fallback
exact_c_phi_seam
```

Do not keep `q_beta_fallback` as one combined bucket; it hides whether the domain or the q tail is causing the expensive fallback rate.

Report:

```text
sample_share
complete_R_energy_share
```

for every bucket.

## Matrix cleanup

The R lobe has no Beer-Lambert absorption. Remove redundant albedo-only matrix cases from the R-specific study.

Use a designed R matrix containing at least:

```text
reference beta_m = 0.2
beta_m = 0.02
beta_m = 0.05
beta_m = 0.1
beta_m = 0.4
beta_m = 0.8
cuticle = 0.0
cuticle = 0.1
cuticle = 0.15
eta = 1.45
eta = 1.55
eta = 1.65
```

Additionally add explicit stress probes for:

```text
theta_i = ±75°
near phi = ±PI
low-beta seam
near grazing theta_o
```

The full matrix does not need to be Cartesian, but the report must state the exact designed cases.

---

# 5. Reduce fallback frequency

## Goal

A Tier-2 LUT should not execute the expensive direct Bessel reference on approximately 28% of shader samples.

The next validator must distinguish why samples leave the LUT path.

### q tails

Measure the complete-R energy outside:

```text
|q| <= 8
|q| <= 10
|q| <= 12
|q| <= 16
```

If the direct complete-R energy outside `|q| <= 12` is negligible, production should return zero or an inexpensive analytic tail rather than run the full Bessel reference.

### low beta

Low beta must use the asymptotic path, not the direct fallback.

### cone-pole and grazing

Measure the complete-R energy contribution of pole/grazing fallback separately. If it is small, evaluate whether a bounded analytic asymptotic/boundary approximation is preferable to full direct evaluation.

## Promotion target

For production-like matrix cases:

```text
expensive direct-Bessel fallback sample share <= 5%
```

Low-beta asymptotic samples do not count as expensive direct fallback.

Also report complete-R energy share so a low sample percentage cannot hide a high-energy error region.

---

# 6. Perform a resolution/channel/format sweep

## Files

- `benchmark/tools/generate_marschner_r_standardized_lut.gd`
- `benchmark/resources/fast_marschner_r_standardized_lut_data.gd`
- new `benchmark/tools/run_marschner_r_standardized_lut_sweep.py`
- `benchmark/scripts/hair_material_adapter.gd`

The current `256×256×128 RGBAF` asset remains the high-resolution diagnostic reference. Do not delete it until the smaller candidate is validated.

## Generator options

Support:

```text
--size=128x64x32
--size=128x96x48
--size=192x96x48
--size=256x128x64

--encoding=linear
--encoding=linear_log

--format=rf
--format=rh
--format=rgbaf
```

Preferred production candidates use a single linear-Q channel because the current matrix shows linear decoding is more accurate than the log channel.

Godot image formats should be handled explicitly:

```text
Image.FORMAT_RF     -> 4 bytes/texel
Image.FORMAT_RH     -> 2 bytes/texel
Image.FORMAT_RGBAF  -> 16 bytes/texel
```

Do not hard-code `* 16` in resource validation or the adapter once RF/RH candidates are supported.

Add:

```gdscript
func bytes_per_texel() -> int:
    match format:
        Image.FORMAT_RH:
            return 2
        Image.FORMAT_RF:
            return 4
        Image.FORMAT_RGBAF:
            return 16
        _:
            return 0
```

## Sweep runner

For each candidate:

1. generate the LUT;
2. run the off-grid interpolation validator;
3. run the complete-R energy matrix;
4. record total raw bytes;
5. record LUT-interior/fallback statistics;
6. reject candidates that fail accuracy gates.

Output one JSON artifact with a Pareto table:

```text
resolution
format
bytes
complete-R aggregate error
per-angle p95 error
worst case error
direct fallback sample share
direct fallback energy share
```

## Initial size target

A production Tier-2 R LUT should preferably be in the single-digit MiB range. Treat the current 128 MiB RGBAF volume as a diagnostic ceiling, not a production target.

---

# 7. Add controlled GPU performance comparisons

## Files

- `benchmark/scripts/benchmark_controller.gd`
- new benchmark suite/resource(s) under `benchmark/resources/`
- new runner if required under `benchmark/tools/`
- runtime test remains a correctness smoke test only

Compare exactly:

```text
CURRENT_MARSCHNER_BASELINE
FAST_MARSCHNER_ANALYTIC
FAST_MARSCHNER_R_STANDARDIZED_LUT
```

For the selected smaller LUT candidate also add a distinct diagnostic variant name rather than silently replacing the 256³-class reference candidate.

## Cases

At minimum:

```text
Blowout close-up, one direct light
Blowout close-up, four direct lights
overdraw-heavy repeated cards
all grooms
```

Use identical:

```text
camera
viewport
light transforms/intensities
source material parameters
coverage/hash phase
comparison_exposure_gain = 1
lobe_scales = vec3(1)
area-light multiplier policy
```

## Metrics

Record:

```text
median GPU frame time
p95 GPU frame time
median CPU frame time
p95 CPU frame time
visible draw calls
visible primitives
shadow draw calls
shadow primitives
LUT byte size
```

Use enough prewarm/settle/sample frames that shader compilation and one-time Texture3D construction are excluded from timed samples.

The existing 60-frame wall-time runtime-test print is informational only and must not be used as the performance contract.

## Hardware profiles

Run at least:

```text
native GPU clocks
core-constrained NVIDIA profile
bandwidth-constrained NVIDIA profile
```

If available, run on a secondary lower-power GPU as an additional data point.

---

# 8. Runtime correctness test improvements

Modify:

```text
benchmark/tests/test_fast_marschner_standardized_r_lut_runtime.gd
```

Add assertions that:

```text
resource contract validation passes
bound q range matches resource q range
bound beta range matches resource beta range
bound theta-cone range matches resource metadata
low-beta blend bounds are the expected production values
linear decoder is the selected default
```

Add deterministic stress renders for:

```text
low longitudinal roughness
near-backward azimuth / R seam
grazing camera-light geometry
```

For each capture, require:

```text
finite pixels
no NaN/Inf-derived overflow artifacts
non-black hair mask
bounded maximum luminance relative to direct diagnostic/reference capture
```

Do not merely check that toggling linear/log decode changes pixels.

---

# 9. Complete-R acceptance gates

For the selected production LUT and asymptotic hybrid:

## Accuracy

```text
complete-R aggregate ratio: 0.98 to 1.02
per-theta_i complete-R ratio: 0.95 to 1.05
complete-R weighted RMS relative error <= 0.05
complete-R p95 relative error <= 0.10
```

The actual observed candidate is expected to be substantially better; these are promotion gates, not targets to tune toward.

## Numerical safety

```text
no NaN
no Inf
nonnegative R contribution
no visible seam introduced at beta blend
no catastrophic low-beta fp32 spike
```

## Runtime behavior

```text
expensive direct-Bessel fallback sample share <= 5%
```

and report its complete-R energy share.

## Memory

Do not promote the 128 MiB RGBAF diagnostic volume. Select a smaller single-channel candidate after the sweep.

## Performance

The selected standardized-R Tier-2 candidate must:

```text
remain faster than CURRENT_MARSCHNER_BASELINE
```

under the constrained-GPU cases, and it should not materially regress the current `FAST_MARSCHNER_ANALYTIC` tier unless the quality improvement is explicitly accepted as a separate quality/performance point.

---

# 10. Recommended implementation order

## Commit A — GPU numerical safety and metadata contract

Implement:

```text
low-beta asymptotic path
asymptotic/LUT blend
metadata uniforms
adapter contract validation
runtime binding assertions
fp32-emulation tests
```

Do not regenerate the production LUT yet.

## Commit B — complete-R validator and branch attribution

Implement:

```text
Fresnel-weighted complete-R integration
split fallback buckets
sample and energy shares
new designed R matrix
```

Regenerate the 512×128 study report.

## Commit C — size/format sweep

Implement:

```text
RF/RH support
single-channel linear encoding
resolution sweep runner
Pareto report
```

Select a production candidate.

## Commit D — GPU performance suite

Implement:

```text
controlled baseline/Fast/current-LUT comparisons
constrained clock profiles
stable run manifests
```

## Commit E — promotion

Only after all gates pass:

```text
promote selected standardized-R implementation to Tier 2
```

Keep the current high-resolution LUT variant available as a diagnostic/reference artifact if useful, but do not make it the default shipping resource.

---

# 11. Stop conditions

Do not promote the candidate when any of the following is true:

```text
low-beta direct Bessel still runs in unstable fp32 range
complete-R validation is absent
IOR does not affect the R matrix
expensive direct fallback remains common
LUT remains ~128 MiB
GPU performance has not been compared against baseline and Fast analytic
metadata and shader sampling domains can diverge silently
```

Do not compensate failures with:

```text
global exposure
R lobe scalar gains
hidden roughness floors
removal of seam/grazing cases
relaxed energy gates
```
