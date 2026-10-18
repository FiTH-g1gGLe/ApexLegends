# FiTH Apex Legends Configs and Tools

Tested Apex Legends performance configs, a config builder, and a sensitivity finder for mouse and keyboard players.
Everything here is plain text or a web page. No installers, no registry edits, no scripts that change Windows.

- Website: [fithgaming.co.uk](https://fithgaming.co.uk)
- Discord: [discord.gg/Br7z7zBvFb](https://discord.gg/Br7z7zBvFb)
- YouTube: [FiTHGAMINGOFFICIAL](https://www.youtube.com/FiTHGAMINGOFFICIAL)
- Facebook: [FiTHGAMINGOFFICIAL](https://www.facebook.com/gaming/FiTHGAMINGOFFICIAL)

Last verified in-game: **17 October 2026** (videoconfig `configversion 10`).

## What's in here

| Folder | What it is |
|---|---|
| [`configs/`](configs) | Ready-to-use `videoconfig.txt` files: the game's own Low and High, plus the FiTH competitive config |
| [`tools/config-builder.html`](tools/config-builder.html) | Build your own `videoconfig.txt`: every setting explained, presets, hardware detection, one-click download |
| [`tools/sensitivity-finder.html`](tools/sensitivity-finder.html) | Aim test that finds your hip-fire sensitivity and your 1x, 2x and 3x ADS multipliers |
| [`tools/wordpress/`](tools/wordpress) | The same two tools packaged to paste into an Elementor HTML widget |
| [`docs/`](docs) | What every setting does, what's been tested, and how Apex ADS sensitivity works |
| [`legacy/season-21/`](legacy/season-21) | The old Season 21 configs, kept for reference. They use an outdated file format |

Live versions: [Config builder](https://fithgaming.co.uk/apex/) · [Sensitivity finder](https://fithgaming.co.uk/apex-sensitivity/)

To use a tool from this repository, download the `.html` file and open it in Chrome or Edge.

## Install a videoconfig

1. Close Apex Legends completely.
2. Press `Win + R`, paste `%USERPROFILE%\Saved Games\Respawn\Apex\local` and press Enter.
3. Copy your current `videoconfig.txt` somewhere safe as a backup.
4. Put the new file in, named exactly `videoconfig.txt`.
5. Launch and play. **Don't open the video settings menu**, because saving anything there rewrites the file with menu values.

The file survives restarts without being read-only. To undo, put your backup back, or delete the file and the game makes a fresh one.

## What we confirmed in-game (17 Oct 2026)

- **Hand-edited videoconfig files work** and survive restarts.
- **The file can do things the menu can't.** Even at the menu's lowest setting, sun shadows stay on (`csm_enabled 1`). Setting `csm_enabled 0` in the file removes them, which gains FPS and removes the dark areas enemies hide in.
- **The autoexec still runs** through the `+exec autoexec` launch option (a test keybind worked), but **`cl_fovScale` is blocked** and does nothing.
- **Sensitivity maths:** hip-fire turn distance follows Source-engine maths exactly. 800 DPI at sensitivity 2.27 measured 22.9 cm per 360°, matching the formula `360 ÷ (DPI × sens × 0.022) × 2.54`.

Details: [docs/settings-reference.md](docs/settings-reference.md), [docs/autoexec.md](docs/autoexec.md), [docs/ads-sensitivity.md](docs/ads-sensitivity.md), [docs/file-format-history.md](docs/file-format-history.md).

## A warning about "FPS packs"

Many FPS boost packs online contain no game config at all. One popular pack we reviewed was all registry edits and scripts, including one that turns off Windows exploit protections (DEP, CFG, SEHOP) system-wide, with no measurable FPS benefit. Everything in this repository is a game config file you can read line by line.
