# videoconfig.txt format history

The file format changes every year or two, and old configs quietly stop working. Comparing three real files: deafps (2020, version 7), the Season 21 FiTH config (2024, version 8) and the current game default (2026, version 10).

| Setting | v7 (2020) | v8 (2024) | v10 (2026) |
|---|---|---|---|
| `ssao_enabled` / `ssao_downsample` | Yes | Yes | Gone |
| `dvs_supersample_enable` | Yes | Yes | Gone |
| `set_dress_level` | No | Yes | Gone |
| `dx_version_check_timestamp` | No | Yes | Gone |
| `last_display_width` / `height` | No | Yes | Yes |
| `sound_volume` | No | Yes | Yes |
| `volumetric_fog` | No | Yes | Yes |
| `new_shadow_settings` | No | Yes | Yes |
| `ssao_quality` | No | No | New |
| `map_detail_level` | No | No | New |
| `dynamic_streaming_budget` | No | No | New |

## Other problems in old configs

- Lines without the `setting.` prefix (`mat_disable_bloom`, `mat_specular`, `mat_bumpmap`, `r_dynamic`) are most likely ignored.
- Values outside the documented range (`cl_particle_fallback_base -1`, `mat_forceaniso 0`) may do nothing or be clamped.
- Comments like `// Disable DVS (Dynamic Visual Settings)` are wrong: DVS is adaptive resolution. Comments in generated files are best left out entirely.
