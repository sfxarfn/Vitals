import SwiftUI

/// Peek: you reached for the notch and it answered. Two rows and no more — the
/// panel is what opens when you actually want to do something.
extension NotchView {

    // MARK: Rows

    /// The camera housing row carrying a stat in each flank, and a row of
    /// controls centred below it. Peek is exactly the build Activity's width, so
    /// the flanks divide the same way that one's do.
    var peekContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // The rounded degree is the summary; the panel behind it is where
                // the die actually is. Same move the battery line makes on the
                // row below — peek says the one number, the panel says why.
                Button {
                    panelBody = .thermal
                    show(.panel)
                } label: {
                    readout("thermometer.medium", tempValue, tint: tempTint)
                        .opacity(thermalHovered ? 1 : 0.85)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .onHover { thermalHovered = $0 }
                .animation(.snappy(duration: 0.15), value: thermalHovered)
                // Outside the button, so the flank keeps the exact geometry it
                // had before it became one — peek and the build share this width.
                .flankSlot(metrics.statFlanks.left, .leading, pad: metrics.notchPad)
                Spacer(minLength: 0).frame(width: metrics.notch.width)
                readout("cpu", "\(Int(telemetry.stall.cpuPercent.rounded()))%", tint: .white)
                    .flankSlot(metrics.statFlanks.right, .trailing, pad: metrics.notchPad)
            }
            .frame(height: metrics.notch.height)
            peekRow.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: size.height)
    }

    /// Peek's second row: the charge state in words, then the tray and the gear.
    /// The glyph on its own said how full the battery was and nothing about where
    /// the power was going, which is the half a hover is asking for.
    private var peekRow: some View {
        HStack(spacing: 10) {
            // The summary is also the way into the numbers behind it — the panel
            // opens straight onto the battery row rather than the shelf.
            Button {
                panelBody = .battery
                show(.panel)
            } label: {
                batteryStatus.opacity(batteryHovered ? 1 : 0.85)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { batteryHovered = $0 }
            .animation(.snappy(duration: 0.15), value: batteryHovered)
            Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 22)
                .padding(.horizontal, 4)
            // Fills up when the shelf is holding something, so the hover says
            // whether there is anything down there before you open it.
            Button {
                // The tray asks for the shelf, so it undoes a readout left up by
                // the badge or by either stat above.
                panelBody = .shelf
                show(.panel)
            } label: {
                Image(systemName: shelf.urls.isEmpty ? "tray" : "tray.full.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(trayHovered ? 0.9 : 0.45))
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { trayHovered = $0 }
            .animation(.snappy(duration: 0.15), value: trayHovered)
            SettingsLink {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(settingsHovered ? 0.9 : 0.45))
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { settingsHovered = $0 }
            .animation(.snappy(duration: 0.15), value: settingsHovered)
        }
    }

    // MARK: Stats

    /// Glyph plus one short value. Same 17/12 pair the compact pill uses, so a
    /// stat reads at the same weight whether you hovered for it or it came to
    /// you — the glyph is the only thing that says which stat this is.
    private func readout(_ symbol: String, _ value: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                // SF Symbols do not share a bounding box — `cpu` is near-square
                // and `thermometer.medium` narrow and tall — so at one point
                // size the two flanks take different room and their values stop
                // lining up. A fixed box is what makes the pair symmetric.
                .frame(width: 20)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(.white)
        }
    }

}
