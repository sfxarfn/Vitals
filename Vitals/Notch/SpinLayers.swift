import AppKit
import SwiftUI

// Marks that turn for as long as a condition lasts — the Xcode build ring, the
// Claude burst. They sit on the resting notch for minutes, so what they cost per
// frame is what the notch costs all that time.
//
// A SwiftUI `repeatForever` is stepped by SwiftUI on every display frame — 120 a
// second on a ProMotion screen — and each step re-lays-out and re-renders the
// whole hosting view. Measured on the equaliser it was ~10% CPU in a Debug
// build. These are Core Animation layers instead: the rotation runs on the
// render server and the app does nothing per frame.

/// A layer that turns clockwise forever inside a view.
private class SpinView: NSView {
    let spinner = CALayer()
    private let period: Double

    init(period: Double) {
        self.period = period
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(spinner)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        // Bounds and position, never `frame`: the layer is rotating, and a
        // frame is read through its transform.
        spinner.bounds = CGRect(origin: .zero, size: bounds.size)
        spinner.position = CGPoint(x: bounds.midX, y: bounds.midY)
        sizeChanged()
        startSpin()
    }

    /// Subclasses redraw what depends on the size.
    func sizeChanged() {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A layer animation is dropped when the view leaves its window.
        startSpin()
    }

    private func startSpin() {
        guard window != nil, spinner.animation(forKey: "spin") == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        // Negative is clockwise in AppKit's y-up space.
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi
        turn.duration = period
        turn.repeatCount = .infinity
        turn.timingFunction = CAMediaTimingFunction(name: .linear)
        spinner.add(turn, forKey: "spin")
    }
}

// MARK: Arc

/// A ring with a gap that turns — the indeterminate build progress. Only the arc
/// moves; a long-running Activity should not pulse the whole notch.
struct SpinningArc: NSViewRepresentable {
    var color: NSColor
    var lineWidth: CGFloat = 3
    /// The part of the circle that is drawn, as fractions of the way round.
    var from: CGFloat = 0.08
    var to: CGFloat = 0.72
    var period: Double = 0.9

    func makeNSView(context: Context) -> NSView {
        ArcView(period: period)
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? ArcView)?.apply(color: color, lineWidth: lineWidth, from: from, to: to)
    }

    private final class ArcView: SpinView {
        private let arc = CAShapeLayer()
        private var lineWidth: CGFloat = 3

        override init(period: Double) {
            super.init(period: period)
            arc.fillColor = nil
            arc.lineCap = .round
            spinner.addSublayer(arc)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        func apply(color: NSColor, lineWidth: CGFloat, from: CGFloat, to: CGFloat) {
            self.lineWidth = lineWidth
            arc.strokeColor = color.cgColor
            arc.lineWidth = lineWidth
            arc.strokeStart = from
            arc.strokeEnd = to
            needsLayout = true
        }

        override func sizeChanged() {
            arc.frame = spinner.bounds
            arc.path = CGPath(ellipseIn: spinner.bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
                              transform: nil)
        }
    }
}

// MARK: Image

/// A template image turning slowly — the Claude burst. Tinted in, because a
/// layer has no foreground style to be coloured by.
struct SpinningImage: NSViewRepresentable {
    var name: String
    var tint: NSColor
    var period: Double

    func makeNSView(context: Context) -> NSView {
        ImageView(period: period)
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? ImageView)?.apply(name: name, tint: tint)
    }

    private final class ImageView: SpinView {
        private var applied: (name: String, tint: NSColor)?

        override init(period: Double) {
            super.init(period: period)
            spinner.contentsGravity = .resizeAspect
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        func apply(name: String, tint: NSColor) {
            if let applied, applied.name == name, applied.tint == tint { return }
            applied = (name, tint)
            spinner.contents = Self.tinted(name, tint)
            spinner.contentsScale = window?.backingScaleFactor ?? 2
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            spinner.contentsScale = window?.backingScaleFactor ?? 2
        }

        /// The template asset filled with `tint`, drawn at 4× its 20pt slot so a
        /// retina screen has pixels to spare.
        private static func tinted(_ name: String, _ tint: NSColor) -> CGImage? {
            guard let source = NSImage(named: name) else { return nil }
            let out = NSImage(size: NSSize(width: 80, height: 80), flipped: false) { rect in
                source.draw(in: rect)
                tint.set()
                rect.fill(using: .sourceIn)
                return true
            }
            return out.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
    }
}
