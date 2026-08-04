extends SceneTree

## Deterministic depth-contract validation for the FAST_MARSCHNER_DUAL_SCATTER
## slice.
##
## Source contract (attributes_texture.g): 0 = deep, 1 = shallow. The dual
## slice maps depth monotonically to a deepness proxy (1 - depth) so DEEP
## strands receive the greater/equal local density response.
##
## Checks:
##   1. The committed shader include actually contains the deepness mapping
##      (source-contract pin; fails if the shader drifts).
##   2. Endpoint assertions: deepness(0) = 1, deepness(1) = 0, and the
##      resulting local density with the profile density factor.
##   3. Monotonicity over a deterministic depth grid: deeper depth always maps
##      to strictly greater deepness and greater/equal local density.
##   4. The Blowout attributes texture's G channel is read (never mutated) and
##      reported, so the packed data is known to exist.
##
## Run with: godot --headless --path <project> --script res://benchmark/tools/validate_dual_scatter_depth_contract.gd

const INCLUDE_PATH := "res://assets/hair/materials/shaders/hair_marschner_fast.gdshaderinc"
const DEPTH_GRID_STEP := 0.05

var _failures: PackedStringArray = []


func _initialize() -> void:
	_check_shader_contract()
	_check_mapping_math()
	_check_attributes_texture()
	if _failures.is_empty():
		print("DUAL_DEPTH_CONTRACT_OK")
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _check_shader_contract() -> void:
	var include_text: String = FileAccess.get_file_as_string(INCLUDE_PATH)
	if include_text.is_empty():
		_failures.append("could not read " + INCLUDE_PATH)
		return
	if not include_text.contains("float deepness = 1.0 - clamp(depth, 0.0, 1.0);"):
		_failures.append("shader include no longer contains the explicit deepness mapping (1 - depth)")
	else:
		print("CONTRACT_EVIDENCE shader_contains_deepness_mapping=true")
	if not include_text.contains("* (1.0 - view_alignment) * 0.5;") or include_text.contains("(1.0 - abs(view_alignment))"):
		_failures.append("dual backward scattering must peak for opposing light/view alignment without abs() suppression")
	else:
		print("CONTRACT_EVIDENCE backward_lobe_opposing_alignment=true")


## Mirrors the shader's deepness/local-density expressions exactly.
func _deepness(depth: float) -> float:
	return 1.0 - clampf(depth, 0.0, 1.0)


func _local_density(depth: float, density: float) -> float:
	return _deepness(depth) * clampf(density, 0.0, 1.0)


func _check_mapping_math() -> void:
	# Endpoints.
	if not is_equal_approx(_deepness(0.0), 1.0):
		_failures.append("deepness(0) must be 1 (deep strand, full density response), got %s" % _deepness(0.0))
	if not is_equal_approx(_deepness(1.0), 0.0):
		_failures.append("deepness(1) must be 0 (shallow strand), got %s" % _deepness(1.0))
	if not is_equal_approx(_deepness(0.5), 0.5):
		_failures.append("deepness(0.5) must be 0.5, got %s" % _deepness(0.5))
	# Monotonicity over a deterministic grid: deeper (smaller) depth must map to
	# strictly greater deepness, and greater/equal local density.
	var previous_deepness := 2.0
	var previous_density := 1e9
	var grid_points := 0
	var depth_value := 0.0
	while depth_value <= 1.0:
		var deepness := _deepness(depth_value)
		if deepness >= previous_deepness:
			_failures.append("deepness must strictly decrease as depth increases (monotonic), failed at depth %s" % depth_value)
		var density_value := _local_density(depth_value, 0.5)
		if density_value > previous_density:
			_failures.append("local density must be non-increasing for increasing depth at %s" % depth_value)
		previous_deepness = deepness
		previous_density = density_value
		grid_points += 1
		depth_value += DEPTH_GRID_STEP
	# Deep-vs-shallow response assertion.
	if _local_density(0.0, 1.0) < _local_density(1.0, 1.0):
		_failures.append("deep strands must receive greater/equal local density than shallow strands")
	print("CONTRACT_EVIDENCE grid_points=%d deepness(0)=%.3f deepness(1)=%.3f local_density(0,1)=%.3f local_density(1,1)=%.3f" % [
		grid_points, _deepness(0.0), _deepness(1.0), _local_density(0.0, 1.0), _local_density(1.0, 1.0),
	])


func _check_attributes_texture() -> void:
	# Read-only: confirm the packed G channel data exists on the Blowout groom
	# (the dual slice reads it through the strand_depth varying). Never mutated.
	var attributes_texture: Texture2D = load("res://assets/hair/models/blowout/blowout_attrib.png") as Texture2D
	if attributes_texture == null:
		_failures.append("Blowout attributes texture failed to load")
		return
	var image: Image = attributes_texture.get_image()
	if image == null or image.get_width() <= 0:
		_failures.append("Blowout attributes texture has no readable image")
		return
	var min_g := 1.0
	var max_g := 0.0
	var sample_count := 0
	for y in image.get_height():
		for x in image.get_width():
			var pixel: Color = image.get_pixel(x, y)
			min_g = minf(min_g, pixel.g)
			max_g = maxf(max_g, pixel.g)
			sample_count += 1
	print("CONTRACT_EVIDENCE attributes_g_channel_min=%.3f max=%.3f samples=%d (read-only)" % [min_g, max_g, sample_count])
	if sample_count == 0:
		_failures.append("attributes texture has no pixels")
