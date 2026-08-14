// Represents the index of refraction of hair strands. For human hair, η=1.55
#define ETA 1.55

// If defined, uses the energy conserving longitudinal scattering function described in
// "An Energy-Conserving Hair Reflectance Model" (d'Eon et al., 2011).
//
// Comment out to instead use a Gaussian distribution as originally used in
// "Light Scattering from Human Hair Fibers" (Marschner et al., 2003).
#define USE_ENERGY_CONSERVING_LONGITUDINAL_SCATTERING_FUNCTION

// If defined, uses the physically-based, non-separable lobe widths/tilts described in
// "A Fiber Scattering Model with Non-Separable Lobes" (d'Eon et al., 2014).
//
// Comment out to instead use the constant-based lobe widths/tilts originally used in
// "Light Scattering from Human Hair Fibers" (Marschner et al., 2003).
#define USE_NON_SEPARABLE_LONGITUDINAL_WIDTHS_AND_TILT_ANGLES

// If defined, uses an approximate form of the lobe tilts based on the
// first-order Taylor expansion of the ray path functions described in
// "A Fiber Scattering Model with Non-Separable Lobes" (d'Eon et al., 2014).
//
// Comment out to instead use the exact lobe tilt calculations defined in `compute_longitudinal_lobe_tilt()`.
// The approximate form is near-visually identical to the exact form for cuticle-tilt offset values <10°.
// Note that lobe widths will always use the approximate form described in d'Eon et al.
#define USE_APPROXIMATE_NON_SEPARABLE_LONGITUDINAL_TILT_ANGLES

// If defined, uses an empirical constant for the value of h_TRT. Otherwise, uses an
// analytically derived expression for h_TRT. For high values of azimuthal roughness (β_N),
// the approximate form is near-identical to the analytical form.
#define USE_APPROXIMATE_TRT_CROSS_SECTION_OFFSET

// --- Planes ---
#define M   0 // Longitudinal Direction (along hair strand)
#define N   1 // Azimuthal Direction (around hair strand)

// --- Lobes (Modes) ---
#define R   0 // (p=0) Denotes paths where light rays reflect (R) off the front surface of fiber.
#define TT  1 // (p=1) Denotes paths where light rays transmit (T) into fiber, then transmit again (T) out the back.
#define TRT 2 // (p=2) Denotes paths where light rays transmit (T) into fiber, reflect (R) off the back, then transmit again (T) out the front.

// The `lobe_scales` Debug uniform used by hair_BSDF() below is declared in the
// consuming shaders (hair.gdshader / hair_a2c.gdshader) so the editor's hover
// tooltips, which only scan the main shader file, can display its description.

/** Approximation of the natural log of the zeroth-ordered modified bessel function of the first kind. */
// Source: https://iopscience.iop.org/article/10.1088/1742-6596/1043/1/012003/pdf
vec3 log_bessel_zero(vec3 x) {
	vec3 x_sq = x*x;
	return log((0.564187 + 1.01298/(x_sq + 2.32434)) * inversesqrt(sqrt(x_sq*0.25 + 1.0)) * (exp(-2.0*abs(x))*0.5 + 0.5)) + x;
}


vec3 gaussian(vec3 theta, vec3 beta_inv) {
	return exp(-0.5 * theta*theta*beta_inv*beta_inv) * beta_inv * inversesqrt(TAU);
}


float fresnel(float cos_theta, float cos_theta_t, const float eta) {
	const float F0 = (1.0 - eta)*(1.0 - eta) / ((1.0 + eta)*(1.0 + eta));

	float p = 1.0 - cos_theta;
	float p_sq = p*p;
	return mix(p_sq*p_sq*p, 1.0, F0);
}


/** Logistic distribution normalized to [-π..π] and scaled to match a Gaussian distribution. */
// Source: "A Practical and Controllable Hair and Fur Model for Production Path Tracing" (Chiang et al., 2016)
float logistic(float cos_phi, float s_inv) {
	float phi = sqrt(1.0 - cos_phi) * (1.5707288 + cos_phi*(-0.2121144 + cos_phi*0.0742610)); // Approximate: acos(cos_phi)
	float eta_prime_inv = exp(-phi * s_inv);
	float b = exp(-2.0*sqrt(TAU) * s_inv);
	float c = 1.0 + eta_prime_inv;
	return min(1, s_inv * eta_prime_inv*(1.0 + b) / ((1.0 - b) * c*c));
}


