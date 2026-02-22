extends Node2D

## Unified GameManager — BB2 game mechanics + BB1 host-authoritative networking.
## Handles: arena, fighters, camera, HUD, joysticks, rounds, timer, stamina,
## powerups, network sync, and game-over flow.

var player: Fighter
var enemy: Fighter
var cam: Camera2D
var effects: EffectsManager
var hud_layer: CanvasLayer
var hp_bar_player: ProgressBar
var hp_bar_enemy: ProgressBar
var st_bar_player: ProgressBar
var st_bar_enemy: ProgressBar
var game_over: bool = false
var _game_over_panel: VBoxContainer
var _menu_btn: Button
var _play_again_btn: Button
var game_over_label: Label
var is_host: bool = true

const ARENA_W = 3000.0
const FLOOR_Y = 340.0
const SPAWN_X = 120.0
var ground_node: Node2D

# Joysticks
var joy_move: VirtualJoystick
var joy_attack: VirtualJoystick
var _joy_layer: CanvasLayer

# Powerups
var powerup_spawner: PowerUpSpawner

# ── Network ──
var _snapshot_timer: float = 0.0
const SNAPSHOT_INTERVAL = 0.05  # 20Hz snapshot rate
var _last_input: Dictionary = {}

# ── Round system ──
const ROUNDS_TO_WIN = 2   # Best of 3
var player_round_wins: int = 0
var enemy_round_wins: int = 0
var current_round: int = 1
var round_active: bool = true
var _round_transitioning: bool = false
var sudden_death_active: bool = false
var _sudden_death_overlay: ColorRect = null

# Round indicators (UI)
var _round_dots_player: Array = []
var _round_dots_enemy: Array = []

# ── Timer ──
const ROUND_TIME = 60.0
var round_timer: float = ROUND_TIME
var _timer_label: Label
var _timer_sync_timer: float = 0.0

# ── Round announcement ──
var _announce_label: Label

func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.10, 0.10, 0.16))
	var nm = get_node_or_null("/root/NetworkManager")
	if nm:
		is_host = nm.is_host
		if is_host:
			nm.input_received.connect(_on_client_input)
		else:
			nm.snapshot_received.connect(_on_snapshot)
		nm.restart_received.connect(_on_restart_received)
		nm.round_reset_received.connect(_on_round_reset_received)
		nm.round_win_received.connect(_on_round_win_received)
		nm.powerup_spawned.connect(_on_powerup_spawned_from_network)
		nm.powerup_despawned.connect(_on_powerup_despawned_from_network)
		nm.power_picked_received.connect(_on_power_picked_from_network)
		nm.round_update_received.connect(_on_round_update_from_network)
		nm.match_end_received.connect(_on_match_end_from_network)
		nm.sudden_death_received.connect(_on_sudden_death_from_network)
		# RESTORE round state from autoload (persists across scene reloads)
		player_round_wins = nm.round_state["player_wins"]
		enemy_round_wins = nm.round_state["enemy_wins"]
		current_round = nm.round_state["current_round"]
	_build_arena()
	_spawn_fighters()
	_setup_camera()
	_setup_effects()
	_build_hud()
	_build_joysticks()
	_setup_powerup_spawner()
	# Update UI with restored state
	_update_round_indicators()
	_show_round_announcement("ROUND " + str(current_round) + " — FIGHT!")

# ══════════  ARENA  ══════════
func _build_arena() -> void:
	ground_node = Node2D.new()
	ground_node.name = "Ground"
	add_child(ground_node)
	var g := StaticBody2D.new()
	g.name = "GroundBody"
	g.position = Vector2(640, FLOOR_Y + 25)
	g.collision_layer = 1; g.collision_mask = 0
	var gs := CollisionShape2D.new()
	var gr := RectangleShape2D.new()
	gr.size = Vector2(ARENA_W, 50); gs.shape = gr
	g.add_child(gs); ground_node.add_child(g)
	var earth := Polygon2D.new()
	earth.polygon = PackedVector2Array([
		Vector2(-ARENA_W/2, FLOOR_Y), Vector2(ARENA_W/2, FLOOR_Y),
		Vector2(ARENA_W/2, FLOOR_Y+300), Vector2(-ARENA_W/2, FLOOR_Y+300)])
	earth.position = Vector2(640, 0)
	earth.color = Color(0.22, 0.16, 0.10)
	ground_node.add_child(earth)
	var grass := Polygon2D.new()
	grass.polygon = PackedVector2Array([
		Vector2(-ARENA_W/2, FLOOR_Y-3), Vector2(ARENA_W/2, FLOOR_Y-3),
		Vector2(ARENA_W/2, FLOOR_Y+4), Vector2(-ARENA_W/2, FLOOR_Y+4)])
	grass.position = Vector2(640, 0)
	grass.color = Color(0.3, 0.6, 0.2)
	ground_node.add_child(grass)
	for i in range(-20, 21):
		var mk := Polygon2D.new()
		var mx = 640 + i * 80.0
		mk.polygon = PackedVector2Array([
			Vector2(mx-1, FLOOR_Y+4), Vector2(mx+1, FLOOR_Y+4),
			Vector2(mx+1, FLOOR_Y+12), Vector2(mx-1, FLOOR_Y+12)])
		mk.color = Color(0.18, 0.13, 0.08)
		ground_node.add_child(mk)
	_wall(Vector2(640 - ARENA_W/2 - 25, 100))
	_wall(Vector2(640 + ARENA_W/2 + 25, 100))

func _wall(pos: Vector2) -> void:
	var w := StaticBody2D.new()
	w.position = pos; w.collision_layer = 1; w.collision_mask = 0
	var s := CollisionShape2D.new()
	var r := RectangleShape2D.new()
	r.size = Vector2(50, 700); s.shape = r
	w.add_child(s); add_child(w)

