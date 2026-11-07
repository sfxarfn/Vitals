import AppKit
import SwiftUI

// Light that travels the notch's own edge. Behind the black shape, so only what
// escapes the edge is seen — the same trick as the thermal glow bars, but along
// the whole outline instead of one flank.
//
// Core Animation layers, not a SwiftUI `repeatForever`: this sits on screen for
// seconds, and a SwiftUI loop re-renders the whole hosting view every display
// frame. See `SpinLayers.swift`.

extension NotchShape {
    /// The outline from the tip of the left flare, down the side, round the
    /// bottom and up to the tip of the right one. `path(in:)` closes with a run
    /// back across the top, which is the screen edge and has nothing to light —
    /// and would be counted in the length a trim is a fraction of.
    func outline(in rect: CGRect) -> Path {
        var open = Path()
        path(in: rect).forEach { element in
            switch element {
            case .move(let to): open.move(to: to)
            case .line(let to): open.addLine(to: to)
            case .quadCurve(let to, let control): open.addQuadCurve(to: to, control: control)
            case .curve(let to, let c1, let c2): open.addCurve(to: to, control1: c1, control2: c2)
            case .closeSubpath: break
            }
        }
        return open
    }
}

/// A faint tint all the way along the edge, and a swell — brighter and wider —
/// that runs along it from top left to top right and repeats, like a wave round
/// a stadium. Each dot rises and falls on the same curve, started a little later
/// the further along the outline it sits; the delay *is* the travel.
struct OutlineGlow: NSViewRepresentable {
    /// The silhouette's flare and bottom radii, so the layers sit on its real edge.
    var top: CGFloat
    var bottom: CGFloat
    var tint: NSColor
    /// False under Reduce Motion: the tint holds along the edge and nothing runs.
    var animated: Bool