// Demo: https://www.desmos.com/calculator/the6h5uo6z
vec3 compute_cross_section_offset(float cos_phi_half, float sin_phi_half, float eta_prime_inv) {
	vec3 h;

	h[R] = -sin_phi_half;
	h[TT] = sign(sin_phi_half)*cos_phi_half*inversesqrt(1.0 + eta_prime_inv*(1.0 - 2.0*eta_prime_inv*abs(sin_phi_half)));
#ifdef USE_APPROXIMATE_TRT_CROSS_SECTION_OFFSET
	h[TRT] = 0.91;
#else
	// Bro...
	float s2 = sin_phi_half*sin_phi_half;
	float c2 = 1.0 - s2; // cos(φ)*0.5 + 0.5
	float a2 = eta_prime_inv*eta_prime_inv;

	// --- Coefficient Calculations ---
	float A0 = 4.0*a2 - 1.0;
	float A1 = A0*2.0 + 3.0*s2;
	float A2 = A0*A0 + (48.0*a2 + 24.0)*s2*a2;
	float A3 = (64.0*a2 + 16.0)*a2 - 3.0*s2 + 4.0;

	// --- Solve Cubic Equation (via Cardano's Method) ---
	float B0 = -(A1*A1*A1) + (108.0*c2*c2 + 9.0*A1*A3)*s2;
	float B1 = B0*B0 - 64.0*A2*A2*A2; // The cubic discriminant
	float B2 = sign(B1)*0.5 + 0.5;    // ...and its "path selector"
	float B3 = sqrt(abs(B1));

	float C0 = pow(abs(B0) + B3, 1.0/3.0);
	float C1 = C0 + 4.0*A2 / C0;                     // Real case    (B1 >= 0)
	float C2 = 4.0*sqrt(A2)*cos(atan(B3, B0) / 3.0); // Complex case (B1 < 0)

	// --- Reconstruct Quartic Root ---
	float D0 = C1*B2 + C2*(1.0 - B2); // Select path based on sign of discriminant
	float D1 = sqrt(D0 + 2.0*A1) + 1e-10;
	float D2 = sqrt(max(0.0, -D0 + 4.0*A1 + (12.0*sqrt(6.0))*abs(sin_phi_half)*c2 / D1));
	h[TRT] = clamp(sign(sin_phi_half)*(0.25*abs(sin_phi_half) - (sqrt(6.0)/24.0)*(D1 + D2)) / a2, -1, 1);
#endif
	return h;
}


/** Computes the exact exiting longitudinal angle (sin(θ_cone)) for R, TT, and TRT lobes. */
vec3 compute_longitudinal_lobe_tilt(float cos_theta_i, float sin_theta_i, vec3 h, float alpha) {
	vec3 sin_theta_cone;

	// We calculate longitudinal tilt caused by azimuthal cross-section offset (h) and
	// cuticle tilt-offset (alpha) by computing the exact analytic Nusselt sphere ray composition
	// (i.e., successive rotations at each transmission/reflection event per lobe).
	float ca = cos(alpha);
	float sa = sin(alpha);
	float s2a = 2.0*sa*ca;         // sin(2α)
	float c2a = ca*ca - sa*sa;     // cos(2α)
	float s4a = 2.0*s2a*c2a;       // sin(4α)
	float c4a = c2a*c2a - s2a*s2a; // cos(2α)

	vec2 T0 = cos_theta_i*sqrt(1.0 - h.xy*h.xy); // Note: h_TRT is unused
	vec2 T1 = T0*sa + sin_theta_i*ca;
	vec2 T2 = sin_theta_i*sa - T0*ca;

	// Equivalent: R[α](x,y)
	sin_theta_cone[R] = -(T1[R])*ca - abs(T2[R])*sa; // sin(theta_cone)

	// Equivalent: T'[α](-T[α](x,y))
	float B0 = h[TT]*h[TT]*cos_theta_i*cos_theta_i;
	float B2 = sqrt(ETA*ETA - B0 - T1[TT]*T1[TT]);
	float B3 = T1[TT]*c2a - B2*s2a;
	sin_theta_cone[TT] = clamp(-B3*ca - sqrt(max(0.0, 1.0 - B0 - B3*B3))*sa, -1, 1);

	// Equivalent: T'[α](-R'[α](-T[α](x,y)))
	float C0 = cos_theta_i*sa + sin_theta_i*ca;
	float C1 = sqrt(ETA*ETA - C0*C0);
	float C2 = s4a*C1 - c4a*C0;
	sin_theta_cone[TRT] = clamp(C2*ca - sqrt(max(0.0, 1.0 - C2*C2))*sa, -1, 1);

	return sin_theta_cone;
}