# ══════════  FIGHTERS  ══════════
func _spawn_fighters() -> void:
	var spawn_y = FLOOR_Y - 91

	# LOCAL VIEW: local player ALWAYS left, opponent ALWAYS right
	var local_x = 640 - SPAWN_X
	var remote_x = 640 + SPAWN_X
	var local_facing = 1     # faces RIGHT
	var remote_facing = -1   # faces LEFT

	# Local player — always runs local physics, ALWAYS blue, ALWAYS left
	player = Fighter.new()
	player.name = "Player"
	player.position = Vector2(local_x, spawn_y)
	player.facing = local_facing
	player.is_player = true
	player.is_local = true
	player.is_host_controlled = false
	player.body_layer = 2; player.body_mask = 1 | 4 | 16
	player.weapon_layer = 8; player.weapon_mask = 1 | 4
	add_child(player)
	player.apply_role(true)   # BLUE — role-locked

	# Remote player — ALWAYS red, ALWAYS right
	enemy = Fighter.new()
	enemy.name = "Enemy"
	enemy.position = Vector2(remote_x, spawn_y)
	enemy.facing = remote_facing
	enemy.is_player = false
	enemy.is_local = false
	enemy.is_host_controlled = is_host  # Host runs physics for enemy 
	enemy.body_layer = 4; enemy.body_mask = 1 | 2 | 8
	enemy.weapon_layer = 16; enemy.weapon_mask = 1 | 2
	add_child(enemy)
	enemy.apply_role(false)   # RED — role-locked

	player.health_changed.connect(_on_player_hp)
	enemy.health_changed.connect(_on_enemy_hp)
	player.stamina_changed.connect(_on_player_stamina)
	enemy.stamina_changed.connect(_on_enemy_stamina)
	player.died.connect(_on_fighter_died.bind("player"))
	enemy.died.connect(_on_fighter_died.bind("enemy"))

	# On HOST: when local player hits enemy, send damage info to client
	if is_host:
		player.hit_landed.connect(_on_host_player_hit)
		enemy.hit_landed.connect(_on_host_enemy_hit)

	# Footstep sounds
	player.footstep.connect(func(_side): SoundManager.play_footstep())

# ══════════  CAMERA  ══════════
func _setup_camera() -> void:
	cam = Camera2D.new()
	cam.name = "Cam"
	cam.position = Vector2(640, 260)
	cam.zoom = Vector2(1.5, 1.5)
	cam.position_smoothing_enabled = true
	cam.position_smoothing_speed = 5.0
	add_child(cam)

# ══════════  EFFECTS  ══════════
func _setup_effects() -> void:
	effects = EffectsManager.new()
	effects.name = "Effects"
	effects.setup(cam); add_child(effects)
	player.hit_landed.connect(_on_local_hit_effects)
	enemy.hit_landed.connect(_on_local_hit_effects)

func _on_local_hit_effects(hit_pos: Vector2, hit_dir: Vector2, damage: float, hit_body: RigidBody2D) -> void:
	_spawn_hit_effects(hit_pos, hit_dir, damage, hit_body)
	SoundManager.play_hit()

## HOST: local player's weapon hit the enemy
func _on_host_player_hit(_hit_pos: Vector2, _hit_dir: Vector2, damage: float, _hit_body: RigidBody2D) -> void:
	var nm = get_node_or_null("/root/NetworkManager")
	if nm and nm.connected:
		nm.send_damage({"amount": damage, "target": "enemy"})

## HOST: enemy's weapon hit the local player
func _on_host_enemy_hit(_hit_pos: Vector2, _hit_dir: Vector2, damage: float, _hit_body: RigidBody2D) -> void:
	var nm = get_node_or_null("/root/NetworkManager")
	if nm and nm.connected:
		nm.send_damage({"amount": damage, "target": "player"})

func _spawn_hit_effects(hit_pos: Vector2, hit_dir: Vector2, damage: float, hit_body: RigidBody2D) -> void:
	effects.spawn_blood(hit_pos, int(clampf(damage * 1.5, 5, 25)), hit_dir)
	effects.shake(clampf(damage * 0.6, 3.0, 20.0))
	effects.flash_body_part(hit_body)
	effects.spawn_damage_number(hit_pos, damage)
	if randf() < 0.5:
		effects.spawn_ground_splat(hit_pos, FLOOR_Y)

# ══════════  HUD  ══════════
var _hud_root: Control
var _bg_p: ColorRect
var _bg_e: ColorRect
var _vs_label: Label

