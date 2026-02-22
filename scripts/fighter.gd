extends Node2D
class_name Fighter

signal health_changed(current_hp: float, max_hp: float)
signal stamina_changed(current_st: float, max_st: float)
signal died()
signal hit_landed(hit_pos: Vector2, hit_dir: Vector2, damage: float, hit_body: RigidBody2D)

# --- Config ---
var fighter_color: Color = Color(0.85, 0.2, 0.2)
var facing: int = 1
var is_player: bool = true
var is_local: bool = true       # false for network-controlled remote players
var is_host_controlled: bool = false  # true when HOST runs physics for this remote fighter

var body_layer: int  = 2
var body_mask: int   = 1 | 4 | 16
var weapon_layer: int = 8
var weapon_mask: int  = 1 | 4

# --- Health ---
var health: float     = 500.0
var max_health: float = 500.0
var is_dead: bool     = false

# --- Stamina ---
var stamina: float      = 1000.0
var max_stamina: float  = 1000.0
const STAMINA_REGEN     = 150.0   # per second when not attacking
const STAMINA_COST      = 15.0    # per swing
const STAMINA_RED_THRESHOLD = 200.0  # flash warning below this

# --- Body ---
var parts: Dictionary = {}
var weapon_r: RigidBody2D
var weapon_l: RigidBody2D
var _hit_cooldown_r: float = 0.0
var _hit_cooldown_l: float = 0.0
var _spawn_global_y: float = 0.0
var _walk_phase: float = 0.0
var move_direction: float = 0.0
var MOVE_FORCE: float = 4200.0
var base_move_force: float = 4200.0
var speed_boost_active: bool = false
var is_attacking: bool = false

# ── Dimensions ──
const HEAD_R  = 16.0
const TORSO   = Vector2(26, 54)
const U_ARM   = Vector2(12, 30)
const L_ARM   = Vector2(10, 26)
const U_LEG   = Vector2(15, 34)
const L_LEG   = Vector2(13, 30)
const WEAPON  = Vector2(6, 48)

const ANG_DAMP = 5.0
const LIN_DAMP = 0.3
const WALK_STRIDE = 0.55
const WALK_KNEE_BEND = 0.7
const WALK_SPEED = 0.08

# ── Network sync ──
const SYNC_PARTS: Array = [
	"torso", "head",
	"uarm_r", "larm_r", "uarm_l", "larm_l",
	"uleg_front", "lleg_front", "uleg_back", "lleg_back"
]

# Interpolation buffer for client-side rendering of remote state
var _snapshot_buffer: Array = []  # Array of { "time": float, "parts": Dictionary }
const INTERP_DELAY = 0.08  # 80ms interpolation delay for smoothness
var _render_time: float = 0.0

func _ready() -> void:
	_build_ragdoll()
	_spawn_global_y = global_position.y

func _physics_process(delta: float) -> void:
	if is_dead:
		# Still interpolate dead remote bodies
		if not is_local and not is_host_controlled:
			_interpolate_from_buffer(delta)
		return

	# CLIENT rendering remote state from snapshots (frozen kinematic)
	if not is_local and not is_host_controlled:
		_interpolate_from_buffer(delta)
		return

	# LOCAL or HOST-CONTROLLED: run full physics
	_apply_muscles(delta)
	_apply_movement(delta)
	_regen_stamina(delta)
	if _hit_cooldown_r > 0: _hit_cooldown_r -= delta
	if _hit_cooldown_l > 0: _hit_cooldown_l -= delta

# ══════════════════  STAMINA  ══════════════════
func _regen_stamina(delta: float) -> void:
	if is_dead:
		return
	if stamina < max_stamina:
		stamina = min(stamina + STAMINA_REGEN * delta, max_stamina)
		stamina_changed.emit(stamina, max_stamina)

func use_stamina(amount: float) -> bool:
	if stamina < amount:
		return false
	stamina -= amount
	stamina_changed.emit(stamina, max_stamina)
	return true

