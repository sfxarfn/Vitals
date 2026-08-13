# Vitals Repository Structure

This document is the navigation guide for the Vitals repository. It explains
where code belongs and how the main pieces connect. Product behavior remains
canonical in [`product.md`](product.md), visual rules in
[`design.md`](design.md), and lifecycle decisions in
[`lifecycles.md`](lifecycles.md).

## Top-level layout

```text
Vitals/
├── Vitals/                    # macOS app source and bundled assets
│   ├── Activities/            # long-running work owned by a known lifecycle
│   ├── Assets.xcassets/       # app icon, accent color, and asset catalog
│   ├── Commands/              # local protocol used by vitals-notify
│   ├── Events/                # machine-originated readings, decisions, and pills
│   ├── Extensions/            # conditions displayed beside the current state
│   ├── Interactions/          # hover, panel, detail views, and file shelf
│   ├── Notch/                 # window, state, geometry, and root rendering
│   └── VitalsApp.swift        # app entry point and Settings scene
├── Vitals.xcodeproj/          # Xcode project and build settings
├── bin/
│   └── vitals-notify          # command-line client for the local app protocol
├── installation-files/        # optional Xcode and Claude integration hooks
├── .ai/                       # agent context and binding product/design decisions
│   └── steering/
│       └── structure.md       # this file
├── README.md                  # installation, integration, and removal guide
└── CLAUDE.md                  # repository-specific build/run constraints
```

Xcode's `xcuserdata/`, Finder's `.DS_Store`, and other machine-local files are
not part of the architecture.

## Runtime architecture

```text
VitalsApp / AppDelegate
        │
        ▼
NotchController ───────────────► NotchState + NotchMetrics
   │       │       │                         │
   │       │       └── Commands              ▼
   │       └────────── Activities         NotchView
   └────────────────── Events                │
                         │                    ▼
                         └──────────── category-specific SwiftUI views

Telemetry / explicit hooks ──► Extensions ──► outboard ExtensionSlots
```

`NotchController` is the main-actor coordination hub. It owns the `NSPanel`,
starts data sources, converts their updates into states, arbitrates Events and
Activities, allocates Extensions, and handles pointer and drag behavior.

`NotchState` represents the exclusive shape currently occupying the notch.
Extensions are intentionally stored outside that enum because they accompany a
state rather than replacing it. `NotchMetrics` is the single source of truth
for shape size, flank width, lean, and the fixed backing window size.

`NotchView` renders the black surface and routes each state to a view in its
category directory. State needed by those category views is declared on
`NotchView`; Swift extensions cannot add stored properties.

## Source directories

### `Vitals/Notch/` — surface and orchestration

| File | Responsibility |
|---|---|
| `NotchController.swift` | Owns the panel and coordinates telemetry, commands, Activities, Events, Extensions, hover, drag, and state restoration. |
| `NotchState.swift` | Defines all exclusive states, layout metrics, flank allocation, size, and lean. |
| `NotchView.swift` | Draws and animates the surface, glow, shadows, and state content. |
| `NotchShape.swift` | Defines the outward-flaring notch outline. |
| `Marks.swift` | Contains custom Bluetooth and AirDrop marks unavailable as SF Symbols. |
| `CGSSpace.swift` | Keeps the panel attached across macOS space changes using private window-space APIs. |

### `Vitals/Events/` — the machine acted

Events are temporary facts presented on their own clock.

| File | Responsibility |
|---|---|
| `Telemetry.swift` | Collects power, thermal, CPU, and network readings. |
| `EventEngine.swift` | Turns readings into closed-set Signals using thresholds, hysteresis, and cooldowns. |
| `Accessory.swift` | Detects accessory connections, battery levels, and lost headset audio. |
| `EventPills.swift` | Renders compact, sided, accessory, and audio Events. |
| `VerdictPill.swift` | Renders completed Xcode build verdicts. |

The shell-reported Event model lives in `Commands/CommandReceiver.swift`
because its source and validation belong to the command protocol.

### `Vitals/Activities/` — work the user started

Activities remain visible until their owning work ends; while active, the most
recent Activity replaces Idle as the resting state.