func _build_hud() -> void:
	hud_layer = CanvasLayer.new()
	hud_layer.name = "HUD"
	add_child(hud_layer)

	_hud_root = Control.new()
	_hud_root.name = "HUDRoot"
	_hud_root.anchor_left = 0.0; _hud_root.anchor_top = 0.0
	_hud_root.anchor_right = 1.0; _hud_root.anchor_bottom = 1.0
	_hud_root.offset_left = 0; _hud_root.offset_top = 0
	_hud_root.offset_right = 0; _hud_root.offset_bottom = 0
	_hud_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_layer.add_child(_hud_root)

	# ── Player HP (top-left, percentage-based width) ──
	_bg_p = ColorRect.new()
	_bg_p.color = Color(0.08, 0.08, 0.10)
	_bg_p.anchor_left = 0.0; _bg_p.anchor_top = 0.0
	_bg_p.anchor_right = 0.38; _bg_p.anchor_bottom = 0.0
	_bg_p.offset_left = 16; _bg_p.offset_top = 12
	_bg_p.offset_right = 0; _bg_p.offset_bottom = 56
	_hud_root.add_child(_bg_p)

	hp_bar_player = ProgressBar.new()
	hp_bar_player.anchor_left = 0.0; hp_bar_player.anchor_top = 0.0
	hp_bar_player.anchor_right = 0.38; hp_bar_player.anchor_bottom = 0.0
	hp_bar_player.offset_left = 18; hp_bar_player.offset_top = 14
	hp_bar_player.offset_right = -2; hp_bar_player.offset_bottom = 52
	hp_bar_player.min_value = 0; hp_bar_player.max_value = 500; hp_bar_player.value = 500
	hp_bar_player.show_percentage = false
	hp_bar_player.add_theme_stylebox_override("fill", _bar_style(Color(0.22, 0.52, 0.92)))
	hp_bar_player.add_theme_stylebox_override("background", _bar_style(Color(0.15, 0.15, 0.18)))
	_hud_root.add_child(hp_bar_player)

	# Player stamina (below HP)
	st_bar_player = ProgressBar.new()
	st_bar_player.anchor_left = 0.0; st_bar_player.anchor_top = 0.0
	st_bar_player.anchor_right = 0.38; st_bar_player.anchor_bottom = 0.0
	st_bar_player.offset_left = 18; st_bar_player.offset_top = 56
	st_bar_player.offset_right = -2; st_bar_player.offset_bottom = 74
	st_bar_player.min_value = 0; st_bar_player.max_value = 1000; st_bar_player.value = 1000
	st_bar_player.show_percentage = false
	st_bar_player.add_theme_stylebox_override("fill", _bar_style(Color(0.9, 0.75, 0.15)))
	st_bar_player.add_theme_stylebox_override("background", _bar_style(Color(0.15, 0.15, 0.18)))
	_hud_root.add_child(st_bar_player)

	# ── Enemy HP (top-right, percentage-based width) ──
	_bg_e = ColorRect.new()
	_bg_e.color = Color(0.08, 0.08, 0.10)
	_bg_e.anchor_left = 0.62; _bg_e.anchor_top = 0.0
	_bg_e.anchor_right = 1.0; _bg_e.anchor_bottom = 0.0
	_bg_e.offset_left = 0; _bg_e.offset_top = 12
	_bg_e.offset_right = -16; _bg_e.offset_bottom = 56
	_hud_root.add_child(_bg_e)

	hp_bar_enemy = ProgressBar.new()
	hp_bar_enemy.anchor_left = 0.62; hp_bar_enemy.anchor_top = 0.0
	hp_bar_enemy.anchor_right = 1.0; hp_bar_enemy.anchor_bottom = 0.0
	hp_bar_enemy.offset_left = 2; hp_bar_enemy.offset_top = 14
	hp_bar_enemy.offset_right = -18; hp_bar_enemy.offset_bottom = 52
	hp_bar_enemy.min_value = 0; hp_bar_enemy.max_value = 500; hp_bar_enemy.value = 500
	hp_bar_enemy.show_percentage = false
	hp_bar_enemy.add_theme_stylebox_override("fill", _bar_style(Color(0.88, 0.22, 0.18)))
	hp_bar_enemy.add_theme_stylebox_override("background", _bar_style(Color(0.15, 0.15, 0.18)))
	_hud_root.add_child(hp_bar_enemy)

	# Enemy stamina (below HP)
	st_bar_enemy = ProgressBar.new()
	st_bar_enemy.anchor_left = 0.62; st_bar_enemy.anchor_top = 0.0
	st_bar_enemy.anchor_right = 1.0; st_bar_enemy.anchor_bottom = 0.0
	st_bar_enemy.offset_left = 2; st_bar_enemy.offset_top = 56
	st_bar_enemy.offset_right = -18; st_bar_enemy.offset_bottom = 74
	st_bar_enemy.min_value = 0; st_bar_enemy.max_value = 1000; st_bar_enemy.value = 1000
	st_bar_enemy.show_percentage = false
	st_bar_enemy.add_theme_stylebox_override("fill", _bar_style(Color(0.9, 0.75, 0.15)))
	st_bar_enemy.add_theme_stylebox_override("background", _bar_style(Color(0.15, 0.15, 0.18)))
	_hud_root.add_child(st_bar_enemy)

	# ── Timer (top-center, large) ──
	_timer_label = Label.new()
	_timer_label.text = str(int(ROUND_TIME))
	_timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_timer_label.anchor_left = 0.5; _timer_label.anchor_top = 0.0
	_timer_label.anchor_right = 0.5; _timer_label.anchor_bottom = 0.0
	_timer_label.offset_left = -50; _timer_label.offset_top = 6
	_timer_label.offset_right = 50; _timer_label.offset_bottom = 52
	_timer_label.add_theme_font_size_override("font_size", 48)
	_timer_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	_hud_root.add_child(_timer_label)

	# ── VS label (below timer) ──
	_vs_label = Label.new()
	_vs_label.text = "⚔ VS ⚔"
	_vs_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_vs_label.anchor_left = 0.5; _vs_label.anchor_top = 0.0
	_vs_label.anchor_right = 0.5; _vs_label.anchor_bottom = 0.0
	_vs_label.offset_left = -60; _vs_label.offset_top = 52
	_vs_label.offset_right = 60; _vs_label.offset_bottom = 76
	_vs_label.add_theme_font_size_override("font_size", 22)
	_vs_label.add_theme_color_override("font_color", Color(0.9, 0.85, 0.7))
	_hud_root.add_child(_vs_label)

	# ── Round indicators ──
	_build_round_indicators()

	# ── Announcement label (center, large) ──
	_announce_label = Label.new()
	_announce_label.text = ""
	_announce_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_announce_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_announce_label.anchor_left = 0.5; _announce_label.anchor_top = 0.35
	_announce_label.anchor_right = 0.5; _announce_label.anchor_bottom = 0.35
	_announce_label.offset_left = -400; _announce_label.offset_top = -50
	_announce_label.offset_right = 400; _announce_label.offset_bottom = 50
	_announce_label.add_theme_font_size_override("font_size", 56)
	_announce_label.add_theme_color_override("font_color", Color(1, 0.9, 0.2))
	_announce_label.visible = false
	_hud_root.add_child(_announce_label)

	# ── Game over panel (large, centered, with background) ──
	var go_bg = ColorRect.new()
	go_bg.name = "GameOverBG"
	go_bg.anchor_left = 0.0; go_bg.anchor_top = 0.0
	go_bg.anchor_right = 1.0; go_bg.anchor_bottom = 1.0
	go_bg.color = Color(0.0, 0.0, 0.0, 0.6)
	go_bg.visible = false
	go_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_root.add_child(go_bg)

	_game_over_panel = VBoxContainer.new()
	_game_over_panel.anchor_left = 0.5; _game_over_panel.anchor_top = 0.5
	_game_over_panel.anchor_right = 0.5; _game_over_panel.anchor_bottom = 0.5
	_game_over_panel.offset_left = -280; _game_over_panel.offset_top = -160
	_game_over_panel.offset_right = 280; _game_over_panel.offset_bottom = 160
	_game_over_panel.alignment = BoxContainer.ALIGNMENT_CENTER
	_game_over_panel.add_theme_constant_override("separation", 24)
	_game_over_panel.visible = false
	_hud_root.add_child(_game_over_panel)

	game_over_label = Label.new()
	game_over_label.text = ""
	game_over_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	game_over_label.add_theme_font_size_override("font_size", 60)
	game_over_label.add_theme_color_override("font_color", Color(1, 0.9, 0.2))
	_game_over_panel.add_child(game_over_label)

	_play_again_btn = Button.new()
	_play_again_btn.text = "⚔  PLAY AGAIN"
	_play_again_btn.custom_minimum_size = Vector2(0, 80)
	_play_again_btn.add_theme_font_size_override("font_size", 30)
	var again_sb = StyleBoxFlat.new()
	again_sb.bg_color = Color(0.18, 0.58, 0.28)
	again_sb.corner_radius_top_left = 12; again_sb.corner_radius_top_right = 12
	again_sb.corner_radius_bottom_left = 12; again_sb.corner_radius_bottom_right = 12
	again_sb.shadow_color = Color(0, 0, 0, 0.3)
	again_sb.shadow_size = 4; again_sb.shadow_offset = Vector2(0, 3)
	_play_again_btn.add_theme_stylebox_override("normal", again_sb)
	var again_hover = again_sb.duplicate()
	again_hover.bg_color = Color(0.22, 0.68, 0.32)
	_play_again_btn.add_theme_stylebox_override("hover", again_hover)
	_play_again_btn.add_theme_color_override("font_color", Color.WHITE)
	_play_again_btn.pressed.connect(_on_play_again_pressed)
	_game_over_panel.add_child(_play_again_btn)

	_menu_btn = Button.new()
	_menu_btn.text = "↩  MAIN MENU"
	_menu_btn.custom_minimum_size = Vector2(0, 70)
	_menu_btn.add_theme_font_size_override("font_size", 26)
	var menu_sb = StyleBoxFlat.new()
	menu_sb.bg_color = Color(0.32, 0.32, 0.38)
	menu_sb.corner_radius_top_left = 12; menu_sb.corner_radius_top_right = 12
	menu_sb.corner_radius_bottom_left = 12; menu_sb.corner_radius_bottom_right = 12
	menu_sb.shadow_color = Color(0, 0, 0, 0.3)
	menu_sb.shadow_size = 4; menu_sb.shadow_offset = Vector2(0, 3)
	_menu_btn.add_theme_stylebox_override("normal", menu_sb)
	var menu_hover = menu_sb.duplicate()
	menu_hover.bg_color = Color(0.42, 0.42, 0.48)
	_menu_btn.add_theme_stylebox_override("hover", menu_hover)
	_menu_btn.add_theme_color_override("font_color", Color.WHITE)
	_menu_btn.pressed.connect(_on_menu_pressed)
	_game_over_panel.add_child(_menu_btn)

	# Store game over bg ref for show/hide
	_game_over_panel.set_meta("bg", go_bg)

	get_viewport().size_changed.connect(_on_viewport_resized)
	_on_viewport_resized()  # Apply immediately