# ══════════════════  BUILD  ══════════════════
func _build_ragdoll() -> void:
	parts["torso"] = _rect("Torso", Vector2.ZERO, TORSO, 4.0)

	var neck_y = -TORSO.y / 2.0
	parts["head"] = _circle("Head", Vector2(0, neck_y - HEAD_R), HEAD_R, 0.8)
	parts["head"].gravity_scale = 0.1
	_pin(parts["torso"], parts["head"], Vector2(0, neck_y))

	var sh_r = Vector2(facing * (TORSO.x / 2.0 + 2), neck_y + 10)
	parts["uarm_r"] = _rect("UArmR", sh_r + Vector2(0, U_ARM.y / 2.0), U_ARM, 1.0)
	_pin(parts["torso"], parts["uarm_r"], sh_r)
	var elbow_r = sh_r + Vector2(0, U_ARM.y)
	parts["larm_r"] = _rect("LArmR", elbow_r + Vector2(0, L_ARM.y / 2.0), L_ARM, 0.7)
	_pin(parts["uarm_r"], parts["larm_r"], elbow_r)
	var wrist_r = elbow_r + Vector2(0, L_ARM.y)
	weapon_r = _rect("WeaponR", wrist_r + Vector2(facing * WEAPON.y / 2.0, 0),
					Vector2(WEAPON.y, WEAPON.x), 1.2, Color(0.72, 0.72, 0.78))
	weapon_r.collision_layer = weapon_layer
	weapon_r.collision_mask  = weapon_mask
	weapon_r.contact_monitor = true
	weapon_r.max_contacts_reported = 4
	weapon_r.body_entered.connect(_on_weapon_hit_r)
	_pin(parts["larm_r"], weapon_r, wrist_r)

	var sh_l = Vector2(-facing * (TORSO.x / 2.0 + 2), neck_y + 10)
	parts["uarm_l"] = _rect("UArmL", sh_l + Vector2(0, U_ARM.y / 2.0), U_ARM, 1.0)
	_pin(parts["torso"], parts["uarm_l"], sh_l)
	var elbow_l = sh_l + Vector2(0, U_ARM.y)
	parts["larm_l"] = _rect("LArmL", elbow_l + Vector2(0, L_ARM.y / 2.0), L_ARM, 0.7)
	_pin(parts["uarm_l"], parts["larm_l"], elbow_l)
	var wrist_l = elbow_l + Vector2(0, L_ARM.y)
	weapon_l = _rect("WeaponL", wrist_l + Vector2(-facing * WEAPON.y / 2.0, 0),
					Vector2(WEAPON.y, WEAPON.x), 1.2, Color(0.55, 0.4, 0.25))
	weapon_l.collision_layer = weapon_layer
	weapon_l.collision_mask  = weapon_mask
	weapon_l.contact_monitor = true
	weapon_l.max_contacts_reported = 4
	weapon_l.body_entered.connect(_on_weapon_hit_l)
	_pin(parts["larm_l"], weapon_l, wrist_l)

	var hip_y = TORSO.y / 2.0
	for i in 2:
		var tag = "front" if i == 0 else "back"
		var xo  = 4.0 if i == 0 else -4.0
		var hip = Vector2(xo, hip_y)
		var ul = _rect("ULeg_" + tag, hip + Vector2(0, U_LEG.y / 2.0), U_LEG, 2.0)
		parts["uleg_" + tag] = ul
		_pin(parts["torso"], ul, hip)
		var knee = hip + Vector2(0, U_LEG.y)
		var ll = _rect("LLeg_" + tag, knee + Vector2(0, L_LEG.y / 2.0), L_LEG, 1.5)
		parts["lleg_" + tag] = ll
		_pin(ul, ll, knee)

	var all: Array = parts.values()
	all.append(weapon_r); all.append(weapon_l)
	for a_i in range(all.size()):
		for b_i in range(a_i + 1, all.size()):
			all[a_i].add_collision_exception_with(all[b_i])

	# Client-side remote fighters: freeze all physics, we position them via snapshots
	if not is_local and not is_host_controlled:
		_freeze_all_parts()

func _freeze_all_parts() -> void:
	for key in parts:
		var p: RigidBody2D = parts[key]
		p.freeze = true
		p.freeze_mode = RigidBody2D.FREEZE_MODE_KINEMATIC
	for w in [weapon_r, weapon_l]:
		w.freeze = true
		w.freeze_mode = RigidBody2D.FREEZE_MODE_KINEMATIC

