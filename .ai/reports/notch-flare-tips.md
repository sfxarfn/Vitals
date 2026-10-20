# Notch flare tips

**Status:** Done — 2026-10-20 (unbuilt)
**Why:** The top flare tips showed a 1px vertical line where they met the screen edge. A later fix left a kink between the edge and the curve.

## What changed
- `Vitals/Notch/NotchShape.swift`:
  - The flares start on `minY` again, so their tangent is horizontal at the screen edge.
  - The 1pt overhang above the edge stays, so the menu bar does not show through as a hairline.
  - The overhang now reaches each tip through a 6pt sliver. The sliver keeps the same horizontal tangent and tapers outward, where the old overhang ended in a square.

## Verification
- None run. The user builds in Xcode. Look at both top corners in idle, peek and the panel, on both screens.

## Notes
- Rejected: starting the flares 1pt above the edge. By the time the curve reaches the edge it has dropped about 15°, which reads as a kink.
- Rejected: an overhang only between the flares. The user found it less smooth.
- If the line comes back, suspect the window's top landing a pixel below the screen edge (`NotchController.place`). Fix that alignment rather than the shape.

## Follow-up: clipped tips on the external display — 2026-10-20
The tips looked cut again after the synthetic-notch scaling landed.
- Cause: `NotchMetrics.screenWindowSize` was `windowSize × scale`, a
  fractional size on a scaled (synthetic) notch. AppKit rounds the window
  frame, so its top landed a sliver below the screen edge — hidden across the
  thick middle, visible where each flare thins out to meet the edge.
- `Vitals/Notch/NotchState.swift` — `screenWindowSize` rounds both sides up
  to whole points, so `place()` puts the top exactly on `screen.frame.maxY`.
  The shape is unchanged.
- Pending after building: both top corners on the external display, idle and
  panel; the MacBook screen (scale 1) should look the same as before.