func _build_round_indicators() -> void:
	for i in 3:
		var dot_p = _create_round_dot()
		dot_p.anchor_left = 0.0; dot_p.anchor_top = 0.0
		dot_p.anchor_right = 0.0; dot_p.anchor_bottom = 0.0
		dot_p.offset_left = 18 + i * 28; dot_p.offset_top = 80
		dot_p.offset_right = 18 + i * 28 + 20; dot_p.offset_bottom = 100
		_hud_root.add_child(dot_p)
		_round_dots_player.append(dot_p)

		var dot_e = _create_round_dot()
		dot_e.anchor_left = 1.0; dot_e.anchor_top = 0.0
		dot_e.anchor_right = 1.0; dot_e.anchor_bottom = 0.0
		dot_e.offset_left = -18 - (3 - i) * 28; dot_e.offset_top = 80
		dot_e.offset_right = -18 - (3 - i) * 28 + 20; dot_e.offset_bottom = 100
		_hud_root.add_child(dot_e)
		_round_dots_enemy.append(dot_e)

	_update_round_indicators()

func _create_round_dot() -> ColorRect:
	var dot = ColorRect.new()
	dot.color = Color(0.25, 0.25, 0.30)
	return dot

func _update_round_indicators() -> void:
	for i in 3:
		if i < _round_dots_player.size():
			_round_dots_player[i].color = Color(0.22, 0.52, 0.92) if i < player_round_wins else Color(0.25, 0.25, 0.30)
		if i < _round_dots_enemy.size():
			_round_dots_enemy[i].color = Color(0.88, 0.22, 0.18) if i < enemy_round_wins else Color(0.25, 0.25, 0.30)

