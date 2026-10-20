# Peek and panel merged into one paged panel

**Status:** Done — 2026-10-19
**Why:** Peek and the panel were two sizes of one surface, and every click
from one to the other resized the notch. Hover now opens a single panel the
height of the old one, with the shelf visible straight away and the readouts
one arrow away.

## What changed
- `Vitals/Notch/NotchState.swift` — `NotchState.peek` removed. New
  `panelFlanks` (82, 82) for the panel; `windowSize` takes the wider of the
  panel and a `statFlanks` Activity with both Extension slots.
- `Vitals/Notch/NotchController.swift` — hover always opens `.panel`; every
  `.peek` check dropped (interactive window, drag approach from rest only).
- `Vitals/Notch/NotchView.swift` — peek's transition, shape key and rubber
  "closing" case removed; `panelBody` resets to the shelf whenever the
  panel closes.
- `Vitals/Interactions/PanelView.swift` — rewritten body:
  - housing row: die (clicks to Thermal) and CPU in the flanks, pinned to
    the panel's outer edges by the body's 12pt inset (`panelInset`) so they
    line up with the summary column and the right arrow; slack falls inward
    toward the housing (other states' pills still hug the housing);
  - 44pt summary column: battery (`AC` with a plug when full on the
    adapter, else `NN%`) and download rate (`5K`, `1.2M`), each jumping to
    its page and outlined while that page is up;
  - `PanelBody` is `CaseIterable` (Shelf → Battery → Thermal → Network);
    chevron arrows outside the slot walk it and wrap; dots under the slot,
    each clickable to its page (10pt hit box round the 4pt mark);
  - a file dragged over any page switches to the shelf;
  - Back button, trash and gear removed (Clear shelf and Settings… stay in
    the context menus); AirDrop strip 52 → 40pt.
  - `readout`, `rateFormatter` and new `compactRate` moved here.
- `Vitals/Interactions/PeekView.swift` — deleted.
- `BatteryReadout.swift`, `ThermalReadout.swift`, `NetworkReadout.swift` —
  hero tile 104 → 70pt, gaps 12 → 6; thermal degree 26 → 22pt and its
  headroom line "N° left"; network rate 20 → 16pt. Peek's battery summary
  (`batteryStatus` and its wording) removed.
- `.ai/README.md` — code map updated.
- Comments across `Vitals/` that still described peek (NotchView, the
  controller, NotchState, the three readouts, VitalsPressable, EventEngine,
  Telemetry) rewritten for the single panel; no code change in them.

## Verification
- Not built or run here (project rule). Pending: hover opens the panel on
  the Shelf page; arrows and dots walk four pages and wrap; summary tiles
  and the degree jump to their pages; full + adapter shows "AC"; a drag
  over a readout page flips to the shelf and drops land; numbers fit their
  tiles on all three pages, on the MacBook and on the external display;
  the 🌡 degree's left edge sits over the summary column's left edge and the
  CPU stat's right edge over the right arrow's.

## Notes
- Deliberately departs from `design.md` and `product.md` (peek as its own
  Interaction) at the user's request; the steering docs were not updated.
- `NotchView.show` is no longer called from the panel; left in place.

## Follow-up: feature pages vs. stat details — 2026-10-19
- `PanelView.swift` — `PanelBody` split in two. `PanelPage` (`.shelf` for
  now) is the feature pages the arrows and dots walk; `PanelDetail`
  (`.battery`, `.thermal`, `.network`) is a stat's numbers, opened over the
  current page by the die flank or a summary tile and never in the cycle.
  Arrows and dots only show with no detail up and more than one page, so
  today they are hidden and the Shelf slot takes their room. The same stat
  closes its detail, another switches it, and while a detail is up the
  housing row's left flank cross-fades the degree for "‹ Back" (the old
  panel's back button, at the degree's outer-edge position), which returns
  to the feature page; the CPU flank stays. The active summary tile keeps
  its outline.
