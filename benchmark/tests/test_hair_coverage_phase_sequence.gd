extends SceneTree

## Verifies the 16-step Bayer phase mapping used by the TAA-aligned benchmark.
const BAYER := [
	0.01 / 16.0, 8.0 / 16.0, 2.0 / 16.0, 10.0 / 16.0,
	12.0 / 16.0, 4.0 / 16.0, 14.0 / 16.0, 6.0 / 16.0,
	3.0 / 16.0, 11.0 / 16.0, 1.0 / 16.0, 9.0 / 16.0,
	15.0 / 16.0, 7.0 / 16.0, 13.0 / 16.0, 5.0 / 16.0,
]

func _initialize() -> void:
	var seen: Dictionary = {}
	for phase in 16:
		var ox := phase & 3
		var oy := (phase >> 2) & 3
		var index := oy * 4 + ox
		seen[BAYER[index]] = true
	if seen.size() != 16:
		push_error("16-phase Bayer sequence did not visit all thresholds")
		quit(1)
		return

	var legacy_seen: Dictionary = {}
	for phase in 16:
		var diagonal := phase & 3
		var index := diagonal * 4 + diagonal
		legacy_seen[BAYER[index]] = true
	if legacy_seen.size() != 4:
		push_error("Legacy diagonal phase model changed unexpectedly")
		quit(1)
		return

	print("HAIR_COVERAGE_PHASE_SEQUENCE_OK")
	quit(0)
