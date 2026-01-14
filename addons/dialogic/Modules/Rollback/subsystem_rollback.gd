extends DialogicSubsystem

const DEFAULT_HISTORY_SIZE := 100
const DEBUG_ENABLED := true  # Set to false to disable debug logging

var history_snapshots: Array = []
var history_index: int = -1
var is_in_rollback := false
var rollback_blocked: bool = false
var block_snapshot_index: int = -1

var mouse_wheel_enabled: bool = true
var waiting_for_advance: bool = false  # After rollback, next click should advance

# Debug: track call counts to detect loops
var _debug_frame_call_counts := {}
var _debug_last_frame := -1

signal rollback_performed(steps: int)
signal rollforward_performed(steps: int)
signal rollback_blocked_signal()
signal rollback_unblocked()

func _debug_log(msg: String, func_name: String = "") -> void:
	if not DEBUG_ENABLED:
		return
	var frame := Engine.get_process_frames()
	# Reset counts each frame
	if frame != _debug_last_frame:
		_debug_frame_call_counts.clear()
		_debug_last_frame = frame
	# Track call count per function per frame
	if func_name:
		_debug_frame_call_counts[func_name] = _debug_frame_call_counts.get(func_name, 0) + 1
		var count: int = _debug_frame_call_counts[func_name]
		if count > 10:
			push_error("[Rollback] LOOP DETECTED! %s called %d times in frame %d" % [func_name, count, frame])
		print("[Rollback][F%d][#%d] %s" % [frame, count, msg])
	else:
		print("[Rollback][F%d] %s" % [frame, msg])

func _ready():
	mouse_wheel_enabled = ProjectSettings.get_setting("dialogic/rollback/mouse_wheel_enabled", true)


func post_install() -> void:
	# Connect to signals after all subsystems are installed
	# Snapshot when text finishes revealing (game is waiting for click to continue)
	if dialogic.has_subsystem('Text'):
		dialogic.Text.text_finished.connect(_on_text_finished)
	# Snapshot when choices are shown (so we can roll back to choice selection)
	if dialogic.has_subsystem('Choices'):
		dialogic.Choices.question_shown.connect(_on_question_shown)
		dialogic.Choices.choice_selected.connect(_on_choice_selected)
	# Handle user advancing (for rollback continuation)
	if dialogic.has_subsystem('Inputs'):
		dialogic.Inputs.dialogic_action.connect(_on_user_advance)

func _on_text_finished(info: Dictionary) -> void:
	_debug_log("_on_text_finished: ENTER (event_idx=%s, info_text='%s', info_character='%s')" % [
		dialogic.current_event_idx,
		info.get('text', '').substr(0, 30),
		info.get('character', '')
	], "_on_text_finished")
	# Take a snapshot when text finishes revealing - this is when game waits for input
	if is_in_rollback:
		_debug_log("_on_text_finished: EXIT - is_in_rollback", "_on_text_finished")
		return
	if dialogic.current_timeline == null:
		_debug_log("_on_text_finished: EXIT - no timeline", "_on_text_finished")
		return
	if waiting_for_advance:
		# Don't snapshot right after rollback - wait for user to advance first
		_debug_log("_on_text_finished: EXIT - waiting_for_advance", "_on_text_finished")
		return
	_debug_log("_on_text_finished: taking snapshot with info override", "_on_text_finished")
	# Pass the info from the signal - this contains the correct text/speaker
	# at the moment text_finished was emitted, which may differ from current_state_info
	# if multiple events processed rapidly
	take_snapshot(info)

func _on_question_shown(_info: Dictionary) -> void:
	_debug_log("_on_question_shown: ENTER (event_idx=%s, state=%s)" % [dialogic.current_event_idx, dialogic.current_state], "_on_question_shown")
	# Take a snapshot when choices are shown - allows rolling back to choice selection
	if is_in_rollback:
		_debug_log("_on_question_shown: EXIT - is_in_rollback", "_on_question_shown")
		return
	if dialogic.current_timeline == null:
		_debug_log("_on_question_shown: EXIT - no timeline", "_on_question_shown")
		return
	if waiting_for_advance:
		_debug_log("_on_question_shown: EXIT - waiting_for_advance", "_on_question_shown")
		return
	_debug_log("_on_question_shown: taking snapshot for choice state", "_on_question_shown")
	take_snapshot()

