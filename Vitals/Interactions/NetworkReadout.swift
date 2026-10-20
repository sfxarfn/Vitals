import SwiftUI

/// The link in numbers: the summary column's download rate opened up into what
/// is carrying it.
/// The rates alone say the network is slow; the rows behind them say whether
/// that is the link, the signal, or nothing to do with the radio at all.
///
/// A detail in the panel's slot, with the same 96pt hero tile and four rows as
/// `batteryPanel` and `thermalPanel`.
extension NotchView {

    // MARK: The panel's numbers

    var networkPanel: some View {
        HStack(spacing: 6) {
            // Down takes the middle for the same reason the die does on the
            // thermal tile: it is the number the panel was opened for. Up is
            // pushed to the bottom edge as its counterpart, not stacked under it.
            VStack(spacing: 0) {
                Text(interfaceName)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 2)
                Text(rate(telemetry.net.down))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Spacer(minLength: 2)
                // The arrow is the only thing marking this one as the other
                // direction, so it stays glued to its number rather than taking
                // a fixed box to line up with anything.
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up").font(.system(size: 8, weight: .bold))
                    Text(rate(telemetry.net.up)).monospacedDigit()
                }
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(.vertical, 8)
            .frame(width: 96).frame(maxHeight: .infinity)
            .background { RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)) }

            VStack(spacing: 5) {
                statLine("Link Rate", linkValue)
                statLine("Signal", signalValue, tint: signalTint)
                statLine("Band", bandValue)
                // The one row that answers on a machine with the radio off, which
                // is why it is the row that is always here.
                statLine("VPN", telemetry.net.vpn ? "Active" : "Off",
                         tint: telemetry.net.vpn ? .green : .white.opacity(0.45))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 10)
            .background { RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)) }
        }
    }

    // MARK: Wording

    /// What is carrying the traffic. The network's own name is not an option:
    /// reading the SSID needs the Location grant since macOS 14, and a prompt
    /// for it is a steep price for a word.
    ///
    /// ponytail: an associated radio is called Wi-Fi and everything else Wired,
    /// which is a guess on a machine sitting on Ethernet with the radio also up.
    /// The default route's interface is the real answer — `SCDynamicStore`, and
    /// a store to keep alive — if that machine ever turns up.
    private var interfaceName: String {
        telemetry.net.rssi != nil ? "Wi-Fi" : "Wired"
    }

    /// Negotiated PHY rate, which is the ceiling on the numbers to its left and
    /// the first thing worth checking when they are lower than expected.
    private var linkValue: String {
        telemetry.net.linkMbps.map { "\(Int($0.rounded())) Mbps" } ?? "—"
    }

    private var signalValue: String {
        telemetry.net.rssi.map { "\($0) dBm" } ?? "—"
    }

    /// Band and channel together: the band explains the link rate and the
    /// channel is what you change if it is the crowded one.
    private var bandValue: String {
        guard let band = telemetry.net.band else { return "—" }
        guard let channel = telemetry.net.channel else { return band }
        return "\(band) · \(channel)"
    }

    /// The only place on this panel that colours a number. Calibration knob, and
    /// the usual Wi-Fi bands: above -60 nothing is wrong, -75 is where rate
    /// adaptation starts costing throughput, below it the link is holding on.
    /// No threshold, no pill, no glow — nothing in the app acts on this.
    private var signalTint: Color {
        guard let rssi = telemetry.net.rssi else { return .white.opacity(0.4) }
        switch rssi {
        case (-60)...:  return .green
        case (-75)...:  return .yellow
        default:        return .red
        }
    }

    /// The shared formatter, so this detail and the summary column cannot round
    /// the same rate two different ways.
    private func rate(_ bytesPerSecond: Double) -> String {
        Self.rateFormatter.string(fromByteCount: Int64(max(bytesPerSecond, 0))) + "/s"
    }
}
