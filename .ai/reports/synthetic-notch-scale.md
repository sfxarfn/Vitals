# Scale the notch's content on an external display

**Status:** Done — 2026-10-19
**Why:** On an external display the synthetic notch is only menu-bar tall, so
peek's shape was shorter and narrower while its type, glyphs and gaps stayed
at full size — crowded against the top and the bottom curve.

## What changed
- `Vitals/Notch/NotchState.swift` — `NotchMetrics.scale` (screen points per
  layout point) and `NotchMetrics.measured(_:synthetic:)`: a synthetic notch
  gets `scale = clamp(height / 38, 0.75…1)` and its `notch` stored in layout
  points (measured ÷ scale); a real housing stays at 1. New
  `screenWindowSize` and `screenShape(for:extensions:)` convert back.
- `Vitals/Notch/NotchView.swift` — the whole notch is laid out in layout
  points and scaled by `metrics.scale` from the top centre into a
  screen-sized frame, so shape, type, glyphs and gaps shrink together.
- `Vitals/Notch/NotchController.swift` — window frame, hover notch rect, and
  the peek/panel stay-inside regions use screen points.

## Verification
- Not built or run here (project rule). Pending: on the external display,
  peek should look like the MacBook's, only smaller, flush with the menu bar;
  hover, leaving peek, the panel, shelf drop and AirDrop all still hit in the
  right place. On the MacBook nothing should change (scale 1).

## Notes
- 38pt is the same calibration the corner radii already used; 0.75 is the
  floor so a 24pt menu bar does not take the 12pt readings under ~9pt.
