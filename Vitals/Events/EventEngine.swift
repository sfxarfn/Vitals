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

/// A flattened view of telemetry. Every signal is a number with two thresholds,
/// which keeps the engine free of per-signal special cases.
struct Reading {
    var percent = 0
    var onAC = false
    /// Signed: positive is current going into the pack, negative is coming out.
    var batteryWatts = 0.0
    /// Die temperature, or 0 on a machine whose sensor tree we cannot read —
    /// which sits under every thermal threshold, so a missing sensor is silent.
    var dieTempC = 0.0
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
    // Thermal — one ladder, warm from 80° and hot from 85°.
    case thermalWarm, thermalSerious
    // CPU: sustained load is machine state. Completion belongs to the process
    // that knows what it was doing and arrives through `vitals-notify`.
    case cpuSustained

    /// Only the crossings you can act on are worth a pill. The two Cautions hold
    /// for as long as the work does, which is far too long to interrupt for, so
    /// they light their edge instead and say nothing.
    var loudness: Loudness {
        switch self {
        case .chargingStarted, .charged,
             .thermalSerious:                 .pill
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
        // Degrees off the hottest die sensor, in one ladder: warm at 80, hot at
        // 85, back to warm under 75, and all the way to green under 60. The
        // clear-below numbers are what stop a build oscillating around a single
        // degree from strobing the edge — a die crossing 80 sits there, it does
        // not tap it. Red's band is tighter than orange's because 85 is a place
        // the machine passes through, not one it settles at.
        case .thermalSerious:       (85, 75)
        // 65.5, not 65: peek prints the rounded degree, and a die at 65.4 shown
        // as "65°" in orange next to a rule that says 65 is green reads as a bug.
        // Clear where the displayed number clears.
        case .thermalWarm:          (80, 65.5)
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
        case .thermalSerious,
             .thermalWarm:          r.dieTempC
        case .cpuSustained:         r.cpuSustainedSeconds
        }
    }

    // MARK: How it looks

    var symbol: String {
        switch self {
        case .chargingStarted:      "bolt.fill"
        case .charged:              "battery.100percent.bolt"
        case .thermalSerious:       "thermometer.high"
        case .thermalWarm:          "thermometer.medium"
        case .cpuSustained:         "cpu"
        }
    }

    var title: String {
        switch self {
        case .chargingStarted:      "Charging"
        case .charged:              "Charged"
        case .thermalSerious:       "Running hot"
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
        case .thermalSerious:               .red
        case .thermalWarm, .cpuSustained:   .orange
        }
    }

    /// What the edge glows, which is not always what the signal is tinted. Heat
    /// glows orange at every level: the edge sits in peripheral vision, where
    /// red reads as an alarm you have to act on — and a die at 90° through a
    /// long build is a fact, not an emergency. Red stays where you went looking
    /// for it, on the glyph and the pill.
    var glowTint: Color { self == .thermalSerious ? .orange : tint }

    // MARK: How it presents

    /// Says everything in a glyph and one number, so it wears the accessory
    /// pill's width and layout instead of the full event pill's — the number
    /// carries more than the word would ("48°", not "Cooled down").
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
        case .thermalWarm, .thermalSerious: .left
        case .cpuSustained:                 .right
        case .chargingStarted, .charged:    .center
        }
    }

    // MARK: Recovery

    /// Whether clearing deserves a pill of its own. Only heat qualifies: it is
    /// the one you stop and wait out, so "you can go back to work" is news.
    /// Nobody is waiting for the battery to stop being full.
    var announcesRecovery: Bool { self == .thermalSerious }

    /// Which signal's clear actually means "go back to work". Usually its own,
    /// but thermal hands its all-clear down a rung: red falling to orange at 75°
    /// is still a machine running hot, and a "Cooled down" pill over an edge
    /// still glowing orange contradicts itself. The pill waits for green.
    var recoveryClearedBy: Signal {
        switch self {
        case .thermalSerious: .thermalWarm
        default:              self
        }
    }

    var recoverySymbol: String {
        switch self {
        case .thermalSerious: "thermometer.low"
        default:              symbol
        }
    }

    var recoveryTitle: String {
        switch self {
        case .thermalSerious: "Cooled down"
        default:              title
        }
    }
}

/// One presentation. `recovered` inverts the polarity: the signal just fell back
/// under its threshold rather than crossing it, which is the same signal saying
/// the opposite thing, so it gets its own word and glyph instead of its own case.
struct Event: Equatable {
    var signal: Signal
    var recovered = false

    var symbol: String { recovered ? signal.recoverySymbol : signal.symbol }
    var title: String { recovered ? signal.recoveryTitle : signal.title }
    var tint: Color { recovered ? .green : signal.tint }
}

// MARK: - Engine