- `NotchView.swift` — `panelBody` state → `panelPage` + `panelDetail`;
  `showShelf()` (in `PanelView`) resets both when the panel closes, when a
  file is dragged over the panel and when a drop lands.
- Comments in the readouts, `NotchState`, `NotchController` and the
  `.ai/README.md` code map now call the readouts details, not pages.
- Pending after building: no arrows or dots with only Shelf; temp flank,
  AC tile and network tile open their details and close them on a second
  click; Back replaces the degree while a detail is up and returns to Shelf;
  a drag over a detail flips to Shelf; reopening the panel starts on Shelf.

## Follow-up: details grow out of their tile — 2026-10-19
- `PanelView.swift` — while a detail is up the summary column is gone and
  the detail takes the whole body. Its background (white 6%, radius 14) is
  matched (`GrowAnchor` → `matchedGeometryEffect`, namespace `panelGrow`)
  to what opened it: the AC/battery tile, the network tile, or the
  temperature flank (an invisible rect behind the readout). It grows out of
  that frame on a spring (response 0.35, damping 0.85); the numbers fade in
  0.16s later, and the column and shelf fade out. Back, or the same stat,
  reverses it. Reduce Motion turns the anchors off — a plain crossfade. The
  body is a `ZStack` of three siblings so the background and the numbers
  can run on different timing; the panel's shape never changes.
- The summary tiles' 1pt "active" outline is removed — the column is not
  on screen while its detail is.
- `NotchView.swift` — `@Namespace var panelGrow`.
- Battery, thermal and network details: hero tile 70 → 96pt; thermal's
  headroom line back to "N° of headroom".
- Pending after building: each of the three opens by growing out of its
  tile or the degree with the column gone; Back shrinks it back in and the
  column and shelf return; the notch outline does not move during either;
  with Reduce Motion on it is a crossfade; the details' numbers fit at 96pt.

## Follow-up: hover light on the summary tiles — 2026-10-19
- `PanelView.swift` — the AirDrop strip's cursor-following light is now a
  shared modifier, `.hoverSpotlight(cornerRadius:reach:aimed:bright:)`
  (`HoverSpotlight`), which keeps the pointer position in its own `@State`.
  AirDrop passes its drop point and `airDropTargeted` so a file still holds
  the brighter light (reach 64). The AC/battery and network tiles use it at
  reach 34 with `VitalsPressStyle(scales: false)` (no growth, press dims).
  The light sits on the tile, not on the matched background, so it does not
  travel with the grow.
- `NotchView.swift` — `airDropSpot` now only carries the drag's aim point.
- Pending after building: hovering either summary tile shows a light that
  follows the pointer and fades out on leave; AirDrop behaves as before on
  hover and while a file is aimed at it; opening a detail from a tile does
  not carry the light into the grow.

## Follow-up: CPU opens the thermal detail — 2026-10-19
- `PanelView.swift` — the CPU flank is a button (`VitalsPressStyle`) that
  toggles the thermal detail, like the degree. A new `GrowOrigin`
  (`.detail(_)`, `.cpu`, `.cpuAtRest`) replaces `PanelDetail` as the grow
  anchor id, and `toggleDetail(_:from:)` records where the detail opened
  from, so thermal grows out of whichever stat was clicked and shrinks back
  into it. The CPU stays on screen while the detail is up, so its anchor
  switches to `.cpuAtRest` then instead of sharing the detail's id.
- `NotchView.swift` — `@State var detailOrigin: GrowOrigin?`.
- Pending after building: clicking the CPU % opens thermal growing out of
  the right flank; Back or clicking it again shrinks it back there; the
  degree still opens thermal from the left; the CPU number does not jump
  or fade while the detail is open.

## Follow-up: arrows stay with one page — 2026-10-19
- `PanelView.swift` — the chevron arrows always sit outside the Shelf slot
  on the feature page. With one `PanelPage` they are white 0.2 and
  `.disabled` (so `PressableChrome` gives no hand cursor, hover or press);
  with a second page they go live at white 0.6 and wrap. `pagingShown` is
  now `canPage` (more than one page); the dots still need it. A detail
  still hides the arrows with the rest of the page.
