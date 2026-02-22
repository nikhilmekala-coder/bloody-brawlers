extends Control

## Main Menu for Bloody Brawler — Create Party, Join Party, Start Game
## Premium UI with large touch-friendly buttons for mobile + PC

var _title_label: Label
var _subtitle_label: Label
var _create_btn: Button
var _join_btn: Button
var _start_btn: Button
var _code_label: Label
var _numpad_container: GridContainer
var _entered_code: String = ""
var _code_display: Label
var _status_label: Label
var _back_btn: Button
var _submit_code_btn: Button
var _server_input: LineEdit
var _vbox: VBoxContainer

enum MenuState { MAIN, HOST_WAITING, JOIN_INPUT, LOBBY }
var _state: int = MenuState.MAIN

func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.05, 0.03, 0.07))
	_build_ui()
	_set_state(MenuState.MAIN)
	var nm = get_node_or_null("/root/NetworkManager")
	if nm:
		nm.room_created.connect(_on_room_created)
		nm.room_joined.connect(_on_room_joined)
		nm.player_connected.connect(_on_player_connected)
		nm.player_disconnected.connect(_on_player_disconnected)
		nm.game_start.connect(_on_game_start)
		nm.connection_error.connect(_on_connection_error)
	get_viewport().size_changed.connect(_on_viewport_resized)

