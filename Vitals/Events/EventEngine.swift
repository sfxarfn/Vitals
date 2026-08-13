import Foundation
import SwiftUI

/// How loud a signal is allowed to be. A `pill` interrupts once and leaves; a
/// `glow` never interrupts, it just lights the notch edge for as long as the
/// condition holds. Loudness is a property of the signal's *type*, not its
/// severity — a state that lasts twenty minutes cannot pop open for twenty
/// minutes, however bad it is.
enum Loudness { case glow, pill }

/// Which side of the notch an Event owns. Centre spreads one message across
/// both flanks; the others grow one edge only. See `Signal.side`.
enum Side { case center, left, right }

/// A flattened view of telemetry. Power and CPU are numbers with thresholds;
/// thermal pressure is macOS's own state machine, because its transitions carry
/// meaning that a temperature threshold cannot reproduce.
struct Reading {
    var percent = 0
    var onAC = false
    /// Signed: positive is current going into the pack, negative is coming out.
    var batteryWatts = 0.0
    var thermalState: ProcessInfo.ThermalState = .nominal
    var cpuSustainedSeconds = 0.0
}

/// Everything the machine can say about itself, one case per Event `product.md`
/// lists under Power, Thermal and CPU. The other two subsystems it lists —
/// Connections and Xcode — do not read off telemetry, so they arrive as their
/// own `NotchState` rather than through here.
///
/// `loudness` says whether a signal earns a pill or only an edge; `side` says
/// which edge.
enum Signal: String, CaseIterable {
    // Power.
    case chargingStarted, charged
    // Thermal — macOS's fair, serious and critical pressure levels.
    case thermalWarm, thermalSerious, thermalCritical
    // CPU: sustained load is machine state. Completion belongs to the process
    // that knows what it was doing and arrives through `vitals-notify`.
    case cpuSustained

    /// Only crossings worth acting on earn a pill. Fair thermal pressure and
    /// sustained CPU load can hold for a long time, so they light an edge rather
    /// than occupying the notch for the life of the condition.
    var loudness: Loudness {
        switch self {
        case .chargingStarted, .charged,
             .thermalSerious, .thermalCritical: .pill
        case .thermalWarm, .cpuSustained:     .glow
        }
    }

    // MARK: Thresholds

    /// Asserts above the first number, clears below the second. Equal means no
    /// hysteresis, which is fine for signals the OS already debounces.
    var thresholds: (assertAbove: Double, clearBelow: Double) {
        switch self {
        // 3W, not a hair over zero: the reading wanders either side of idle by a
        // watt or so, and the hysteresis is what makes unplugging the thing that
        // clears this — so plugging back in is a fresh crossing and fires again.
        case .chargingStarted:      (3, 1)
        case .charged:              (99.5, 98)
        // Thermal is updated by `updateThermal`, not this numeric path. These
        // levels let priming seed the right glow without inventing temperatures.
        case .thermalWarm:          (0.5, 0.5)
        case .thermalSerious:       (1.5, 1.5)
        case .thermalCritical:      (2.5, 2.5)
        case .cpuSustained:         (60, 30)
        }
    }

    func value(_ r: Reading) -> Double {
        switch self {
        // Watts into the pack, which is the half `isCharging` cannot answer:
        // that flag reads true for an adapter merely running the machine, and
        // false right through the negotiation where current does start flowing.
        //
        // Silent near full. A pack held at 100% is deliberately cycled off the
        // adapter and topped back up every few minutes — `pmset -g log` shows AC
        // and Batt alternating seconds apart with nothing else changing — and
        // each of those pulses is real current going in that means nothing. 95 is
        // where the rest of the app already stops calling a pack "charging".
        case .chargingStarted:      r.onAC && r.percent < 95 ? r.batteryWatts : 0
        // The percentage alone: a pack only climbs to full on the adapter, so
        // the "running on the adapter" half of the Event comes free.
        case .charged:              Double(r.percent)
        case .thermalWarm,
             .thermalSerious,
             .thermalCritical:      Self.thermalLevel(r.thermalState)
        case .cpuSustained:         r.cpuSustainedSeconds
        }
    }

    private static func thermalLevel(_ state: ProcessInfo.ThermalState) -> Double {
        switch state {
        case .nominal:  0
        case .fair:     1
        case .serious:  2
        case .critical: 3
        @unknown default: 0
        }
    }

    // MARK: How it looks

    var symbol: String {
        switch self {
        case .chargingStarted:      "bolt.fill"
        case .charged:              "battery.100percent.bolt"
        case .thermalSerious:       "thermometer.high"
        case .thermalCritical:      "thermometer.high"
        case .thermalWarm:          "thermometer.medium"
        case .cpuSustained:         "cpu"
        }
    }

