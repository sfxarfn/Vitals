import SwiftUI

// Glyphs SF Symbols does not ship, drawn by hand rather than looked up.

// MARK: Bluetooth

/// The Bluetooth rune, drawn rather than looked up: SF Symbols has no glyph for
/// it. One continuous stroke, exactly as the mark is constructed.
struct BluetoothMark: Shape {
    func path(in rect: CGRect) -> Path {
        let x = { (t: CGFloat) in rect.minX + rect.width * t }
        let y = { (t: CGFloat) in rect.minY + rect.height * t }
        var path = Path()
        path.move(to: CGPoint(x: x(0), y: y(0.3)))
        path.addLine(to: CGPoint(x: x(1), y: y(0.7)))
        path.addLine(to: CGPoint(x: x(0.5), y: y(1)))
        path.addLine(to: CGPoint(x: x(0.5), y: y(0)))
        path.addLine(to: CGPoint(x: x(1), y: y(0.3)))
        path.addLine(to: CGPoint(x: x(0), y: y(0.7)))
        return path
    }
}

// MARK: AirDrop

/// The AirDrop mark, drawn for the same reason `BluetoothMark` is: SF Symbols
/// ships no AirDrop glyph, and Finder's own asset only exists inside a private
/// framework. Rings around a dot with one wedge cut out of the bottom — the gap
/// is a constant angle, so its edges run straight out of the centre and read as
/// a single wedge rather than three unrelated notches.
struct AirDropMark: Shape {
    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        // Small enough that the caller's stroke closes it into a solid dot.
        path.addEllipse(in: CGRect(x: centre.x - radius * 0.07, y: centre.y - radius * 0.07,
                                   width: radius * 0.14, height: radius * 0.14))
        // Three rings, not the six of the full-size icon — past that they merge
        // into a grey disc at the 18pt this is drawn at.
        for scale in [0.42, 0.71, 1.0] {
            path.addArc(center: centre, radius: radius * scale,
                        startAngle: .degrees(101), endAngle: .degrees(79),
                        clockwise: false)
        }
        return path
    }
}

// MARK: Claude

/// The burst while Claude is working: the real mark, turning slowly.
///
/// The turn is deliberately slower than anything that reads as a spinner — it
/// only keeps the burst from settling into one pose over the minutes this
/// condition can last. An earlier version drew the spokes by hand and pulsed
/// them; the asset replaced it. `git log` has the shape if the pulse is wanted
/// back, but it cannot be had on top of a bitmap.
///
/// Its own view, so the loop lives on a `@State` that appears with the mark and
/// dies with it. The notch's growth transaction only nils animations driven by
/// its own key, so this keeps running through a state change underneath it.
struct ClaudeWorkingMark: View {
    @State private var running = false

    var body: some View {
        // The real burst, shipped as an asset rather than approximated: the
        // spokes are uneven in a way a generated ring is not, and the drawn
        // version existed only because that was hard to reach by hand. Template
        // asset, so `extensionTint` still colours it like every other mark.
        Image("ClaudeLogo")
            .resizable()
            .scaledToFit()
            // Scoped to the rotation alone. A plain `.animation(value:)` put
            // the forever-loop on the whole transaction that flipped `running`,
            // so the mark's position rode it too and slid in from the edge.
            .animation(.linear(duration: 11).repeatForever(autoreverses: false)) {
                $0.rotationEffect(.degrees(running ? 360 : 0))
            }
            .onAppear { running = true }
    }
}