func _build_ui() -> void:
	anchor_left = 0; anchor_top = 0
	anchor_right = 1; anchor_bottom = 1
	offset_left = 0; offset_top = 0
	offset_right = 0; offset_bottom = 0

	# ── Rich dark background ──
	var bg = ColorRect.new()
	bg.anchor_left = 0; bg.anchor_top = 0
	bg.anchor_right = 1; bg.anchor_bottom = 1
	bg.color = Color(0.05, 0.03, 0.07)
	add_child(bg)

	# ── Blood accent bar at top ──
	var accent_bar = ColorRect.new()
	accent_bar.anchor_left = 0; accent_bar.anchor_top = 0
	accent_bar.anchor_right = 1; accent_bar.anchor_bottom = 0
	accent_bar.offset_top = 0; accent_bar.offset_bottom = 5
	accent_bar.color = Color(0.85, 0.12, 0.08)
	add_child(accent_bar)

	# ── ScrollContainer for small screens ──
	var scroll = ScrollContainer.new()
	scroll.anchor_left = 0; scroll.anchor_top = 0
	scroll.anchor_right = 1; scroll.anchor_bottom = 1
	scroll.offset_left = 0; scroll.offset_top = 0
	scroll.offset_right = 0; scroll.offset_bottom = 0
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	# ── Center container ──
	var center_wrap = CenterContainer.new()
	center_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center_wrap.custom_minimum_size = Vector2(0, 640)
	scroll.add_child(center_wrap)

	_vbox = VBoxContainer.new()
	_vbox.name = "MainVBox"
	_vbox.custom_minimum_size = Vector2(460, 0)
	_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_vbox.add_theme_constant_override("separation", 20)
	center_wrap.add_child(_vbox)

	# ── Title ──
	_title_label = Label.new()
	_title_label.text = "BLOODY\nBRAWLER"
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", 72)
	_title_label.add_theme_color_override("font_color", Color(0.92, 0.12, 0.08))
	_vbox.add_child(_title_label)

	# ── Subtitle ──
	_subtitle_label = Label.new()
	_subtitle_label.text = "⚔  ONLINE PvP  ⚔"
	_subtitle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle_label.add_theme_font_size_override("font_size", 26)
	_subtitle_label.add_theme_color_override("font_color", Color(0.65, 0.55, 0.45))
	_vbox.add_child(_subtitle_label)

	# ── Divider ──
	var divider = ColorRect.new()
	divider.custom_minimum_size = Vector2(0, 2)
	divider.color = Color(0.25, 0.15, 0.12, 0.6)
	_vbox.add_child(divider)

	# ── Server URL ──
	var server_label = Label.new()
	server_label.text = "SERVER"
	server_label.add_theme_font_size_override("font_size", 16)
	server_label.add_theme_color_override("font_color", Color(0.45, 0.4, 0.5))
	_vbox.add_child(server_label)

	_server_input = LineEdit.new()
	if OS.has_feature("web"):
		var host = JavaScriptBridge.eval("window.location.host", true)
		if host and str(host) != "":
			_server_input.text = "wss://" + str(host)
		else:
			_server_input.text = "wss://localhost:8080"
	else:
		_server_input.text = "wss://localhost:8080"
	_server_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_server_input.custom_minimum_size = Vector2(0, 56)
	_server_input.add_theme_font_size_override("font_size", 20)
	_apply_input_style(_server_input)
	_vbox.add_child(_server_input)

	# ── Create Party button ──
	_create_btn = Button.new()
	_create_btn.text = "🎮  CREATE PARTY"
	_create_btn.custom_minimum_size = Vector2(0, 72)
	_apply_btn_style(_create_btn, Color(0.18, 0.50, 0.88))
	_create_btn.pressed.connect(_on_create_pressed)
	_vbox.add_child(_create_btn)

	# ── Join Party button ──
	_join_btn = Button.new()
	_join_btn.text = "🔗  JOIN PARTY"
	_join_btn.custom_minimum_size = Vector2(0, 72)
	_apply_btn_style(_join_btn, Color(0.18, 0.72, 0.38))
	_join_btn.pressed.connect(_on_join_pressed)
	_vbox.add_child(_join_btn)

	# ── Code display (for entering code & showing host code) ──
	_code_label = Label.new()
	_code_label.text = "_ _ _ _ _ _"
	_code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_code_label.add_theme_font_size_override("font_size", 48)
	_code_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	_code_label.custom_minimum_size = Vector2(0, 60)
	_code_label.visible = false
	_vbox.add_child(_code_label)

	# ── Numpad ──
	_numpad_container = GridContainer.new()
	_numpad_container.columns = 3
	_numpad_container.add_theme_constant_override("h_separation", 12)
	_numpad_container.add_theme_constant_override("v_separation", 12)
	_numpad_container.visible = false
	_vbox.add_child(_numpad_container)

	for i in range(1, 10):
		var btn = Button.new()
		btn.text = str(i)
		btn.custom_minimum_size = Vector2(100, 72)
		_apply_btn_style(btn, Color(0.20, 0.18, 0.28))
		btn.add_theme_font_size_override("font_size", 34)
		btn.pressed.connect(_on_numpad_pressed.bind(str(i)))
		_numpad_container.add_child(btn)

	var back_del_btn = Button.new()
	back_del_btn.text = "⌫"
	back_del_btn.custom_minimum_size = Vector2(100, 72)
	_apply_btn_style(back_del_btn, Color(0.6, 0.18, 0.18))
	back_del_btn.add_theme_font_size_override("font_size", 34)
	back_del_btn.pressed.connect(_on_numpad_backspace)
	_numpad_container.add_child(back_del_btn)

	var zero_btn = Button.new()
	zero_btn.text = "0"
	zero_btn.custom_minimum_size = Vector2(100, 72)
	_apply_btn_style(zero_btn, Color(0.20, 0.18, 0.28))
	zero_btn.add_theme_font_size_override("font_size", 34)
	zero_btn.pressed.connect(_on_numpad_pressed.bind("0"))
	_numpad_container.add_child(zero_btn)

	_submit_code_btn = Button.new()
	_submit_code_btn.text = "JOIN →"
	_submit_code_btn.custom_minimum_size = Vector2(100, 72)
	_apply_btn_style(_submit_code_btn, Color(0.18, 0.72, 0.38))
	_submit_code_btn.add_theme_font_size_override("font_size", 26)
	_submit_code_btn.pressed.connect(_on_submit_code_pressed)
	_numpad_container.add_child(_submit_code_btn)

	# ── Room code display (host) ──
	_code_display = Label.new()
	_code_display.text = ""
	_code_display.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_code_display.add_theme_font_size_override("font_size", 56)
	_code_display.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	_code_display.visible = false
	_vbox.add_child(_code_display)

	# ── Status label ──
	_status_label = Label.new()
	_status_label.text = ""
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 24)
	_status_label.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_vbox.add_child(_status_label)

	# ── Start Game button ──
	_start_btn = Button.new()
	_start_btn.text = "⚔  START GAME"
	_start_btn.custom_minimum_size = Vector2(0, 80)
	_apply_btn_style(_start_btn, Color(0.85, 0.18, 0.12))
	_start_btn.add_theme_font_size_override("font_size", 30)
	_start_btn.pressed.connect(_on_start_pressed)
	_start_btn.disabled = true
	_start_btn.visible = false
	_vbox.add_child(_start_btn)

	# ── Back button ──
	_back_btn = Button.new()
	_back_btn.text = "←  BACK"
	_back_btn.custom_minimum_size = Vector2(0, 60)
	_apply_btn_style(_back_btn, Color(0.35, 0.35, 0.40))
	_back_btn.pressed.connect(_on_back_pressed)
	_back_btn.visible = false
	_vbox.add_child(_back_btn)

	# Blood splatter decor
	_add_blood_decor()

