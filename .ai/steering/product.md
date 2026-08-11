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
| Tier 1 | Hairline glow on the notch edge. No motion. | Persistent states |
| Tier 2 | Pill grows horizontally, symmetric, ~440pt cap, auto-hides | Transient events |
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

Tier 1 — glows only:

- Charger disconnected (usually self-caused, but catches a cable that fell out).
- Memory pressure warning.
- Sustained CPU above 85% for 60s.
- Swap grew more than 500MB in 5 minutes.

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
- File shelf, AirDrop, HUD replacement, calendar — the surrounding notch-app
  feature set exists elsewhere and is not the point.

## Open questions

1. Whether the private now-playing framework is usable on macOS 26. Unverified.
   Blocks music, blocks nothing else.
2. Whether the user docks to an external display regularly. If yes, the
   "invisible when docked" decision needs a menu bar fallback.
