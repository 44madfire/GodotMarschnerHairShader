extends RefCounted
class_name HairCoveragePolicy

## Coverage strategy shared by HairMaterialProfile and HairCoverageController.
##
## AUTO prefers alpha-to-coverage when 3D MSAA is enabled, otherwise temporal
## Bayer when TAA is enabled, otherwise stable Bayer. Explicit modes are useful
## for debugging or projects that intentionally override viewport AA policy.
enum Mode {
	AUTO = 0,
	STATIC_BAYER = 1,
	TAA_BAYER = 2,
	ALPHA_TO_COVERAGE = 3,
}

const TAA_PHASE_COUNT: int = 16


static func resolve(viewport: Viewport, requested_mode: int = Mode.AUTO) -> int:
	var mode: int = clampi(requested_mode, Mode.AUTO, Mode.ALPHA_TO_COVERAGE)
	if mode != Mode.AUTO:
		return mode
	if viewport != null and viewport.msaa_3d != Viewport.MSAA_DISABLED:
		return Mode.ALPHA_TO_COVERAGE
	if viewport != null and viewport.use_taa:
		return Mode.TAA_BAYER
	return Mode.STATIC_BAYER


static func bayer_phase(effective_mode: int, rendered_frame_index: int) -> int:
	if effective_mode != Mode.TAA_BAYER:
		return 0
	return maxi(rendered_frame_index, 0) & (TAA_PHASE_COUNT - 1)


static func uses_alpha_to_coverage(effective_mode: int) -> bool:
	return effective_mode == Mode.ALPHA_TO_COVERAGE


static func mode_name(effective_mode: int) -> String:
	match effective_mode:
		Mode.STATIC_BAYER:
			return "static_bayer"
		Mode.TAA_BAYER:
			return "taa_bayer"
		Mode.ALPHA_TO_COVERAGE:
			return "alpha_to_coverage"
	return "auto"
