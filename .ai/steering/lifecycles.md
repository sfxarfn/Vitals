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