# ══════════════════  VISUAL ROLE LOCKING  ══════════════════
## Call AFTER _build_ragdoll(). Sets color based on local/remote role.
## Local player = ALWAYS blue. Opponent = ALWAYS red.
## Snapshots NEVER override color — this is role-locked locally.
func apply_role(role_is_local: bool) -> void:
	var body_col: Color
	var wpn_r_col: Color
	var wpn_l_col: Color
	if role_is_local:
		body_col = Color(0.22, 0.52, 0.92)   # Blue
		wpn_r_col = Color(0.72, 0.72, 0.78)  # Silver sword
		wpn_l_col = Color(0.55, 0.4, 0.25)   # Wooden shield
	else:
		body_col = Color(0.88, 0.22, 0.18)   # Red
		wpn_r_col = Color(0.72, 0.72, 0.78)
		wpn_l_col = Color(0.55, 0.4, 0.25)
	fighter_color = body_col
	# Recolor all body parts (each has an outline Polygon2D + fill Polygon2D)
	for key in parts:
		_recolor_body(parts[key], body_col)
	_recolor_body(weapon_r, wpn_r_col)
	_recolor_body(weapon_l, wpn_l_col)

func _recolor_body(body: RigidBody2D, col: Color) -> void:
	# The fill polygon is the LAST Polygon2D child (outline is first)
	var polys: Array[Polygon2D] = []
	for child in body.get_children():
		if child is Polygon2D:
			polys.append(child)
	if polys.size() >= 2:
		# polys[0] = outline (dark), polys[1] = fill (colored)
		polys[1].color = col

# ══════════════════  HELPERS  ══════════════════
func _rect(n: String, pos: Vector2, sz: Vector2, m: float,
			col: Color = fighter_color) -> RigidBody2D:
	var b := RigidBody2D.new()
	b.name = n; b.position = pos; b.mass = m
	b.angular_damp = ANG_DAMP; b.linear_damp = LIN_DAMP
	b.collision_layer = body_layer; b.collision_mask = body_mask
	b.gravity_scale = 0.35
	b.continuous_cd = RigidBody2D.CCD_MODE_CAST_RAY
	var mat := PhysicsMaterial.new()
	mat.friction = 1.0; mat.bounce = 0.0
	b.physics_material_override = mat
	var cs := CollisionShape2D.new()
	var r := RectangleShape2D.new(); r.size = sz; cs.shape = r
	b.add_child(cs)
	var outline := Polygon2D.new()
	var ho = sz / 2.0 + Vector2(2, 2)
	outline.polygon = PackedVector2Array([
		Vector2(-ho.x, -ho.y), Vector2(ho.x, -ho.y),
		Vector2(ho.x,  ho.y),  Vector2(-ho.x,  ho.y)])
	outline.color = Color(0.05, 0.05, 0.08)
	b.add_child(outline)
	var v := Polygon2D.new()
	var h = sz / 2.0
	v.polygon = PackedVector2Array([
		Vector2(-h.x, -h.y), Vector2(h.x, -h.y),
		Vector2(h.x,  h.y),  Vector2(-h.x,  h.y)])
	v.color = col
	b.add_child(v)
	add_child(b)
	return b

func _circle(n: String, pos: Vector2, rad: float, m: float) -> RigidBody2D:
	var b := RigidBody2D.new()
	b.name = n; b.position = pos; b.mass = m
	b.angular_damp = ANG_DAMP; b.linear_damp = LIN_DAMP
	b.collision_layer = body_layer; b.collision_mask = body_mask
	b.gravity_scale = 0.35
	b.continuous_cd = RigidBody2D.CCD_MODE_CAST_RAY
	var mat := PhysicsMaterial.new()
	mat.friction = 1.0; mat.bounce = 0.0
	b.physics_material_override = mat
	var cs := CollisionShape2D.new()
	var c := CircleShape2D.new(); c.radius = rad; cs.shape = c
	b.add_child(cs)
	var outline := Polygon2D.new()
	var opts := PackedVector2Array()
	for i in 24:
		var a = i * TAU / 24.0
		opts.append(Vector2(cos(a), sin(a)) * (rad + 2))
	outline.polygon = opts; outline.color = Color(0.05, 0.05, 0.08)
	b.add_child(outline)
	var v := Polygon2D.new()
	var pts := PackedVector2Array()
	for i in 24:
		var a = i * TAU / 24.0
		pts.append(Vector2(cos(a), sin(a)) * rad)
	v.polygon = pts; v.color = fighter_color
	b.add_child(v)
	add_child(b)
	return b