/// Tracks which signals are asserted, applies hysteresis, and rate-limits the
/// pill presentations so a flapping signal cannot machine-gun the notch.
struct EventEngine {
    static let cooldown: TimeInterval = 300

    private(set) var active: Set<Signal> = []
    private var lastFired: [Signal: Date] = [:]
    /// Signals whose assert actually reached the notch. An all-clear is only news
    /// if you were told about the problem — without this, a signal flapping under
    /// the cooldown would announce recoveries from pills that never appeared.
    private var presented: Set<Signal> = []
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
            let v = s.value(r)
            let (on, off) = s.thresholds
            if active.contains(s) {
                guard v < off else { continue }
                active.remove(s)
                // The all-clear need not belong to the signal that just cleared
                // — see `recoveryClearedBy`. Thermal's red is owed its pill by
                // the orange band underneath it.
                let owed = presented.filter { $0.announcesRecovery && $0.recoveryClearedBy == s }
                presented.subtract(owed)
                fired.append(contentsOf: owed.map { Event(signal: $0, recovered: true) })
            } else if v > on {
                active.insert(s)
                guard s.loudness == .pill else { continue }
                if let last = lastFired[s], now.timeIntervalSince(last) < Self.cooldown { continue }
                lastFired[s] = now
                presented.insert(s)
                fired.append(Event(signal: s))
            }
        }
        return fired
    }

    // MARK: Glow

    /// The residue an Event leaves behind. The pill announces the crossing and
    /// goes; while the condition under it is still true the edge nearest that
    /// subsystem stays lit, until its all-clear. One edge each, on the same side
    /// as the stat peek shows for it — heat left, load right — so a side always
    /// means one thing.
    var cpuGlow: Signal? { active.contains(.cpuSustained) ? .cpuSustained : nil }

    /// The thermal level: warm from 80°, hot from 85°, nil once the die is back
    /// to 65°. Hot wins over warm — both are asserted up there, and one edge can
    /// only say one thing. The edge itself renders every level orange (see
    /// `glowTint`); the peek glyph is what carries hot as red.
    var thermalGlow: Signal? {
        if active.contains(.thermalSerious) { return .thermalSerious }
        return active.contains(.thermalWarm) ? .thermalWarm : nil
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
        let full = Reading(percent: 100, dieTempC: 90)
        assert(b.update(full, now: t0).isEmpty, "the first reading is a baseline, not news")
        assert(b.update(full, now: t0.addingTimeInterval(EventEngine.cooldown + 1)).isEmpty,
               "baseline must seed `active`, or the next tick reads as a crossing")

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

        // MARK: The thermal ladder

        // The left edge walks it: dark, orange at 80, red at 85, and back down
        // through orange before it goes out under 60.
        var g = primed()
        _ = g.update(Reading(dieTempC: 78), now: t0)
        assert(g.thermalGlow == nil, "78° is not warm yet")
        _ = g.update(Reading(dieTempC: 82), now: t0)
        assert(g.thermalGlow == .thermalWarm)
        assert(g.update(Reading(dieTempC: 87), now: t0) == [Event(signal: .thermalSerious)])
        assert(g.thermalGlow == .thermalSerious, "hot must win over warm")
        assert(Signal.thermalSerious.glowTint == .orange, "the edge never goes red")
        _ = g.update(Reading(dieTempC: 78), now: t0)
        assert(g.thermalGlow == .thermalSerious, "must not clear red inside its band")

        // Red falling to orange is not an all-clear: the pill is owed to green.
        assert(g.update(Reading(dieTempC: 72), now: t0).isEmpty, "no all-clear while still orange")
        assert(g.thermalGlow == .thermalWarm, "cooling out of red drops back to orange")
        assert(g.update(Reading(dieTempC: 66), now: t0).isEmpty)
        assert(g.thermalGlow == .thermalWarm, "orange holds to 65")
        assert(g.update(Reading(dieTempC: 65), now: t0) == [Event(signal: .thermalSerious, recovered: true)],
               "the all-clear lands with green, and once")
        assert(g.thermalGlow == nil)
        assert(g.update(Reading(dieTempC: 55), now: t0).isEmpty)

        // A whole ladder walked inside the cooldown is silent both ways: the
        // pill is suppressed, and so is the all-clear behind it, since there was
        // never a pill to recover from.
        assert(g.update(Reading(dieTempC: 87), now: t0.addingTimeInterval(1)).isEmpty,
               "cooldown must suppress re-fire")
        assert(g.update(Reading(dieTempC: 55), now: t0.addingTimeInterval(2)).isEmpty,
               "no all-clear for a pill that never showed")

        // A machine with no readable sensor reports 0°, which must stay dark
        // rather than reading as ice-cold-and-fine on a warm die.
        var n = primed()
        _ = n.update(Reading(), now: t0)
        assert(n.thermalGlow == nil)

        print("EventEngine self-check passed")
    }
}
#endif