func _apply_btn_style(btn: Button, color: Color) -> void:
	btn.add_theme_font_size_override("font_size", 28)
	var normal = StyleBoxFlat.new()
	normal.bg_color = color
	normal.corner_radius_top_left = 12; normal.corner_radius_top_right = 12
	normal.corner_radius_bottom_left = 12; normal.corner_radius_bottom_right = 12
	normal.content_margin_left = 20; normal.content_margin_right = 20
	normal.content_margin_top = 8; normal.content_margin_bottom = 8
	# Subtle shadow
	normal.shadow_color = Color(0, 0, 0, 0.3)
	normal.shadow_size = 4
	normal.shadow_offset = Vector2(0, 3)
	btn.add_theme_stylebox_override("normal", normal)
	var hover = normal.duplicate()
	hover.bg_color = color.lightened(0.18)
	hover.shadow_size = 6
	btn.add_theme_stylebox_override("hover", hover)
	var pressed_s = normal.duplicate()
	pressed_s.bg_color = color.darkened(0.12)
	pressed_s.shadow_size = 2
	btn.add_theme_stylebox_override("pressed", pressed_s)
	var disabled_s = normal.duplicate()
	disabled_s.bg_color = Color(0.25, 0.25, 0.28, 0.5)
	disabled_s.shadow_size = 0
	btn.add_theme_stylebox_override("disabled", disabled_s)
	btn.add_theme_color_override("font_color", Color.WHITE)
	btn.add_theme_color_override("font_disabled_color", Color(0.5, 0.5, 0.5))

func _apply_input_style(input: LineEdit) -> void:
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.08, 0.14)
	sb.border_color = Color(0.35, 0.25, 0.50)
	sb.border_width_bottom = 3; sb.border_width_top = 3
	sb.border_width_left = 3; sb.border_width_right = 3
	sb.corner_radius_top_left = 10; sb.corner_radius_top_right = 10
	sb.corner_radius_bottom_left = 10; sb.corner_radius_bottom_right = 10
	sb.content_margin_left = 16; sb.content_margin_right = 16
	sb.content_margin_top = 8; sb.content_margin_bottom = 8
	input.add_theme_stylebox_override("normal", sb)
	var focus = sb.duplicate()
	focus.border_color = Color(0.6, 0.4, 0.9)
	input.add_theme_stylebox_override("focus", focus)
	input.add_theme_color_override("font_color", Color.WHITE)
	input.add_theme_color_override("font_placeholder_color", Color(0.5, 0.5, 0.5))

func _add_blood_decor() -> void:
	for i in range(12):
		var drop = Polygon2D.new()
		var cx = randf_range(30, 1250)
		var cy = randf_range(8, 80)
		var r = randf_range(5, 18)
		var pts = PackedVector2Array()
		for j in 8:
			var a = j * TAU / 8.0
			pts.append(Vector2(cos(a), sin(a)) * r)
		drop.polygon = pts
		drop.position = Vector2(cx, cy)
		drop.color = Color(0.65, 0.04, 0.04, randf_range(0.2, 0.55))
		add_child(drop)

func _on_viewport_resized() -> void:
	var vp = get_viewport().get_visible_rect().size
	var is_landscape = vp.x > vp.y
	# Scale vbox width based on viewport
	var target_w = min(vp.x * 0.85, 600.0) if is_landscape else min(vp.x * 0.90, 500.0)
	if _vbox:
		_vbox.custom_minimum_size.x = target_w

# ══════════  STATE MANAGEMENT  ══════════

