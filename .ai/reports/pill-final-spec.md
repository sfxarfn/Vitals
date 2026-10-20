# Pills: the final spec

**Status:** Reverted — 2026-10-19. The pills are back to their original look; see `pill-revert.md`.
**Why:** The user settled the pill design after several mockups. It supersedes
the one-line text pills in `pill-refinements.md`:
- Events become icon-only.
- Activities share one fixed width.
- Heat loses its pills, because the edge glow already says it.
- The VPN reminder is the one Event that keeps text.

## What changed
### Widths (`NotchState.swift`, `NotchMetrics`)
- `glyphFlank` (40) is the one symmetric width for every Event.
- `vpnReminderFlanks` (52, 52): "VPN" beside the lock, against "30m" beside the
  clock.
- `activityFlanks` (64, 64) for every Activity. Set by a 4-digit done/total at
  9pt beside an 18pt ring, plus about 8pt of corner clearance.
- Removed: `sidedFlank`, `lineFlanks`, `chargeFlanks`, `accessoryFlanks`,
  `trackFlanks`. `windowSize` now sizes from the Activity width.
- `flankSlot(…, outer:)` adds a third placement: pinned to the outer edge,
  with slack falling inward. It is used for right-aligned Activity content.

### Activities
- **Build with counter** (`BuildPill.swift`): the Xcode icon centred, then
  the old layout of done over total in small stacked digits beside an 18pt
  blue ring. It is right-aligned and 8pt clear of the corner.
- **Build without counter**, and **vitals-notify activity**
  (`ExternalActivityPill.swift`): the icon centred, then elapsed time and a
  spinner, right-aligned. `ElapsedSpinner.format` shows m:ss under an hour and
  h:mm above, in a fixed 34pt width set by "59:59".

### Events (`EventPills.swift`, `VerdictPill.swift`): `glyphPill`, a glyph per flank
| Event | Left | Right |
|---|---|---|
| Charging started | orange bolt | `battery.N` at the level (`batteryStep`) |
| Charged | green battery-bolt | green ✓ |
| Accessory | device glyph | ring only, green / red ≤20% (Bluetooth mark if no level) |
| Audio lost | unchanged | unchanged |
| Build verdict | Xcode icon | green ✓ / red ✗ (failure persists, red line) |
| vitals-notify event | subject symbol | outcome symbol in its tint (failure persists) |
| Track change | 20pt cover | equaliser in the cover's colour |
| VPN connected | orange lock | `globe` |
| VPN reminder | orange lock + "VPN" | "30m"/"1h"/"2h"/"4h" + `clock`, right-aligned |

- The track-change title and artist text, and the 9-character caps, are
  reverted (`TrackChange.capped`/limits removed).
- `Accessory.batteryTint` is now green, or red at ≤20%.
- `BuildProgress.duration` / `errorCount` and the verdict timing are removed,
  since the verdict shows no text.

### Thermal (`EventEngine.swift`)
- Every thermal Signal is `.glow`. There are no serious, critical or "Cooling
  down" pills. The edge glow tints by level: fair and serious orange, critical
  red (`glowTint == tint`).
- The thermal state machine is reduced to `setThermalActive`. Removed:
  recovery (`Event.recovered`, `recoverySymbol`/`Title`, `thermalRecovery`,
  `fireThermal`, `thermalRank`), `Side`, `Signal.side` and `isCompact`.
- `.sided` is gone end to end: the state, `sidedPill`/`flank`, the
  controller's per-side timers and `clearSided`, the shape key, and the
  thermal and all-clear previews.
- The DEBUG self-check's thermal section now asserts that no level or
  transition presents, and that the glow follows the state with critical red.

## Verification
- Not built or run here (project rule). After building, check:
  - The DEBUG self-checks pass at launch.
  - Settings → Preview:
    - Every Event is two glyphs on one symmetric width, and nothing crowds the
      corners.
    - The VPN reminder reads "🔒 VPN | 30m 🕐".
    - Builds (with and without a counter) and "Tests running" share one width.
      The counter shows done/total and the ring; the others show a ticking
      time and a spinner, right-aligned.
  - A Bluetooth device with a battery shows a ring only, red at 20% or under.
  - Under thermal pressure the edges glow, orange and then red at critical,
    with no pill at any step.
  - A failed build still shows ✗ with the red line until you hover the notch.
