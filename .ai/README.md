# .ai — start here

Context for agents working on Vitals. Read [`steering/product.md`](steering/product.md),
[`steering/design.md`](steering/design.md),
[`steering/lifecycles.md`](steering/lifecycles.md), and
[`steering/structure.md`](steering/structure.md) before proposing anything;
most "obvious improvements" are already decided against, with reasons.

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
| [`../README.md`](../README.md) | The user-facing installation, command setup, and uninstallation guide for moving a known-good `Vitals.app` to another Mac. |
| [`steering/product.md`](steering/product.md) | What Vitals is and what the notch says. The three exclusive categories — **Interactions**, **Events**, **Activities** — plus compositional **Extensions**, Idle as the floor and Glow as Event residue. |
| [`steering/design.md`](steering/design.md) | How the notch looks and moves: shape, flank layout, how width is bought, which states may grow vertically, and the grow/shrink rule. |
| [`steering/lifecycles.md`](steering/lifecycles.md) | How conditions and explicit work begin and end, including the binding decision to keep CPU monitoring on adaptive in-process polling. |
| [`steering/structure.md`](steering/structure.md) | How the repository is organized, how the runtime pieces connect, and where new code belongs. |
| [`../CLAUDE.md`](../CLAUDE.md) | Build rules. Short version: never run `xcodebuild` or `swift build`, never launch the app — the user does that in Xcode. Make the edit, say what to look for, stop. |

The main [`README.md`](../README.md) is the canonical installation guide. Any
change to Vitals' requirements, installation process, command installation,
permissions, updating, or uninstallation must update that file in the same
change.

## Code map

The tree mirrors `product.md`: one directory per category, plus `Notch/` for the
surface they draw on. A new state goes in the directory of the category it
belongs to — if it fits none of them, it does not belong in the notch.

### `Notch/` — the surface

| File | Role |
|---|---|
| [`NotchState.swift`](../Vitals/Notch/NotchState.swift) | `NotchState` (every shape, grouped by category), `NotchMetrics` (every width, each a named ceiling), and `flankSlot` — the one place content is pinned against the camera housing. |
| [`NotchController.swift`](../Vitals/Notch/NotchController.swift) | Owns the `NSPanel`, finds the notch, drives hover and drag, queues what the notch shows and arbitrates the two sides. The one `@MainActor` hub. |
| [`NotchView.swift`](../Vitals/Notch/NotchView.swift) | The black shape: growth, Interaction-only shadows, edge glow, and the one switch that routes each state to its category. |
| [`NotchShape.swift`](../Vitals/Notch/NotchShape.swift) | The outward-flaring notch outline. Third-party, see its header. |
| [`Marks.swift`](../Vitals/Notch/Marks.swift) | The Bluetooth, AirDrop and Claude glyphs, drawn by hand — SF Symbols ships none of them. Claude's is the exception: the real burst, bundled as the `ClaudeLogo` template asset and turned slowly. |
| [`SpinLayers.swift`](../Vitals/Notch/SpinLayers.swift) | The marks that turn for minutes — the build ring and the Claude burst — as Core Animation layers. A SwiftUI `repeatForever` re-renders the whole notch every display frame; these cost the app nothing per frame. Anything that loops on the resting notch belongs here. |
| [`CGSSpace.swift`](../Vitals/Notch/CGSSpace.swift) | Private-API window space, so the panel survives a space swipe. |

### `Events/` — the machine talking

| File | Role |
|---|---|
| [`Telemetry.swift`](../Vitals/Events/Telemetry.swift) | Power, die temperature, CPU load and the network link. Push where macOS offers it, poll only CPU. |
| [`EventEngine.swift`](../Vitals/Events/EventEngine.swift) | Readings → signals, with hysteresis and a cooldown. `Signal` is one case per Event under Power and Thermal — nothing else; CPU has no Signal. Only power presents: heat is glow-only at every level, lighting both edges tinted by level (critical red). Owns `Loudness` (pill or glow). Pure value type; has a `DEBUG` self-check. |
| [`Accessory.swift`](../Vitals/Events/Accessory.swift) | Bluetooth accessory connect detection and battery. |
| [`EventPills.swift`](../Vitals/Events/EventPills.swift) | How an Event draws: compact (power), accessory, audio lost, command events, the track change (cover + equaliser) and the VPN pills — glyph-over-caption stacks. Heat has no pill; it glows. |
| [`VerdictPill.swift`](../Vitals/Events/VerdictPill.swift) | How a finished build draws. An Event, not the tail of the Activity — the build has handed the notch back before this queues. The controller files Xcode's `xcode-build-succeeded/failed` Behavior events as this. |
| [`../Vitals/Commands/CommandReceiver.swift`](../Vitals/Commands/CommandReceiver.swift) | The local, versioned protocol behind `vitals-notify`, plus the explicit Event and Activity models it accepts. |