func _bar_style(color: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.corner_radius_top_left = 6; sb.corner_radius_top_right = 6
	sb.corner_radius_bottom_left = 6; sb.corner_radius_bottom_right = 6
	return sb

func _on_viewport_resized() -> void:
	var vp = get_viewport().get_visible_rect().size
	var is_landscape = vp.x > vp.y

	var joy_scale = 1.2 if is_landscape else 1.0
	var new_radius = 176.0 * joy_scale
	var new_knob = 60.0 * joy_scale
	var new_max = 136.0 * joy_scale

	if joy_move:
		joy_move.base_radius = new_radius
		joy_move.knob_radius = new_knob
		joy_move.max_distance = new_max
		joy_move.queue_redraw()
	if joy_attack:
		joy_attack.base_radius = new_radius
		joy_attack.knob_radius = new_knob
		joy_attack.max_distance = new_max
		joy_attack.queue_redraw()

# Cached style refs for stamina red flash
var _st_fill_normal_player: StyleBoxFlat
var _st_fill_red_player: StyleBoxFlat
var _st_fill_normal_enemy: StyleBoxFlat
var _st_fill_red_enemy: StyleBoxFlat
var _st_red_flash_active_p: bool = false
var _st_red_flash_active_e: bool = false

func _on_player_hp(cur: float, mx: float) -> void:
	if hp_bar_player: hp_bar_player.value = cur
func _on_enemy_hp(cur: float, mx: float) -> void:
	if hp_bar_enemy: hp_bar_enemy.value = cur

func _on_player_stamina(cur: float, mx: float) -> void:
	if not st_bar_player: return
	st_bar_player.value = cur
	# Red flash when below threshold
	if cur < Fighter.STAMINA_RED_THRESHOLD and not _st_red_flash_active_p:
		_st_red_flash_active_p = true
		st_bar_player.add_theme_stylebox_override("fill", _bar_style(Color(0.9, 0.2, 0.15)))
	elif cur >= Fighter.STAMINA_RED_THRESHOLD and _st_red_flash_active_p:
		_st_red_flash_active_p = false
		st_bar_player.add_theme_stylebox_override("fill", _bar_style(Color(0.9, 0.75, 0.15)))

func _on_enemy_stamina(cur: float, mx: float) -> void:
	if not st_bar_enemy: return
	st_bar_enemy.value = cur
	if cur < Fighter.STAMINA_RED_THRESHOLD and not _st_red_flash_active_e:
		_st_red_flash_active_e = true
		st_bar_enemy.add_theme_stylebox_override("fill", _bar_style(Color(0.9, 0.2, 0.15)))
	elif cur >= Fighter.STAMINA_RED_THRESHOLD and _st_red_flash_active_e:
		_st_red_flash_active_e = false
		st_bar_enemy.add_theme_stylebox_override("fill", _bar_style(Color(0.9, 0.75, 0.15)))

# ══════════  JOYSTICKS  ══════════
func _build_joysticks() -> void:
	_joy_layer = CanvasLayer.new()
	_joy_layer.name = "JoystickLayer"
	_joy_layer.layer = 10
	add_child(_joy_layer)

	var root_ctrl = Control.new()
	root_ctrl.name = "JoystickRoot"
	root_ctrl.anchor_left = 0.0; root_ctrl.anchor_top = 0.0
	root_ctrl.anchor_right = 1.0; root_ctrl.anchor_bottom = 1.0
	root_ctrl.offset_left = 0; root_ctrl.offset_top = 0
	root_ctrl.offset_right = 0; root_ctrl.offset_bottom = 0
	root_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_joy_layer.add_child(root_ctrl)

	var joy_w = 400.0
	var joy_h = 400.0
	var margin = 10.0
	var inward = 60.0  # Push joysticks toward center

	joy_move = VirtualJoystick.new()
	joy_move.name = "JoyMove"
	joy_move.anchor_left = 0.0; joy_move.anchor_top = 1.0
	joy_move.anchor_right = 0.0; joy_move.anchor_bottom = 1.0
	joy_move.offset_left = margin + inward; joy_move.offset_top = -(joy_h + margin)
	joy_move.offset_right = margin + inward + joy_w; joy_move.offset_bottom = -margin
	joy_move.base_radius = 176.0; joy_move.knob_radius = 60.0; joy_move.max_distance = 136.0
	joy_move.base_color = Color(0.3, 0.7, 1.0, 0.15)
	joy_move.knob_color = Color(0.3, 0.7, 1.0, 0.45)
	joy_move.active_color = Color(0.3, 0.8, 1.0, 0.7)
	joy_move.label_text = "MOVE"
	joy_move.joystick_input.connect(_on_move_joy)
	joy_move.joystick_released.connect(_on_move_released)
	root_ctrl.add_child(joy_move)

	joy_attack = VirtualJoystick.new()
	joy_attack.name = "JoyAttack"
	joy_attack.anchor_left = 1.0; joy_attack.anchor_top = 1.0
	joy_attack.anchor_right = 1.0; joy_attack.anchor_bottom = 1.0
	joy_attack.offset_left = -(joy_w + margin + inward); joy_attack.offset_top = -(joy_h + margin)
	joy_attack.offset_right = -(margin + inward); joy_attack.offset_bottom = -margin
	joy_attack.base_radius = 176.0; joy_attack.knob_radius = 60.0; joy_attack.max_distance = 136.0
	joy_attack.base_color = Color(1.0, 0.4, 0.2, 0.15)
	joy_attack.knob_color = Color(1.0, 0.4, 0.2, 0.45)
	joy_attack.active_color = Color(1.0, 0.5, 0.2, 0.7)
	joy_attack.label_text = "ATTACK"
	joy_attack.joystick_flick.connect(_on_attack_flick)
	joy_attack.joystick_input.connect(_on_attack_joy)
	joy_attack.joystick_released.connect(_on_attack_released)
	root_ctrl.add_child(joy_attack)

# ══════════  INPUT HANDLERS  ══════════

func _on_move_joy(dir: Vector2) -> void:
	if game_over or not round_active: return
	if abs(dir.x) > 0.1:
		player.move_direction = sign(dir.x)
	else:
		player.move_direction = 0.0
	_send_input_if_changed()

func _on_move_released() -> void:
	player.move_direction = 0.0
	_send_input_if_changed()

var _attack_accumulator: float = 0.0

func _on_attack_joy(dir: Vector2) -> void:
	if game_over or not round_active: return
	player.is_attacking = true
	_attack_accumulator += dir.length() * 0.016
	if _attack_accumulator > 0.15:
		var strength = clampf(dir.length() * 1.5, 0.5, 2.0)
		player.swing_arm("r", dir, strength)
		_send_attack_input("r", dir, strength)
		if dir.length() > 0.7:
			player.swing_arm("l", Vector2(-dir.x, dir.y) * 0.5, strength * 0.4)
			_send_attack_input("l", Vector2(-dir.x, dir.y) * 0.5, strength * 0.4)
		_attack_accumulator = 0.0
	_send_input_if_changed()

func _on_attack_released() -> void:
	player.is_attacking = false
	_send_input_if_changed()

func _on_attack_flick(dir: Vector2, strength: float) -> void:
	if game_over or not round_active: return
	player.swing_arm("r", dir, strength * 2.5)
	_send_attack_input("r", dir, strength * 2.5)
	player.is_attacking = false
	_send_input_if_changed()

func _send_input_if_changed() -> void:
	var nm = get_node_or_null("/root/NetworkManager")
	if not nm or not nm.connected:
		return
	var input := {
		"move": snapped(player.move_direction, 0.01),
		"attacking": player.is_attacking,
	}
	if input.get("move") == _last_input.get("move") and \
	   input.get("attacking") == _last_input.get("attacking"):
		return
	_last_input = input.duplicate()
	nm.send_input(input)

func _send_attack_input(side: String, dir: Vector2, strength: float) -> void:
	var nm = get_node_or_null("/root/NetworkManager")
	if nm and nm.connected:
		nm.send_input({
			"atk_side": side,
			"atk_x": snapped(dir.x, 0.01),
			"atk_y": snapped(dir.y, 0.01),
			"atk_str": snapped(strength, 0.01),
		})

# ══════════  PHYSICS + NETWORK SYNC  ══════════

func _physics_process(delta: float) -> void:
	if not game_over and round_active:
		_update_camera()
		_update_round_timer(delta)

	if is_host:
		_snapshot_timer += delta
		if _snapshot_timer >= SNAPSHOT_INTERVAL:
			_snapshot_timer = 0.0
			_send_snapshot()

func _update_round_timer(delta: float) -> void:
	# No timer during Sudden Death
	if sudden_death_active:
		_timer_label.text = "SD"
		return
	# Both host and client run local countdown for smooth display
	round_timer -= delta
	round_timer = max(round_timer, 0.0)
	_timer_label.text = str(int(ceil(round_timer)))

	# Warning sound at 10s
	if round_timer <= 10.0 and round_timer > 9.5:
		SoundManager.play_timer_warning()

	if round_timer <= 0.0 and is_host:
		_on_timer_expired()

func _on_timer_expired() -> void:
	if _round_transitioning:
		return
	if player.health > enemy.health:
		enemy.health = 0
		enemy.health_changed.emit(0.0, enemy.max_health)
		enemy._die()
		_end_round("player")
	elif enemy.health > player.health:
		player.health = 0
		player.health_changed.emit(0.0, player.max_health)
		player._die()
		_end_round("enemy")
	else:
		# EQUAL HP — SUDDEN DEATH MODE
		_trigger_sudden_death()

func _trigger_sudden_death() -> void:
	sudden_death_active = true

	# Set both fighters to 1 HP
	player.health = 1.0
	player.health_changed.emit(1.0, player.max_health)
	enemy.health = 1.0
	enemy.health_changed.emit(1.0, enemy.max_health)

	# Disable healing on both fighters
	player.set_meta("no_heal", true)
	enemy.set_meta("no_heal", true)

	# Reset round timer (no timer in sudden death) — display "SD"
	round_timer = 999.0
	_timer_label.text = "SD"

	# Show SUDDEN DEATH announcement
	_show_round_announcement("☠ SUDDEN DEATH ☠")
	SoundManager.play_round_start()

	# Red pulsing overlay
	if not _sudden_death_overlay:
		_sudden_death_overlay = ColorRect.new()
		_sudden_death_overlay.name = "SuddenDeathOverlay"
		_sudden_death_overlay.anchor_left = 0.0; _sudden_death_overlay.anchor_top = 0.0
		_sudden_death_overlay.anchor_right = 1.0; _sudden_death_overlay.anchor_bottom = 1.0
		_sudden_death_overlay.color = Color(0.8, 0.05, 0.05, 0.12)
		_sudden_death_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_hud_root.add_child(_sudden_death_overlay)
		# Pulse animation
		var pulse = _sudden_death_overlay.create_tween()
		pulse.set_loops()
		pulse.tween_property(_sudden_death_overlay, "color:a", 0.20, 0.6) \
			.set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)
		pulse.tween_property(_sudden_death_overlay, "color:a", 0.06, 0.6) \
			.set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)

	# Notify client (host-only)
	if is_host:
		var nm = get_node_or_null("/root/NetworkManager")
		if nm and nm.connected:
			nm._send({"type": "sudden_death"})

