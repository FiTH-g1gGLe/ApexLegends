# Autoexec: what still works

Respawn blocked most config commands in 2019 and has never published which ones work, so most autoexecs online are copied from config to config with commands that do nothing. This page only lists what has been tested.

## How to run an autoexec

1. Put `autoexec.cfg` in the game's `cfg` folder (Steam: `C:\Program Files (x86)\Steam\steamapps\common\Apex Legends\cfg`).
2. Add `+exec autoexec` to the launch options (Steam: right-click Apex Legends → Properties → Launch options).

## Test results (17 October 2026)

| Command | Result | How it was tested |
|---|---|---|
| `bind "F6" "+jump"` | **Works** | F6 jumped in the Firing Range, so the autoexec runs |
| `cl_fovScale "1.7"` | **Blocked** | Side-by-side screenshots identical to FOV 110 in the menu |

## Commands to test next

| Command | Value | What to check |
|---|---|---|
| `mat_letterbox_aspect_goal` / `threshold` | 0 / 0 | Stretched resolution fills the screen with no black bars |
| `fps_max` | 240 | FPS counter caps at 240 |
| `mat_disable_bloom` | 1 | Less glow around bright lights |
| `dlight_enable` / `r_dynamic` | 0 / 0 | No light flashes from muzzle flashes |
| `snd_setmixer PlayerFootsteps vol` | 0.1 | Your own footsteps quieter |
| `snd_setmixer GlobalFootsteps vol` | 1.2 | Enemy footsteps louder (needs a second player) |
| `miles_occlusion` | 0 | Sounds less muffled through walls (needs a second player) |
| `cl_forcepreload` | 1 | Fewer stutters after loading in |

Test in the Firing Range, same spot each time, adding one command at a time.

## What the old Season 21 autoexec got wrong

The [legacy autoexec](../legacy/season-21/autoexec.cfg) has about 300 commands, and most of them can't be doing anything:

- **Commands that would break the game if they ran**, such as `r_drawworld 0` and `r_drawstaticprops 0`. The game was playable, so they were ignored.
- **Settings that belong in videoconfig.txt** (shadows, textures, ragdolls). Two values for one setting cause conflicts.
- **Leftovers from other Source games**, such as `tf_particles_disable_weather` from Team Fortress 2.
- **Network commands** (`cl_predict`, `cl_lagcompensation`) with no FPS benefit and a risk of worse hit registration.

Rules for anything added here: only commands seen working, labelled with the date tested, and nothing that would be an unfair advantage if it worked, such as removing fog or brightening the whole map.