func _on_choice_selected(_info: Dictionary) -> void:
	# When selecting a choice after rolling back, discard any future snapshots
	# so rollbacks target the new branch correctly.
	if is_in_rollback:
		return
	if history_index > 0:
		var discard_count := history_index
		_debug_log("_on_choice_selected: discarding %d future snapshots (history_index was %d)" % [discard_count, history_index], "_on_choice_selected")
		for i in range(discard_count):
			history_snapshots.pop_front()
		if block_snapshot_index >= 0:
			block_snapshot_index -= discard_count
			if block_snapshot_index < 0:
				block_snapshot_index = -1
				rollback_blocked = false
		_debug_log("_on_choice_selected: history rewritten, new size=%d" % history_snapshots.size(), "_on_choice_selected")
	history_index = -1

func _input(event: InputEvent):
	if not mouse_wheel_enabled:
		return
	if not dialogic.current_timeline:
		return
	if dialogic.paused:
		return

	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.pressed:
			if mouse_event.button_index == MOUSE_BUTTON_WHEEL_UP:
				_debug_log("_input: WHEEL_UP detected, calling rollback(1)", "_input")
				rollback(1)
			elif mouse_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_debug_log("_input: WHEEL_DOWN detected, calling rollforward(1)", "_input")
				rollforward(1)

func clear_game_state(_clear_flag := DialogicGameHandler.ClearFlags.FULL_CLEAR) -> void:
	_debug_log("clear_game_state: ENTER (is_in_rollback=%s)" % is_in_rollback, "clear_game_state")
	# Don't clear history during rollback - we need it to navigate back/forward
	if is_in_rollback:
		_debug_log("clear_game_state: EXIT - skipping, is_in_rollback=true", "clear_game_state")
		return
	history_snapshots.clear()
	history_index = -1
	rollback_blocked = false
	block_snapshot_index = -1
	waiting_for_advance = false
	_debug_log("clear_game_state: EXIT - cleared all state", "clear_game_state")

func save_game_state() -> void:
	# Rollback state is session-specific and should NOT be saved into snapshots
	# or game saves. This prevents recursive/nested history data.
	_debug_log("save_game_state: SKIP - rollback state is session-specific", "save_game_state")
	pass

func load_game_state(_load_flag := LoadFlags.FULL_LOAD) -> void:
	# Rollback state is session-specific and should NOT be loaded from snapshots
	# or game saves. The current session's history is managed separately.
	_debug_log("load_game_state: SKIP - rollback state is session-specific", "load_game_state")
	pass