func _send_snapshot() -> void:
	var nm = get_node_or_null("/root/NetworkManager")
	if not nm or not nm.connected:
		return
	var snap := {
		"p1": player.pack_snapshot(),
		"p2": enemy.pack_snapshot(),
		"timer": snapped(round_timer, 0.1),
	}
	nm.send_snapshot(snap)

## HOST receives input from client → apply to enemy fighter
func _on_client_input(data: Dictionary) -> void:
	if not is_host or not enemy:
		return
	if data.has("move"):
		data["move"] = -data["move"]
	if data.has("atk_x"):
		data["atk_x"] = -data["atk_x"]
	enemy.apply_remote_input(data)

## CLIENT receives snapshot from host → push to interpolation buffers
func _on_snapshot(data: Dictionary) -> void:
	if is_host:
		return
	if data.get("type") == "damage":
		_handle_damage_from_host(data)
		return

	# Update timer from host
	if data.has("timer"):
		round_timer = data["timer"]
		_timer_label.text = str(int(ceil(round_timer)))

	# p1 = host's local player = client's enemy
	# p2 = host's enemy = client's player
	if data.has("p1") and enemy:
		var mirrored = _mirror_snapshot(data["p1"])
		enemy.push_snapshot(mirrored)
	if data.has("p2") and player:
		var p2_data = data["p2"]
		# POSITION CORRECTION: gently correct client's local player toward host state
		var mirrored_p2 = _mirror_snapshot(p2_data)
		player.apply_position_correction(mirrored_p2)
		# HP correction from host
		if p2_data.has("hp"):
			var server_hp = p2_data["hp"]
			if server_hp != player.health:
				player.health = server_hp
				player.health_changed.emit(player.health, player.max_health)
				if player.health <= 0.0 and not player.is_dead:
					player._die()
		if p2_data.has("st"):
			var server_st = p2_data["st"]
			if server_st != player.stamina:
				player.stamina = server_st
				player.stamina_changed.emit(player.stamina, player.max_stamina)

