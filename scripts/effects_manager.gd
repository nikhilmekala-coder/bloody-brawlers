extends Node2D
class_name EffectsManager

## Handles blood splatter, screen shake, hit flash, and impact effects.

var _cam: Camera2D
var _shake_amount: float = 0.0
var _shake_decay: float = 8.0

func setup(camera: Camera2D) -> void:
	_cam = camera

func _process(delta: float) -> void:
	# Screen shake decay
	if _shake_amount > 0.1 and _cam:
		_cam.offset = Vector2(
			randf_range(-_shake_amount, _shake_amount),
			randf_range(-_shake_amount, _shake_amount))
		_shake_amount = lerp(_shake_amount, 0.0, _shake_decay * delta)
	elif _cam:
		_cam.offset = Vector2.ZERO
		_shake_amount = 0.0

# ══════════  BLOOD PARTICLES  ══════════
func spawn_blood(pos: Vector2, amount: int = 12, direction: Vector2 = Vector2.ZERO) -> void:
	for i in amount:
		var drop := _create_blood_drop(pos, direction)
		add_child(drop)

func _create_blood_drop(pos: Vector2, dir: Vector2) -> RigidBody2D:
	var drop := RigidBody2D.new()
	drop.position = pos
	drop.mass = 0.05
	drop.gravity_scale = 1.2
	drop.collision_layer = 0
	drop.collision_mask = 1  # Only collide with ground
	drop.linear_damp = 0.3

	# Tiny collision shape
	var cs := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = randf_range(2.0, 5.0)
	cs.shape = circle
	drop.add_child(cs)

	# Visual — red circle
	var vis := Polygon2D.new()
	var pts := PackedVector2Array()
	var r = circle.radius
	for j in 8:
		var a = j * TAU / 8.0
		pts.append(Vector2(cos(a), sin(a)) * r)
	vis.polygon = pts
	vis.color = Color(
		randf_range(0.6, 0.9),
		randf_range(0.0, 0.08),
		randf_range(0.0, 0.05))
	drop.add_child(vis)

	# Random velocity burst
	var spread = dir.normalized() * randf_range(100, 350) if dir.length() > 0 else Vector2.ZERO
	spread += Vector2(randf_range(-150, 150), randf_range(-250, -50))
	drop.linear_velocity = spread

	# Auto-remove after a few seconds
	var timer := Timer.new()
	timer.wait_time = randf_range(2.0, 4.0)
	timer.one_shot = true
	timer.timeout.connect(func(): drop.queue_free())
	drop.add_child(timer)
	timer.start()

	return drop

# ══════════  SCREEN SHAKE  ══════════
func shake(intensity: float = 8.0) -> void:
	_shake_amount = max(_shake_amount, intensity)

# ══════════  HIT FLASH  ══════════
func flash_body_part(body: RigidBody2D, flash_color: Color = Color.WHITE) -> void:
	# Flash all Polygon2D children white briefly
	var originals: Array[Color] = []
	var polygons: Array[Polygon2D] = []
	for child in body.get_children():
		if child is Polygon2D:
			polygons.append(child)
			originals.append(child.color)
			child.color = flash_color

	# Restore after brief delay
	var tween := create_tween()
	tween.tween_interval(0.08)
	tween.tween_callback(func():
		for k in range(polygons.size()):
			if is_instance_valid(polygons[k]):
				polygons[k].color = originals[k])

# ══════════  DAMAGE NUMBER  ══════════
func spawn_damage_number(pos: Vector2, damage: float) -> void:
	var label := Label.new()
	label.text = str(int(damage))
	label.position = pos + Vector2(-10, -30)
	label.add_theme_font_size_override("font_size", 22)
	label.add_theme_color_override("font_color", Color(1, 0.3, 0.1))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	label.add_theme_constant_override("outline_size", 3)
	label.z_index = 10
	add_child(label)

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "position:y", pos.y - 80, 0.7).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "modulate:a", 0.0, 0.7).set_delay(0.3)
	tween.set_parallel(false)
	tween.tween_callback(func(): label.queue_free())

# ══════════  GROUND BLOOD SPLAT  ══════════
func spawn_ground_splat(pos: Vector2, ground_y: float) -> void:
	var splat := Polygon2D.new()
	var w = randf_range(8, 20)
	var h = randf_range(3, 6)
	splat.polygon = PackedVector2Array([
		Vector2(-w, -h), Vector2(w, -h),
		Vector2(w, h), Vector2(-w, h)])
	splat.color = Color(0.5, 0.02, 0.02, 0.7)
	splat.position = Vector2(pos.x, ground_y)
	splat.z_index = -1
	add_child(splat)
