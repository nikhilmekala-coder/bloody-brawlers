extends Area2D
class_name PowerUp

## A collectable power-up that grants either a health or speed boost.
## HOST-AUTHORITATIVE: only the HOST detects collisions and applies effects.
## Client power-ups have monitoring DISABLED — they are visual-only.
## Removal on client happens via network event (power_picked).

enum Type { HEALTH, SPEED }

var type: Type = Type.HEALTH
var picked_up: bool = false
var is_host_powerup: bool = true  # Set by spawner — client sets to false
var _float_tween: Tween
var _despawn_timer: Timer

# Visual
const ICON_RADIUS = 14.0
const GLOW_RADIUS = 20.0
var _icon_node: Node2D

func _ready() -> void:
	# ── Collision setup ──
	collision_layer = 32
	collision_mask = 2 | 4
	monitorable = false

	# CRITICAL: Only host monitors collisions.
	# Client power-ups are VISUAL ONLY — removed by network event.
	monitoring = is_host_powerup

	var cs := CollisionShape2D.new()
	var shape := CircleShape2D.new()
	shape.radius = 22.0
	cs.shape = shape
	add_child(cs)

	# ── Visual icon ──
	_icon_node = Node2D.new()
	_icon_node.name = "Icon"
	add_child(_icon_node)
	_build_icon()

	# ── Connect pickup (HOST ONLY) ──
	if is_host_powerup:
		body_entered.connect(_on_body_entered)

	# ── Despawn timer (8 seconds) ──
	_despawn_timer = Timer.new()
	_despawn_timer.wait_time = 8.0
	_despawn_timer.one_shot = true
	_despawn_timer.timeout.connect(_on_despawn)
	add_child(_despawn_timer)
	_despawn_timer.start()

	# ── Floating animation ──
	_start_float_animation()

func _build_icon() -> void:
	var color: Color
	if type == Type.HEALTH:
		color = Color(0.2, 0.85, 0.3)  # Green
	else:
		color = Color(0.25, 0.55, 1.0)  # Blue

	# Outer glow
	var glow := Polygon2D.new()
	var glow_pts := PackedVector2Array()
	for i in 16:
		var a = i * TAU / 16.0
		glow_pts.append(Vector2(cos(a), sin(a)) * GLOW_RADIUS)
	glow.polygon = glow_pts
	glow.color = Color(color.r, color.g, color.b, 0.25)
	_icon_node.add_child(glow)

	# Inner circle
	var inner := Polygon2D.new()
	var inner_pts := PackedVector2Array()
	for i in 16:
		var a = i * TAU / 16.0
		inner_pts.append(Vector2(cos(a), sin(a)) * ICON_RADIUS)
	inner.polygon = inner_pts
	inner.color = color
	_icon_node.add_child(inner)

	# Symbol on top
	if type == Type.HEALTH:
		var plus_h := Polygon2D.new()
		plus_h.polygon = PackedVector2Array([
			Vector2(-8, -2), Vector2(8, -2),
			Vector2(8, 2), Vector2(-8, 2)])
		plus_h.color = Color.WHITE
		_icon_node.add_child(plus_h)
		var plus_v := Polygon2D.new()
		plus_v.polygon = PackedVector2Array([
			Vector2(-2, -8), Vector2(2, -8),
			Vector2(2, 8), Vector2(-2, 8)])
		plus_v.color = Color.WHITE
		_icon_node.add_child(plus_v)
	else:
		var bolt := Polygon2D.new()
		bolt.polygon = PackedVector2Array([
			Vector2(-2, -10), Vector2(4, -10),
			Vector2(0, -2), Vector2(5, -2),
			Vector2(-3, 10), Vector2(0, 2),
			Vector2(-5, 2)])
		bolt.color = Color.WHITE
		_icon_node.add_child(bolt)

	_icon_node.add_child(_make_ring(ICON_RADIUS + 2.0, Color.WHITE, 1.5))

func _make_ring(radius: float, color: Color, width: float) -> Line2D:
	var ring := Line2D.new()
	for i in 25:
		var a = i * TAU / 24.0
		ring.add_point(Vector2(cos(a), sin(a)) * radius)
	ring.default_color = color
	ring.width = width
	return ring

func _start_float_animation() -> void:
	_float_tween = create_tween()
	_float_tween.set_loops()
	_float_tween.tween_property(_icon_node, "position:y", -6.0, 0.6) \
		.set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)
	_float_tween.tween_property(_icon_node, "position:y", 6.0, 0.6) \
		.set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)

## HOST ONLY — collision detected
func _on_body_entered(body: Node) -> void:
	if picked_up:
		return
	if not is_host_powerup:
		return  # Safety check — client should never reach here
	var fighter := _find_fighter(body)
	if fighter == null:
		return
	# Only process if this fighter has physics authority here
	if not fighter.is_local and not fighter.is_host_controlled:
		return
	# Mark as picked up IMMEDIATELY
	picked_up = true

	# Determine WHO picked it up (from host's perspective)
	# fighter.is_player = true means host's local player (= "host_player")
	# fighter.is_player = false means host's enemy (= "host_enemy")
	var picked_by = "host_player" if fighter.is_player else "host_enemy"

	# Apply effect on host
	if type == Type.HEALTH:
		fighter.apply_health_boost(100.0)
	else:
		fighter.apply_speed_boost(2.0, 5.0)

	# Sound
	var sm = get_node_or_null("/root/SoundManager")
	if sm:
		sm.play_powerup_pickup()

	# Broadcast pickup to other device
	var pid = get_meta("powerup_id") if has_meta("powerup_id") else -1
	var nm = get_node_or_null("/root/NetworkManager")
	if nm and nm.connected:
		nm._send({
			"type": "power_picked",
			"power_id": pid,
			"picked_by": picked_by,
			"ptype": type,
		})

	queue_free()

func _find_fighter(node: Node) -> Fighter:
	var parent = node.get_parent()
	if parent is Fighter:
		return parent as Fighter
	return null

func _on_despawn() -> void:
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 0.3)
	tween.tween_callback(queue_free)
