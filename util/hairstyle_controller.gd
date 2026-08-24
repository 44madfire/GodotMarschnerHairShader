@tool
extends Node3D

const DEFAULT_HAIRSTYLE := 1

func _ready() -> void:
	if not Engine.is_editor_hint(): return
	for i in get_child_count():
		get_child(i).visible = i == DEFAULT_HAIRSTYLE

func _process(delta: float) -> void:
	if not Engine.is_editor_hint(): return

	# Only make the selected node(s) visible, make all others hidden.
	var selected_children: Array[Node] = Engine.get_singleton(&'EditorInterface') \
		.get_selection() \
		.get_selected_nodes() \
		.filter(func(x: Node) -> bool: return x.get_parent() == self)

	if selected_children.is_empty(): return

	for child in get_children():
		child.visible = child in selected_children

func _notification(what: int) -> void:
	if what == NOTIFICATION_EDITOR_PRE_SAVE:
		for i in get_child_count():
			get_child(i).visible = i == DEFAULT_HAIRSTYLE
