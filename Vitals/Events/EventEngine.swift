import Foundation
import SwiftUI

/// How loud a signal is allowed to be. A `pill` interrupts once and leaves; a
/// `glow` never interrupts, it just lights the notch edge for as long as the
/// condition holds. Loudness is a property of the signal's *type*, not its
/// severity — a state that lasts twenty minutes cannot pop open for twenty
/// minutes, however bad it is.
enum Loudness { case glow, pill }

/// A flattened view of telemetry. Power is numbers with thresholds;
/// thermal pressure is macOS's own state machine, because its transitions carry
/// meaning that a temperature threshold cannot reproduce.
struct Reading {
    var percent = 0
    var onAC = false
    /// Signed: positive is current going into the pack, negative is coming out.
    var batteryWatts = 0.0
    var thermalState: ProcessInfo.ThermalState = .nominal
}

/// Everything the machine can say about itself, one case per Event under Power
/// and Thermal. CPU has none: sustained load once lit an edge of its own, but on
/// a fanless chip it is the heat, so the thermal glow already says it. The other two subsystems it lists —
/// Connections and Xcode — do not read off telemetry, so they arrive as their
/// own `NotchState` rather than through here.
///
/// `loudness` says whether a signal earns a pill or only lights the edges.
enum Signal: String, CaseIterable {
    // Power.
    case chargingStarted, charged
    // Thermal — macOS's fair, serious and critical pressure levels.
    case thermalWarm, thermalSerious, thermalCritical

    /// Power crossings earn a pill. Heat never does, at any level: the edge
    /// glow lights both sides for as long as the pressure holds and darkens
    /// with it, tinted by how bad it is — a pill on top of that was the same
    /// news said twice.
    var loudness: Loudness {
        switch self {
        case .chargingStarted, .charged: .pill
        case .thermalWarm, .thermalSerious, .thermalCritical: .glow
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
        }
    }

    var title: String {
        switch self {
        case .chargingStarted:      "Charging"
        case .charged:              "Charged"
        case .thermalSerious:       "Thermal caution"
        case .thermalCritical:      "Throttling active"
        case .thermalWarm:          "Warm"
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
        case .thermalWarm, .thermalSerious: .orange
        }
    }

    /// What the edge glows: its level's tint. With no thermal pill any more the
    /// glow is the whole message, so critical is red there — the one heat
    /// state that is an emergency rather than a fact.
    var glowTint: Color { tint }

}

/// One presentation of a Signal that earns a pill.
struct Event: Equatable {
    var signal: Signal

    var symbol: String { signal.symbol }
    var title: String { signal.title }
    var tint: Color { signal.tint }
}

// MARK: - Engine

/// Tracks asserted signals and rate-limits pill presentations. Numeric signals
/// use hysteresis; thermal follows macOS's already-debounced state transitions.
struct EventEngine {
    static let cooldown: TimeInterval = 300

    private(set) var active: Set<Signal> = []
    private var lastFired: [Signal: Date] = [:]
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
        setThermalActive(r.thermalState)
        return fired
    }

    /// macOS already debounces thermal pressure, so its state is taken as is:
    /// each level lights the edges, nothing is announced.
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

    // MARK: Glow

    /// Heat, on both edges, for as long as macOS says the pressure holds: fair
    /// and serious glow orange, critical red. Only nominal turns them dark.
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

        // Charged holds between 98% and 99.5%.
        var h = primed()
        _ = h.update(Reading(percent: 100), now: t0)
        assert(h.active.contains(.charged))
        _ = h.update(Reading(percent: 99), now: t0)
        assert(h.active.contains(.charged), "must not clear inside the hysteresis band")
        _ = h.update(Reading(percent: 97), now: t0)
        assert(!h.active.contains(.charged))

        // MARK: Thermal state

        // Heat never presents, at any level or on any transition — the glow
        // carries it, and follows the state both ways.
        var g = primed()
        for state: ProcessInfo.ThermalState in [.fair, .serious, .critical, .serious, .fair, .nominal, .critical] {
            assert(g.update(Reading(thermalState: state), now: t0).isEmpty, "heat is glow-only")
        }
        assert(g.thermalGlow == .thermalCritical)
        assert(Signal.thermalCritical.glowTint == .red, "critical is the one red edge")
        _ = g.update(Reading(thermalState: .serious), now: t0)
        assert(g.thermalGlow == .thermalSerious)
        assert(Signal.thermalSerious.glowTint == .orange)
        _ = g.update(Reading(thermalState: .fair), now: t0)
        assert(g.thermalGlow == .thermalWarm)
        _ = g.update(Reading(thermalState: .nominal), now: t0)
        assert(g.thermalGlow == nil)

        print("EventEngine self-check passed")
    }
}
#endif
