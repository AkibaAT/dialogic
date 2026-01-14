class_name DialogicRollbackEvent
extends DialogicEvent

enum Modes {BLOCK, UNBLOCK}

var mode: Modes = Modes.BLOCK

func _init() -> void:
	event_name = "Rollback"
	event_description = "Controls rollback behavior. Block prevents rollback past this point, Unblock allows it again."
	set_default_color('Color4')
	event_category = "Logic"
	event_sorting_index = 10
	help_page_path = "https://docs.dialogic.pro/rollback.html"

func _execute() -> void:
	match mode:
		Modes.BLOCK:
			dialogic.Rollback.block_rollback()
		Modes.UNBLOCK:
			dialogic.Rollback.unblock_rollback()
	finish()

func get_shortcode() -> String:
	return "rollback"

func get_shortcode_parameters() -> Dictionary:
	return {
		"mode": {"property": "mode", "default": Modes.BLOCK,
				"suggestions": func(): return {"Block":{'value':Modes.BLOCK}, "Unblock":{'value':Modes.UNBLOCK}}}
	}

func _load_from_string(string: String) -> void:
	var regex := RegEx.new()
	regex.compile("mode=(.+)")
	var result := regex.search(string)
	if result:
		var mode_str := result.get_string().split("=")[1].strip_edges()
		if mode_str == "Unblock":
			mode = Modes.UNBLOCK
		else:
			mode = Modes.BLOCK

func _to_string() -> String:
	return "{rollback mode=" + ("Block" if mode == Modes.BLOCK else "Unblock") + "}"

func get_required_subsystems() -> Array:
	return ["Rollback"]

func get_event_color() -> Color:
	return DialogicUtil.get_color('Color4')

func get_event_name() -> String:
	return "Rollback"

func build_event_editor() -> void:
	add_header_edit("mode", ValueType.FIXED_OPTIONS, {'left_text': 'Mode:', 'options': [
		{"label": "Block", "value": Modes.BLOCK, "icon": null},
		{"label": "Unblock", "value": Modes.UNBLOCK, "icon": null}
	]})
	add_body_edit("", ValueType.LABEL, {"text": "Prevents rollback past this point in the story."}, "mode == Modes.BLOCK")
	add_body_edit("", ValueType.LABEL, {"text": "Allows rollback again after being blocked."}, "mode == Modes.UNBLOCK")