func _pin(a: RigidBody2D, b_body: RigidBody2D, anchor: Vector2) -> PinJoint2D:
	var j := PinJoint2D.new()
	j.name = "J_" + a.name + "_" + b_body.name
	j.position = anchor
	j.disable_collision = true
	j.softness = 0.0
	add_child(j)
	j.node_a = j.get_path_to(a)
	j.node_b = j.get_path_to(b_body)
	return j

# ══════════════════  MUSCLES + WALK  ══════════════════
signal footstep(side: String)

var _smooth_speed: float = 0.0
var _idle_timer: float = 0.0
var _prev_walk_phase: float = 0.0

func _apply_muscles(delta: float) -> void:
	var torso: RigidBody2D = parts["torso"]
	var head: RigidBody2D = parts["head"]

	var y_err = torso.global_position.y - _spawn_global_y
	torso.apply_central_force(Vector2(0, -y_err * 800.0))
	torso.apply_central_force(Vector2(0, -torso.linear_velocity.y * 60.0))

	var desired_head_y = torso.global_position.y - TORSO.y / 2.0 - HEAD_R
	head.apply_central_force(Vector2(0, -(head.global_position.y - desired_head_y) * 500.0))
	head.apply_central_force(Vector2(-(head.global_position.x - torso.global_position.x) * 400.0, 0))

	var up_str = 8000.0 if is_attacking else 5000.0
	var up_damp = 60.0 if is_attacking else 40.0
	var tilt = 0.0
	if abs(move_direction) > 0.05 and not is_attacking:
		tilt = move_direction * 0.08
	torso.apply_torque(-(torso.rotation - tilt) * up_str)
	torso.apply_torque(-torso.angular_velocity * up_damp)

	var raw_speed = abs(torso.linear_velocity.x)
	_smooth_speed = lerp(_smooth_speed, raw_speed, delta * 10.0)
	if _smooth_speed < 2.0:
		_smooth_speed = 0.0

	var walk_blend = clampf(_smooth_speed / 70.0, 0.0, 1.0)

	if walk_blend > 0.03:
		_prev_walk_phase = _walk_phase
		_walk_phase += delta * _smooth_speed * 0.12
		_walk_phase = fmod(_walk_phase, TAU)

		if _prev_walk_phase < PI and _walk_phase >= PI:
			footstep.emit("right")
		if _walk_phase < _prev_walk_phase:
			footstep.emit("left")

		var r_phase = _walk_phase
		var r_hip = sin(r_phase) * 0.65 * walk_blend
		var r_knee = max(0.0, -cos(r_phase)) * 0.85 * walk_blend
		var r_plant = max(0.0, -sin(r_phase)) * 150.0 * walk_blend
		_drive_leg("front", r_hip, r_knee, r_plant, torso.rotation)

		var l_phase = _walk_phase + PI
		var l_hip = sin(l_phase) * 0.65 * walk_blend
		var l_knee = max(0.0, -cos(l_phase)) * 0.85 * walk_blend
		var l_plant = max(0.0, -sin(l_phase)) * 150.0 * walk_blend
		_drive_leg("back", l_hip, l_knee, l_plant, torso.rotation)

		var bob = sin(_walk_phase * 2.0) * 1.5 * walk_blend
		torso.apply_central_force(Vector2(0, bob))

		var arm_swing = sin(_walk_phase) * 0.25 * walk_blend
		_rest_arm("uarm_r", facing * (-PI / 5.0) - arm_swing, 250.0)
		_rest_arm("uarm_l", -facing * (-PI / 5.0) + arm_swing, 250.0)

		_idle_timer = 0.0
	else:
		_drive_leg("front", 0.0, 0.0, 0.0, torso.rotation)
		_drive_leg("back", 0.0, 0.0, 0.0, torso.rotation)
		_rest_arm("uarm_r", facing * (-PI / 5.0), 200.0)
		_rest_arm("uarm_l", -facing * (-PI / 5.0), 200.0)
		_idle_timer += delta
		var breath = sin(_idle_timer * 1.8) * 0.005
		torso.apply_torque(breath * 200.0)

	if is_attacking:
		torso.apply_central_force(Vector2(-torso.linear_velocity.x * 80.0, 0))
		for key in ["uleg_front", "uleg_back", "lleg_front", "lleg_back"]:
			var leg: RigidBody2D = parts[key]
			leg.apply_torque(-leg.rotation * 10000.0)
			leg.apply_torque(-leg.angular_velocity * 80.0)