### `Activities/` — work you started

| File | Role |
|---|---|
| [`BuildWatcher.swift`](../Vitals/Activities/BuildWatcher.swift) | The DerivedData FSEvent gate, Xcode build/archive progress scraped off the toolbar over the Accessibility API, and the cancel fallback. Always on, no setting. Xcode Behaviors own lifecycle and verdict; the grant only decides whether the task count is there. |
| [`BuildPill.swift`](../Vitals/Activities/BuildPill.swift) | How a running build draws. |
| [`ExternalActivityPill.swift`](../Vitals/Activities/ExternalActivityPill.swift) | How explicitly reported long-running work draws when it has a lifecycle but no invented progress counter. |
| [`MeetingWatcher.swift`](../Vitals/Activities/MeetingWatcher.swift) | Finds a live call — Google Meet or a Slack Huddle in Chrome, Arc or Safari, or the FaceTime, Slack or Discord app — from CoreAudio per-process microphone listeners — push-only, no timer — and brings its window back. Its lifecycle is the `.meeting` Activity, the resting state while a call runs. |
| [`MeetingPill.swift`](../Vitals/Activities/MeetingPill.swift) | How a live meeting draws: the call app's icon (a video glyph for Meet) with a green live dot, centred, on the left; the time on the call on the right. |

### `Interactions/` — you reached for it

| File | Role |
|---|---|
| [`PanelView.swift`](../Vitals/Interactions/PanelView.swift) | The panel — what hover opens: the two stat flanks, the summary column, `PanelPage`'s feature pages behind two arrows and the dots (hidden while Shelf is the only one; opens on Shelf if it holds something or a file is in hand, else Meeting while a call is live, else Now Playing), the `PanelDetail` readouts the stats open over them, the shelf and the AirDrop strip. |
| [`BatteryReadout.swift`](../Vitals/Interactions/BatteryReadout.swift) | The battery in words and numbers: the summary column's value ("AC" on wall power) and the battery page. |
| [`ThermalReadout.swift`](../Vitals/Interactions/ThermalReadout.swift) | The die, same way: peek's degree and tint, and the panel behind them — throttle headroom, memory, and whichever temperatures the chip is willing to name (M1 splits its die three ways; M2/M3 do not). |
| [`NetworkReadout.swift`](../Vitals/Interactions/NetworkReadout.swift) | The link, same way: peek's two rates opened into what carries them — link rate, signal, band and channel, and whether a VPN has it. Names the interface, never the network: the SSID costs a Location prompt. |
| [`Shelf.swift`](../Vitals/Interactions/Shelf.swift) | The drop box and the AirDrop plumbing. |
| [`NowPlaying.swift`](../Vitals/Interactions/NowPlaying.swift) | Now Playing, read through ungive/mediaremote-adapter: Apple-signed `/usr/bin/perl` still holds the MediaRemote entitlement third-party apps lost in macOS 15.4. One stream for the life of the app (measured: idle perl at 0% CPU, ~33 MB), which also feeds the track-change pill; Music and Spotify over `osascript` if the adapter keeps dying. |
| [`NowPlayingPage.swift`](../Vitals/Interactions/NowPlayingPage.swift) | The panel's second feature page: artwork (click opens the player), title, artist, a progress hairline and the transport buttons. |
| [`MeetingPage.swift`](../Vitals/Interactions/MeetingPage.swift) | The panel's third feature page, always present — "No meeting" until a call is live — it then outranks Now Playing as the opening page, but never a held or stored file: app tile, room and clock. Tile and name are one button that returns to the call. |
| [`MediaRemoteAdapter/`](../Vitals/Interactions/MediaRemoteAdapter) | The vendored adapter (BSD 3-Clause, licence beside it). The library ships zipped and is unpacked into Caches at runtime — Xcode recognises a Mach-O by its contents and links it whatever its extension, which made dyld abort at launch; rebuild it with [`tools/build-mediaremote-adapter.sh`](../tools/build-mediaremote-adapter.sh). |

### `Extensions/` — concurrent conditions

| File | Role |
|---|---|
| [`NotchExtension.swift`](../Vitals/Extensions/NotchExtension.swift) | An explicitly reported lifecycle (today: Claude), plus the activation-order allocator that gives the oldest condition the right slot and the next one the left. VPN is no longer an Extension — it is the `.vpn` Event pill and a badge on the panel's network tile. |

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
- **`NotchView` is one type across five files.** Swift extensions cannot add
  storage, so every `@State` is declared in `NotchView.swift` and is internal,
  not private, because the category files read it.
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
