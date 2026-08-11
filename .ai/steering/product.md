# Vitals — Product

## What it is

A personal macOS notch app for a MacBook Air 13" M3. It turns the notch into an
ambient status surface: silent at rest, a brief pill when something happens, a
full panel on hover.

Single user, single machine. Not a product, not shipped, no App Store.

## Who it's for

One developer, working in Xcode on a fanless 16GB M3 Air, whose real daily pain
is the machine stalling under memory pressure and thermal throttling before a
build finishes.

## The problem it actually solves

Not "show me system stats" — those tools exist. The gap is **being told**
instead of **looking**. Existing monitors require you to already suspect
something is wrong before you check. Vitals inverts that: it stays invisible
until a signal crosses a line, then interrupts once.

Two things drove the design and neither is in the original mockup:

- **RAM usage % is not a stall predictor.** macOS compresses and swaps
  aggressively, so usage% reads calm while the machine thrashes. The predictors
  are memory *pressure level*, swap growth, and pageout rate.
- **Thermal throttling is half of "why is Xcode slow"** on a fanless Air, and
  it was entirely absent from the original four modules.

## Principles

1. **Silent by default.** The notch is a stock notch until something matters.
2. **An interruption must pass the gate**: you didn't cause it, *and* you can
   act on it. Confirming what the user just did is the failure mode that makes
   people disable Dynamic Islands.
3. **Type, not severity, decides loudness.** Transient events interrupt.
   Persistent states glow. A state that lasts 20 minutes cannot pop open for 20
   minutes.
4. **Never duplicate what macOS already tells you.** The system low-battery
   warning cannot be suppressed, so Vitals does not add a second one.
5. **A power monitor must not cost power.** Push notifications over polling
   wherever the OS offers them.
6. **The notch's own 209pt is hardware.** No permanent content can live there,
   and the flanks belong to other apps' menus and status items. Only transient
   overlap is acceptable.

## Interaction model

| State | Appearance | Trigger |
|---|---|---|
| Rest | Invisible. Stock notch. | — |
| Tier 1 | Glow leaking past a notch edge — throttling left, CPU right. No motion. | Persistent states |
| Peek | Two rows: die temp left, CPU load right, gear below. | Hover dwell |
| Tier 2 | Pill grows horizontally, symmetric, ~440pt cap, auto-hides | Transient events |
| Accessory | Narrower pill: glyph in the left flank, battery ring or Bluetooth mark in the right | A Bluetooth accessory connects |
| Audio lost | Same width as Accessory, two beats: headphones turn over into a red slashed pair, speaker fades up opposite | Bluetooth output falls back to the built-in speakers |
| Hover | Morphs from the pill's edges, grows down and wider | 250ms dwell inside the notch rect |

Hover requires a dwell delay because the cursor crosses the notch constantly on
its way to the menu bar. Click pins the panel open; click again or Esc
dismisses. Right-click opens settings.

The tier-2 pill is symmetric and will briefly cover the trailing end of the
focused app's menus. Accepted: it is transient and macOS offers no way to
reserve the space.

## Modules

**Power** — battery %, charge state, time to full/empty, and three distinct
power numbers: what the wall delivers, what reaches the battery, and the
difference (system draw). The last one is derived and is more useful than
anything a single "watts in" figure can show.

**Stall risk** — memory pressure as a *word*, not a percentage; swap used and
its trend; sustained CPU as a sparkline; thermal state.

**Accessory** — a Dynamic-Island-style acknowledgement when a Bluetooth
accessory connects: type glyph on the left, charge on the right. The same audio
listener also catches the reverse, when sound drops off a headset back onto the
built-in speakers.

**Shelf** — a temporary drop box in the hover panel, plus an AirDrop tile.
Originally a non-goal (see below); built anyway, because a collapsed notch is
already the place the cursor is when a drag starts.

**Music** — deferred, but the panel's slot model is heterogeneous from day one
so it can be added without a rewrite. Highest-risk integration in the project:
playback is a Chrome tab (YouTube Music), and reading system now-playing depends
on a private framework Apple has been closing off.

### Cut and why

- **Network.** Generated no event worth firing. A live Mbps readout is a number
  you admire, not one you act on.
- **Workflow (Jira / CI).** Deferred entirely. It needs network, Keychain, OAuth,
  token refresh, rate limits, and offline states — likely more code than the
  other modules combined — while the "active ticket" display shows something the
  user typed themselves.
