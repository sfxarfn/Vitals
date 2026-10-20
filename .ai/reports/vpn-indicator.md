# VPN indicator: two pills and a panel badge

**Status:** Done — 2026-10-19
**Why:** The user wants to notice when a VPN is connected without having to
remember it. From the mockup they picked three things (a connect pill, a
reminder pill and a panel badge) and not the persistent mark, so that mark is
gone.

## What changed
- `Vitals/Notch/NotchState.swift` — `case vpn(VPNNotice)`, a whole-notch
  Event on `lineFlanks`. `VPNNotice.minutesOn` is nil for the connect pill,
  else the mark reached; `reminderText` gives "30m on", "1h on" and so on.
  The `extensionFlank` comment now names Claude's burst (~24pt) as the widest
  mark; the value stays 38.
- `Vitals/Events/EventPills.swift` — `vpnPill`: orange `lock.fill` + "VPN" on
  the left; "Connected" on the right, or the mark at white 0.6.
- `Vitals/Notch/NotchController.swift`
  - `trackVPN()` runs on the telemetry tick (`evaluate`):
    - Off → on queues the connect pill every time, auto-connect included.
      The first reading after launch is the baseline: a VPN already on gets
      no pill, and its schedule counts from launch.
    - While on, `vpnReminderMarks = [30, 60, 120, 240]` minutes: one reminder
      at each mark, then none for that connection. Only the latest mark passed
      is queued (a Mac that slept through two gets one), and a newer reminder
      replaces a pending one.
    - On → off says nothing, resets the schedule and drops any pending VPN
      pill.
  - VPN pills last 2s and queue like other Events. They wait while the panel
    is open or another Event is showing.
  - The VPN Extension is gone: `vpnExtension`, its activation and its slot.
  - The previews gain a "VPN" section with "VPN connected" and "VPN on for an
    hour".
- `Vitals/Notch/NotchView.swift` — the `"vpn"` mark drawing and its tint note
  are removed. The idle notch no longer leans right for VPN. Shape key and
  content case added.
- `Vitals/Interactions/PanelView.swift` — while connected, the network mini
  tile carries an 11pt bold "VPN" badge: dark text on orange, radius 4, over
  its top-right corner. The network detail's "VPN Active / Off" row is
  unchanged.
- `Vitals/VitalsApp.swift` — the Settings "VPN connected" Extension preview
  button is removed, since VPN previews are Events now.
  `NotchExtension.swift` — its doc and self-check no longer use VPN.
- `.ai/README.md` — the Extensions row now says VPN moved out.

## Verification
- Not built or run here (project rule). After building:
  - Connect a VPN: within one telemetry tick (up to ~10s at rest) the
    "🔒 VPN · Connected" pill shows for about 2s. The idle notch does not lean
    right afterwards.
  - Hover: the network tile has the orange VPN badge on its corner.
  - Disconnect: no pill, and the badge goes.
  - Previews → VPN: both pills draw.
  - The reminders at 30m, 1h, 2h and 4h are easiest to check by temporarily
    shrinking `vpnReminderMarks`. Note it gets no pill if the VPN was already
    on at launch.

## Notes
- No pill on disconnect, as asked.
- A VPN already up at launch has its reminders counted from launch, because
  the real connect time is not known.
