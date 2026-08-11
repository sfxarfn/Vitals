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
        case .netNegativeOnAC:      (0.5, 0.1)
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
        case .netNegativeOnAC:      r.onAC ? -r.batteryWatts : 0
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

    /// Returns the tier-2 events that should be presented on this tick.
    mutating func update(_ r: Reading, now: Date = Date()) -> [Event] {
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

    /// Worst currently-asserted tier-1 signal, for the resting hairline.
    var hairline: Signal? {
        active.filter { $0.tier == .one }
            .min { a, b in Signal.allCases.firstIndex(of: a)! < Signal.allCases.firstIndex(of: b)! }
    }
}

#if DEBUG
enum EventEngineSelfCheck {
    static func run() {
        var e = EventEngine()
        let t0 = Date()

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
        var h = EventEngine()
        assert(h.update(Reading(cpuSustainedSeconds: 61), now: t0) == [])          // tier 1, never fires
        assert(h.active.contains(.cpuSustained))
        _ = h.update(Reading(cpuSustainedSeconds: 45), now: t0)
        assert(h.active.contains(.cpuSustained), "must not clear inside the hysteresis band")
        _ = h.update(Reading(cpuSustainedSeconds: 10), now: t0)
        assert(!h.active.contains(.cpuSustained))

        // A tier-1 signal that clears announces nothing, recovery or otherwise.
        _ = h.update(Reading(cpuSustainedSeconds: 61), now: t0)
        assert(h.update(Reading(cpuSustainedSeconds: 0), now: t0).isEmpty)

        // Draining on AC only counts while plugged in.
        var d = EventEngine()
        assert(d.update(Reading(onAC: false, batteryWatts: -12), now: t0).isEmpty)
        assert(d.update(Reading(onAC: true, batteryWatts: -12), now: t0) == [Event(signal: .netNegativeOnAC)])

        // Load finished arrives as a one-shot: Telemetry raises it for a single
        // sample, so the engine must fire on that sample and then go quiet.
        var l = EventEngine()
        assert(l.update(Reading(loadFinished: true), now: t0) == [Event(signal: .loadFinished)])
        assert(l.update(Reading(loadFinished: false), now: t0.addingTimeInterval(1)).isEmpty)

        print("EventEngine self-check passed")
    }
}
#endif