/** Returns the longitudinal scattering components (scalar) for R, TT, and TRT lobes. */
vec3 longitudinal_scattering(float cos_theta_i, float sin_theta_i, float cos_theta_o, float sin_theta_o, float cos_theta_d, float sin_theta_d, float cos_phi_half, float alpha, float beta, vec3 h) {
#ifdef USE_NON_SEPARABLE_LONGITUDINAL_WIDTHS_AND_TILT_ANGLES
	vec3 k_sq = sin_theta_d*sin_theta_d + cos_theta_d*cos_theta_d * h*h;
	vec3 z = sqrt(1.0 - k_sq);
	vec3 z_prime = sqrt(ETA*ETA - k_sq)*vec3(R, TT, TRT);

	// Approximate form for the lobe tilts using the L2 norm of the first-order Taylor expansion of
	// the ray exit direction with respect to alpha at each transmission/reflection event per lobe.
	// Source: "A Fiber Scattering Model with Non-Separable Lobes" (d'Eon et al., 2014).
	vec3 beta_m = vec3(beta); // Lobe Widths
	beta_m[R] *= sqrt(2)*cos_phi_half;
	beta_m[TT] *= (z[TT] + 0.5*z_prime[TT]) / cos_theta_d;
	beta_m[TRT] *= 2.0*sqrt(ETA*ETA - sin_theta_d*sin_theta_d) / cos_theta_d - 1.0;

#ifdef USE_APPROXIMATE_NON_SEPARABLE_LONGITUDINAL_TILT_ANGLES
	// Approximate form for the lobe tilts using the sum of the first-order Taylor expansion of the
	// ray exit direction with respect to alpha at each transmission/reflection event per lobe.
	// Source: "A Fiber Scattering Model with Non-Separable Lobes" (d'Eon et al., 2014).
	vec3 sin_theta_cone = clamp(-sin_theta_i + (2.0*z_prime - 2.0*z)*alpha, -1, 1);
#else
	vec3 sin_theta_cone = compute_longitudinal_lobe_tilt(cos_theta_i, sin_theta_i, h, alpha);
#endif

#else
	// Note: We multiply by 2 and 1.5 to more closely match the results of d'Eon et al., 2014.
	// Source: "Light Scattering from Human Hair Fibers" (Marschner et al., 2003)
	vec3 alpha_m = vec3(1, -0.5, -1.5)*alpha * 2.0; // Lobe Tilts
	vec3 beta_m = vec3(1, 0.5, 2)*beta * 1.5;       // Lobe Widths

	vec3 sin_theta_cone = -cos_theta_i*sin(alpha_m) - sin_theta_i*cos(alpha_m);
#endif

#ifdef USE_ENERGY_CONSERVING_LONGITUDINAL_SCATTERING_FUNCTION
	vec3 v_inv = 1.0 / (beta_m*beta_m);
	vec3 cos_theta_cone = sqrt(1.0 - sin_theta_cone*sin_theta_cone);

	// Below is a reasonable approximation for the energy-conserving longitudinal scattering function
	// described in "An Energy-Conserving Hair Reflectance Model" (d'Eon et al., 2011).
	//
	// Demo: https://www.desmos.com/3d/xns2vtxhge
	return exp((sin_theta_cone*sin_theta_o - 1.0)*v_inv + log_bessel_zero(cos_theta_cone*cos_theta_o*v_inv))*v_inv / cos_theta_o;// * (1.0 + 0.424422/pow(v_inv + 0.4, vec3(3))); // <- Correction factor
#else
	// Source: "Physically Based Hair Shading in Unreal" (Karis, 2016)
	return gaussian(-sin_theta_cone + sin_theta_o, 1.0 / beta_m);
#endif
}


/** Calculates the attenuation (reduction of light energy) for light rays traveling through a hair strand for a given mode. */
// Source: "An Energy-Conserving Hair Reflectance Model" (d'Eon et al., 2011).
vec3 azimuthal_attenuation(int mode, float cos_theta_t, float cos_theta_d, vec3 absorbtion, float eta_prime_inv, float h) {
	// Combined losses due to surface reflection (Fresnel) and internal volumetric absorption (Beer-Lambert).
	float fresnel = fresnel(cos_theta_d*sqrt(1.0 - h*h), cos_theta_t, ETA);
	vec3 transmittance = exp(-absorbtion/cos_theta_t * 4.0*(1.0 - eta_prime_inv*eta_prime_inv*h*h) * float(mode)); // Beer-Lambert Law
	return (1.0 - fresnel)*(1.0 - fresnel)*pow(fresnel, float(mode - 1)) * transmittance;
}


/** Calculates cos(ϕ − Φ(p,h)) where Φ(p,h) = 2*asin(h/η')*p - 2*asin(h) - π*p */
// Source: "An Energy-Conserving Hair Reflectance Model" (d'Eon et al., 2011).
float azimuthal_angular_offset(int mode, float cos_phi, float sin_phi, float eta_prime_inv, float h) {
	float gamma = (2.126*h*eta_prime_inv + PI)*float(mode); // Approximate: γ_t = asin(h/η') ≈ 1.063*h*eta_prime_inv
	float A = 1.0 - 2.0*h*h;
	float B = 2.0 * h*sqrt(1.0 - h*h);
	float C = cos(gamma);
	float S = sin(gamma);
	return cos_phi*(C*A + S*B) + sin_phi*(S*A - C*B); // Angle difference
}