func _drive_leg(tag: String, hip_angle: float, knee_angle: float, plant_force: float, torso_rot: float) -> void:
	var ul: RigidBody2D = parts["uleg_" + tag]
	var ll: RigidBody2D = parts["lleg_" + tag]
	var spread = 0.04 if tag == "front" else -0.04
	var upper_target = torso_rot + hip_angle + spread
	ul.apply_torque((upper_target - ul.rotation) * 6000.0)
	ul.apply_torque(-ul.angular_velocity * 35.0)
	var lower_target = upper_target + knee_angle
	ll.apply_torque((lower_target - ll.rotation) * 5000.0)
	ll.apply_torque(-ll.angular_velocity * 30.0)
	if plant_force > 0.0:
		ll.apply_central_force(Vector2(0, plant_force))

func _rest_arm(key: String, target: float, force: float) -> void:
	var arm: RigidBody2D = parts[key]
	arm.apply_torque((target - arm.rotation) * force)
	arm.apply_torque(-arm.angular_velocity * 8.0)

func _apply_movement(_delta: float) -> void:
	var torso: RigidBody2D = parts["torso"]
	if abs(move_direction) > 0.05:
		torso.apply_central_force(Vector2(move_direction * MOVE_FORCE, 0))
	else:
		var vx = torso.linear_velocity.x
		if abs(vx) > 1.0:
			torso.apply_central_force(Vector2(-vx * 120.0, 0))
		else:
			torso.linear_velocity.x = 0.0

# ══════════════════  COMBAT  ══════════════════
func swing_arm(side: String, drag_dir: Vector2, strength: float = 1.0) -> void:
	if is_dead:
		return
	# Only apply physics impulses on devices running physics for this fighter
	if not is_local and not is_host_controlled:
		return
	# Check stamina — host-authoritative
	if is_local or is_host_controlled:
		if not use_stamina(STAMINA_COST):
			return  # Not enough stamina

	var uarm: RigidBody2D = parts["uarm_" + side]
	var larm: RigidBody2D = parts["larm_" + side]
	var wpn: RigidBody2D = weapon_r if side == "r" else weapon_l

	# Use move_direction sign for torque, not facing (facing is fixed at spawn)
	var dir_sign = sign(move_direction) if abs(move_direction) > 0.05 else facing
	var torque_dir = drag_dir.x * dir_sign
	var torque_mag = strength * 8000.0

	uarm.apply_torque_impulse(torque_dir * torque_mag)
	larm.apply_torque_impulse(torque_dir * torque_mag * 0.5)
	wpn.apply_torque_impulse(torque_dir * torque_mag * 0.3)

func quick_swing(side: String, strength: float = 1.0) -> void:
	var dir_sign = sign(move_direction) if abs(move_direction) > 0.05 else facing
	var dir = Vector2(dir_sign, -0.3).normalized()
	swing_arm(side, dir, strength)

func move_forward(force: float = 6000.0) -> void:
	var dir_sign = sign(move_direction) if abs(move_direction) > 0.05 else facing
	parts["torso"].apply_central_impulse(Vector2(dir_sign * force, 0))

func move_backward(force: float = 4500.0) -> void:
	var dir_sign = sign(move_direction) if abs(move_direction) > 0.05 else facing
	parts["torso"].apply_central_impulse(Vector2(-dir_sign * force, 0))

func _on_weapon_hit_r(other: Node) -> void:
	_handle_weapon_hit(other, weapon_r, _hit_cooldown_r, "r")

func _on_weapon_hit_l(other: Node) -> void:
	_handle_weapon_hit(other, weapon_l, _hit_cooldown_l, "l")

func _handle_weapon_hit(other: Node, wpn: RigidBody2D, cooldown: float, side: String) -> void:
	if is_dead or cooldown > 0.0:
		return
	# Only the physics-authority device detects hits
	if not is_local and not is_host_controlled:
		return
	var owner_node = other.get_parent()
	if owner_node == self or not (owner_node is Fighter):
		return
	var speed = wpn.linear_velocity.length()
	if speed < 30.0:
		return
	var dmg = speed * 0.12
	if other.name == "Head":
		dmg *= 2.5
	elif other.name == "Torso":
		dmg *= 1.2
	else:
		dmg *= 0.6
	owner_node.take_damage(dmg, other.global_position, wpn.linear_velocity)
	other.apply_central_impulse(wpn.linear_velocity.normalized() * speed * 4.0)
	hit_landed.emit(other.global_position, wpn.linear_velocity, dmg, other)
	if side == "r":
		_hit_cooldown_r = 0.18
	else:
		_hit_cooldown_l = 0.18

