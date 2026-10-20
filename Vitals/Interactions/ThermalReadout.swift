import SwiftUI

/// The die in numbers: the left flank's rounded degree opened up into where the heat
/// actually sits and how much room is left before the machine starts paying for
/// it in clocks. Fanless is this machine's whole problem, so the left flank gets
/// the same treatment the battery tile has — a summary you can click through.
///
/// A detail in the panel's slot, with the same 96pt hero tile and four rows as
/// `batteryPanel` and `networkPanel`.
extension NotchView {

    /// Where this machine starts trading clocks for heat. There is no API for
    /// it: Apple publishes no Tjmax, and `thermalState` says only *that* it is
    /// throttling, never how close. Calibration knob — 100° is the observed
    /// give-up point on this M3 Air; move it if the machine says otherwise, and
    /// note the number only sets the headroom line, never a threshold.
    static let throttleCeilingC: Double = 100

    /// "Apple M3". `machdep.cpu.brand_string` is the chip's own name and the one
    /// thing on this panel that cannot change while the app runs, so it is read
    /// once. A host that will not answer gets no line rather than a placeholder.
    static let chipName: String = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0
        else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0) == 0
        else { return "" }
        return String(cString: buf).trimmingCharacters(in: .whitespaces)
    }()

    // MARK: The flank's summary

    /// A machine whose sensor tree we cannot read gets a dash, not a zero — 0°
    /// is a plausible-looking temperature and reads as a working sensor.
    var tempValue: String {
        telemetry.stall.tempC.map { "\(Int($0.rounded()))°" } ?? "—"
    }

    /// The same macOS thermal-pressure state the edge glow follows: nominal is
    /// green, fair and serious are orange, and critical is red. Shared with the
    /// panel below, so clicking through cannot change the colour of the number
    /// you clicked.
    var tempTint: Color {
        guard telemetry.stall.tempC != nil else { return .white.opacity(0.4) }
        return thermalGlow?.tint ?? .green
    }

    // MARK: The panel's numbers

    var thermalPanel: some View {
        HStack(spacing: 6) {
            // The chip's name and the headroom line are pushed to the tile's two
            // edges rather than stacked around the degree, so the number the
            // panel exists for takes the whole middle instead of a third of it.
            VStack(spacing: 0) {
                Text(Self.chipName)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 2)
                // A decimal here and nowhere else: the flank rounds because it has
                // one short slot, and the whole reason to open this is that the rounded
                // number stopped being enough.
                Text(telemetry.stall.tempC.map { String(format: "%.1f°", $0) } ?? "—")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tempTint)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 2)
                Text(headroom)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.vertical, 8)
            .frame(width: 96).frame(maxHeight: .infinity)
            .background { RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)) }

            VStack(spacing: 5) {
                ForEach(rows) { statLine($0.label, $0.value, tint: $0.tint) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 10)
            .background { RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)) }
        }
    }

    // MARK: Wording

    /// The second line, and the one thing the flank cannot say. Degrees left is a
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
        case .serious:  return "Thermal caution"
        case .critical: return "Throttling active"
        @unknown default: return "—"
        }
    }

    /// The rows on the right, which are whatever this chip is willing to name.
    /// M1 splits its die three ways and spends the room on those; M2 and M3
    /// publish it as sixteen unlabelled sensors, so naming any of them would be
    /// a guess — the big number on the left already is the chip, and the rows go
    /// to the parts of the machine that are *not* it, plus what memory is doing.
    ///
    /// Four rows either way: the block is a fixed slot the battery panel shares,
    /// and a fifth row would shrink the type on both.
    private var rows: [ThermalRow] {
        let groups = telemetry.stall.dieGroups
        let memory = ThermalRow(label: "Memory", value: memoryValue, tint: memoryTint)
        guard groups[.pCore] == nil, groups[.eCore] == nil else {
            return [ThermalRow(label: "P-Cores", value: degrees(.pCore)),
                    ThermalRow(label: "E-Cores", value: degrees(.eCore)),
                    ThermalRow(label: "GPU", value: degrees(.gpu)),
                    memory]
        }
        return [ThermalRow(label: "SSD", value: degrees(.storage)),
                ThermalRow(label: "Battery", value: degrees(.battery)),
                memory,
                // The split behind the row above, and the reason it is dimmed: it
                // explains a number rather than being one you act on.
                ThermalRow(label: "Lock/Pressure", value: memorySplit,
                           tint: .white.opacity(0.45))]
    }

    /// A label, a value, and what colour the value is. Named only because
    /// `ForEach` cannot key off a tuple.
    struct ThermalRow: Identifiable {
        let label: String
        let value: String
        var tint: Color = .white
        var id: String { label }
    }

    /// A block whose sensors did not answer gets a dash, the same way a machine
    /// with no readable tree does in the flank — a 0.0° row reads as a cold GPU.
    private func degrees(_ group: SensorGroup) -> String {
        telemetry.stall.dieGroups[group].map { String(format: "%.1f°", $0) } ?? "—"
    }

    /// Wired plus compressed, which is the half of memory that means the machine
    /// is out of room. Sits here rather than anywhere louder on purpose: it is a
    /// number you came looking for, not one the notch has an opinion about.
    private var memoryValue: String {
        telemetry.memory.map { "\(percent($0.used))%" } ?? "—"
    }

    /// The two halves the row above adds together, in the order the label names.
    private var memorySplit: String {
        telemetry.memory.map { "\(percent($0.wired))%/\(percent($0.compressed))%" } ?? "—"
    }

    /// The only place on this panel that colours a memory number. Calibration
    /// knob, and a soft one — these are the bands where this machine starts
    /// swapping, not thresholds anything acts on.
    private var memoryTint: Color {
        guard let used = telemetry.memory?.used else { return .white.opacity(0.4) }
        switch used {
        case ..<0.4:  return .green
        case ..<0.7:  return .yellow
        default:      return .red
        }
    }

    private func percent(_ fraction: Double) -> Int { Int((fraction * 100).rounded()) }
}