    var title: String {
        switch self {
        case .chargingStarted:      "Charging"
        case .charged:              "Charged"
        case .thermalSerious:       "Thermal caution"
        case .thermalCritical:      "Throttling active"
        case .thermalWarm:          "Warm"
        case .cpuSustained:         "CPU pegged"
        }
    }

    var tint: Color {
        switch self {
        // Charging is amber and full is green, the way a charge indicator has
        // read since long before this app: the colour is the state of the pack,
        // not a severity, so it does not share the Cautions' meaning of orange.
        case .chargingStarted:              .orange
        case .charged:                      .green
        case .thermalCritical:              .red
        case .thermalWarm, .thermalSerious,
             .cpuSustained:                 .orange
        }
    }

    /// What the edge glows, which is not always what the signal is tinted. Heat
    /// glows orange at every level: the edge sits in peripheral vision, where
    /// red reads as an alarm you have to act on — and a die at 90° through a
    /// long build is a fact, not an emergency. Red stays where you went looking
    /// for it, on the glyph and the pill.
    var glowTint: Color { self == .thermalCritical ? .orange : tint }

    // MARK: How it presents

    /// Says everything in a glyph and one number, so it wears the accessory
    /// pill's width and layout instead of the full event pill's — the number
    /// carries more than the word would ("48°", not "Cooling down").
    var isCompact: Bool {
        switch self {
        case .chargingStarted, .charged: true
        default: false
        }
    }

    /// Which way the pill grows. Centre is the default and splits its message
    /// across the two flanks. A one-sided pill has only one thing to say — a
    /// glyph and at most one number — so a symmetric shape would spend the far
    /// flank on nothing and the notch sliding both ways would read louder than
    /// the news is. Side is identity, not decoration: heat is always the left
    /// edge and load always the right, glow included, so a glance at which edge
    /// moved already says which subsystem is talking.
    var side: Side {
        switch self {
        case .thermalWarm, .thermalSerious, .thermalCritical: .left
        case .cpuSustained:                 .right
        case .chargingStarted, .charged:    .center
        }
    }

    // MARK: Recovery

    var recoverySymbol: String {
        switch self {
        case .thermalSerious, .thermalCritical: "thermometer.low"
        default:              symbol
        }
    }

    var recoveryTitle: String {
        switch self {
        case .thermalSerious, .thermalCritical: "Cooling down"
        default:              title
        }
    }
}

/// One presentation. `recovered` inverts the polarity: a condition returned to
/// its all-clear, which is the same signal saying the opposite thing, so it gets
/// its own word and glyph instead of its own case.
struct Event: Equatable {
    var signal: Signal
    var recovered = false

    var symbol: String { recovered ? signal.recoverySymbol : signal.symbol }
    var title: String { recovered ? signal.recoveryTitle : signal.title }
    var tint: Color { recovered ? .green : signal.tint }
}

// MARK: - Engine

/// Tracks asserted signals and rate-limits pill presentations. Numeric signals
/// use hysteresis; thermal follows macOS's already-debounced state transitions.
struct EventEngine {
    static let cooldown: TimeInterval = 300

    private(set) var active: Set<Signal> = []
    private var lastFired: [Signal: Date] = [:]
    /// The most severe thermal Event that actually reached the notch. Recovery
    /// is only news if the problem was presented, and only nominal pays this debt.
    private var thermalRecovery: Signal?
    private var previousThermalState: ProcessInfo.ThermalState?
    private var primed = false

    /// Returns the Events that should be presented on this tick.
    mutating func update(_ r: Reading, now: Date = Date()) -> [Event] {
        // The first reading is a baseline, not news. Every signal here is a
        // crossing, and nothing has crossed yet — without this the app announces
        // whatever happened to be true when it started, so launching at 100% on
        // the charger fires "Charged" for a battery that filled an hour ago.
        // Rebuilding in Xcode does it on every run.
        if !primed {
            primed = true
            active = Set(Signal.allCases.filter { $0.value(r) > $0.thresholds.assertAbove })
            previousThermalState = r.thermalState
            return []
        }

        var fired: [Event] = []
        for s in Signal.allCases {
            guard !s.isThermal else { continue }
            let v = s.value(r)
            let (on, off) = s.thresholds
            if active.contains(s) {
                guard v < off else { continue }
                active.remove(s)
            } else if v > on {
                active.insert(s)
                guard s.loudness == .pill else { continue }
                if let last = lastFired[s], now.timeIntervalSince(last) < Self.cooldown { continue }
                lastFired[s] = now
                fired.append(Event(signal: s))
            }
        }
        fired.append(contentsOf: updateThermal(r.thermalState, now: now))
        return fired
    }