func _handle_damage_from_host(data: Dictionary) -> void:
	# HP correction comes via snapshot, damage event is for effects only
	pass

func _mirror_snapshot(snap: Dictionary) -> Dictionary:
	var result = snap.duplicate(true)
	if result.has("parts"):
		var arr: Array = result["parts"]
		var i = 0
		while i < arr.size():
			arr[i] = 1280.0 - arr[i]      # mirror X
			arr[i + 2] = -arr[i + 2]       # negate rotation
			i += 3
		result["parts"] = arr
	return result

func _input(_event: InputEvent) -> void:
	pass

func _update_camera() -> void:
	if not player or not enemy: return
	if not player.parts.has("torso") or not enemy.parts.has("torso"): return
	var pt = player.parts["torso"].global_position
	var et = enemy.parts["torso"].global_position
	var mid = (pt + et) / 2.0
	cam.position = lerp(cam.position, Vector2(mid.x, mid.y - 40), 0.08)
	var dist = pt.distance_to(et)
	var z = clampf(800.0 / max(dist, 1.0), 0.6, 1.5)
	cam.zoom = lerp(cam.zoom, Vector2(z, z), 0.04)

# ══════════  ROUND SYSTEM  ══════════

func _on_fighter_died(who: String) -> void:
	if _round_transitioning or game_over:
		return
	# HOST-ONLY AUTHORITY: only host decides round outcomes.
	# Client waits for round_win message from host.
	if not is_host:
		return
	if who == "player":
		_end_round("enemy")
	else:
		_end_round("player")

func _end_round(winner: String) -> void:
	if _round_transitioning:
		return
	_round_transitioning = true
	round_active = false

	# Award round
	if winner == "player":
		player_round_wins += 1
	elif winner == "enemy":
		enemy_round_wins += 1
	elif winner == "draw":
		player_round_wins += 1
		enemy_round_wins += 1

	_update_round_indicators()
	SoundManager.play_round_end()

	# Host sends round_win to client
	if is_host:
		var nm = get_node_or_null("/root/NetworkManager")
		if nm and nm.connected:
			nm.send_round_win({
				"winner": winner,
				"p_wins": player_round_wins,
				"e_wins": enemy_round_wins,
			})
		# Persist round state in autoload
		if nm:
			nm.round_state["player_wins"] = player_round_wins
			nm.round_state["enemy_wins"] = enemy_round_wins

	# Check for match over
	if player_round_wins >= ROUNDS_TO_WIN or enemy_round_wins >= ROUNDS_TO_WIN:
		_match_over()
		return

	# KO slow-motion + camera zoom
	_ko_slowmo()

func _ko_slowmo() -> void:
	Engine.time_scale = 0.3
	# Zoom camera toward the fallen fighter
	var ko_target = enemy if enemy.is_dead else player
	if ko_target.parts.has("torso"):
		var target_pos = ko_target.parts["torso"].global_position
		cam.position = lerp(cam.position, target_pos, 0.5)
	cam.zoom = lerp(cam.zoom, Vector2(2.5, 2.5), 0.5)
	SoundManager.play_ko()

	await get_tree().create_timer(0.5).timeout
	Engine.time_scale = 1.0

	# Show round result
	var round_msg = "ROUND " + str(current_round)
	if player_round_wins > enemy_round_wins:
		round_msg += " — YOU WIN!"
	elif enemy_round_wins > player_round_wins:
		round_msg += " — ENEMY WINS!"
	else:
		round_msg += " — DRAW!"
	_show_round_announcement(round_msg)
	await get_tree().create_timer(1.5).timeout

	# HOST ONLY: increment round and trigger reset.
	# Client waits for round_reset message from host instead.
	if is_host:
		current_round += 1
		_reset_round()

func _reset_round() -> void:
	_round_transitioning = false
	round_active = true
	round_timer = ROUND_TIME

	# Persist round state BEFORE scene reload
	var nm = get_node_or_null("/root/NetworkManager")
	if nm:
		nm.round_state["player_wins"] = player_round_wins
		nm.round_state["enemy_wins"] = enemy_round_wins
		nm.round_state["current_round"] = current_round

	# Send round_reset to client
	if is_host and nm and nm.connected:
		nm.send_round_reset({
			"round": current_round,
			"timer": ROUND_TIME,
			"p_wins": player_round_wins,
			"e_wins": enemy_round_wins,
		})

	# Reload scene — round state will be restored from NetworkManager in _ready
	get_tree().change_scene_to_file("res://main.tscn")

