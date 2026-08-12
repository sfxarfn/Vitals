# .ai — start here

Context for agents working on Vitals. Read [`steering/product.md`](steering/product.md)
and [`steering/design.md`](steering/design.md) before proposing anything; most
"obvious improvements" are already decided against, with reasons.

The steering docs are the **target**, not a description of the code. Where the
two disagree, the code is what has to move.

`product.md` was rebuilt from an older doc that is no longer in the tree. Three
things it settled are still binding and are not written down anywhere else:

- **Vitals cannot be sandboxed.** Reading Xcode's toolbar needs the Accessibility
  grant, which a sandboxed app can never hold — `ENABLE_APP_SANDBOX` stays `NO`
  in both configs.
- **Classic Bluetooth headsets cannot report battery.** Only BLE answers the GATT
  Battery Service; the rest is a private framework.
- **Memory pressure is not watched, and the omission is the finding.** The
  original doc named it as this machine's daily pain. It is not — thermal is.
  Five memory Signals were sampled, thresholded and deleted. The thermal panel
  prints one memory number, which is not a walk-back: it has no threshold, no
  pill and no glow, and nothing in the app decides anything from it. Giving
  memory a `Signal` again means re-testing the premise first, not re-reading
  this note.

None is worth re-investigating. The full old doc, including what was cut and why,
is in git history: `git show d02f2ba:.ai/steering/product.md`.

## Documents

| Path | What it holds |
|---|---|
| [`steering/product.md`](steering/product.md) | What Vitals is and what the notch says. Every state it can take, in three categories — **Interactions**, **Events**, **Activities** — plus Idle as the floor and Glow as the residue an Event leaves behind. |
| [`steering/design.md`](steering/design.md) | How the notch looks and moves: shape, flank layout, how width is bought, which states may grow vertically, and the grow/shrink rule. |
| [`../CLAUDE.md`](../CLAUDE.md) | Build rules. Short version: never run `xcodebuild` or `swift build`, never launch the app — the user does that in Xcode. Make the edit, say what to look for, stop. |

## Code map

The tree mirrors `product.md`: one directory per category, plus `Notch/` for the
surface all three draw on. A new state goes in the directory of the category it
belongs to — if it fits none of them, it does not belong in the notch.

### `Notch/` — the surface

| File | Role |
|---|---|
| [`NotchState.swift`](../Vitals/Notch/NotchState.swift) | `NotchState` (every shape, grouped by category), `NotchMetrics` (every width, each a named ceiling), and `flankSlot` — the one place content is pinned against the camera housing. |
| [`NotchController.swift`](../Vitals/Notch/NotchController.swift) | Owns the `NSPanel`, finds the notch, drives hover and drag, queues what the notch shows and arbitrates the two sides. The one `@MainActor` hub. |
| [`NotchView.swift`](../Vitals/Notch/NotchView.swift) | The black shape: growth, shadows, edge glow, and the one switch that routes each state to its category. |
| [`NotchShape.swift`](../Vitals/Notch/NotchShape.swift) | The outward-flaring notch outline. Third-party, see its header. |
| [`Marks.swift`](../Vitals/Notch/Marks.swift) | The Bluetooth and AirDrop glyphs, drawn by hand — SF Symbols ships neither. |
| [`CGSSpace.swift`](../Vitals/Notch/CGSSpace.swift) | Private-API window space, so the panel survives a space swipe. |

### `Events/` — the machine talking

| File | Role |
|---|---|
| [`Telemetry.swift`](../Vitals/Events/Telemetry.swift) | Power, die temperature and CPU load. Push where macOS offers it, poll only CPU. |
| [`EventEngine.swift`](../Vitals/Events/EventEngine.swift) | Readings → signals, with hysteresis and a cooldown. `Signal` is one case per Event `product.md` lists under Power, Thermal and CPU — nothing else. Owns `Loudness` (pill or glow) and `Side`. Pure value type; has a `DEBUG` self-check. |
| [`Accessory.swift`](../Vitals/Events/Accessory.swift) | Bluetooth accessory connect detection and battery. |
| [`EventPills.swift`](../Vitals/Events/EventPills.swift) | How an Event draws: sided, compact, accessory, audio lost. |
| [`VerdictPill.swift`](../Vitals/Events/VerdictPill.swift) | How a finished build draws. An Event, not the tail of the Activity — the build has handed the notch back before this queues. |

### `Activities/` — work you started

| File | Role |
|---|---|
| [`BuildWatcher.swift`](../Vitals/Activities/BuildWatcher.swift) | Xcode build/archive progress, scraped off the toolbar over the Accessibility API. Ends by handing a verdict to `onVerdict`, which the controller queues as an Event. |
| [`BuildPill.swift`](../Vitals/Activities/BuildPill.swift) | How a running build draws. |

### `Interactions/` — you reached for it

| File | Role |
|---|---|
| [`PeekView.swift`](../Vitals/Interactions/PeekView.swift) | Peek: the two stat flanks and the row of controls under them. |
| [`PanelView.swift`](../Vitals/Interactions/PanelView.swift) | The panel: `PanelBody` and its one body slot, the back button, the shelf and the AirDrop tile. |
| [`BatteryReadout.swift`](../Vitals/Interactions/BatteryReadout.swift) | The battery in words and numbers, shared by both Interactions so the wording cannot drift. |
| [`ThermalReadout.swift`](../Vitals/Interactions/ThermalReadout.swift) | The die, same way: peek's degree and tint, and the panel behind them — per-block temperatures, throttle headroom, memory. |
| [`Shelf.swift`](../Vitals/Interactions/Shelf.swift) | The drop box and the AirDrop plumbing. |

[`VitalsApp.swift`](../Vitals/VitalsApp.swift) sits at the root: `@main`, the
accessory-policy app, the Settings scene, and the debug self-checks.

## Things that will bite you

- **`NotchMetrics.windowSize` is the panel's real size in every state.** States
  inset into it; the frame never changes. Adding a wider state means widening
  that, or the new state gets clipped.
- **The notch's own width is dead space.** The camera housing sits over it, so
  every layout puts content in the two flanks and leaves the middle empty. Each
  flank hugs the notch and the slack falls outward, unless it asks to be
  centred — `flankSlot` is the only place that decides either, so nothing lays
  out a flank by hand. Optical corrections to what a flank *holds* — a fixed
  box, a rotation, a point of offset — are not that: they live in the content,
  above the `flankSlot` call, and `design.md` lists them as the third lever.
- **`Signal` is closed to `product.md`'s Event list.** A reading the notch never
  says anything about is not a Signal — it was sampled, thresholded and thrown
  away, and five of those were deleted once. Add the doc entry first, then the
  case; `Telemetry` only samples what some Signal reads.
- **`NotchView` is one type across five files.** Extensions cannot add storage,
  so every `@State` is declared in `NotchView.swift` and is internal, not
  private, because the category files read it.
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
- `// MARK:` sections everywhere they help — files are read by category, and the
  jump bar is how you get to one.
- The project uses a synchronized file group — new files and new directories
  under `Vitals/` are picked up without touching `project.pbxproj`. Build
  *settings* still need editing there (both `Debug` and `Release`).
