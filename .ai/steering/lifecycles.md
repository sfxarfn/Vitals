# Vitals — Lifecycles

How Vitals learns that a condition or a piece of work has started and ended.
What appears in the notch is defined in [`product.md`](product.md).

## CPU monitoring

CPU monitoring keeps the current in-process, adaptive polling approach in
`Telemetry`.

- Read machine-wide CPU counters with `host_processor_info` and calculate load
  from the difference between consecutive samples.
- Poll every 10 seconds while the notch is resting and every second while it is
  expanded. Give the timer tolerance so macOS can coalesce wake-ups.
- Treat CPU as machine state: assert the right-edge glow only after load has
  remained above the sustained threshold, and clear it when load releases.
- Continue using OS notifications where macOS offers them, such as power-source
  and thermal-state changes. There is no equivalent notification for crossing a
  machine-wide CPU-load threshold, so CPU remains the part that must be polled.

Do not replace this with an external listener that calls `vitals-notify`. Such a
listener would still have to poll the same counters, then add process-launch and
distributed-notification overhead. It would move the sampling rather than
remove it.

## Thermal monitoring

Thermal monitoring uses `ProcessInfo.processInfo.thermalState` as the authority
for Events and the persistent left edge. Its notification drives the state
machine directly inside Vitals; it does not go through `vitals-notify`.

- `.nominal` keeps the edge dark. Returning here after a presented `.serious`
  or `.critical` Event emits one green **Cooling down** Event.
- `.fair` lights the edge orange without interrupting.
- `.serious` keeps the orange edge and emits **Thermal caution** on entry.
- `.critical` keeps the persistent edge orange and emits the red
  **Throttling active** Event on entry.

Descending through `.serious` or `.fair` is not recovery; the edge and recovery
debt remain until `.nominal`. Repeated readings of one state do nothing, and a
direct jump to `.critical` emits only the critical Event rather than queuing a
lesser Caution first.

The private IOHID temperature sensors remain explanatory telemetry: the current
degree and the P-core, E-core and GPU split shown in Peek and Thermal Detail.
Their values do not decide Events or edge state.

## Explicit work

`vitals-notify` is for work whose lifecycle is already known by the process
doing it: builds, tests, deployments and similar commands. Those processes may
report Activity start and stop, plus the final Event, without Vitals inferring
completion from CPU load.

This is complementary to CPU monitoring. CPU answers whether the machine is
under sustained load; an explicit lifecycle answers what work is running and
how it ended. Neither substitutes for the other.

## Xcode builds

Xcode Behaviors are the authoritative lifecycle: their scripts report build
start, success and failure through `vitals-notify`. The Accessibility watcher is
optional enrichment that reads Xcode's live task counter; it does not infer an
outcome from the counter disappearing.

The watcher has no setting. There is nothing to switch off, because at rest it
costs nothing to leave on: the DerivedData FSEvent stream is a subscription to a
daemon macOS already runs, and there is no timer until a build writes. A switch
would have bought a Settings row and two states to reason about in exchange for
saving zero.

The Accessibility grant is the only opt-in, and it buys exactly one thing: the
task counter. Nothing prompts for it on its own — the watcher does not interrupt
a build to ask — so the Settings row is the whole path to it.

Without the grant the Activity still identifies itself with Xcode's app icon and
**Building**, while an indeterminate blue ring says **Progress**. No percentage
or zero counter is invented. If AX progress becomes available, the right flank
changes to the live task counter and determinate ring, and the pill uses the
wider tracked-build layout. Xcode's identity stays fixed.

### Ending a build Xcode never ended

Success and failure arrive as Behaviors and stop everything: the poll goes down,
progress clears, and a short deadzone keeps DerivedData's tail writes from
restarting it. The FSEvent stream stays up — it is the gate for the next build.

Cancels have no Behavior and no script, so the watcher has to conclude one. Two
tiers of evidence, and they are not equal:

- **With the counter**, both halves are required: it was read and then stopped
  answering, over a disk that also went quiet. Twenty seconds of each.
