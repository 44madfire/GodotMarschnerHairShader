extends Node

## Optional command-line entry point. Editor/manual runs are unaffected unless
## a user argument explicitly supplies --suite=<res path>.

@export var controller_path: NodePath = NodePath("../BenchmarkController")

var _suite_path := ""
var _quit_on_complete := false


func _ready() -> void:
	_parse_user_arguments()
	if _suite_path.is_empty():
		return
	call_deferred("_start_requested_suite")


func _parse_user_arguments() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--suite="):
			_suite_path = argument.trim_prefix("--suite=").strip_edges()
		elif argument == "--quit-on-complete":
			_quit_on_complete = true


func _start_requested_suite() -> void:
	var controller: Node = get_node_or_null(controller_path)
	if not controller or not controller.has_method(&"start_suite"):
		push_error("Benchmark CLI could not find a controller with start_suite().")
		_quit_with_error_if_requested()
		return

	var suite: Resource = load(_suite_path) as Resource
	if not suite:
		push_error("Benchmark CLI could not load suite resource: %s" % _suite_path)
		_quit_with_error_if_requested()
		return

	if controller.has_signal(&"suite_completed"):
		controller.connect(&"suite_completed", Callable(self, "_on_suite_completed"))
	var started: bool = controller.start_suite(suite)
	if not started:
		_quit_with_error_if_requested()


func _on_suite_completed(success: bool, _suite_id: StringName) -> void:
	if _quit_on_complete:
		get_tree().quit(0 if success else 1)


func _quit_with_error_if_requested() -> void:
	if _quit_on_complete:
		get_tree().quit(1)
