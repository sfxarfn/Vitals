# .ai — start here

Context for agents working on Vitals. Read [`steering/product.md`](steering/product.md)
before proposing anything; most "obvious improvements" are already decided
against in there, with reasons.

## Documents

| Path | What it holds |
|---|---|
| [`steering/product.md`](steering/product.md) | What Vitals is, the interaction model, the event catalog, what was cut and why, and a **Settled** section of platform limits that are not worth re-investigating. |
| [`../CLAUDE.md`](../CLAUDE.md) | Build rules. Short version: never run `xcodebuild` or `swift build`, never launch the app — the user does that in Xcode. Make the edit, say what to look for, stop. |

## Code map

Roughly the order things happen in.

| File | Role |
|---|---|
| [`VitalsApp.swift`](../Vitals/VitalsApp.swift) | `@main`, accessory-policy app, Settings scene. Runs the debug self-check. |
| [`NotchController.swift`](../Vitals/NotchController.swift) | Owns the `NSPanel`, finds the notch, drives hover/drag, queues what the notch shows. The one `@MainActor` hub. |
| [`CGSSpace.swift`](../Vitals/CGSSpace.swift) | Private-API window space, so the panel survives a space swipe. |
| [`Telemetry.swift`](../Vitals/Telemetry.swift) | Power and stall-risk sampling. Push where macOS offers it, poll only CPU. |
| [`EventEngine.swift`](../Vitals/EventEngine.swift) | Readings → signals, with hysteresis and a cooldown. Pure value type; has a `DEBUG` self-check. |
| [`Accessory.swift`](../Vitals/Accessory.swift) | Bluetooth accessory connect detection and battery. |
| [`BuildWatcher.swift`](../Vitals/BuildWatcher.swift) | Xcode build/archive progress, scraped off the toolbar over the Accessibility API. |
| [`NotchView.swift`](../Vitals/NotchView.swift) | `NotchMode`, `NotchMetrics`, and every pixel of the notch. |
| [`NotchShape.swift`](../Vitals/NotchShape.swift) | The outward-flaring notch outline. Third-party, see its header. |
| [`Shelf.swift`](../Vitals/Shelf.swift) | The drop box and the AirDrop plumbing. |

## Things that will bite you

- **`NotchMetrics.windowSize` is the panel's real size in every mode.** States
  inset into it; the frame never changes. Adding a wider state means widening
  that, or the new state gets clipped.
- **The notch's own width is dead space.** The camera housing sits over it, so
  pill layouts put content in the two flanks and leave the middle empty.
- **Detection channels are not interchangeable.** Input devices come from
  IOKit HID matching, headsets from a CoreAudio default-output listener. Neither
  sees the other's devices. HID usage numbers only mean something *paired with
  their usage page* — usage 1 is a Pointer on page 1 and a Consumer Control on
  page 12, which is what got a headset drawn as a mouse once already.
- **IOKit first-match notifications replay everything already attached** the
  first time the iterator is drained. That drain is also what arms the
  notification, so it cannot be skipped — only its results discarded.
- **Hardware settles late.** Services publish before their properties do, and a
  peripheral needs a moment before it will answer a GATT read. The delays in
  `Accessory.swift` are calibration knobs, not padding.

## Conventions

- Comments explain *why*, especially where the code looks wrong but isn't.
  Match that density; do not narrate what the line already says.
- `ponytail:` marks a deliberate shortcut with a named ceiling and an upgrade
  path. Grep for them before assuming something was an oversight.
- The project uses a synchronized file group — new files in `Vitals/` are picked
  up without touching `project.pbxproj`. Build *settings* still need editing
  there (both `Debug` and `Release`).