- `VitalsPressable.swift` — `PressableChrome` only installs its
  hand-cursor tracking view while the control is enabled; before, a
  disabled button still showed the hand on enter.
- Pending after building: dim arrows either side of the shelf that do
  nothing and show no hand; the shelf is narrower by their width; the panel
  size does not change.

## Follow-up: charging vs. AC in the summary tile — 2026-10-19
- `BatteryReadout.swift` — on the adapter below 100% the battery tile shows
  the charging bolt and the percentage (was: the bolt only when
  `isCharging`, which drops out during negotiation and top-off pulses).
  "AC" with the plug stays reserved for a full pack running off the wall;
  off the adapter it is the level glyph and the percentage.
- Pending after building: plugged in below 100% → bolt + "NN%"; plugged in
  at 100% → plug + "AC"; unplugged → battery glyph + "NN%".

## Follow-up: quieter hover light — 2026-10-19
The hover light read as too much on AirDrop, the summary tiles and Now
Playing.
- `PanelView.swift` (`HoverSpotlight`) — the light drops from 24% to 9%
  white, and from 38% to 20% while a file is aimed at AirDrop. A 1pt
  white-14% hairline now fades in on hover (0.18s), so the edge says "live"
  and the light only fills in under it.
- `NowPlayingPage.swift` — the Now Playing tile loses the light entirely. It
  is not a button, and lighting it promised a click it would not answer; its
  artwork, play/pause and time-skip buttons still react.
- Pending after building: hovering AirDrop and the battery and network tiles
  shows a thin edge and a faint light that follows the pointer; a file over
  AirDrop is still clearly brighter; the Now Playing tile does not light up.

## Follow-up: open early on a file drag — 2026-10-19
A file dragged to the notch had to reach the menu bar before the panel
opened. Pushing a drag that far up hit the screen's top edge, and macOS
opened Mission Control instead.
- `NotchController.swift` — `commitApproach`, driven by the same
  `trackFileDrag` samples as the rim and glow. When `FileDrag.pull` reaches
  0.5 (about 55pt under the housing) and the pointer is inside the area the
  open panel will cover, a 0.12s timer arms. When it fires it checks the
  pointer again: still a file drag, still at rest, still within that pull and
  that area. Then it calls `grow()`, which opens on Shelf because
  `openingPage` sees the drag. A quick sweep across the top leaves before the
  timer fires, and `endFileDrag` cancels it. The in-notch trigger in
  `dragMoved` is kept as the fallback.
- No change to the stay-inside region: every drag event refreshes `lastDrag`
  before `mouseMoved` runs, so the panel cannot shrink under a moving drag.
  Requiring the pointer to be inside the panel's area also means the file is
  already over the drop target when it opens.
- Pending after building: drag a file from Finder toward the notch. The panel
  opens on Shelf while the cursor is still below the menu bar, Mission
  Control never appears, and the drop lands in the shelf. Dragging a file
  quickly across the top of the screen does not open it, and a window drag
  never does.

## Follow-up: arrows answer hover — 2026-10-19
- `PanelView.swift` — `PageArrow`: on hover a live arrow brightens from white
  0.6 to 1, leans 2pt in its direction (spring) and gets a faint white-7%
  column showing its full-height hit area. Disabled (one page) arrows do
  nothing. Reduce Motion: no lean.
- Pending after building: hover each arrow; it lights up and nudges toward its
  page, and clicking still pages.

## Follow-up: arrow hover is a circle, not a column — 2026-10-19
- `PanelView.swift` (`PageArrow`) — the full-height white-7% column read as an
  empty tile beside AirDrop. Hover now draws a 20pt white-12% circle behind
  the chevron, growing in from 0.6×, with the same brighten and 2pt lean. The
  hit area is still the full-height 14pt strip, and the circle overhangs into
  the gap, so the slot does not move.
- Pending after building: hovering an arrow shows a small circle behind the
  chevron only, with no column.
