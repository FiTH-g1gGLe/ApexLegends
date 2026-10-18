# videoconfig.txt settings reference

Every setting in Apex Legends' `videoconfig.txt` (`configversion 10`). **Low** and **High** are what the in-game menu writes at its lowest and highest options, saved from the game on 17 October 2026. **File only** means the menu never changes it, so only an edited file can reach it.

File location: `%USERPROFILE%\Saved Games\Respawn\Apex\local\videoconfig.txt`

## Display

| Setting | What it does | Low | High |
|---|---|---|---|
| `defaultres` / `defaultresheight` | Resolution | your screen | your screen |
| `last_display_width` / `last_display_height` | Last-used resolution; keep equal to the above | your screen | your screen |
| `fullscreen` / `nowindowborder` | 1/1 fullscreen, 0/1 borderless window, 0/0 windowed | 1 / 1 | 1 / 1 |
| `mat_vsync_mode` | V-sync: 0 off, 1 double, 2 triple buffered, 3 adaptive, 4 adaptive (1/2 rate) | 0 | user choice |
| `mat_backbuffer_count` | 2 with triple-buffered V-sync, 1 for every other mode | 1 | 2 with triple |
| `dvs_enable` | Adaptive resolution: drops resolution to hold an FPS target. 0 is off | 0 | 0 |
| `dvs_gpuframetime_min` / `max` | Adaptive resolution target as frame time in microseconds (about 95% and 98% of 1,000,000 ÷ FPS) | – | – |
| `gamma` | Brightness. **Lower is brighter** (0.25 = turned up, 1.75 = turned down) | user choice | user choice |

## Textures

| Setting | What it does | Low | High |
|---|---|---|---|
| `stream_memory` | Texture streaming budget. 0 is the smallest | 0 | 3000000 |
| `dynamic_streaming_budget` | Game sizes the texture budget automatically (file only) | 1 | 1 |
| `mat_picmip` | Texture quality reduction; higher is blurrier. 3 and 4 are file only | 2 | 0 |
| `mat_forceaniso` | Texture filtering: 1 bilinear/trilinear, up to 16 anisotropic | 1 | 16 |
| `mat_mip_linear` | Trilinear filtering on/off | 0 | 1 |

## Models and effects

| Setting | What it does | Low | High |
|---|---|---|---|
| `r_lod_switch_scale` | Model detail distance, including players. Below 0.6 is file only | 0.6 | 2 |
| `map_detail_level` | Map detail | 1 | 2 |
| `fadeDistScale` | Distance small objects fade out (file only; effect not yet confirmed) | 1.0 | 1.0 |
| `cl_particle_fallback_base` | Effects detail: 3 low, 0 high | 3 | 0 |
| `cl_particle_fallback_multiplier` | Effects detail: 2 low, 1 high | 2 | 1 |
| `particle_cpu_level` | CPU particle detail | 0 | 2 |
| `cl_ragdoll_maxcount` | Max ragdolls | 0 | 8 |
| `cl_ragdoll_self_collision` | Ragdoll physics detail (file only) | 1 | 1 |
| `cl_gib_allow` | Gib physics effects | 0 | 1 |
| `r_decals` | Max impact marks (bullet holes, scorch marks) | 0 | 256 |
| `r_createmodeldecals` | Impact marks on models | 0 | 1 |

## Shadows and lighting

| Setting | What it does | Low | High |
|---|---|---|---|
| `shadow_enable` | Spot shadows on/off | 0 | 1 |
| `shadow_maxdynamic` | Number of dynamic spot shadows | 0 | 4 |
| `shadow_depth_dimen_min` | Spot shadow resolution | 0 | 512 |
| `shadow_depth_upres_factor_max` | Spot shadow upscaling | 0 | 3 |
| `csm_enabled` | Sun shadows. **The menu leaves them on even at Low; 0 is file only** | 1 | 1 |
| `csm_coverage` | Sun shadow distance | 1 | 2 |
| `csm_cascade_res` | Sun shadow detail | 512 | 1024 |
| `volumetric_lighting` | Light shafts | 0 | 1 |
| `volumetric_fog` | Volumetric fog (file only) | 0 | 0 |
| `ssao_quality` | Ambient occlusion; 0 is off | 0 | 4 |
| `mat_antialias_mode` | Anti-aliasing: 0 off, 12 TSAA | 0 | 12 |

## Other

| Setting | What it does | Low | High |
|---|---|---|---|
| `sound_volume` | Master volume (stored in this file too) | 1 | 1 |
| `new_shadow_settings` | Internal flag; leave at 1 | 1 | 1 |
| `configversion` | File format version; never change | 10 | 10 |

## Files in `configs/`

- `videoconfig-game-low.txt`: exactly what the menu writes at its lowest setting.
- `videoconfig-game-high.txt`: the menu's highest setting, with V-sync and adaptive resolution off.
- `videoconfig-fith-competitive.txt`: everything low except what helps you see players (texture budget high, texture quality 1, 4x filtering, model detail 0.75), with sun shadows and ragdoll collision off. Tested in-game on 17 October 2026.

All three are set for 2560×1440. Change `defaultres`, `defaultresheight`, `last_display_width` and `last_display_height` to your resolution, or use the config builder, which detects it.
