import Foundation
import SwiftUI

/// Loudness. Tier 1 glows the notch edge; tier 2 drops the pill open and auto-hides.
enum Tier { case one, two }

/// A flattened view of telemetry. Every signal is a number with two thresholds,
/// which keeps the engine free of per-signal special cases.
struct Reading {
    var percent = 0
    var onAC = false
    var batteryWatts = 0.0
    var pressure: Int32 = 1
    var thermalIndex = 0
    var cpuSustainedSeconds = 0.0
    var swapGrowthMB = 0.0
    var loadFinished = false
}

enum Signal: String, CaseIterable {
    case netNegativeOnAC, charged, loadFinished, pressureCritical, thermalSerious
    case chargerDisconnected, pressureWarn, cpuSustained, swapGrowth

    var tier: Tier {
        switch self {
        case .netNegativeOnAC, .charged, .loadFinished,
             .pressureCritical, .thermalSerious: .two
        case .chargerDisconnected, .pressureWarn, .cpuSustained, .swapGrowth: .one
        }
    }

    /// Asserts above the first number, clears below the second. Equal means no
    /// hysteresis, which is fine for signals the OS already debounces.
    var thresholds: (assertAbove: Double, clearBelow: Double) {
        switch self {
        // 3W, not a hair over zero: a battery held at full idles around 1W and
        // the reading wanders either side of it. Below this it is a rounding
        // error, not an adapter losing the fight.
        case .netNegativeOnAC:      (3, 1)
        case .charged:              (99.5, 98)
        case .loadFinished:         (0.5, 0.5)
        case .pressureCritical:     (3, 3)
        case .thermalSerious:       (1.5, 1.5)
        case .chargerDisconnected:  (0.5, 0.5)
        case .pressureWarn:         (1.5, 1.5)
        case .cpuSustained:         (60, 30)
        case .swapGrowth:           (500, 200)
        }
    }

    func value(_ r: Reading) -> Double {
        switch self {
        // Silent at full. A pack held at 100% is deliberately cycled off the
        // adapter and topped back up every few minutes — `pmset -g log` shows
        // AC and Batt alternating seconds apart with nothing else changing —
        // and each of those dips is a real discharge that means nothing. The
        // signal is about an adapter losing to the load, which is a question
        // that only exists while there is still charging left to lose.
        case .netNegativeOnAC:      r.onAC && r.percent < 100 ? -r.batteryWatts : 0
        case .charged:              Double(r.percent)
        case .loadFinished:         r.loadFinished ? 1 : 0
        case .pressureCritical,
             .pressureWarn:         Double(r.pressure)
        case .thermalSerious:       Double(r.thermalIndex)
        case .chargerDisconnected:  r.onAC ? 0 : 1
        case .cpuSustained:         r.cpuSustainedSeconds
        case .swapGrowth:           r.swapGrowthMB
        }
    }

    var symbol: String {
        switch self {
        case .netNegativeOnAC:      "exclamationmark.triangle.fill"
        case .charged:              "battery.100percent.bolt"
        case .loadFinished:         "checkmark.circle.fill"
        case .pressureCritical:     "memorychip.fill"
        case .thermalSerious:       "thermometer.high"
        case .chargerDisconnected:  "powerplug"
        case .pressureWarn:         "memorychip"
        case .cpuSustained:         "cpu"
        case .swapGrowth:           "arrow.down.doc"
        }
    }

    var title: String {
        switch self {
        case .netNegativeOnAC:      "Draining on AC"
        case .charged:              "Charged"
        case .loadFinished:         "Load finished"
        case .pressureCritical:     "Memory critical"
        case .thermalSerious:       "Throttling"
        case .chargerDisconnected:  "Unplugged"
        case .pressureWarn:         "Memory pressure"
        case .cpuSustained:         "CPU pegged"
        case .swapGrowth:           "Swapping"
        }
    }

    var tint: Color {
        switch self {
        case .charged, .loadFinished:               .green
        case .pressureCritical, .netNegativeOnAC:   .red
        case .thermalSerious, .pressureWarn,
             .cpuSustained, .swapGrowth:            .orange
        case .chargerDisconnected:                  .yellow
        }
    }

    /// Says everything in a glyph and one number, so it wears the accessory
    /// pill's width and layout instead of the full event pill's — the number
    /// carries more than the word would ("48°", not "Cooled down").
    var isCompact: Bool {
        switch self {
        case .charged, .thermalSerious: true
        default: false
        }
    }

    /// Whether clearing deserves a pill of its own. Only the two stall states
    /// qualify: they are the ones you stop and wait out, so "you can go back to
    /// work" is news. Nobody is waiting for the battery to stop being full.
    var announcesRecovery: Bool {
        switch self {
        case .pressureCritical, .thermalSerious: true
        default: false
        }
    }

    var recoverySymbol: String {
        switch self {
        case .pressureCritical: "memorychip"
        case .thermalSerious:   "thermometer.low"
        default:                symbol
        }
    }

