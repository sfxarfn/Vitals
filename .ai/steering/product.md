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

## Notch State

Every shape the notch can take. Three categories, split by **who acted** and
**how the state ends**. That split is the model — a new state has to land in one
of them, or it does not belong in the notch.

| | Who acted | How it ends |
|---|---|---|
| **Interactions** | You did | When you leave the shape |
| **Events** | The machine did | On its own clock |
| **Activities** | Work you started | When the work ends |

**Idle** is the floor: the notch at its physical size, showing nothing.
Everything returns to it — except an Activity, which *replaces* it as the
resting state for as long as the work runs.

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

### Events

- **Power**
  - **Battery Charged** — the pack reached full and the machine is running on the adapter
  - **Charging Started** — current is going into the pack, not just into the machine
- **Thermal**
  - **Caution** — the die crossed into heat worth knowing about; lights the left edge
  - **Cooling Down** — it came back down; you can stop waiting, and the left edge goes dark
- **CPU**
  - **Caution** — sustained load, long enough that it is the machine and not a blip; lights the right edge
  - **Releasing** — the load let go, the machine is yours again, and the right edge goes dark
- **Connections**
  - **Apple Accessory Connected** — a first-party device, drawn as itself
  - **Generic Accessory Connected** — everything else, drawn by what kind of thing it is
    - with Battery — the level arrives with it, shown as a ring
    - without Battery — no level to report, so the Bluetooth mark stands in
  - **Audio Changed** — sound moved to a different output; the speaker glyph carries
    its own wave count, so the loudness reads off the icon rather than a number
- **Xcode**
  - **Build Canceled** — the run ended without producing anything, so there is
    nothing to come back to
  - **Build Succeeded** — the run you walked away from is done; this is the pill
    that says the machine is yours again

Every Event has a side. Two on the same side: the newer one replaces what is
there. Two on different sides: both show at once.

An Event arriving during an Activity borrows the notch for its lifetime, then
hands it straight back — the Activity returns if the work is still running, and
the notch falls to Idle if it finished meanwhile.

### Activities

- **Xcode**
  - **Build In Progress** — what is running, and how far in