    /// macOS already debounces thermal pressure. Keep its four states intact so
    /// descending through serious and fair cannot masquerade as recovery, and a
    /// direct jump to critical does not queue a lesser Caution first.
    private mutating func updateThermal(_ state: ProcessInfo.ThermalState, now: Date) -> [Event] {
        let previous = previousThermalState
        previousThermalState = state
        setThermalActive(state)

        switch state {
        case .nominal:
            guard let owed = thermalRecovery else { return [] }
            thermalRecovery = nil
            return [Event(signal: owed, recovered: true)]

        case .fair:
            return []

        case .serious:
            guard thermalRank(previous) < thermalRank(state) else { return [] }
            return fireThermal(.thermalSerious, now: now)

        case .critical:
            guard thermalRank(previous) < thermalRank(state) else { return [] }
            return fireThermal(.thermalCritical, now: now)

        @unknown default:
            return []
        }
    }

    private mutating func fireThermal(_ signal: Signal, now: Date) -> [Event] {
        if let last = lastFired[signal], now.timeIntervalSince(last) < Self.cooldown { return [] }
        lastFired[signal] = now
        thermalRecovery = signal
        return [Event(signal: signal)]
    }

    private mutating func setThermalActive(_ state: ProcessInfo.ThermalState) {
        active.subtract([.thermalWarm, .thermalSerious, .thermalCritical])
        switch state {
        case .nominal:
            break
        case .fair:
            active.insert(.thermalWarm)
        case .serious:
            active.formUnion([.thermalWarm, .thermalSerious])
        case .critical:
            active.formUnion([.thermalWarm, .thermalSerious, .thermalCritical])
        @unknown default:
            break
        }
    }

    private func thermalRank(_ state: ProcessInfo.ThermalState?) -> Int {
        guard let state else { return -1 }
        switch state {
        case .nominal:  return 0
        case .fair:     return 1
        case .serious:  return 2
        case .critical: return 3
        @unknown default: return -1
        }
    }

    // MARK: Glow

    /// The residue an Event leaves behind. The pill announces the crossing and
    /// goes; while the condition under it is still true the edge nearest that
    /// subsystem stays lit, until its all-clear. One edge each, on the same side
    /// as the stat peek shows for it — heat left, load right — so a side always
    /// means one thing.
    var cpuGlow: Signal? { active.contains(.cpuSustained) ? .cpuSustained : nil }

    /// Fair begins the orange edge. Serious keeps it and earns a Caution;
    /// critical keeps the same orange edge but carries red in its one-shot Event
    /// and peek glyph. Only nominal turns the edge dark.
    var thermalGlow: Signal? {
        if active.contains(.thermalCritical) { return .thermalCritical }
        if active.contains(.thermalSerious) { return .thermalSerious }
        return active.contains(.thermalWarm) ? .thermalWarm : nil
    }
}

private extension Signal {
    var isThermal: Bool {
        switch self {
        case .thermalWarm, .thermalSerious, .thermalCritical: true
        default: false
        }
    }
}

// MARK: - Self-check

#if DEBUG
enum EventEngineSelfCheck {
    /// An engine primed on a quiet reading, so the checks below can spend their
    /// first real reading on a crossing rather than on the baseline.
    private static func primed() -> EventEngine {
        var e = EventEngine()
        _ = e.update(Reading())
        return e
    }