func _set_state(new_state: int) -> void:
	_state = new_state
	match _state:
		MenuState.MAIN:
			_create_btn.visible = true
			_join_btn.visible = true
			_code_label.visible = false
			_numpad_container.visible = false
			_code_display.visible = false
			_start_btn.visible = false
			_back_btn.visible = false
			_status_label.text = ""

		MenuState.HOST_WAITING:
			_create_btn.visible = false
			_join_btn.visible = false
			_code_label.visible = false
			_numpad_container.visible = false
			_code_display.visible = true
			_start_btn.visible = true
			_start_btn.disabled = true
			_back_btn.visible = true
			_status_label.text = "Waiting for Player 2..."

		MenuState.JOIN_INPUT:
			_create_btn.visible = false
			_join_btn.visible = false
			_code_label.visible = true
			_numpad_container.visible = true
			_entered_code = ""
			_update_code_display()
			_code_display.visible = false
			_start_btn.visible = false
			_back_btn.visible = true
			_status_label.text = "Tap digits to enter room code"

		MenuState.LOBBY:
			_create_btn.visible = false
			_join_btn.visible = false
			_code_label.visible = false
			_numpad_container.visible = false
			_back_btn.visible = true
			var nm = get_node_or_null("/root/NetworkManager")
			if nm and nm.is_host:
				_start_btn.visible = true
				_start_btn.disabled = false
				_status_label.text = "2 players ready! Press START"
			else:
				_start_btn.visible = false
				_status_label.text = "Waiting for host to start..."

# ══════════  BUTTON HANDLERS  ══════════

func _on_create_pressed() -> void:
	var nm = get_node_or_null("/root/NetworkManager")
	if not nm:
		_status_label.text = "Error: NetworkManager not found!"
		return
	_status_label.text = "Connecting..."
	nm.connect_to_server(_server_input.text)
	if not await _wait_for_connection(nm):
		_status_label.text = "Failed to connect!"
		return
	nm.create_room()

func _on_join_pressed() -> void:
	_set_state(MenuState.JOIN_INPUT)

func _on_submit_code_pressed() -> void:
	_on_code_submitted(_entered_code)

func _on_numpad_pressed(digit: String) -> void:
	if _entered_code.length() < 6:
		_entered_code += digit
		_update_code_display()

func _on_numpad_backspace() -> void:
	if _entered_code.length() > 0:
		_entered_code = _entered_code.substr(0, _entered_code.length() - 1)
		_update_code_display()

func _update_code_display() -> void:
	var display = ""
	for i in range(6):
		if i < _entered_code.length():
			display += _entered_code[i]
		else:
			display += "_"
		if i < 5:
			display += " "
	_code_label.text = display

func _on_code_submitted(code: String) -> void:
	if code.length() != 6:
		_status_label.text = "Code must be 6 digits!"
		return
	var nm = get_node_or_null("/root/NetworkManager")
	if not nm:
		_status_label.text = "Error: NetworkManager not found!"
		return
	_status_label.text = "Connecting..."
	nm.connect_to_server(_server_input.text)
	if not await _wait_for_connection(nm):
		_status_label.text = "Failed to connect!"
		return
	nm.join_room(code)
	_status_label.text = "Joining room " + code + "..."

func _on_start_pressed() -> void:
	var nm = get_node_or_null("/root/NetworkManager")
	if nm and nm.is_host:
		nm.start_game()

func _on_back_pressed() -> void:
	var nm = get_node_or_null("/root/NetworkManager")
	if nm:
		nm.leave_room()
		nm.disconnect_from_server()
	_set_state(MenuState.MAIN)

# ══════════  NETWORK CALLBACKS  ══════════

func _on_room_created(code: String) -> void:
	_code_display.text = code
	_set_state(MenuState.HOST_WAITING)

func _on_room_joined() -> void:
	_status_label.text = "Joined! Waiting for host..."

func _on_player_connected() -> void:
	var nm = get_node_or_null("/root/NetworkManager")
	if nm and nm.player_count >= 2:
		_set_state(MenuState.LOBBY)

func _on_player_disconnected() -> void:
	var nm = get_node_or_null("/root/NetworkManager")
	if nm and nm.is_host:
		_set_state(MenuState.HOST_WAITING)
		_status_label.text = "Player 2 disconnected..."
	else:
		_set_state(MenuState.MAIN)
		_status_label.text = "Host disconnected."

func _on_game_start() -> void:
	get_tree().change_scene_to_file("res://main.tscn")

func _on_connection_error(msg: String) -> void:
	_status_label.text = "Error: " + msg

# ══════════  HELPERS  ══════════

func _wait_for_connection(nm, timeout: float = 3.0) -> bool:
	var elapsed := 0.0
	while elapsed < timeout:
		if nm._connected_to_server:
			return true
		await get_tree().create_timer(0.1).timeout
		elapsed += 0.1
	return false