func take_damage(amount: float, _hit_pos: Vector2 = Vector2.ZERO, _hit_dir: Vector2 = Vector2.ZERO) -> void:
	if is_dead:
		return
	health -= amount
	health = max(health, 0.0)
	health_changed.emit(health, max_health)
	if health <= 0.0:
		_die()

func _die() -> void:
	is_dead = true
	# Only modify physics on devices running physics for this body
	if is_local or is_host_controlled:
		for p in parts.values():
			p.angular_damp = 1.0
			p.linear_damp  = 0.1
			p.gravity_scale = 1.0
		for w in [weapon_r, weapon_l]:
			w.angular_damp = 1.0
			w.linear_damp  = 0.1
			w.gravity_scale = 1.0
	died.emit()

# ══════════════════  POWER-UP EFFECTS  ══════════════════
func apply_health_boost(amount: float) -> void:
	if is_dead or health <= 0.0:
		return
	# Blocked during Sudden Death
	if has_meta("no_heal") and get_meta("no_heal"):
		return
	health = clampf(health + amount, 0.0, max_health)
	health_changed.emit(health, max_health)

func apply_speed_boost(multiplier: float, duration: float) -> void:
	if speed_boost_active:
		return
	speed_boost_active = true
	MOVE_FORCE = base_move_force * multiplier
	await get_tree().create_timer(duration).timeout
	MOVE_FORCE = base_move_force
	speed_boost_active = false

# ══════════════════  POSITION CORRECTION  ══════════════════
## Gently correct local player position to match host-authoritative snapshot.
## Only corrects torso position — other parts follow via joints.
## correction_strength controls how aggressively we snap (0.15 = subtle, 0.5 = strong).
func apply_position_correction(snap_data: Dictionary) -> void:
	if is_dead:
		return
	var parts_arr: Array = snap_data.get("parts", [])
	if parts_arr.size() < 3:
		return
	# First 3 values = torso gx, gy, rot
	var target_pos = Vector2(parts_arr[0], parts_arr[1])
	var torso: RigidBody2D = parts.get("torso")
	if not torso:
		return
	var correction_strength = 0.2
	var diff = target_pos - torso.global_position
	# Only correct if drift exceeds threshold (avoid jitter on small diffs)
	if diff.length() > 50.0:
		# Large drift — snap harder
		torso.global_position = torso.global_position.lerp(target_pos, 0.5)
	elif diff.length() > 5.0:
		# Moderate drift — gentle correction
		torso.global_position = torso.global_position.lerp(target_pos, correction_strength)

# ══════════════════  NETWORK SYNC  ══════════════════

## Pack ALL body part transforms into a compact array for snapshot
func pack_snapshot() -> Dictionary:
	var arr: Array = []
	for key in SYNC_PARTS:
		if parts.has(key):
			var p: RigidBody2D = parts[key]
			arr.append(snapped(p.global_position.x, 0.1))
			arr.append(snapped(p.global_position.y, 0.1))
			arr.append(snapped(p.rotation, 0.01))
	# Weapons
	arr.append(snapped(weapon_r.global_position.x, 0.1))
	arr.append(snapped(weapon_r.global_position.y, 0.1))
	arr.append(snapped(weapon_r.rotation, 0.01))
	arr.append(snapped(weapon_l.global_position.x, 0.1))
	arr.append(snapped(weapon_l.global_position.y, 0.1))
	arr.append(snapped(weapon_l.rotation, 0.01))
	return {
		"parts": arr,
		"hp": snapped(health, 0.1),
		"st": snapped(stamina, 0.1),
		"dead": is_dead,
	}