    static func run() {
        let t0 = Date()

        // MARK: Priming

        // Launching into a state announces nothing, and having seen it, does not
        // announce it later either. This is what stops a relaunch at 100% on the
        // charger from firing "Charged" every single time.
        var b = EventEngine()
        let full = Reading(percent: 100, thermalState: .critical)
        assert(b.update(full, now: t0).isEmpty, "the first reading is a baseline, not news")
        assert(b.update(full, now: t0.addingTimeInterval(EventEngine.cooldown + 1)).isEmpty,
               "baseline must seed `active`, or the next tick reads as a crossing")
        assert(b.thermalGlow == .thermalCritical, "launching critical is a glowing baseline, not a pill")

        // MARK: Assert, hold, cool down

        var e = primed()
        var r = Reading(percent: 100)
        assert(e.update(r, now: t0) == [Event(signal: .charged)])
        assert(e.update(r, now: t0.addingTimeInterval(1)).isEmpty, "must not re-fire while held")

        // Clearing a signal that does not announce its recovery is silent.
        r.percent = 50
        assert(e.update(r, now: t0.addingTimeInterval(2)).isEmpty)

        // Re-asserting inside the cooldown stays silent; past it, it fires again.
        r.percent = 100
        assert(e.update(r, now: t0.addingTimeInterval(3)).isEmpty, "cooldown must suppress re-fire")
        r.percent = 50
        _ = e.update(r, now: t0.addingTimeInterval(4))
        r.percent = 100
        assert(e.update(r, now: t0.addingTimeInterval(EventEngine.cooldown + 1)) == [Event(signal: .charged)])

        // MARK: Charging

        // Current into the pack only counts plugged in — off the adapter the
        // same magnitude is the machine draining it.
        var c = primed()
        assert(c.update(Reading(percent: 40, onAC: false, batteryWatts: 8), now: t0).isEmpty)
        assert(c.update(Reading(percent: 40, onAC: true, batteryWatts: 8), now: t0)
               == [Event(signal: .chargingStarted)])

        // Unplugging is what clears it, so plugging back in is news again.
        _ = c.update(Reading(percent: 42, onAC: false, batteryWatts: -8), now: t0.addingTimeInterval(1))
        assert(c.update(Reading(percent: 42, onAC: true, batteryWatts: 8),
                        now: t0.addingTimeInterval(EventEngine.cooldown + 1))
               == [Event(signal: .chargingStarted)])

        // The top-off pulses of a hold at full are real current that means
        // nothing. This is the phantom the gate near full exists to swallow.
        var t = primed()
        assert(t.update(Reading(percent: 99, onAC: true, batteryWatts: 8), now: t0).isEmpty)

        // MARK: Hysteresis

        // CPU sustained holds between 30s and 60s.
        var h = primed()
        assert(h.update(Reading(cpuSustainedSeconds: 61), now: t0) == [])          // glow only, never fires
        assert(h.active.contains(.cpuSustained))
        _ = h.update(Reading(cpuSustainedSeconds: 45), now: t0)
        assert(h.active.contains(.cpuSustained), "must not clear inside the hysteresis band")
        _ = h.update(Reading(cpuSustainedSeconds: 10), now: t0)
        assert(!h.active.contains(.cpuSustained))

        // A glow-only signal that clears announces nothing, recovery or otherwise.
        _ = h.update(Reading(cpuSustainedSeconds: 61), now: t0)
        assert(h.update(Reading(cpuSustainedSeconds: 0), now: t0).isEmpty)

        // MARK: Thermal state

        // Fair starts the orange edge silently. Serious announces Caution, and
        // critical announces the red throttling Event without turning the
        // persistent edge red.
        var g = primed()
        assert(g.update(Reading(thermalState: .fair), now: t0).isEmpty)
        assert(g.thermalGlow == .thermalWarm)
        assert(g.update(Reading(thermalState: .serious), now: t0) == [Event(signal: .thermalSerious)])
        assert(g.thermalGlow == .thermalSerious)
        assert(Signal.thermalSerious.tint == .orange)
        assert(g.update(Reading(thermalState: .critical), now: t0) == [Event(signal: .thermalCritical)])
        assert(g.thermalGlow == .thermalCritical)
        assert(Signal.thermalCritical.tint == .red)
        assert(Signal.thermalCritical.glowTint == .orange, "the persistent edge never goes red")

        // Descending is not recovery while any pressure remains. Nominal turns
        // the edge dark and pays exactly the latest severe Event's recovery.
        assert(g.update(Reading(thermalState: .serious), now: t0).isEmpty)
        assert(g.thermalGlow == .thermalSerious)
        assert(g.update(Reading(thermalState: .fair), now: t0).isEmpty)
        assert(g.thermalGlow == .thermalWarm)
        assert(g.update(Reading(thermalState: .nominal), now: t0)
               == [Event(signal: .thermalCritical, recovered: true)],
               "only nominal announces the all-clear, and once")
        assert(g.thermalGlow == nil)
        assert(g.update(Reading(thermalState: .nominal), now: t0).isEmpty)

        // A jump straight to critical emits only the critical Event, not a
        // lesser Caution first.
        var j = primed()
        assert(j.update(Reading(thermalState: .critical), now: t0)
               == [Event(signal: .thermalCritical)])

        // A whole episode inside the cooldown is silent both ways: the pill is
        // suppressed, and so is the all-clear behind it, since there was no new
        // presentation to recover from.
        assert(g.update(Reading(thermalState: .critical), now: t0.addingTimeInterval(1)).isEmpty,
               "cooldown must suppress re-fire")
        assert(g.update(Reading(thermalState: .nominal), now: t0.addingTimeInterval(2)).isEmpty,
               "no all-clear for a pill that never showed")

        print("EventEngine self-check passed")
    }
}
#endif