    var recoveryTitle: String {
        switch self {
        case .pressureCritical: "Memory clear"
        case .thermalSerious:   "Cooled down"
        default:                title
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

/// Tracks which signals are asserted, applies hysteresis, and rate-limits the
/// tier-2 presentations so a flapping signal cannot machine-gun the notch.
struct EventEngine {
    static let cooldown: TimeInterval = 300

    private(set) var active: Set<Signal> = []
    private var lastFired: [Signal: Date] = [:]
    /// Signals whose assert actually reached the notch. An all-clear is only news
    /// if you were told about the problem — without this, a signal flapping under
    /// the cooldown would announce recoveries from pills that never appeared.
    private var presented: Set<Signal> = []
    private var primed = false

    /// Returns the tier-2 events that should be presented on this tick.
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
                if s.announcesRecovery, presented.remove(s) != nil {
                    fired.append(Event(signal: s, recovered: true))
                }
            } else if v > on {
                active.insert(s)
                guard s.tier == .two else { continue }
                if let last = lastFired[s], now.timeIntervalSince(last) < Self.cooldown { continue }
                lastFired[s] = now
                presented.insert(s)
                fired.append(Event(signal: s))
            }
        }
        return fired
    }

    /// The two resting glows, one per notch edge, each on the same side as the
    /// stat peek shows for it — so a side always means one thing.
    var cpuGlow: Signal? { active.contains(.cpuSustained) ? .cpuSustained : nil }

    /// The left edge lights only once the governor is actually clamping clocks,
    /// not merely when the die is warm. A build holds the 70s for twenty minutes
    /// with nothing wrong, and an edge that is lit through every build is one
    /// nobody reads by the second week.
    var thermalGlow: Signal? { active.contains(.thermalSerious) ? .thermalSerious : nil }
}

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

        // Launching into a state announces nothing, and having seen it, does not
        // announce it later either. This is what stops a relaunch at 100% on the
        // charger from firing "Charged" every single time.
        var b = EventEngine()
        let full = Reading(percent: 100, onAC: true, pressure: 4, thermalIndex: 3)
        assert(b.update(full, now: t0).isEmpty, "the first reading is a baseline, not news")
        assert(b.update(full, now: t0.addingTimeInterval(EventEngine.cooldown + 1)).isEmpty,
               "baseline must seed `active`, or the next tick reads as a crossing")

        var e = primed()

        // Asserts once, does not re-fire while held.
        var r = Reading(pressure: 4)
        assert(e.update(r, now: t0) == [Event(signal: .pressureCritical)])
        assert(e.update(r, now: t0.addingTimeInterval(1)).isEmpty)

        // Clearing announces the all-clear, exactly once.
        r.pressure = 1
        assert(e.update(r, now: t0.addingTimeInterval(2)) == [Event(signal: .pressureCritical, recovered: true)])
        assert(e.update(r, now: t0.addingTimeInterval(3)).isEmpty)

        // Re-asserting inside the cooldown stays silent — and so does the
        // recovery behind it, since no pill ever appeared to recover from.
        r.pressure = 4
        assert(e.update(r, now: t0.addingTimeInterval(4)).isEmpty, "cooldown must suppress re-fire")
        r.pressure = 1
        assert(e.update(r, now: t0.addingTimeInterval(5)).isEmpty, "no all-clear for a pill that never showed")

        // Past the cooldown it may fire again.
        r.pressure = 4
        assert(e.update(r, now: t0.addingTimeInterval(EventEngine.cooldown + 1)) == [Event(signal: .pressureCritical)])

        // Hysteresis: CPU sustained holds between 30s and 60s.
        var h = primed()
        assert(h.update(Reading(cpuSustainedSeconds: 61), now: t0) == [])          // tier 1, never fires
        assert(h.active.contains(.cpuSustained))
        _ = h.update(Reading(cpuSustainedSeconds: 45), now: t0)
        assert(h.active.contains(.cpuSustained), "must not clear inside the hysteresis band")
        _ = h.update(Reading(cpuSustainedSeconds: 10), now: t0)
        assert(!h.active.contains(.cpuSustained))

        // A tier-1 signal that clears announces nothing, recovery or otherwise.
        _ = h.update(Reading(cpuSustainedSeconds: 61), now: t0)
        assert(h.update(Reading(cpuSustainedSeconds: 0), now: t0).isEmpty)

        // The left edge lights from `serious` up. `fair` is fans, not clamped
        // clocks, and must leave the notch dark.
        var g = primed()
        _ = g.update(Reading(thermalIndex: 1), now: t0)
        assert(g.thermalGlow == nil, "fair is not throttling")
        _ = g.update(Reading(thermalIndex: 2), now: t0)
        assert(g.thermalGlow == .thermalSerious)

        // Draining on AC only counts while plugged in.
        var d = primed()
        assert(d.update(Reading(onAC: false, batteryWatts: -12), now: t0).isEmpty)
        assert(d.update(Reading(onAC: true, batteryWatts: -12), now: t0) == [Event(signal: .netNegativeOnAC)])

        // ...and only below full: the top-off cycle at 100% discharges the pack
        // on purpose, which is the phantom this gate exists to swallow.
        // (`charged` fires on this same reading, so check for the absence of the
        // one signal rather than an empty list.)
        var f = primed()
        assert(!f.update(Reading(percent: 100, onAC: true, batteryWatts: -12), now: t0)
            .contains(Event(signal: .netNegativeOnAC)))

        // Load finished arrives as a one-shot: Telemetry raises it for a single
        // sample, so the engine must fire on that sample and then go quiet.
        var l = primed()
        assert(l.update(Reading(loadFinished: true), now: t0) == [Event(signal: .loadFinished)])
        assert(l.update(Reading(loadFinished: false), now: t0.addingTimeInterval(1)).isEmpty)

        print("EventEngine self-check passed")
    }
}
#endif
