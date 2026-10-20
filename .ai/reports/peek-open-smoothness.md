# Smoother idle → peek

**Status:** Done — 2026-10-19
**Why:** Opening peek from idle felt laggy. Not profiled; these are the three
per-frame costs the growth was paying that it did not need.

## What changed
- `Vitals/Notch/NotchView.swift`
  - Content layer clipped with `CentredNotch` (a path clip that draws the
    notch outline at an animatable width/height, centred) instead of
    `.mask` — the mask was a window-sized offscreen alpha pass every frame.
  - Interaction shadows use fixed radii (6 / 24) and fade as a layer
    instead of interpolating radius from 0 on every frame. The layer stays
    in the tree: a first version inserted and removed it, and since the
    shadow source is a black copy of the shape, that copy sat at its final
    (or old) size while the real shape grew — the growth blinked.
  - Thermal and CPU glow bars are only in the tree while a glow is up; two
    clear 20pt-blurred bars were being re-rendered at the growing height.

## Verification
- Not built or run here (project rule). Pending: hover from idle — growth
  and the spread should hold frame rate; the peek shadow fades in with the
  shape; content is still clipped to the outline while it grows; the edge
  glow still fades in and out when thermal or CPU trips it.

## Notes
- Untouched and possibly still felt: the 0.25s dwell before peek opens
  (`NotchController.dwellDelay`), and the very first peek after launch
  building its views and SF Symbols cold. Profile with Instruments
  (SwiftUI + Core Animation) if it is still not smooth.
