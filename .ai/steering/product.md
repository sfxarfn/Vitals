# Vitals — Product

## What it is

A personal macOS notch app for a MacBook Air 13" M3. It turns the notch into an
ambient status surface: silent at rest, a brief pill when something happens, a
full panel on hover.

Single user, single machine. Not a product, not shipped, no App Store.

## Who it's for

One developer, working in Xcode on a fanless 16GB M3 Air, whose real daily pain
is the machine throttling itself before a build finishes. Fanless is the whole
problem: the die climbs, the clocks come down, and nothing on screen says so.
Memory pressure was the original guess at this and turned out not to be it.

## Notch State

Every shape the notch can take. Three exclusive categories, split by **who
acted** and **how the state ends**, plus Extensions that accompany one of those
states without taking it over.

| | Who acted | How it ends |
|---|---|---|
| **Interactions** | You did | When you leave the shape |
| **Events** | The machine did | On its own clock |
| **Activities** | Work you started | When the work ends |

**Extensions** are the compositional exception to the table. A condition begins
and ends on its source's lifecycle, while the current Idle, Event or Activity
keeps its own lifecycle and content.

**Idle** is the floor: the notch's base state at its physical size, showing
nothing. Everything returns to it — except an Activity, which *replaces* it as
the resting state for as long as the work runs. An Extension may still grow
Idle outboard without replacing that floor.

**Glow** is the one thing that outlives its state. An Event announces a
crossing and leaves; where the condition behind it is still true, the notch
edge nearest that subsystem stays lit until its all-clear. Heat is always the
left edge, load always the right — the side is the identity, so a glance says
which subsystem is talking before you read anything.

---

### Interactions

- **Peek** — the pointer rests on the notch and it answers with the stats worth a glance
- **Panel** — peek opens downward into a surface you can actually work in
  - **File Tray** — a drop box that holds files and hands them to AirDrop
  - **Battery Status** — the numbers behind peek's one-line summary
  - **Thermal Detail** — the die behind peek's one rounded degree: where the
    heat sits (P-cores, E-cores, GPU), how many degrees are left before the
    machine starts paying in clocks, and how much room memory has left.
    Reached by clicking peek's left flank, the same way the battery row is
    reached by clicking peek's summary — a stat you glanced at, opened up.
    Memory appears *here and only here*: it is a number you went looking for,
    with no threshold, no pill and no glow behind it, so it does not reopen the
    question of whether memory is worth watching. It is not.

### Events

- **Power**
  - **Battery Charged** — the pack reached full and the machine is running on the adapter
  - **Charging Started** — current is going into the pack, not just into the machine
- **Thermal**
  - **Elevated** — macOS entered `.fair`; silently lights the left edge orange
  - **Thermal Caution** — macOS entered `.serious`; announces the transition and
    keeps the left edge glowing orange
  - **Throttling Active** — macOS entered `.critical`; announces the transition
    with a red temperature icon while the persistent edge remains orange
  - **Cooling Down** — macOS returned to `.nominal` after a presented Caution or
    Throttling Event; you can stop waiting, and the left edge goes dark
- **CPU**
  - **Caution** — sustained load, long enough that it is the machine and not a blip; lights the right edge
  - The right edge goes dark when load releases, but CPU telemetry does not call
    that “finished”: a process reports its exact outcome through Commands.
- **Connections**
  - **Apple Accessory Connected** — a first-party device, drawn as itself
  - **Generic Accessory Connected** — everything else, drawn by what kind of thing it is
    - with Battery — the level arrives with it, shown as a ring
    - without Battery — no level to report, so the Bluetooth mark stands in
  - **Audio Lost** — sound fell off a headset back onto the built-in speakers.
    You did not choose this; the battery did, and the room can hear you now. The
    speaker glyph's wave count carries the output volume, because how loudly is
    half the news. An output you switched to yourself is not filed here — you
    already know, and a pill for it would be noise.
- **Xcode**
  - **Build Failed** — the run ended without producing anything, so there is
    nothing to come back to. A run you cancelled yourself is filed here too:
    you already know you stopped it, and a verdict of its own would be a third
    word and a third glyph spent on news nobody was waiting for.
  - **Build Succeeded** — the run you walked away from is done; this is the pill
    that says the machine is yours again
- **Commands**
  - **Reported Event** — a process says what happened in kebab-case, split over
    the two flanks as subject and outcome (`tests-passed` → `Tests · Passed`).
    Explicit reports are facts, so they are not thresholded or rate-limited.

Every Event has a side. Two on the same side: the newer one replaces what is
there. Two on different sides: both show at once.

An Event arriving during an Activity borrows the notch for its lifetime, then
hands it straight back — the Activity returns if the work is still running, and
the notch falls to Idle if it finished meanwhile.

### Activities

- **Xcode**
  - **Build In Progress** — what is running; optionally enriched with Xcode's
    live task count when **Track build progress** is enabled
- **Commands**
  - **Reported Activity** — long-running work explicitly opens a lifecycle and
    closes it when done. It shows that it is running but invents no progress;
    multiple process IDs stack, with the newest visible and the previous one
    resuming when it stops.

### Extensions

Extensions add one icon beyond the current horizontal state; they never replace
it and never take one of an Event's sided flanks. The first Extension to become
active takes the preferred right edge. A second takes the left edge. When the
earlier one ends, the survivor moves to the right. Interactions hide these
outboard icons because Peek already has room for richer condition summaries and
Panel is that Interaction opened further.

- **Claude In Progress** — Claude Code is processing the current turn. A
  `UserPromptSubmit` hook begins it; `Stop`, `StopFailure` or `SessionEnd` ends
  it. Overlapping Claude sessions collapse into one icon and cannot clear one
  another.
- **VPN Connected** — a real tunnel interface is up with an address. Telemetry
  owns both edges of the lifecycle; it is not an Event and has no timer.