| File | Responsibility |
|---|---|
| `BuildWatcher.swift` | Watches DerivedData for build writes, enriches an Xcode build with a live task count where Accessibility allows, and ends a lifecycle Xcode never closed. |
| `BuildPill.swift` | Renders a running Xcode build or archive. |
| `ExternalActivityPill.swift` | Renders explicitly reported work without inventing progress. |

Xcode Behavior scripts own the authoritative build lifecycle. `BuildWatcher` has
no switch and is always running; the Accessibility grant decides only whether the
task count is available, not whether the watcher exists.

### `Vitals/Interactions/` — the user acted

Interactions begin from pointer or drag input and end when the user leaves the
surface.

| File | Responsibility |
|---|---|
| `PeekView.swift` | Shows the two summary flanks and control row on hover. |
| `PanelView.swift` | Provides the expanded panel, navigation, shelf, and AirDrop tile. |
| `BatteryReadout.swift` | Shares battery wording and values across Peek and Panel. |
| `ThermalReadout.swift` | Shares die summaries and detailed thermal readings. |
| `Shelf.swift` | Owns dropped files and AirDrop handoff behavior. |

### `Vitals/Extensions/` — concurrent conditions

`NotchExtension.swift` defines Extension lifecycles and the allocator that
places the oldest active condition on the right and the next on the left.
Extensions add an outboard icon to Idle, Events, or Activities; they do not
replace those states and are hidden during Interactions.

### `Vitals/Commands/` — local command boundary

`CommandReceiver.swift` validates the versioned JSON payload carried by
`DistributedNotificationCenter`, then maps it to explicit Events, Activities,
or Extensions. It is the app side of `bin/vitals-notify`.

### `Vitals/VitalsApp.swift` — process entry point

Defines the accessory-policy application, creates the single
`NotchController`, registers defaults, runs debug self-checks, and provides the
Settings scene for login launch, Xcode progress, Accessibility, and previews.

## External tools and installation files

- `bin/vitals-notify` is the user-facing CLI. Keep its protocol version and
  behavior synchronized with `CommandReceiver.swift`.
- `installation-files/xcode-build-*.sh` translate Xcode Behavior lifecycle
  callbacks into `vitals-notify` commands.
- `installation-files/claude-extension.sh` translates Claude Code hook
  lifecycles into an Extension.
- `README.md` is the canonical guide for installing, updating, configuring, and
  removing the app, CLI, and hooks.

## Where new code belongs

1. Decide who initiated the state and how it ends:
   - user input ending on departure → `Interactions/`
   - machine fact ending on a timer → `Events/`
   - known work ending with the work → `Activities/`
   - concurrent condition with its own lifecycle → `Extensions/`
2. Add exclusive state representation to `NotchState.swift`; keep Extensions
   outside `NotchState`.
3. Add width and height requirements to `NotchMetrics`. Do not size a state
   locally or lay out a flank by hand.
4. Put category rendering in the corresponding directory and route it through
   `NotchView`.
5. Keep collection and lifecycle ownership near the source (`Telemetry`,
   `BuildWatcher`, `AccessoryWatcher`, or `CommandReceiver`) and arbitration in
   `NotchController`.
6. Update the steering documents first when a change alters product behavior,
   visual rules, or lifecycle policy. Update `README.md` in the same change when
   installation, permissions, commands, integrations, or removal changes.

New Swift files and directories under `Vitals/` are discovered by the Xcode
synchronized file group, so they normally do not require an edit to
`project.pbxproj`. Build-setting changes still need to be applied to both Debug
and Release configurations there.

## Development constraints

- Do not sandbox the app; Xcode toolbar progress requires Accessibility.
- Do not treat memory as a Signal. It is detail-only telemetry in the thermal
  panel.
- Prefer macOS notifications for push-capable state; CPU load remains adaptive
  in-process polling.
- Preserve comments that explain calibration, private API use, and deliberate
  shortcuts marked `ponytail:`.
- Do not run `xcodebuild`, `swift build`, or launch the app from automated agent
  work. The user builds and verifies it in Xcode.