func _on_user_advance():
	_debug_log("_on_user_advance: ENTER (is_in_rollback=%s, waiting_for_advance=%s, current_state=%s)" % [is_in_rollback, waiting_for_advance, dialogic.current_state], "_on_user_advance")

	# After rollback, first click advances to next event
	# (Snapshotting is handled by _on_state_changed when we reach IDLE)
	if not waiting_for_advance:
		_debug_log("_on_user_advance: EXIT - not waiting_for_advance", "_on_user_advance")
		return
	if is_in_rollback:
		_debug_log("_on_user_advance: EXIT - is_in_rollback", "_on_user_advance")
		return
	# Check if we're in WAITING state (chat layout) or IDLE state (normal layout)
	var is_waiting_state := dialogic.current_state == DialogicGameHandler.States.WAITING
	var is_idle_state := dialogic.current_state == DialogicGameHandler.States.IDLE

	if not is_waiting_state and not is_idle_state:
		_debug_log("_on_user_advance: EXIT - not IDLE or WAITING (state=%d)" % dialogic.current_state, "_on_user_advance")
		return

	waiting_for_advance = false
	# Discard future history now - user has committed to this timeline
	# history_index = N means we're viewing snapshot[N], so indices 0 to N-1 are "future"
	if history_index > 0:  # Only discard if there's actually future to discard
		var discard_count := history_index  # NOT +1, we keep the snapshot we're viewing
		_debug_log("_on_user_advance: discarding %d future snapshots (history_index was %d)" % [discard_count, history_index], "_on_user_advance")
		for i in range(discard_count):
			history_snapshots.pop_front()
		if block_snapshot_index >= 0:
			block_snapshot_index -= discard_count
			if block_snapshot_index < 0:
				block_snapshot_index = -1
				rollback_blocked = false
		_debug_log("_on_user_advance: history rewritten, new size=%d" % history_snapshots.size(), "_on_user_advance")
	history_index = -1

	if is_waiting_state:
		# Chat layout: we set WAITING state to prevent auto-advance, so WE must call handle_next_event()
		dialogic.current_state = DialogicGameHandler.States.IDLE
		_debug_log("_on_user_advance: calling handle_next_event() (was WAITING state)", "_on_user_advance")
		dialogic.handle_next_event()
		# If the next event is a choice, show it immediately so we don't require a second click.
		# Defer the check so the choice event has time to execute.
		call_deferred("_ensure_choice_visible_after_rollback")
		_debug_log("_on_user_advance: EXIT - after handle_next_event()", "_on_user_advance")
	else:
		# Normal layout: if no event is currently active, advance manually.
		if not dialogic.has_meta("previous_event"):
			_debug_log("_on_user_advance: calling handle_next_event() (no active event)", "_on_user_advance")
			dialogic.handle_next_event()
		_debug_log("_on_user_advance: EXIT - history reset", "_on_user_advance")

func _ensure_choice_visible_after_rollback() -> void:
	if dialogic.current_state != DialogicGameHandler.States.AWAITING_CHOICE:
		return
	if not dialogic.has_subsystem('Choices'):
		return
	var any_choice_visible := get_tree().get_nodes_in_group('dialogic_choice_button').any(func(node): return node.is_visible_in_tree())
	if not any_choice_visible:
		_debug_log("_ensure_choice_visible_after_rollback: forcing choice reveal", "_ensure_choice_visible_after_rollback")
		dialogic.Choices.show_current_question(true)

func take_snapshot(text_info: Dictionary = {}) -> void:
	_debug_log("take_snapshot: ENTER (history size=%d, history_index=%d)" % [history_snapshots.size(), history_index], "take_snapshot")

	var snapshot := dialogic.get_full_state().duplicate(true)

	# If text_info was provided (from text_finished signal), use it to override
	# the text and speaker in the snapshot. This ensures we capture the correct
	# state at the moment the signal was emitted, not whatever might be in
	# current_state_info now (which could be from a subsequent event).
	if not text_info.is_empty():
		if text_info.has('text'):
			snapshot['text'] = text_info['text']
		if text_info.has('character'):
			snapshot['speaker'] = text_info['character']
		_debug_log("take_snapshot: applied text_info override (text='%s', speaker='%s')" % [
			text_info.get('text', '').substr(0, 30),
			text_info.get('character', '')
		], "take_snapshot")

	# Log what we're capturing for debugging character mix-ups
	var snap_speaker: String = snapshot.get('speaker', '')
	var snap_text: String = snapshot.get('text', '')
	_debug_log("take_snapshot: capturing speaker='%s', text='%s...'" % [snap_speaker, snap_text.substr(0, 50) if snap_text.length() > 50 else snap_text], "take_snapshot")
	# Strip node references from portrait data - nodes are recreated on load
	# and keeping references to freed nodes causes issues
	if snapshot.has('portraits'):
		for char_id in snapshot['portraits']:
			if snapshot['portraits'][char_id] is Dictionary:
				snapshot['portraits'][char_id].erase('node')
	# Save the current state (IDLE, AWAITING_CHOICE, etc.) - needed for choice restoration
	snapshot['_rollback_state'] = dialogic.current_state

	# Save layout-specific history if the layout supports it (e.g., phone/chat layouts)
	if dialogic.has_subsystem('Styles'):
		var layout := dialogic.Styles.get_layout_node()
		if layout and layout.has_method('get_history'):
			snapshot['_layout_history'] = layout.get_history()
			_debug_log("take_snapshot: saved layout history", "take_snapshot")

	history_snapshots.push_front(snapshot)
	var max_size: int = ProjectSettings.get_setting("dialogic/rollback/history_size", DEFAULT_HISTORY_SIZE)
	if history_snapshots.size() > max_size:
		history_snapshots.pop_back()
		# Adjust block index if it was shifted out
		if block_snapshot_index >= max_size:
			block_snapshot_index = -1
			rollback_blocked = false
	# Increment block index since we inserted at front
	if block_snapshot_index >= 0:
		block_snapshot_index += 1
	history_index = -1
	_debug_log("take_snapshot: EXIT (new history size=%d)" % history_snapshots.size(), "take_snapshot")

