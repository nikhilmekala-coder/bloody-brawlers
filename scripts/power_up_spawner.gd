extends Node2D
class_name PowerUpSpawner

## HOST-AUTHORITATIVE power-up spawner with ROLE-RELATIVE positioning.
## Host sends offset_x from arena center. Each device computes world_x:
##   Host:   world_x = arena_center + offset_x
##   Client: world_x = arena_center - offset_x  (mirrored for Blue-left rule)
## Only one power-up can exist at a time.

const ARENA_CENTER_X = 640.0
const MAX_OFFSET = 400.0
const MIN_OFFSET = 60.0
const SPAWN_Y_ABOVE_GROUND = 40.0

var ground_y: float = 340.0
var player: Fighter
var enemy: Fighter
var current_powerup: PowerUp = null
var is_host: bool = true
var _current_powerup_id: int = 0

var _spawn_timer: Timer

func _ready() -> void:
	_spawn_timer = Timer.new()
	_spawn_timer.one_shot = true
	_spawn_timer.timeout.connect(_on_spawn_timer)
	add_child(_spawn_timer)
	_restart_timer()

func _restart_timer() -> void:
	_spawn_timer.wait_time = randf_range(5.0, 10.0)
	_spawn_timer.start()

func _on_spawn_timer() -> void:
	if not is_host:
		_restart_timer()
		return
	if is_instance_valid(current_powerup):
		_restart_timer()
		return
	_spawn_powerup_as_host()
	_restart_timer()

func _spawn_powerup_as_host() -> void:
	var ptype = PowerUp.Type.HEALTH if randf() < 0.5 else PowerUp.Type.SPEED
	var offset_x = randf_range(-MAX_OFFSET, MAX_OFFSET)
	if abs(offset_x) < MIN_OFFSET:
		offset_x = MIN_OFFSET * sign(offset_x) if offset_x != 0.0 else MIN_OFFSET
	offset_x = clampf(offset_x, -MAX_OFFSET, MAX_OFFSET)

	_current_powerup_id += 1
	var pid = _current_powerup_id

	# Host renders at center + offset
	var world_x = ARENA_CENTER_X + offset_x
	var world_y = ground_y - SPAWN_Y_ABOVE_GROUND
	_create_powerup(ptype, Vector2(world_x, world_y), pid, true)

	# Send offset (NOT world pos) to client
	var nm = get_node_or_null("/root/NetworkManager")
	if nm and nm.connected:
		nm.send_powerup_spawn({
			"ptype": ptype,
			"offset_x": snapped(offset_x, 0.1),
			"y": snapped(world_y, 0.1),
			"id": pid,
		})

## Client receives spawn — computes MIRRORED position from offset
func spawn_from_network(data: Dictionary) -> void:
	if is_instance_valid(current_powerup):
		return
	var ptype: int = data.get("ptype", 0)
	var offset_x: float = data.get("offset_x", 0.0)
	var py: float = data.get("y", ground_y - SPAWN_Y_ABOVE_GROUND)
	var pid: int = data.get("id", 0)

	# CLIENT renders at center MINUS offset (role-relative mirror)
	var world_x = ARENA_CENTER_X - offset_x
	_create_powerup(ptype as PowerUp.Type, Vector2(world_x, py), pid, false)

func _create_powerup(ptype: PowerUp.Type, pos: Vector2, pid: int, host_side: bool) -> void:
	var powerup := PowerUp.new()
	powerup.name = "ActivePowerUp"
	powerup.type = ptype
	powerup.is_host_powerup = host_side  # Client = false → no collision monitoring
	powerup.set_meta("powerup_id", pid)
	powerup.global_position = pos
	get_parent().add_child(powerup)
	current_powerup = powerup
	powerup.tree_exiting.connect(_on_powerup_removed)

## CLIENT: Host reports that someone picked up the powerup
func handle_power_picked(data: Dictionary) -> void:
	var pid: int = data.get("power_id", -1)
	if not is_instance_valid(current_powerup):
		return
	if not current_powerup.has_meta("powerup_id"):
		return
	if current_powerup.get_meta("powerup_id") != pid:
		return

	# Remove it visually on client
	current_powerup.picked_up = true

	# Apply effect to the correct LOCAL fighter instance
	# "host_player" picked it → that's the CLIENT's enemy (roles are swapped)
	# "host_enemy" picked it → that's the CLIENT's player
	var picked_by = data.get("picked_by", "")
	var target_fighter: Fighter = null
	if picked_by == "host_player":
		target_fighter = enemy  # Host's player = client's enemy
	elif picked_by == "host_enemy":
		target_fighter = player  # Host's enemy = client's player

	if target_fighter:
		var ptype_val = data.get("ptype", 0)
		if ptype_val == PowerUp.Type.HEALTH:
			target_fighter.apply_health_boost(100.0)
		else:
			target_fighter.apply_speed_boost(2.0, 5.0)

	# Sound
	var sm = get_node_or_null("/root/SoundManager")
	if sm:
		sm.play_powerup_pickup()

	current_powerup.queue_free()

## Called when other device picked up (legacy path — kept for compat)
func despawn_from_network(data: Dictionary) -> void:
	handle_power_picked(data)

func _on_powerup_removed() -> void:
	current_powerup = null