/** Returns the azimuthal scattering components (vector/color) for R, TT, and TRT lobes. */
mat3 azimuthal_scattering(float cos_theta_t, float cos_theta_d, float cos_phi, float sin_phi, float cos_phi_half, float eta_prime_inv, vec3 absorbtion_coefficient, float beta, vec3 h) {
	mat3 distribution = mat3(1);
	mat3 attenuation;

	distribution[R] *= 0.25*cos_phi_half; // R is a special case with a simple cosine lobe.
	attenuation[R] = vec3(fresnel(cos_theta_d*cos_phi_half, cos_theta_t, ETA)); // Equivalent: fresnel(cos(acos(ω_i*ω_o)/2), θ_t)

	distribution[TT] *= logistic(azimuthal_angular_offset(TT, cos_phi, sin_phi, eta_prime_inv, h[TT]), sqrt(2)/beta);
	attenuation[TT] = azimuthal_attenuation(TT, cos_theta_t, cos_theta_d, absorbtion_coefficient, eta_prime_inv, h[TT]);

	distribution[TRT] *= logistic(azimuthal_angular_offset(TRT, cos_phi, sin_phi, eta_prime_inv, h[TRT]), 0.5*sqrt(2)/beta);
	attenuation[TRT] = azimuthal_attenuation(TRT, cos_theta_t, cos_theta_d, absorbtion_coefficient, eta_prime_inv, h[TRT]);

	return attenuation * distribution;
}


vec3 hair_BSDF(vec3 omega_i, vec3 omega_o, float alpha, vec2 beta, vec3 absorbtion_coefficient) {
	// For more information on what the below angles represent, look at Figure 3 in
	// "Light Scattering from Human Hair Fibers" (Marschner et al., 2003).
	float sin_theta_i = omega_i.x;
	float sin_theta_o = omega_o.x;
	float cos_theta_i = length(omega_i.yz);
	float cos_theta_o = length(omega_o.yz);

	// φ = φ_o - φ_i (Relative Azimuth)
	float cos_phi = clamp((omega_i.y*omega_o.y + omega_i.z*omega_o.z) / max(cos_theta_i*cos_theta_o, 1e-6), -0.9999, 0.9999);
	float sin_phi = clamp((omega_i.y*omega_o.z - omega_i.z*omega_o.y) / max(cos_theta_i*cos_theta_o, 1e-6), -0.9999, 0.9999);
	float cos_phi_half = max(1e-6, sqrt(0.5 + 0.5*cos_phi));
	float sin_phi_half = sqrt(0.5 - 0.5*cos_phi) * sign(sin_phi);

	// θ_d = (θ_o - θ_i)/2 (Longitudinal Difference Angle)
	float cos_theta = clamp(cos_theta_o*cos_theta_i + sin_theta_o*sin_theta_i, -1, 1);
	float cos_theta_d = sqrt(0.5 + 0.5*cos_theta);
	float sin_theta_d = sqrt(0.5 - 0.5*cos_theta) * sign(sin_theta_o*cos_theta_i - cos_theta_o*sin_theta_i);

	// sin(θ_i) = η*sin(θ_t) (Longitudinal Inclination Angle) (via Snell's Law)
	float cos_theta_t = sqrt(max(0, 1.0 - sin_theta_i*sin_theta_i/(ETA*ETA)));

	float eta_prime = sqrt(ETA*ETA - sin_theta_d*sin_theta_d) / cos_theta_d; // 'Effective' Index of Refraction
	float eta_prime_inv = 1.0 / eta_prime;

	// The cross-section offset is the perpendicular distance of an incoming ray from a hair strand's
	// center axis. It is normalized to the strand's radius (i.e., in [-1..1]).
	vec3 cross_section_offset = compute_cross_section_offset(cos_phi_half, sin_phi_half, eta_prime_inv);

	// Note: The longitudinal and azimuthal scattering components per lobe (i.e., R, TT, TRT) are multiplied
	//       together and summed via matrix-vector multiplication.
	return azimuthal_scattering(cos_theta_t, cos_theta_d, cos_phi, sin_phi, cos_phi_half, eta_prime_inv, absorbtion_coefficient, beta[N], cross_section_offset)
		* (longitudinal_scattering(cos_theta_i, sin_theta_i, cos_theta_o, sin_theta_o, cos_theta_d, sin_theta_d, cos_phi_half, alpha, beta[M], cross_section_offset) * lobe_scales);
}