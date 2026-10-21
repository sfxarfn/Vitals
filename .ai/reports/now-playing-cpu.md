# now-playing-cpu — Cheaper Now Playing page and expanded-notch timer

**Status:** Done — 2026-10-21
**Why:** With music playing, holding the Now Playing panel open cost 11–12% CPU in a Debug build, against about 1.3% on the Shelf page.

## What changed
- `Vitals/Interactions/NowPlayingPage.swift` — `EqualizerBars` is now three Core Animation layers (`NSViewRepresentable`) instead of SwiftUI-driven bars; the timeline ticks once a second instead of twice; the cover's blurred shadow is a radial gradient.
- `Vitals/Events/Telemetry.swift` — while the notch is expanded the die temperature sensors are read about every 3 seconds (CPU stays at 1 second); a thermal-state change forces a read.
- `.ai/steering/lifecycles.md` — the temperature cadence.

- `Vitals/Notch/SpinLayers.swift` (new), `Vitals/Activities/BuildPill.swift`, `Vitals/Notch/Marks.swift` — the Xcode build ring and the Claude burst are Core Animation layers too, for the same reason; both sit on the resting notch for minutes.

## Verification
- Measured with `top` and `sample` on the running Debug build, panel held on each page: Now Playing playing 11–12% before, about 3.3% after; Shelf about 1.3%.
- Not measured in a Release build, where all numbers should be lower.

## Notes
- Two earlier attempts were measured and rejected: a `repeatForever` SwiftUI animation (stepped every display frame) and a 12 fps `TimelineView` (re-lays-out the whole hosting view per tick).
- The BuildWatcher's 1-second Accessibility read was left alone: it re-reads one cached subtree and its cancel logic and debug asserts are calibrated to 1 second.
- The ring and burst were converted by the same reasoning but not measured.
