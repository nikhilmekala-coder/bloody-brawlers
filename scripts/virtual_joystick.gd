extends Control
class_name VirtualJoystick

## Visible on-screen virtual joystick — supports both mouse and mobile touch.

signal joystick_input(direction: Vector2)
signal joystick_released()
signal joystick_flick(direction: Vector2, strength: float)

@export var base_color: Color = Color(1, 1, 1, 0.15)
@export var knob_color: Color = Color(1, 1, 1, 0.5)
@export var active_color: Color = Color(1, 1, 1, 0.7)
@export var label_text: String = ""
@export var base_radius: float = 65.0
@export var knob_radius: float = 22.0
@export var max_distance: float = 55.0

var _pressed: bool = false
var _knob_pos: Vector2 = Vector2.ZERO
var _center: Vector2 = Vector2.ZERO
var _press_start_time: float = 0.0
var _touch_index: int = -1  # tracks which finger is on this joystick

var direction: Vector2 = Vector2.ZERO
var magnitude: float = 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_center = size / 2.0

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_center = size / 2.0
		queue_redraw()

func _draw() -> void:
	var col = active_color if _pressed else base_color
	draw_circle(_center, base_radius, Color(0, 0, 0, 0.3))
	draw_arc(_center, base_radius, 0, TAU, 48, col, 2.5, true)
	var guide_col = Color(1, 1, 1, 0.08)
	draw_line(_center + Vector2(-base_radius * 0.6, 0), _center + Vector2(base_radius * 0.6, 0), guide_col, 1.0)
	draw_line(_center + Vector2(0, -base_radius * 0.6), _center + Vector2(0, base_radius * 0.6), guide_col, 1.0)
	var knob_pos = _center + _knob_pos
	var knob_col = active_color if _pressed else knob_color
	draw_circle(knob_pos, knob_radius, knob_col)
	draw_arc(knob_pos, knob_radius, 0, TAU, 24, Color(1, 1, 1, 0.6), 1.5, true)
	if label_text != "":
		var font = ThemeDB.fallback_font
		var fsize = 13
		var text_size = font.get_string_size(label_text, HORIZONTAL_ALIGNMENT_CENTER, -1, fsize)
		draw_string(font, _center + Vector2(-text_size.x / 2, base_radius + 20),
					label_text, HORIZONTAL_ALIGNMENT_CENTER, -1, fsize,
					Color(1, 1, 1, 0.35))

# ── Mouse input (desktop testing) ──
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_start_press(event.position)
			else:
				_end_press()
	elif event is InputEventMouseMotion and _pressed:
		_update_press(event.position)

# ── Touch input (mobile) ──
func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var local = event.position - global_position
		if event.pressed:
			# Only accept if touch is within our area and we're not already pressed
			if not _pressed and local.distance_to(_center) < base_radius * 1.5:
				_touch_index = event.index
				_start_press(local)
				get_viewport().set_input_as_handled()
		else:
			if event.index == _touch_index:
				_end_press()
				_touch_index = -1
				get_viewport().set_input_as_handled()

	elif event is InputEventScreenDrag:
		if event.index == _touch_index and _pressed:
			var local = event.position - global_position
			_update_press(local)
			get_viewport().set_input_as_handled()

# ── Shared logic ──
func _start_press(pos: Vector2) -> void:
	_pressed = true
	_press_start_time = Time.get_ticks_msec() / 1000.0
	_update_press(pos)

func _update_press(pos: Vector2) -> void:
	var offset = pos - _center
	var dist = offset.length()
	if dist > max_distance:
		offset = offset.normalized() * max_distance
		dist = max_distance
	_knob_pos = offset
	magnitude = dist / max_distance
	direction = offset.normalized() * magnitude if magnitude > 0.05 else Vector2.ZERO
	joystick_input.emit(direction)
	queue_redraw()

func _end_press() -> void:
	var elapsed = Time.get_ticks_msec() / 1000.0 - _press_start_time
	if elapsed < 0.3 and _knob_pos.length() > max_distance * 0.4:
		joystick_flick.emit(_knob_pos.normalized(), magnitude)
	_pressed = false
	_knob_pos = Vector2.ZERO
	direction = Vector2.ZERO
	magnitude = 0.0
	joystick_released.emit()
	queue_redraw()

func _process(_delta: float) -> void:
	if _pressed and magnitude > 0.05:
		joystick_input.emit(direction)