## Push a snapshot into the interpolation buffer (client-side)
func push_snapshot(data: Dictionary) -> void:
	var parts_arr: Array = data.get("parts", [])
	if parts_arr.size() < (SYNC_PARTS.size() + 2) * 3:
		return  # incomplete snapshot

	# Update health from authoritative source
	if data.has("hp"):
		var new_hp = data["hp"]
		if new_hp != health:
			health = new_hp
			health_changed.emit(health, max_health)
			if health <= 0.0 and not is_dead:
				_die()

	# Update stamina from authoritative source
	if data.has("st"):
		var new_st = data["st"]
		if new_st != stamina:
			stamina = new_st
			stamina_changed.emit(stamina, max_stamina)

	if data.has("dead") and data["dead"] and not is_dead:
		_die()

	# Build target positions dictionary
	var targets := {}
	var idx := 0
	for key in SYNC_PARTS:
		targets[key] = {
			"gx": parts_arr[idx], "gy": parts_arr[idx + 1], "rot": parts_arr[idx + 2]
		}
		idx += 3
	targets["weapon_r"] = {
		"gx": parts_arr[idx], "gy": parts_arr[idx + 1], "rot": parts_arr[idx + 2]
	}
	idx += 3
	targets["weapon_l"] = {
		"gx": parts_arr[idx], "gy": parts_arr[idx + 1], "rot": parts_arr[idx + 2]
	}

	_snapshot_buffer.append({
		"time": Time.get_ticks_msec() / 1000.0,
		"targets": targets,
	})

	# Keep only last 5 snapshots
	while _snapshot_buffer.size() > 5:
		_snapshot_buffer.pop_front()

## Interpolate between buffered snapshots for smooth remote rendering
func _interpolate_from_buffer(_delta: float) -> void:
	if _snapshot_buffer.size() < 2:
		# Not enough snapshots — just snap to latest
		if _snapshot_buffer.size() == 1:
			_apply_snapshot_direct(_snapshot_buffer[0]["targets"])
		return

	# Render at current time minus interpolation delay
	var now = Time.get_ticks_msec() / 1000.0
	_render_time = now - INTERP_DELAY

	# Find the two snapshots to interpolate between
	var from_snap = _snapshot_buffer[0]
	var to_snap = _snapshot_buffer[1]

	for i in range(_snapshot_buffer.size() - 1):
		if _snapshot_buffer[i]["time"] <= _render_time and _snapshot_buffer[i + 1]["time"] >= _render_time:
			from_snap = _snapshot_buffer[i]
			to_snap = _snapshot_buffer[i + 1]
			break
		# If render_time is past this pair, use the latest
		from_snap = _snapshot_buffer[i]
		to_snap = _snapshot_buffer[i + 1]

	# Calculate interpolation factor
	var time_diff = to_snap["time"] - from_snap["time"]
	var t = 1.0
	if time_diff > 0.001:
		t = clampf((_render_time - from_snap["time"]) / time_diff, 0.0, 1.0)

	# Interpolate each body part
	var from_targets = from_snap["targets"]
	var to_targets = to_snap["targets"]

	for key in to_targets:
		var body: RigidBody2D = null
		if key == "weapon_r":
			body = weapon_r
		elif key == "weapon_l":
			body = weapon_l
		elif parts.has(key):
			body = parts[key]
		if body == null:
			continue

		var to_data = to_targets[key]
		if from_targets.has(key):
			var from_data = from_targets[key]
			var from_pos = Vector2(from_data["gx"], from_data["gy"])
			var to_pos = Vector2(to_data["gx"], to_data["gy"])
			body.global_position = from_pos.lerp(to_pos, t)
			body.rotation = lerp_angle(from_data["rot"], to_data["rot"], t)
		else:
			body.global_position = Vector2(to_data["gx"], to_data["gy"])
			body.rotation = to_data["rot"]

func _apply_snapshot_direct(targets: Dictionary) -> void:
	for key in targets:
		var body: RigidBody2D = null
		if key == "weapon_r":
			body = weapon_r
		elif key == "weapon_l":
			body = weapon_l
		elif parts.has(key):
			body = parts[key]
		if body == null:
			continue
		var data = targets[key]
		body.global_position = Vector2(data["gx"], data["gy"])
		body.rotation = data["rot"]

## Apply remote input (called on HOST for the client's fighter)
func apply_remote_input(data: Dictionary) -> void:
	if data.has("move"):
		move_direction = data["move"]
	if data.has("atk_side"):
		var side = data["atk_side"]
		var dir = Vector2(data.get("atk_x", 0), data.get("atk_y", 0))
		var strength = data.get("atk_str", 1.0)
		swing_arm(side, dir, strength)
	if data.has("attacking"):
		is_attacking = data["attacking"]
