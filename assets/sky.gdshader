shader_type sky;
render_mode use_half_res_pass;

uniform vec3 background_color : source_color = vec3(0.0);
uniform vec3 backlight_color : source_color = vec3(0.225, 0.225, 0.265);
uniform float backlight_strength : hint_range(0.0, 10.0) = 1.0;

float phase_henyey_greenstein(float cos_theta, float g) {
	float g_sq = g * g, a = inversesqrt(1.0 + g_sq - 2.0 * g * cos_theta);
	return (1.0 - g_sq) * a*a*a / (4.0*PI);
}

void sky() {
	if (AT_HALF_RES_PASS) {
		COLOR += background_color;

		// --- Fake Backlight ---
		// A dim backlight is needed to prevent the hairstyle from blending into
		// the background due to low contrast.
		float back_d = max(dot(EYEDIR, -normalize(POSITION)), 0.0);
		COLOR += backlight_color * backlight_strength * pow(back_d, 4.0);

		// --- Fake Spotlight ---
		// The Henyey-Greenstein phase function is used here to simulate the
		// appearance of volumetric scattering between the camera and the light source.
		float dist = 1.0 / (1.0 + length(POSITION)*2.0);

		// Vary 'g' factor based on distance so that viewer isn't blinded lol.
		float isotropy = min(1.0 - 0.01*dist*dist, 0.999999) / (1.0 + LIGHT0_SIZE);
		float scattering = phase_henyey_greenstein(clamp(dot(EYEDIR, LIGHT0_DIRECTION), -0.9999, 0.9999), isotropy);
		COLOR += scattering * LIGHT0_COLOR * LIGHT0_ENERGY * float(LIGHT0_ENABLED);
	} else {
		COLOR = HALF_RES_COLOR.rgb;
	}
}