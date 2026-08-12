import SwiftUI

// Two glyphs SF Symbols does not ship, drawn by hand rather than looked up.

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
