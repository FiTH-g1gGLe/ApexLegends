# How Apex ADS sensitivity works

Measured on 17–18 October 2026 at FOV 110, 800 DPI.

## Hip-fire

Turn distance follows Source-engine maths exactly:

```
cm per 360° = 360 ÷ (DPI × sensitivity × 0.022) × 2.54
```

At 800 DPI and sensitivity 2.27 the formula gives 22.9 cm, and a ruler test in-game measured 22.9 cm.

Only DPI × sensitivity matters (eDPI). 700 DPI at 2.7 is not the same as 800 at 2.0; it is about 18% faster. Keep your DPI fixed and change the in-game sensitivity.

## How much each sight zooms

Measured by matching the same target board across screenshots (hip-fire at FOV 110 = 1.00×):

| Sight | On-screen zoom |
|---|---|
| Iron sights / 1x | 1.16–1.19× |
| 2x | 2.22× |
| 3x | 3.45× |

The sight names aren't exact: at FOV 110 the "2x" is about 2.2× and the "3x" about 3.5×.

## How much Apex slows the mouse when aiming

Apex slows the mouse by a fixed amount for each sight, then applies your per-optic multiplier. That amount is **larger than the on-screen zoom**, so aiming feels slower than what you see suggests.

| Sight | Measured with a ruler (full circle) | Slowdown before multiplier |
|---|---|---|
| Hip-fire, 2.27 | 24.1 cm (formula: 22.9 cm) | 1.00× |
| 1x holo, multiplier 0.9 | 34.3 cm | about 1.3–1.4× |
| Iron sights, multiplier 0.9 | 40.6 cm | about 1.5× |
| 2x, multiplier 1.0 | about 61 cm | about 2.4–2.5× |
| 3x | not measured yet | estimated 3.7× |

Hand measurements are about ±10%. A 2019 Apex University analysis found the same pattern, giving about 2.41× for the 2x at max FOV ([source](https://www.reddit.com/r/apexuniversity/comments/ebnu1y/ads_sensitivity_fix)).

## Setting it in Apex

Settings → Mouse/Keyboard → **Per Optic ADS Sensitivity: On**, then set each sight. Iron sights and 1x optics share one setting.

The [sensitivity finder](../tools/sensitivity-finder.html) tests each sight the way it's used: 1x with tracking and flicks, 2x with tracking only, 3x at long range.