    func makeNSView(context: Context) -> NSView { GlowView() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? GlowView)?.apply(top: top, bottom: bottom, tint: tint, animated: animated)
    }

    private final class GlowView: NSView {
        // Calibration knobs. The dots sit a few points apart — four or five
        // overlap at any spot even at rest — so the edge reads as one band of
        // light and the crest as one swell. At 30 they were ~15pt apart on a
        // grown shape and showed as beads, and the crest stepped from one to
        // the next.
        private static let count = 64
        private static let size: CGFloat = 36
        /// One dot's cycle: a swell, then rest until the next one reaches it.
        private static let period = 1.9
        /// The part of `period` the swell takes to rise and fall. With `travel`
        /// it sets how long the crest is along the edge — about half of it at
        /// full strength. A third read as a blip rather than a wave.
        private static let swell = 0.65
        /// How long the crest takes to cross the whole outline. Shorter than
        /// `period`, so the next swell starts before the last has left.
        private static let travel = 1.3
        private static let restScale: CGFloat = 1.05
        private static let peakScale: CGFloat = 1.35
        // Lower than a single dot would need: overlapping dots stack their
        // alpha, and the band is several dots deep everywhere.
        private static let restOpacity: Float = 0.3
        private static let peakOpacity: Float = 0.75

        private var dots: [CALayer] = []
        private var top: CGFloat = 22
        private var bottom: CGFloat = 28
        private var tint: NSColor?
        private var animated = true

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
            for _ in 0..<Self.count {
                let dot = CALayer()
                dot.bounds = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
                dot.contentsGravity = .resize
                layer?.addSublayer(dot)
                dots.append(dot)
            }
            restyle()
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        func apply(top: CGFloat, bottom: CGFloat, tint: NSColor, animated: Bool) {
            self.top = top
            self.bottom = bottom
            if self.tint != tint {
                self.tint = tint
                let image = Self.softDot(tint)
                dots.forEach { $0.contents = image }
            }
            if self.animated != animated {
                self.animated = animated
                restyle()
            }
            needsLayout = true
        }

        override func layout() {
            super.layout()
            guard bounds.width > 1, bounds.height > 1 else { return }
            let outline = NotchShape(topCornerRadius: top, bottomCornerRadius: bottom)
                .outline(in: CGRect(origin: .zero, size: bounds.size))
            // Positions only — the crest's animation is not restarted. Laid out
            // on every frame the silhouette grows, so no implicit animation.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (i, dot) in dots.enumerated() {
                let along = Double(i) / Double(Self.count - 1)
                // Path coordinates are y-down; a layer's are y-up.
                let point = outline.trimmedPath(from: 0, to: max(along, 0.001)).currentPoint ?? .zero
                dot.position = CGPoint(x: point.x, y: bounds.height - point.y)
            }
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // A layer animation is dropped when the view leaves its window.
            if window != nil { restyle() }
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            let scale = window?.backingScaleFactor ?? 2
            dots.forEach { $0.contentsScale = scale }
        }

        /// The resting look, then the crest on top of it unless motion is reduced.
        private func restyle() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (i, dot) in dots.enumerated() {
                let w = Self.endWeight(i)
                dot.removeAnimation(forKey: "wave")
                dot.opacity = Float(w) * (animated ? Self.restOpacity : 0.5)
                let scale = Self.endScale(w) * (animated ? Self.restScale : 0.9)
                dot.transform = CATransform3DMakeScale(scale, scale, 1)
            }
            CATransaction.commit()
            guard animated, window != nil, let layer else { return }
            let now = layer.convertTime(CACurrentMediaTime(), from: nil)
            // One smooth bump — sin², sampled densely — then flat rest. The old
            // curve was three eased segments, which stalled each dot at its
            // peak and again on the way down; with every dot doing it a beat
            // after the last, the crest lurched along instead of gliding.
            let samples = 24
            var keyTimes: [NSNumber] = []
            var bump: [Double] = []
            for k in 0...samples {
                let t = Double(k) / Double(samples) * Self.swell
                keyTimes.append(NSNumber(value: t))
                bump.append(pow(sin(Double.pi * t / Self.swell), 2))
            }
            keyTimes.append(1)
            bump.append(0)
            let scales = bump.map { Double(Self.restScale) + Double(Self.peakScale - Self.restScale) * $0 }
            let opacities = bump.map { Double(Self.restOpacity) + Double(Self.peakOpacity - Self.restOpacity) * $0 }
            for (i, dot) in dots.enumerated() {
                let along = Double(i) / Double(Self.count - 1)
                let w = Self.endWeight(i)
                let swell = CAKeyframeAnimation(keyPath: "transform.scale")
                swell.values = scales.map { $0 * Double(Self.endScale(w)) }
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = opacities.map { $0 * w }
                for animation in [swell, fade] {
                    animation.keyTimes = keyTimes
                    animation.calculationMode = .linear
                }
                let group = CAAnimationGroup()
                group.animations = [swell, fade]
                group.duration = Self.period
                group.repeatCount = .infinity
                // Started later the further along: a dot that has not begun
                // holds the resting look, so the first crest enters at the top
                // left and walks round.
                group.beginTime = now + along * Self.travel
                group.fillMode = .backwards
                dot.add(group, forKey: "wave")
            }
        }

        /// How much of a dot's light survives at its place along the outline:
        /// 1 along the sides and bottom, easing to 0 at the two tips. The
        /// outline starts and ends on the screen edge, at the flare's tip, where
        /// nothing black covers the dot's inner half and the window's top edge
        /// cuts the rest off flat — a bright blob sliced square. Fading the last
        /// stretch lets the light thin out into the bezel instead.
        private static let endFade = 0.14
        private static func endWeight(_ i: Int) -> Double {
            let along = Double(i) / Double(count - 1)
            let x = min(1, min(along, 1 - along) / endFade)
            return x * x * (3 - 2 * x)
        }
        /// Shrunk with the fade, so a dot near a tip is small as well as faint
        /// and does not reach the window's edge to be cut.
        private static func endScale(_ w: Double) -> CGFloat { CGFloat(0.4 + 0.6 * w) }

        /// A round, soft-edged dot in `tint` — the blur a layer cannot cheaply
        /// have, painted once instead. A Gaussian-like falloff, not a three-stop
        /// ramp: the ramp's knee showed as a ring, which is what made each dot
        /// visible on its own.
        private static func softDot(_ tint: NSColor) -> CGImage? {
            let color = tint.usingColorSpace(.sRGB) ?? tint
            let image = NSImage(size: NSSize(width: 96, height: 96), flipped: false) { rect in
                let centre = CGPoint(x: rect.midX, y: rect.midY)
                NSGradient(colorsAndLocations: (color, 0),
                           (color.withAlphaComponent(0.85), 0.2),
                           (color.withAlphaComponent(0.5), 0.4),
                           (color.withAlphaComponent(0.2), 0.6),
                           (color.withAlphaComponent(0.05), 0.8),
                           (color.withAlphaComponent(0), 1))?
                    .draw(fromCenter: centre, radius: 0, toCenter: centre, radius: rect.width / 2, options: [])
                return true
            }
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
    }
}
