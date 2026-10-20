# Peek grows out of the centre

**Status:** Done — 2026-10-19
**Why:** On hover every peek item slid in from the right. It should open out
of the notch's centre.

## What changed
- `Vitals/Notch/NotchView.swift` — root cause: the content lived in the
  growing box's overlay, which is placed from the box's origin; that origin
  moves left as the box widens, carrying everything with it. `sizedBox` is
  now a `ZStack` of `silhouette` (fill, rim, underglow, shadows, glow) and
  `contentLayer`, which is framed to the fixed window width and clipped by
  `CentredNotch` (see `peek-open-smoothness.md`).
- `Vitals/Notch/Marks.swift` — `ClaudeWorkingMark`'s forever rotation is
  scoped with `.animation(_:body:)` to the rotation alone. The old
  `.animation(value:)` put the loop on the whole transaction, so the mark's
  position animated too and slid in from the edge.
- Peek keeps the panel's own entrance (`interactionTransition`: fade plus a
  0.92 scale from the top centre), so it opens the same way the battery and
  other panel pages do. `PeekView.swift` is unchanged from `HEAD`.

## Verification
- Not built or run here (project rule). Pending: hover — peek fades and
  grows out of the centre, nothing from the right edge; every other state
  still grows symmetric (Events, build pill, panel); panel controls and drop
  still hit. With a Claude Extension active the burst spins in place.

## Notes
- A per-item spread (each flank sliding out, the second row diagonally)
  was built and then removed: eight geometry measurements plus a per-frame
  environment change made the open feel heavy.
- Extension marks outboard of peek still sit in their strips as the shape
  grows.