- **Battery low warnings.** macOS already does this and cannot be silenced.
- **Charge-hold-at-80% notice.** Would fire near-daily; training the user to
  ignore the notch poisons the four events that matter.

## Event catalog

Tier 2 — interrupts:

- Net-negative on AC (plugged in but still draining: weak hub, phone charger, or
  load exceeding the adapter). The most valuable event here — invisible today
  and directly actionable.
- Battery reached 100%.
- Memory pressure critical.
- Thermal state serious or critical.
- Bluetooth accessory connected. **A deliberate exception to principle 2**: this
  one *is* self-caused. It earns its place the way the iOS Dynamic Island does —
  the acknowledgement is the point, and it carries a charge level you would
  otherwise dig through Control Center for.
- Bluetooth audio lost to the built-in speakers. The headset battery died
  mid-call and you are now talking to the room. CoreAudio reports the route and
  not the reason, so choosing the switch by hand fires it too; that miss is
  cheap next to the one it catches.
- Memory pressure or thermal state recovered. The all-clear only fires for
  signals whose alarm actually reached the notch — these are the two states you
  stop and wait out, so "go back to work" is worth saying. Nothing else gets a
  recovery; nobody is waiting for the battery to stop being full.
- Sustained load finished: CPU held above 85% for a minute, then sat under 30%
  for ten seconds. Self-caused, and a second deliberate exception to principle
  2 — the whole reason the machine is watched is that builds take long enough
  to walk away from. It is a CPU shape, not a build hook, so a long render or a
  Docker image reads the same.

Tier 1 — glows only. Two edges, so two can show at once:

- **Right edge, CPU** — sustained CPU above 85% for 60s.
- **Left edge, throttling** — thermal state at serious or worse. Heat on its own
  never glows: a build holds the 70s for twenty minutes with nothing wrong, and
  an edge lit through every build is one nobody reads.

Peek's thermometer glyph carries the finer read of the same state — green while
nothing is being cut (`nominal` and `fair`, where fans are the only cost),
orange once the governor starts clamping (`serious`), red when it is clamping
hard (`critical`). The degrees beside it stay the raw sensor number. No degree
threshold is used anywhere: 78° is fine on one machine and clamped on another,
so `thermalState` is the authority and the number is only context.

Asserted but drawn nowhere: charger disconnected, memory pressure warning, swap
growth. Memory still gets its tier-2 pill at critical; the warning band lost its
edge when the left one went thermal.

Every signal uses hysteresis plus a 5-minute cooldown. Without it, pressure
oscillating during a build fires the pill repeatedly.

## Behavior at the edges

**Fullscreen** is the highest-value moment, not an exception — it is when builds
run and when the machine stalls. Tier-2 pills still draw over fullscreen
content; tier-1 glow is suppressed; hover is disabled since there is no menu bar
to hover.

**External displays and clamshell** are out of scope for v1. Docked or
lid-closed, Vitals is invisible.

## Non-goals

- Shipping, selling, or distributing this.
- App Store compatibility.
- Historical data, logging, or post-mortem analysis.
- Replacing iStat Menus or Stats as a general-purpose monitor.
- HUD replacement and calendar — the rest of the surrounding notch-app feature
  set exists elsewhere and is not the point. (The file shelf and AirDrop were
  on this list and got built; they are Modules now.)

## Open questions

1. Whether the private now-playing framework is usable on macOS 26. Unverified.
   Blocks music, blocks nothing else.
2. Whether the user docks to an external display regularly. If yes, the
   "invisible when docked" decision needs a menu bar fallback.

## Settled, do not re-litigate

**Classic Bluetooth headsets cannot report battery.** Verified on this machine:
nothing publishes `BatteryPercent` in the IORegistry,
`/Library/Preferences/com.apple.Bluetooth.plist` has no `DeviceCache` on macOS
26, and `/Library/Bluetooth/` is `Operation not permitted`. macOS receives the
level over HFP into `bluetoothd`, which exposes no public API — Control Center
reads it through the private `BluetoothManager` framework. The GATT Battery
Service (0x180F) via CoreBluetooth is the only public route and only BLE devices
answer it. Headsets therefore get the Bluetooth mark, not a ring. This is a
platform limit, not a missing feature.
