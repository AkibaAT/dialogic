@tool
extends DialogicSettingsPage

@onready var history_size: SpinBox = $HistorySize
@onready var mouse_wheel_check: CheckBox = $MouseWheelCheck


func _get_title() -> String:
	return "Rollback"


func _get_priority() -> int:
	return 90


func _is_feature_tab() -> bool:
	return true


func _ready():
	history_size.value_changed.connect(_on_history_size_value_changed)
	mouse_wheel_check.toggled.connect(_on_mouse_wheel_check_toggled)


func _refresh() -> void:
	history_size.value = ProjectSettings.get_setting("dialogic/rollback/history_size", 100)
	mouse_wheel_check.button_pressed = ProjectSettings.get_setting("dialogic/rollback/mouse_wheel_enabled", true)


func _on_history_size_value_changed(value):
	ProjectSettings.set_setting("dialogic/rollback/history_size", int(value))
	ProjectSettings.save()


func _on_mouse_wheel_check_toggled(toggled_on):
	ProjectSettings.set_setting("dialogic/rollback/mouse_wheel_enabled", toggled_on)
	ProjectSettings.save()
