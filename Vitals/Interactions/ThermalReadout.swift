import SwiftUI

/// The die in numbers: peek's one rounded degree opened up into where the heat
/// actually sits and how much room is left before the machine starts paying for
/// it in clocks. Fanless is this machine's whole problem, so the left flank gets
/// the same treatment the battery line has — a summary you can click through.
///
/// Takes the shelf row's slot and its 104pt tile, exactly as `batteryPanel`
/// does, so the swap reads as the row changing its mind rather than the panel
/// resizing under the pointer.
extension NotchView {

    /// Where this machine starts trading clocks for heat. There is no API for
    /// it: Apple publishes no Tjmax, and `thermalState` says only *that* it is
    /// throttling, never how close. Calibration knob — 100° is the observed
    /// give-up point on this M3 Air; move it if the machine says otherwise, and
    /// note the number only sets the headroom line, never a threshold.
    static let throttleCeilingC: Double = 100

    // MARK: Peek's summary

    /// A machine whose sensor tree we cannot read gets a dash, not a zero — 0°
    /// is a plausible-looking temperature and reads as a working sensor.
    var tempValue: String {
        telemetry.stall.tempC.map { "\(Int($0.rounded()))°" } ?? "—"
    }

    /// The same ladder the left edge is glowing on, read off the same signal —
    /// green under 60, orange from 70, red from 80 — so the hovered number and
    /// the glow beside it can never disagree. Hysteresis comes free with it.
    /// Shared with the panel below, so clicking through cannot change the colour
    /// of the number you clicked.
    var tempTint: Color {
        guard telemetry.stall.tempC != nil else { return .white.opacity(0.4) }
        return thermalGlow?.tint ?? .green
    }

    // MARK: The panel's numbers

    var thermalPanel: some View {
        HStack(spacing: 12) {
            VStack(spacing: 2) {
                // A decimal here and nowhere else: peek rounds because it has one
                // flank, and the whole reason to open this is that the rounded
                // number stopped being enough.
                Text(telemetry.stall.tempC.map { String(format: "%.1f°", $0) } ?? "—")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tempTint)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(headroom)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: 104).frame(maxHeight: .infinity)
            .background { RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)) }

            VStack(spacing: 5) {
                statLine("P-Cores", degrees(.pCore))
                statLine("E-Cores", degrees(.eCore))
                statLine("GPU", degrees(.gpu))
                statLine("Memory", memoryValue)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 12)
            .background { RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)) }
        }
    }

    // MARK: Wording

    /// The second line, and the one thing peek cannot say. Degrees left is a
    /// guess against a calibrated ceiling, so it is only honest while macOS
    /// agrees nothing is happening — the moment `thermalState` leaves nominal
    /// the margin is no longer a margin, and the state itself is the news.
    private var headroom: String {
        switch telemetry.thermalState {
        case .nominal:
            guard let t = telemetry.stall.tempC else { return "No sensor" }
            let left = max(Self.throttleCeilingC - t, 0)
            return "\(Int(left.rounded()))° of headroom"
        case .fair:     return "Warming up"
        case .serious:  return "Throttling"
        case .critical: return "Heavily throttled"
        @unknown default: return "—"
        }
    }

    /// A block whose sensors did not answer gets a dash, the same way a machine
    /// with no readable tree does in peek — a 0.0° row reads as a cold GPU.
    private func degrees(_ group: SensorGroup) -> String {
        telemetry.stall.dieGroups[group].map { String(format: "%.1f°", $0) } ?? "—"
    }

    /// Wired plus compressed, which is the half of memory that means the machine
    /// is out of room. Sits here rather than anywhere louder on purpose: it is a
    /// number you came looking for, not one the notch has an opinion about.
    private var memoryValue: String {
        telemetry.memoryUsed.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }
}
