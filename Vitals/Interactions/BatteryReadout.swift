import SwiftUI

/// The battery in words and numbers. It appears in both Interactions — a
/// one-line summary in peek, the three power figures behind it in the panel —
/// so the wording lives in one place and cannot drift between them.
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

    // MARK: Peek's summary

    var batteryStatus: some View {
        HStack(spacing: 7) {
            Image(systemName: telemetry.power.isCharging
                  ? "battery.100percent.bolt"
                  : "battery.\(batteryStep)percent")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                // The bolt variant is not the same width as the plain glyph, so
                // a fixed box is what stops the two lines beside it sliding
                // sideways the moment the charger goes in.
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(powerSource)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(chargeDetail)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    /// First line: what the machine is running on. A full pack is decided by the
    /// level, not by `isCharging`.
    private var powerSource: String {
        let p = telemetry.power
        guard p.onAC else { return "On Battery" }
        return p.percent >= 95 ? "Fully Charged" : (p.isCharging ? "Charging" : "Plugged In")
    }

    /// Second line: where the power is coming from, which is what the first line
    /// leaves open.
    private var chargeDetail: String {
        let p = telemetry.power
        guard p.onAC else { return p.minutesToEmpty.map(duration) ?? batteryValue }
        // A full pack means nothing is flowing into it — the wattage stops being
        // the story and the adapter is simply running the machine.
        guard p.percent < 95, let rated = p.adapterWatts else { return "Using Direct Power" }
        var source = "Source: \(Int(rated.rounded()))W"
        // Only worth the parenthesis when the port did not hand over the brick's
        // full rating — otherwise it is the same number said twice.
        if let live = p.adapterContractWatts, abs(live - rated) >= 1 {
            source += " (\(Int(live.rounded()))W)"
        }
        return source
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

    /// Takes the shelf row's slot, and its 104pt tile width, so the swap reads
    /// as the row changing its mind rather than the panel resizing.
    ///
    /// Three power figures, because the third is the useful one: what the wall
    /// delivers, what reaches the battery, and the difference — the system draw.
    var batteryPanel: some View {
        HStack(spacing: 12) {
            VStack(spacing: 2) {
                Text("\(telemetry.power.percent)%")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(chargeState)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: 104).frame(maxHeight: .infinity)
            .background { RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)) }

            VStack(spacing: 5) {
                statLine("Battery", String(format: "%+.1f W", telemetry.power.batteryWatts))
                statLine("System", telemetry.power.systemWatts.map { String(format: "%.1f W", $0) } ?? "—")
                statLine("Adapter", adapterValue)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 12)
            .background { RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)) }
        }
    }

    /// On AC with no estimate the honest line is that it is plugged in —
    /// `isCharging` cannot be the only thing that decides the wording.
    private var chargeState: String {
        let p = telemetry.power
        if let m = p.minutesToFull, p.isCharging { return "\(duration(m)) to full" }
        if p.onAC { return p.isCharging ? "Charging" : (p.percent >= 95 ? "Charged" : "Plugged in") }
        return p.minutesToEmpty.map { "\(duration($0)) left" } ?? "On battery"
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