func _match_over() -> void:
	game_over = true
	Engine.time_scale = 0.3
	SoundManager.play_match_over()

	var msg = ""
	if player_round_wins >= ROUNDS_TO_WIN:
		msg = "YOU WIN!"
	else:
		msg = "DEFEATED"

	await get_tree().create_timer(0.5).timeout
	Engine.time_scale = 1.0

	game_over_label.text = msg
	# Show dark overlay + panel
	if _game_over_panel.has_meta("bg"):
		_game_over_panel.get_meta("bg").visible = true
	_game_over_panel.visible = true

func _on_round_win_received(data: Dictionary) -> void:
	if is_host or _round_transitioning or game_over:
		return
	# Note: on the client, "player" from host = client's "enemy" and vice versa
	var host_p_wins = data.get("p_wins", 0)
	var host_e_wins = data.get("e_wins", 0)
	# Host's player wins = client's enemy wins (and vice versa)
	player_round_wins = host_e_wins
	enemy_round_wins = host_p_wins
	_update_round_indicators()

	# Persist to autoload
	var nm = get_node_or_null("/root/NetworkManager")
	if nm:
		nm.round_state["player_wins"] = player_round_wins
		nm.round_state["enemy_wins"] = enemy_round_wins

	if player_round_wins >= ROUNDS_TO_WIN or enemy_round_wins >= ROUNDS_TO_WIN:
		_match_over()
	else:
		_ko_slowmo()

func _on_round_reset_received(data: Dictionary) -> void:
	# Client receives round reset from host
	if is_host:
		return
	current_round = data.get("round", current_round + 1)
	round_timer = data.get("timer", ROUND_TIME)
	# Also restore wins from reset message
	var host_p_wins = data.get("p_wins", 0)
	var host_e_wins = data.get("e_wins", 0)
	player_round_wins = host_e_wins
	enemy_round_wins = host_p_wins
	# Persist BEFORE scene reload
	var nm = get_node_or_null("/root/NetworkManager")
	if nm:
		nm.round_state["player_wins"] = player_round_wins
		nm.round_state["enemy_wins"] = enemy_round_wins
		nm.round_state["current_round"] = current_round
	get_tree().change_scene_to_file("res://main.tscn")

func _show_round_announcement(text: String) -> void:
	if _announce_label:
		_announce_label.text = text
		_announce_label.visible = true
		_announce_label.modulate.a = 1.0
		SoundManager.play_round_start()
		var tw = create_tween()
		tw.tween_interval(1.5)
		tw.tween_property(_announce_label, "modulate:a", 0.0, 0.5)
		tw.tween_callback(func(): _announce_label.visible = false)

# ══════════  GAME OVER  ══════════
func _on_menu_pressed() -> void:
	game_over = false; Engine.time_scale = 1.0
	# FULL reset round state
	var nm = get_node_or_null("/root/NetworkManager")
	if nm:
		nm.reset_round_state()
		nm.leave_room()
	get_tree().change_scene_to_file("res://main_menu.tscn")

func _on_play_again_pressed() -> void:
	var nm = get_node_or_null("/root/NetworkManager")
	if nm:
		nm.reset_round_state()  # Full match reset
		if nm.connected:
			nm.send_restart()
	_restart_game()

func _on_restart_received() -> void:
	var nm = get_node_or_null("/root/NetworkManager")
	if nm:
		nm.reset_round_state()
	_restart_game()

func _restart_game() -> void:
	game_over = false
	Engine.time_scale = 1.0
	# round_state is already reset in NetworkManager
	get_tree().change_scene_to_file("res://main.tscn")

# ══════════  POWER-UP SPAWNER  ══════════
func _setup_powerup_spawner() -> void:
	powerup_spawner = PowerUpSpawner.new()
	powerup_spawner.name = "PowerUpSpawner"
	powerup_spawner.ground_y = FLOOR_Y
	powerup_spawner.player = player
	powerup_spawner.enemy = enemy
	powerup_spawner.is_host = is_host
	add_child(powerup_spawner)

func _on_powerup_spawned_from_network(data: Dictionary) -> void:
	if not is_host and powerup_spawner:
		powerup_spawner.spawn_from_network(data)

func _on_powerup_despawned_from_network(data: Dictionary) -> void:
	if powerup_spawner:
		powerup_spawner.despawn_from_network(data)

func _on_power_picked_from_network(data: Dictionary) -> void:
	# Client receives: host detected a power-up pickup
	if not is_host and powerup_spawner:
		powerup_spawner.handle_power_picked(data)

func _on_round_update_from_network(data: Dictionary) -> void:
	if is_host:
		return
	var nm = get_node_or_null("/root/NetworkManager")
	if nm:
		nm.round_state["player_wins"] = data.get("client_wins", 0)
		nm.round_state["enemy_wins"] = data.get("client_enemy_wins", 0)
		nm.round_state["current_round"] = data.get("current_round", 1)

func _on_sudden_death_from_network() -> void:
	if is_host:
		return
	_trigger_sudden_death()

func _on_match_end_from_network(data: Dictionary) -> void:
	if is_host or game_over:
		return
	var winner = data.get("winner", "")
	game_over = true
	Engine.time_scale = 0.3
	SoundManager.play_match_over()
	var msg = ""
	if winner == "blue":
		msg = "DEFEATED"
	else:
		msg = "YOU WIN!"
	await get_tree().create_timer(0.5).timeout
	Engine.time_scale = 1.0
	game_over_label.text = msg
	if _game_over_panel.has_meta("bg"):
		_game_over_panel.get_meta("bg").visible = true
	_game_over_panel.visible = true

