extends Node

## Autoload singleton — placeholder audio manager.
## Methods print to console until real audio assets are added.

func play_hit() -> void:
	print("[SFX] Hit!")

func play_ko() -> void:
	print("[SFX] KO!")

func play_round_start() -> void:
	print("[SFX] Round start!")

func play_round_end() -> void:
	print("[SFX] Round end!")

func play_footstep() -> void:
	pass  # Too frequent for console logging

func play_powerup_pickup() -> void:
	print("[SFX] Powerup collected!")

func play_timer_warning() -> void:
	print("[SFX] Timer warning!")

func play_match_over() -> void:
	print("[SFX] Match over!")