func rollback(steps: int = 1) -> bool:
	_debug_log("rollback: ENTER (steps=%d, is_in_rollback=%s, history_index=%d, history_size=%d)" % [steps, is_in_rollback, history_index, history_snapshots.size()], "rollback")
	# Prevent concurrent rollbacks - apply_snapshot is async
	if is_in_rollback:
		_debug_log("rollback: EXIT - already in rollback", "rollback")
		return false
	if steps <= 0:
		_debug_log("rollback: EXIT - steps <= 0", "rollback")
		return false
	if history_snapshots.is_empty():
		_debug_log("rollback: EXIT - no snapshots", "rollback")
		return false

	# Calculate new index
	# From live state: snapshot[0] is the current state, so roll back 1 → index 1 (previous)
	# From index N: roll back 1 → index N+1
	var new_index: int
	if history_index < 0:
		new_index = steps  # NOT steps-1, because index 0 is current state
	else:
		new_index = history_index + steps

	# Bounds check
	if new_index >= history_snapshots.size():
		_debug_log("rollback: EXIT - would exceed history bounds (new_index=%d, size=%d)" % [new_index, history_snapshots.size()], "rollback")
		return false

	# Block check
	if rollback_blocked and block_snapshot_index >= 0:
		if new_index > block_snapshot_index:
			_debug_log("rollback: EXIT - blocked by block_snapshot_index", "rollback")
			rollback_blocked_signal.emit()
			return false

	history_index = new_index
	_debug_log("rollback: applying snapshot at index %d" % history_index, "rollback")
	var snapshot: Dictionary = history_snapshots[history_index]
	apply_snapshot(snapshot)
	rollback_performed.emit(steps)
	_debug_log("rollback: EXIT - success", "rollback")
	return true

func rollforward(steps: int = 1) -> bool:
	_debug_log("rollforward: ENTER (steps=%d, is_in_rollback=%s, history_index=%d)" % [steps, is_in_rollback, history_index], "rollforward")
	# Prevent concurrent rollbacks - apply_snapshot is async
	if is_in_rollback:
		_debug_log("rollforward: EXIT - already in rollback", "rollforward")
		return false
	if steps <= 0:
		_debug_log("rollforward: EXIT - steps <= 0", "rollforward")
		return false
	if history_index < 0:
		_debug_log("rollforward: EXIT - already at live state", "rollforward")
		return false
	if history_index == 0:
		# At most recent snapshot, can't roll forward (user must click to continue)
		_debug_log("rollforward: EXIT - at most recent snapshot, use click to continue", "rollforward")
		return false

	# Roll forward toward more recent snapshots
	var new_index := history_index - steps
	new_index = max(new_index, 0)  # Don't go below 0

	history_index = new_index
	_debug_log("rollforward: applying snapshot at index %d" % history_index, "rollforward")
	var snapshot: Dictionary = history_snapshots[history_index]
	apply_snapshot(snapshot)
	rollforward_performed.emit(steps)
	_debug_log("rollforward: EXIT - success", "rollforward")
	return true

