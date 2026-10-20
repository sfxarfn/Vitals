# Drop target — one signal, one scale, one accent

**Status:** Done — 2026-10-18
**Why:** The open panel's drop state read as broken: the silhouette rim, the
shelf box's 2pt white ring and the dashed ghost all lit at once, the
silhouette stretched x and y by different amounts, and cyan, white and a
blue→purple gradient competed for the same interaction.

## What changed
- `Vitals/Notch/NotchView.swift` — `silhouetteX`/`silhouetteY` → one
  `silhouetteScale` (1 + reach × 0.025, landing press-in × 0.98). Rim and
  underglow now only show during the pull, never on the open panel.
  `shelfAccent` is `.accentColor` and internal.
- `Vitals/Interactions/PanelView.swift` — shelf box target: fill 0.10, 1pt
  accent line and a soft accent glow inside, replacing the 2pt white ring.
  AirDrop is a 52pt icon strip (was a 104pt labelled tile): white 9% at
  rest with an accent mark, solid accent with a white mark and 1pt white
  edge when targeted; the name is in `.help` and the accessibility label.
  The battery, thermal and network pages keep their 104pt left tile, so
  that swap no longer matches widths. It no longer
  grows at all — hover or drop scale put its corner under the camera
  housing. Instead a soft radial light (`airDropSpotlight`, state
  `airDropSpot`) sits under the pointer on hover and under the file during
  a drag; a press dims it. `VitalsPressStyle(scales:)` turns the growth off.
- `Vitals/Interactions/ShelfMotion.swift` — `ShelfGhost` is a plain filled
  slot, no dashed outline.
- No pointer following: removed the silhouette's sideways nudge and lean
  (`FileDrag.lean`, `dragLean`, `silhouetteNudge`), the shelf chips' magnet
  tilt, the dragged-out chip's tilt (`liftTilt`, `liftSample`) and the AirDrop
  tile origin plumbing that only fed the lean. The rim gradient is now fixed
  top-to-bottom.

## Verification
- Not built or run here (project rule). Pending: drag a file over the closed
  notch (rim + glow in accent), over the open shelf (only the box lights),
  over AirDrop (tile brightens and the light follows the file, no growth;
  hovering it shows the same light under the pointer), and drop (no stretch). Moving the
  file left and right must not shift the notch or tilt any chip; dragging a
  chip out must not tilt it.

## Notes
- Deliberately departs from `design.md` at the user's request.
- Open/close `RubberEffect` keyframes are still non-uniform; left as-is.
