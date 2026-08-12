import SwiftUI

/// How an Event draws. Every one of these is two flanks with the camera housing
/// between them, and each is up for `NotchController.eventDuration` and gone.
extension NotchView {

    // MARK: Sided

    /// One Event per live flank, with the notch's own width between them. A
    /// missing side contributes nothing at all — the shape is already narrower
    /// by that flank, so an empty spacer there would push the live one across
    /// the camera housing.
    func sidedPill(_ left: Event?, _ right: Event?) -> some View {
        HStack(spacing: 0) {
            if let left { flank(left, .leading) }
            Spacer(minLength: 0).frame(width: metrics.notch.width)
            if let right { flank(right, .trailing) }
        }
        .frame(height: metrics.notch.height)
    }

    /// One Event in one flank, `side` being the side of the notch it owns.
    /// Everything sits in a single 15/12 pair rather than the compact pill's
    /// 17/12, because here the glyph and its value share a flank instead of
    /// owning one each.
    private func flank(_ event: Event, _ side: HorizontalEdge) -> some View {
        HStack(spacing: 4) {
            // CPU releasing is a verdict on work, not a reading: it leads
            // with what was busy and lets the checkmark be the news, where
            // every other one-sided pill leads with its own glyph.
            if event.signal == .loadFinished {
                Image(systemName: "cpu").foregroundStyle(.white)
                Image(systemName: event.symbol).foregroundStyle(event.tint)
            } else {
                Image(systemName: event.symbol).foregroundStyle(event.tint)
                Text(compactValue(event))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(.white)
            }
        }
        .font(.system(size: 15, weight: .medium))
        .flankSlot(metrics.sidedFlank, side, pad: metrics.notchPad)
    }

    // MARK: Centre

    /// Same two-flank shape as the accessory pill: tinted glyph on the left, a
    /// live number on the right, camera housing in between. A number says more
    /// than the word would and costs half the room.
    ///
    /// The glyph is the one flank in the app that is centred rather than pinned.
    /// It is a bolt or a battery against "100%" — hugging both edges would leave
    /// the glyph with two or three times the outer gap the number has, and the
    /// pill reads as leaning even though it is symmetric.
    func compactPill(_ event: Event) -> some View {
        HStack(spacing: 0) {
            Image(systemName: event.symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(event.tint)
                // Two points inward, on top of the centring. `battery.100percent.bolt`
                // is a wide horizontal glyph whose ink sits left of the box it
                // is centred in — the terminal nub on its right end is drawn
                // into the glyph's own padding — so geometric centre reads as
                // sitting slightly outward. Optical, not layout: the slot is
                // fixed and the glyph never fills it.
                //
                // Calibration knob. It rides along on the bolt, which is narrow
                // enough that two points is inside the noise.
                .offset(x: 2)
                .flankSlot(metrics.glyphFlank, .leading, pad: metrics.notchPad, centered: true)
            Spacer(minLength: 0).frame(width: metrics.notch.width)
            Text(compactValue(event))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(.white)
                .flankSlot(metrics.glyphFlank, .trailing, pad: metrics.notchPad)
        }
        .frame(height: metrics.notch.height)
    }

    /// Falls back to the word when the sensor tree gave us nothing — a thermal
    /// pill with an empty flank would look broken rather than quiet.
    private func compactValue(_ event: Event) -> String {
        switch event.signal {
        case .thermalSerious:
            telemetry.stall.tempC.map { "\(Int($0.rounded()))°" } ?? event.title
        default:
            batteryValue
        }
    }

    // MARK: Connections

    /// A Bluetooth accessory connected. Same two-flank trick as the event pill:
    /// the camera housing owns the middle, so the glyph and the level take a
    /// side each.
    func accessoryPill(_ accessory: Accessory) -> some View {
        HStack(spacing: 0) {
            Image(systemName: accessory.symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .flankSlot(metrics.glyphFlank, .leading, pad: metrics.notchPad)
            Spacer(minLength: 0).frame(width: metrics.notch.width)
            batteryRing(accessory).flankSlot(metrics.glyphFlank, .trailing, pad: metrics.notchPad)
        }
        .frame(height: metrics.notch.height)
    }

    /// A device that never reported a level gets the Bluetooth mark instead —
    /// an empty ring would read as a flat battery. Classic Bluetooth headsets
    /// cannot report one at all — a platform limit, not a missing feature.
    @ViewBuilder private func batteryRing(_ accessory: Accessory) -> some View {
        if let level = accessory.battery {
            ring(Double(level) / 100, tint: accessory.batteryTint)
        } else {
            BluetoothMark()
                .stroke(Color(red: 0, green: 0.51, blue: 1),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 11, height: 18)
        }
    }

    func audioLostPill(_ loudness: Double) -> some View {
        AudioLostPill(metrics: metrics, loudness: loudness)
    }
}

// MARK: - Audio lost

/// Sound just fell off a headset onto the built-in speakers, told in two beats
/// inside the notch's two flanks.
///
/// Nothing travels between them on purpose: the notch's own width in the middle
/// is the camera housing, so an icon sliding across it is invisible for most of
/// the trip and the swap reads as a glitch. The left glyph turns over in place
/// and the right one fades up instead, which lands as a handoff without either
/// icon entering dead space. The resting frame it settles into has to carry the
/// whole message on its own — the pill lives 2.6s and you look up late.
///
/// Its own type, not a method, because the turnover needs state of its own.
private struct AudioLostPill: View {
    let metrics: NotchMetrics
    /// The speakers' volume at the handoff, 0–1.
    let loudness: Double
    @State private var lost = false

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: lost ? "headphones.slash" : "headphones")
                .foregroundStyle(lost ? Color.red : .white)
                .contentTransition(.symbolEffect(.replace))
                .flankSlot(metrics.glyphFlank, .leading, pad: metrics.notchPad)
            Spacer(minLength: 0).frame(width: metrics.notch.width)
            // Variable-value symbol: the waves are drawn by the volume, not
            // picked. That is the second half of the message — you are on the
            // speakers, and this is how much of you the room is getting. A
            // muted machine draws the bare speaker.
            Image(systemName: "speaker.wave.3.fill", variableValue: loudness)
                .foregroundStyle(.white)
                .opacity(lost ? 1 : 0)
                .flankSlot(metrics.glyphFlank, .trailing, pad: metrics.notchPad)
        }
        .font(.system(size: 17, weight: .medium))
        .frame(height: metrics.notch.height)
        .task {
            // Beat one is the pill arriving with the headset still on it; the
            // turnover only lands once the shape has finished growing, or the
            // two animations fight and neither reads.
            try? await Task.sleep(for: .seconds(0.35))
            withAnimation(.easeOut(duration: 0.3)) { lost = true }
        }
    }
}