func apply_snapshot(snapshot: Dictionary) -> void:
	_debug_log("apply_snapshot: ENTER", "apply_snapshot")
	is_in_rollback = true
	# Ensure any previously executed event disconnects its input/signal hooks.
	# Without this, stale event handlers can advance the timeline twice after rollback.
	_debug_log("apply_snapshot: cleaning up previous event", "apply_snapshot")
	dialogic._cleanup_previous_event()
	# Clear any pending choice reveal connections/timers from the previous state.
	if dialogic.has_subsystem('Choices'):
		var choices := dialogic.get_subsystem('Choices')
		choices.hide_all_choices()
		choices._choice_blocker.stop()
		if choices._choice_blocker.timeout.is_connected(choices.show_current_question):
			choices._choice_blocker.timeout.disconnect(choices.show_current_question)
		if dialogic.has_subsystem('Inputs') and dialogic.Inputs.dialogic_action.is_connected(choices.show_current_question):
			dialogic.Inputs.dialogic_action.disconnect(choices.show_current_question)

	# Clear subsystems that only add/update but don't remove existing elements
	# Portraits: load_game_state only adds characters, doesn't remove ones not in snapshot
	# Audio: load_game_state only updates channels in saved state, doesn't stop others
	_debug_log("apply_snapshot: clearing Portraits and Audio", "apply_snapshot")
	if dialogic.has_subsystem('Portraits'):
		dialogic.get_subsystem('Portraits').clear_game_state()
	if dialogic.has_subsystem('Audio'):
		dialogic.get_subsystem('Audio').clear_game_state()

	# Restore state
	_debug_log("apply_snapshot: restoring current_state_info", "apply_snapshot")
	dialogic.current_state_info = snapshot.duplicate(true)
	# Clear text sub-index so the next Text event doesn't skip revealing.
	dialogic.current_state_info.erase("text_sub_idx")

	# Load subsystem states (this restores text, backgrounds, portraits, etc.)
	# Styles first, then others
	_debug_log("apply_snapshot: loading Styles subsystem", "apply_snapshot")
	if dialogic.has_subsystem('Styles'):
		dialogic.get_subsystem('Styles').load_game_state()

	_debug_log("apply_snapshot: awaiting process_frame", "apply_snapshot")
	await get_tree().process_frame
	_debug_log("apply_snapshot: after process_frame", "apply_snapshot")

	# Check EARLY if layout has history - we need to know before loading subsystems
	# For layouts with history (e.g., chat layouts), the text is shown as panels,
	# so we don't want the Text subsystem to set DialogText which could trigger signals
	var layout_has_history := false
	if snapshot.has('_layout_history') and dialogic.has_subsystem('Styles'):
		var layout := dialogic.Styles.get_layout_node()
		if layout and layout.has_method('load_history'):
			layout_has_history = true
			_debug_log("apply_snapshot: detected layout with history - will skip Text subsystem", "apply_snapshot")

	_debug_log("apply_snapshot: loading other subsystems", "apply_snapshot")
	for subsystem in dialogic.get_children():
		if subsystem.name == 'Styles' or subsystem.name == 'Rollback':
			continue
		# Skip Text subsystem for layouts with history - text is shown as panels
		if subsystem.name == 'Text' and layout_has_history:
			_debug_log("apply_snapshot: SKIPPING subsystem Text (layout has history)", "apply_snapshot")
			continue
		_debug_log("apply_snapshot: loading subsystem %s" % subsystem.name, "apply_snapshot")
		(subsystem as DialogicSubsystem).load_game_state()

	# Restore layout-specific history if the layout supports it (e.g., phone/chat layouts)
	if layout_has_history and dialogic.has_subsystem('Styles'):
		var layout := dialogic.Styles.get_layout_node()
		if layout:
			if layout.has_method('clear'):
				_debug_log("apply_snapshot: clearing layout", "apply_snapshot")
				layout.clear()
			if layout.has_method('load_history'):
				_debug_log("apply_snapshot: loading layout history", "apply_snapshot")
				layout.load_history(snapshot['_layout_history'])

	# Set up timeline if needed
	var timeline_path: String = dialogic.current_state_info.get('current_timeline', '')
	var saved_event_idx: int = dialogic.current_state_info.get('current_event_idx', 0)
	_debug_log("apply_snapshot: timeline=%s, event_idx=%d" % [timeline_path, saved_event_idx], "apply_snapshot")

	if timeline_path and (dialogic.current_timeline == null or dialogic.current_timeline.resource_path != timeline_path):
		_debug_log("apply_snapshot: loading new timeline", "apply_snapshot")
		var timeline = load(timeline_path)
		if timeline:
			timeline.process()
			dialogic.current_timeline = timeline
			dialogic.current_timeline_events = dialogic.current_timeline.events
			for event in dialogic.current_timeline_events:
				event.dialogic = dialogic

	# Set position - user will click to advance to next event
	if dialogic.current_timeline and saved_event_idx >= 0:
		dialogic.current_event_idx = saved_event_idx

	# Restore the game state (IDLE, AWAITING_CHOICE, etc.)
	var saved_state: int = snapshot.get('_rollback_state', DialogicGameHandler.States.IDLE)
	_debug_log("apply_snapshot: restoring state=%d (AWAITING_CHOICE=%d)" % [saved_state, DialogicGameHandler.States.AWAITING_CHOICE], "apply_snapshot")

	# If we were at a choice, show the choices again
	if saved_state == DialogicGameHandler.States.AWAITING_CHOICE and dialogic.has_subsystem('Choices'):
		_debug_log("apply_snapshot: restoring AWAITING_CHOICE - showing choices", "apply_snapshot")
		dialogic.current_state = DialogicGameHandler.States.AWAITING_CHOICE
		dialogic.Choices.show_current_question(true)
		# For choices, we don't set waiting_for_advance - user selects a choice instead
		is_in_rollback = false
		waiting_for_advance = false
		_debug_log("apply_snapshot: EXIT - choice state restored", "apply_snapshot")
		return

	# Handle text bubble styles - they need about_to_show_text signal for proper positioning
	# Skip this for layouts with history (e.g., chat layouts) since text is already shown as panels
	var text_content: String = dialogic.current_state_info.get('text', '')

	if layout_has_history:
		_debug_log("apply_snapshot: skipping text display - layout has history (messages shown as panels)", "apply_snapshot")
	# If there's no text, ensure bubbles are hidden (they may have stale state)
	elif text_content.is_empty():
		if dialogic.has_subsystem('Styles'):
			var layout := dialogic.Styles.get_layout_node()
			if layout and 'bubbles' in layout:
				_debug_log("apply_snapshot: no text content, hiding all bubbles", "apply_snapshot")
				for bubble in layout.bubbles:
					bubble.current_character = null
					if bubble.visible:
						bubble.hide()
						bubble.set_process(false)
	elif dialogic.has_subsystem('Text'):
		var speaker_id: String = dialogic.current_state_info.get('speaker', '')
		var character: DialogicCharacter = null
		if not speaker_id.is_empty():
			character = DialogicResourceUtil.get_character_resource(speaker_id)
			if character == null:
				push_warning("[Rollback] Could not find character resource for speaker_id: '%s'" % speaker_id)
		var portrait_name: String = ''
		if character and dialogic.current_state_info.has('portraits'):
			# Portraits are keyed by character identifier, not resource_path
			var char_portrait_info: Dictionary = dialogic.current_state_info['portraits'].get(character.get_identifier(), {})
			portrait_name = char_portrait_info.get('portrait', '')
		_debug_log("apply_snapshot: emitting about_to_show_text (speaker_id='%s', character=%s, character_path=%s)" % [speaker_id, character, character.resource_path if character else "null"], "apply_snapshot")
		# Reset text bubbles before showing new text - they may have stale current_character values
		if dialogic.has_subsystem('Styles'):
			var layout := dialogic.Styles.get_layout_node()
			if layout and 'bubbles' in layout:
				_debug_log("apply_snapshot: resetting %d text bubbles" % layout.bubbles.size(), "apply_snapshot")
				for bubble in layout.bubbles:
					bubble.current_character = null
					if bubble.visible:
						bubble.hide()
						bubble.set_process(false)
			# Debug: check if text bubble layout has this character registered
			if layout and 'registered_characters' in layout:
				var registered: Dictionary = layout.registered_characters
				_debug_log("apply_snapshot: layout has %d registered characters" % registered.size(), "apply_snapshot")
				for reg_char in registered:
					var matches := "NO MATCH"
					if reg_char == character:
						matches = "MATCH!"
					elif reg_char and character and reg_char.resource_path == character.resource_path:
						matches = "SAME PATH, DIFFERENT INSTANCE"
					_debug_log("apply_snapshot:   registered: %s (path=%s) -> %s" % [reg_char, reg_char.resource_path if reg_char else "null", matches], "apply_snapshot")
		dialogic.Text.about_to_show_text.emit({
			'text': text_content,
			'character': character,
			'portrait': portrait_name,
			'append': false
		})
		# Also emit started_revealing_text on text nodes to trigger bubble resize
		# (normally this fires from reveal_text(), but we set text directly during rollback)
		await get_tree().process_frame
		_debug_log("apply_snapshot: emitting started_revealing_text on text nodes for resize", "apply_snapshot")
		for text_node in get_tree().get_nodes_in_group('dialogic_dialog_text'):
			if text_node.has_signal('started_revealing_text'):
				text_node.started_revealing_text.emit()
		_debug_log("apply_snapshot: finished emitting started_revealing_text", "apply_snapshot")

	is_in_rollback = false
	waiting_for_advance = true  # Next click will advance to next event

	# For chat layouts, set state to WAITING to prevent Dialogic from auto-advancing
	# (since there's no text being displayed, IDLE state would cause immediate advance)
	if layout_has_history:
		dialogic.current_state = DialogicGameHandler.States.WAITING
		_debug_log("apply_snapshot: set state to WAITING for chat layout (prevents auto-advance)", "apply_snapshot")

	_debug_log("apply_snapshot: EXIT (is_in_rollback=%s, waiting_for_advance=%s)" % [is_in_rollback, waiting_for_advance], "apply_snapshot")

