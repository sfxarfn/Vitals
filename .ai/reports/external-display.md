# External display support

**Status:** Done — 2026-08-27
**Why:** The notch was built-in display only. Working on an external monitor meant
losing every Event, Activity and Interaction until you looked back at the laptop.

## What changed
- `Vitals/Notch/NotchController.swift` — `notchScreen()` split into a per-screen
  `notchRect(of:)` that synthesizes a menu-bar-tall, 180pt notch on a screen with
  no auxiliary areas, gated on the new `externalDisplay` default. `rebuildWindow`
  keeps its hosting view and its CGSSpace across a move; `place` is the one framer
  for `rebuildWindow`/`repin`. `followPointer()`, called from `mouseMoved`, moves
  the panel to the pointer's display, from rest only.
- `Vitals/VitalsApp.swift` — General gets a "Show on external displays" toggle
  writing `externalDisplay` and calling `setExternalDisplay`.
- `README.md` — requirement now names the setting as the alternative to a housing.

## Verification
- Not built or run — build rule. Nothing verified on device.

## Notes
- One panel that follows the pointer, not one panel per screen: hover geometry,
  `ignoresMouseEvents` and the drag baseline are all single-window in the
  controller. Mirroring on every display means per-screen hover state.
- `menuBarVisible()` is a global layer-24 probe: a second display keeps a menu bar
  up while the first is fullscreen, so the glow and hover no longer suppress in
  that case. Pre-existing ceiling, now reachable more often.

## Follow-ups
- The private CGS space belongs to the display it was created on; a panel parked
  in it never draws on another. It is given up on a synthetic notch, so the
  swipe-pinning there is `.canJoinAllSpaces` + `repin` only.
- `NotchMetrics.synthetic` scales the two corner radii by the height actually
  present (`notch.height / 38`). A menu-bar-tall notch was drawing a 22pt flare
  and a 28pt bottom curve into 24pt of height, which pinched the sides on any
  state wider than idle. A real housing scales by 1 and is untouched.
