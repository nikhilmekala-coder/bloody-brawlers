extends Node

## Autoload singleton managing WebSocket connection to relay server.
## Host-authoritative model: client sends inputs, host sends snapshots.

signal room_created(code: String)
signal room_joined()
signal player_connected()
signal player_disconnected()
signal game_start()
signal restart_received()
signal connection_error(msg: String)

# Host-authoritative signals
signal input_received(data: Dictionary)      # Host receives client inputs
signal snapshot_received(data: Dictionary)   # Client receives host snapshots

# Round / game-flow signals
signal round_reset_received(data: Dictionary)
signal round_win_received(data: Dictionary)
signal powerup_spawned(data: Dictionary)
signal powerup_despawned(data: Dictionary)
signal power_picked_received(data: Dictionary)
signal round_update_received(data: Dictionary)
signal match_end_received(data: Dictionary)
signal sudden_death_received()

# ── Round state persistence (survives scene reloads) ──
var round_state := {
	"player_wins": 0,
	"enemy_wins": 0,
	"current_round": 1,
	"match_active": true,
}

func reset_round_state() -> void:
	round_state = {
		"player_wins": 0,
		"enemy_wins": 0,
		"current_round": 1,
		"match_active": true,
	}

var is_host: bool = false
var room_code: String = ""
var connected: bool = false
var player_count: int = 0

var _ws: WebSocketPeer = null
var _server_url: String = "wss://localhost:8080"
var _connected_to_server: bool = false

func _ready() -> void:
	if OS.has_feature("web"):
		var host = JavaScriptBridge.eval("window.location.host", true)
		if host and host != "":
			_server_url = "wss://" + str(host)
			print("[NET] Auto-detected server URL: ", _server_url)
	set_process(true)

func _process(_delta: float) -> void:
	if _ws == null:
		return
	_ws.poll()
	var state = _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not _connected_to_server:
			_connected_to_server = true
			print("[NET] Connected to server")
		while _ws.get_available_packet_count() > 0:
			var pkt = _ws.get_packet()
			var text = pkt.get_string_from_utf8()
			_handle_message(text)
	elif state == WebSocketPeer.STATE_CLOSING:
		pass
	elif state == WebSocketPeer.STATE_CLOSED:
		if _connected_to_server:
			_connected_to_server = false
			connected = false
			print("[NET] Disconnected from server")
			connection_error.emit("Disconnected from server")
		_ws = null

# ══════════  PUBLIC API  ══════════

func connect_to_server(url: String = "") -> void:
	if url != "":
		_server_url = url
	_ws = WebSocketPeer.new()
	var err = _ws.connect_to_url(_server_url)
	if err != OK:
		print("[NET] Failed to connect: ", err)
		connection_error.emit("Failed to connect to server")
		_ws = null

func create_room() -> void:
	is_host = true
	_send({"type": "create_room"})

func join_room(code: String) -> void:
	is_host = false
	room_code = code
	_send({"type": "join_room", "code": code})

func start_game() -> void:
	if is_host:
		_send({"type": "start_game"})

## Client sends input to host (lightweight, only when changed)
func send_input(data: Dictionary) -> void:
	data["type"] = "input"
	_send(data)

## Host sends snapshot to client (20Hz, full state of both fighters)
func send_snapshot(data: Dictionary) -> void:
	data["type"] = "snapshot"
	_send(data)

## Host sends damage event (authoritative HP update)
func send_damage(data: Dictionary) -> void:
	data["type"] = "damage"
	_send(data)

## Host sends round reset to client
func send_round_reset(data: Dictionary) -> void:
	data["type"] = "round_reset"
	_send(data)

## Host sends round win info to client
func send_round_win(data: Dictionary) -> void:
	data["type"] = "round_win"
	_send(data)

## Host sends powerup spawn to client
func send_powerup_spawn(data: Dictionary) -> void:
	data["type"] = "powerup_spawn"
	_send(data)

func send_restart() -> void:
	_send({"type": "restart"})

func leave_room() -> void:
	_send({"type": "leave_room"})
	room_code = ""
	connected = false
	player_count = 0
	is_host = false

func disconnect_from_server() -> void:
	if _ws:
		_ws.close()
	_ws = null
	_connected_to_server = false
	connected = false

# ══════════  INTERNAL  ══════════

func _send(data: Dictionary) -> void:
	if _ws and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send_text(JSON.stringify(data))

func _handle_message(text: String) -> void:
	var json = JSON.new()
	var err = json.parse(text)
	if err != OK:
		print("[NET] Invalid JSON: ", text)
		return
	var data: Dictionary = json.data
	var msg_type = data.get("type", "")

	match msg_type:
		"room_created":
			room_code = data.get("code", "")
			connected = true
			player_count = 1
			print("[NET] Room created: ", room_code)
			room_created.emit(room_code)

		"room_joined":
			connected = true
			room_code = data.get("code", room_code)
			print("[NET] Joined room: ", room_code)
			room_joined.emit()

		"player_connected":
			player_count = data.get("count", player_count + 1)
			print("[NET] Player connected, count: ", player_count)
			player_connected.emit()

		"player_disconnected":
			player_count = data.get("count", max(0, player_count - 1))
			print("[NET] Player disconnected, count: ", player_count)
			player_disconnected.emit()

		"game_start":
			print("[NET] Game starting!")
			game_start.emit()

		"input":
			input_received.emit(data)

		"snapshot":
			snapshot_received.emit(data)

		"damage":
			# Client receives authoritative damage from host
			snapshot_received.emit(data)  # Also process as state update

		"round_reset":
			print("[NET] Round reset received!")
			round_reset_received.emit(data)

		"round_win":
			print("[NET] Round win received!")
			round_win_received.emit(data)

		"powerup_spawn":
			powerup_spawned.emit(data)

		"power_despawn":
			powerup_despawned.emit(data)

		"power_picked":
			power_picked_received.emit(data)

		"round_update":
			round_update_received.emit(data)

		"match_end":
			match_end_received.emit(data)

		"sudden_death":
			sudden_death_received.emit()

		"restart":
			print("[NET] Restart received!")
			restart_received.emit()

		"error":
			var msg = data.get("message", "Unknown error")
			print("[NET] Server error: ", msg)
			connection_error.emit(msg)

		_:
			print("[NET] Unknown message type: ", msg_type)
