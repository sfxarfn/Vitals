import SwiftUI

/// The battery in words and numbers. It appears twice in the panel — the
/// summary column's short value and the detail behind it — and in the battery
/// pills, so the wording lives in one place and cannot drift between them.
///
/// The recurring caveat: `isCharging` reads false through adapter negotiation
/// and for every top-off pulse of a hold at full, so nothing here decides "full"
/// from that flag alone.
extension NotchView {

    /// The pack as a short value, for the flanks that have room for one and
    /// nothing else. A pack at the top says so in a word: "100%" is a
    /// measurement, and at the ceiling there is nothing left to measure — the
    /// only thing worth reading is that it is done. Every other level is a
    /// number, because that is the half you are actually watching move.
    ///
    /// Lives here with the rest of the battery wording so a pill and a hover
    /// cannot end up calling the same pack two different things.
    var batteryValue: String {
        telemetry.power.percent >= 100 ? "Full" : "\(telemetry.power.percent)%"
    }

    /// What colour the pack is. The detail's number only — the summary column's
/// glyph stays white, because the detail is where the tinted number lives.
///
/// Charging amber and full green are `Signal`'s colours, not new ones: the
/// tint is the state of the pack, never a severity. The two low bands below
/// them are, and they are a calibration knob of the same kind as the thermal
/// panel's memory tint — no `Signal`, no pill, no glow, nothing decides
/// anything from them.
var batteryTint: Color {
let p = telemetry.power
// Order matters: a pack held at full pulses `isCharging` false all day, so
// the level has to answer before the flag gets asked.
if p.onAC, p.percent >= 95 { return .green }
if p.onAC, p.isCharging { return .orange }
switch p.percent {
case ..<10: return .red
case ..<20: return .yellow
default: return .white
}
}

// MARK: The summary column

    /// A full pack on the adapter is not a battery any more — the machine is
    /// running off the wall — so the column says that instead of "100%".
    private var onWallPower: Bool {
        telemetry.power.onAC && telemetry.power.percent >= 100
    }

    /// Three states, and "AC" is only the last of them. On the adapter below
    /// full the pack is still filling, so it says charging — the bolt and the
    /// level — rather than AC. Decided by the adapter, not `isCharging`: that
    /// flag reads false through negotiation and every top-off pulse, which would
    /// flick the bolt off on a pack that is plainly charging.
    var batteryMiniSymbol: String {
        if onWallPower { return "powerplug.fill" }
        return telemetry.power.onAC ? "battery.100percent.bolt" : "battery.\(batteryStep)percent"
    }

    var batteryMiniValue: String {
        onWallPower ? "AC" : "\(telemetry.power.percent)%"
    }

    /// SF Symbols only ships five fill levels, so the reading snaps to the
    /// nearest one rather than rounding down — 60% on a `50percent` glyph reads
    /// emptier than the battery is.
    var batteryStep: Int {
        switch telemetry.power.percent {
        case ..<13:  0
        case ..<38:  25
        case ..<63:  50
        case ..<88:  75
        default:     100
        }
    }

    // MARK: The panel's numbers

    /// A detail in the panel's slot: the same 96pt hero tile and four rows as
    /// the thermal and network details, so switching reads as the slot
    /// changing its mind rather than the layout moving.
    ///
    /// Four rows, matching the thermal panel's block: what reaches the battery,
    /// what the machine burns, what the wall delivers, and what the pack has
    /// left to give.
    var batteryPanel: some View {
        HStack(spacing: 6) {
            VStack(spacing: 2) {
                Text("\(telemetry.power.percent)%")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(batteryTint)
                Text(chargeState)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(width: 96).frame(maxHeight: .infinity)
            .background { RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)) }

            VStack(spacing: 5) {
                statLine("Battery", batteryWattsValue)
                statLine("System", telemetry.power.systemWatts.map { String(format: "%.1f W", $0) } ?? "—")
                statLine("Adapter", adapterValue, dot: adapterDot)
                // The split behind the row: the percentage is what the pack can
                // still hold, the count is how it got there. Dimmed like the
                // thermal panel's own explanatory row — nothing acts on it.
                statLine("Health", healthValue, tint: .white.opacity(0.45))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 10)
            .background { RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)) }
        }
    }

    /// Signed, except at nothing: "-0.0 W" is a rounding artefact that reads as
    /// a drain, so anything that rounds to zero says plain "0.0 W".
    private var batteryWattsValue: String {
        let w = telemetry.power.batteryWatts
        return abs(w) < 0.05 ? "0.0 W" : String(format: "%+.1f W", w)
    }

    /// On AC with no estimate the honest line is that it is plugged in —
    /// `isCharging` cannot be the only thing that decides the wording.
    private var chargeState: String {
        let p = telemetry.power
        if let m = p.minutesToFull, p.isCharging { return "\(duration(m)) to full" }
        if p.onAC { return p.isCharging ? "Charging" : (p.percent >= 95 ? "Charged" : "Plugged in") }
        return p.minutesToEmpty.map { "\(duration($0)) left" } ?? "On battery"
    }

    /// Health and cycles in one row, because either alone is half the story: a
    /// 92% pack at 40 cycles and one at 800 are not the same battery.
    private var healthValue: String {
        guard let h = telemetry.power.healthPercent else { return "—" }
        guard let c = telemetry.power.cycleCount, c > 0 else { return "\(h)%" }
        return "\(h)% · \(c)"
    }

    /// Amber when the port settled below what the brick is rated for — a 96W
    /// charger negotiating 27W is a cable, a hub or a shared lane, and all
    /// three are things you can go fix. 1W of tolerance, because a
    /// rounding difference is not a finding.
    ///
    /// Green is the absence of that finding, not proof of the opposite, and it
    /// has to be: a full pack draws nothing, so the firmware reports no
    /// negotiated current and the contract goes unreadable — which is the state
    /// this machine spends most of its day in. A dot that only lit while the
    /// battery happened to be filling would be off exactly when you looked.
    /// Off AC there is no adapter, and no dot.
    private var adapterDot: Color? {
        let p = telemetry.power
        guard p.onAC else { return nil }
        guard let rated = p.adapterWatts, let live = p.adapterContractWatts,
              rated - live >= 1 else { return .green }
        return .orange
    }

    private var adapterValue: String {
        let p = telemetry.power
        guard p.onAC else { return "—" }
        if let w = p.adapterWatts { return "\(Int(w.rounded()))W" }
        return p.adapterName ?? "AC"
    }

    /// The estimate is nil until macOS has watched the draw settle, which is why
    /// every caller here treats it as optional rather than showing a 0:00.
    private func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }
}