func block_rollback() -> void:
	rollback_blocked = true
	block_snapshot_index = 0  # Current position (most recent snapshot)
	rollback_blocked_signal.emit()

func unblock_rollback() -> void:
	rollback_blocked = false
	block_snapshot_index = -1
	rollback_unblocked.emit()

func can_rollback() -> bool:
	if history_snapshots.is_empty():
		return false
	# Calculate what the new index would be
	# From live: need at least 2 snapshots (index 0 is current, index 1 is previous)
	# From index N: need snapshot at N+1
	var new_index: int
	if history_index < 0:
		new_index = 1  # Need index 1 (previous state), not 0 (current state)
	else:
		new_index = history_index + 1
	# Check bounds
	if new_index >= history_snapshots.size():
		return false
	# Check block
	if rollback_blocked and block_snapshot_index >= 0:
		if new_index > block_snapshot_index:
			return false
	return true

func can_rollforward() -> bool:
	# Can only roll forward if we've rolled back past index 0
	return history_index > 0

func get_rollback_position() -> float:
	if history_snapshots.is_empty():
		return 0.0
	if history_index < 0:
		return 0.0
	return float(history_index) / float(history_snapshots.size() - 1)

func get_history_count() -> int:
	return history_snapshots.size()

func get_undo_count() -> int:
	# How many steps back we are from live state
	return history_index + 1 if history_index >= 0 else 0

func get_redo_count() -> int:
	# How many steps we can roll forward (toward index 0)
	return history_index if history_index > 0 else 0