- **Without it**, the disk stands alone over a much longer silence. A blind
  watcher cannot tell a cancelled run from a long link phase, so this window has
  to outlast every silence a real build takes.

The weaker tier is deliberate and it has a known cost: a project whose products
land outside DerivedData gives the watcher no witness at all, and a long build
there gets dropped off the notch. That is the price of ending cancelled runs
without the grant, and it is the right trade — the alternative was an Activity
that sat in the notch until the next build started.

## Meetings

A meeting is an Activity with no owner that reports it, so Vitals has to infer
its lifecycle — and the inference is push-only. While it runs it is the resting
state like any other Activity: the newest of the running Activities and the
meeting owns the notch, an Xcode build with only the toolbar counter (no start
time) outranks it, and the meeting returns when that ends.

- **Begin:** CoreAudio listeners on the default input device
  (`kAudioDevicePropertyDeviceIsRunningSomewhere`), on the process object list,
  and on each process's `kAudioProcessPropertyIsRunningInput`. macOS calls back
  when a process starts or stops capturing, and each notification looks at once
  and again 400ms later, because one can arrive before the property it
  announces reads back its new value.
- **Safety net:** measured on a real call, those notifications sometimes never
  arrive on a join — Vitals only saw the call when something else changed the
  process list. So a two-second timer re-reads the same flags. It touches
  CoreAudio properties only, never tabs, windows or `osascript`, and only for
  the handful of processes that are one of the watched apps — each process's
  bundle ID is read once and cached, so a tick is the process-list query plus a
  few flag reads — and the real work (the tab lookup) still runs
  only once an app is capturing. This is the same trade CPU monitoring makes:
  where macOS offers no dependable push, a cheap read on a slack timer is the
  price.
- **Identify:** only when a supported app starts capturing:
  - A browser (Chrome, Arc, Safari) needs a tab on `meet.google.com/<code>` —
    a Google Meet call — or on `slack.com/huddle` — a Slack Huddle in the
    browser — found with one `osascript` call; with neither, the capture is some
    other page and no meeting is declared. That lookup is also what vouches for
    Safari, whose capture runs in WebKit processes every WebKit app shares. A
    browser that finds nothing is not asked again for 30 seconds.
  - A native app (Slack, FaceTime, Discord) is a call as soon as it captures.
    Its window title names the room, read through the Accessibility grant the
    Xcode watcher already uses, with a plain fallback ("Huddle", "FaceTime
    call", "Voice call") when it cannot be read.
- **Confirm:** only Slack waits — a couple of seconds, so a voice-message clip
  on the same microphone never becomes a meeting. A browser has its call tab to
  vouch for it, and FaceTime and Discord only capture on a call, so none of
  those waits: the notch says so as the call starts. The tab lookup asks each
  window for all its URLs in one Apple Event, so many tabs do not slow it.
- **End:** the capture closes and stays closed for two seconds, so a device
  switch (which closes and reopens the stream in under one) does not flicker the
  notch, while a call you left clears at once. No polling of tabs or windows
  while a meeting runs. The elapsed time is the stored start date; the clock is
  only drawn while the notch or the Meeting page is on screen.
- **Return:** clicking the Meeting page, for a browser call, runs one more
  `osascript` call that finds the tab by its URL (not a remembered index — tabs
  move) and selects it, raises its window and activates the browser. A native
  app raises its call window over Accessibility and activates the app.

The one permission this adds is Automation for each browser, asked the first
time that browser is used to identify a meeting. The native apps need nothing beyond the existing Accessibility
row, and without it the click only brings the app forward.

## Extensions

Extensions are concurrent conditions, not queued states. Each records its
inactive-to-active timestamp; the oldest active condition owns the preferred
right slot and the next owns the left. Ending either condition immediately
rebuilds those slots, so a lone survivor returns to the right.

VPN uses network telemetry's tunnel level. Claude uses explicit Claude Code
hooks: `UserPromptSubmit` starts a session-scoped lifecycle and `Stop`,
`StopFailure`, and `SessionEnd` stop it. Session IDs keep overlapping processes
independent, while presentation collapses every active Claude session into one
condition whose timestamp is retained until the final session stops.
