import AppKit
import SwiftUI

/// The light that announces charging. One run, along the display: bottom-left
/// corner, up the left edge, across the top, into the notch. When it gets
/// there the notch grows the charging pill — the arrival is the trigger.
///
/// Not the outline glow. That one lives on the silhouette and repeats for as
/// long as the state holds, and its tint says who finished. This one never
/// touches the outline, never repeats, and is gone the moment the bolt lands.
@MainActor
final class ChargeArc {
    private var panel: NSPanel?
    private var generation = 0

    /// How long the charge takes to reach the notch. The pill is presented
    /// when this elapses, not when the state is filed.
    static let travel: TimeInterval = 0.9

    func play(on screen: NSScreen, notchMinX: CGFloat, done: @escaping () -> Void) {
        generation += 1
        let generation = generation
        close()

        let panel = NSPanel(contentRect: screen.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .mainMenu + 2
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none

        let host = NSHostingView(rootView: ChargeArcView(
            endX: notchMinX - screen.frame.minX,
            canvas: screen.frame.size))
        host.frame = CGRect(origin: .zero, size: screen.frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel
        panel.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.travel) {
            MainActor.assumeIsolated {
                guard generation == self.generation else { return }
                self.close()
                done()
            }
        }
    }

    /// Drops a run that has not landed yet. The completion does not fire.
    func cancel() {
        generation += 1
        close()
    }

    private func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Yellow light behind the notch once the charge has landed. The black shape
/// covers the fill, so only the shadow past the edge is seen, and that shadow
/// breathes. Not the outline glow: nothing travels, the whole edge brightens
/// and dims together.
struct ChargePulse: NSViewRepresentable {
    var top: CGFloat
    var bottom: CGFloat
    var animated: Bool

    func makeNSView(context: Context) -> ChargePulseView { ChargePulseView() }

    func updateNSView(_ view: ChargePulseView, context: Context) {
        view.apply(top: top, bottom: bottom, animated: animated)
    }
}

final class ChargePulseView: NSView {
    private let glow = CAShapeLayer()
    private var top: CGFloat = 22
    private var bottom: CGFloat = 28
    private var animated = true
    private var pulsing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        let yellow = NSColor.systemYellow
        glow.fillColor = yellow.withAlphaComponent(0.9).cgColor
        glow.shadowColor = yellow.cgColor
        glow.shadowRadius = 22
        glow.shadowOpacity = 1
        glow.shadowOffset = .zero
        layer?.addSublayer(glow)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(top: CGFloat, bottom: CGFloat, animated: Bool) {
        if self.top != top || self.bottom != bottom {
            self.top = top
            self.bottom = bottom
            needsLayout = true
        }
        if self.animated != animated {
            self.animated = animated
            pulsing = false
        }
        startPulseIfNeeded()
    }

    override func layout() {
        super.layout()
        guard bounds.width > 1, bounds.height > 1 else { return }
        // The shape's path is y-down. A layer's is y-up.
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = bounds
        glow.path = NotchShape(topCornerRadius: top, bottomCornerRadius: bottom)
            .path(in: bounds).cgPath.copy(using: &flip)
        CATransaction.commit()
        startPulseIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A layer animation is dropped when the view leaves its window.
        pulsing = false
        startPulseIfNeeded()
    }

    /// Armed once. Layout runs on every frame the notch grows, and restarting
    /// the pulse there would pin it at the bright end for the whole open.
    private func startPulseIfNeeded() {
        guard window != nil, !pulsing else { return }
        pulsing = true
        glow.removeAnimation(forKey: "pulse")
        guard animated else {
            glow.opacity = 0.75
            return
        }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.3
        pulse.toValue = 1
        pulse.duration = 0.75
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.opacity = 1
        glow.add(pulse, forKey: "pulse")
    }
}

/// A jagged charge with a short tail, so it reads as something running rather
/// than a line being drawn and left behind. The halo is the charge's own
/// light; the white core is the part that is actually moving.
private struct ChargeArcView: View {
    var endX: CGFloat
    var canvas: CGSize
    @State private var progress: CGFloat = 0

    var body: some View {
        let bolt = ChargeBolt(endX: endX)
        ZStack {
            bolt.trim(from: max(0, progress - 0.16), to: progress)
                .stroke(Color.yellow.opacity(0.9),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                .blur(radius: 7)
            bolt.trim(from: max(0, progress - 0.07), to: progress)
                .stroke(Color.white,
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            Circle()
                .fill(Color.white)
                .frame(width: 7, height: 7)
                .shadow(color: .yellow, radius: 8)
                .position(ChargeBolt.point(at: progress, in: canvas, endX: endX))
                .opacity(progress > 0.02 && progress < 1 ? 1 : 0)
        }
        .frame(width: canvas.width, height: canvas.height)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeIn(duration: ChargeArc.travel)) { progress = 1 }
        }
    }
}

/// Bottom-left, up the left edge, then across the top to `endX` — the notch's
/// left side. The jag stays on the bezel: it dies out at each end so the
/// charge leaves the corner and meets the notch cleanly.
private struct ChargeBolt: Shape {
    var endX: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let pts = Self.points(in: rect, endX: endX)
        guard let first = pts.first else { return path }
        path.move(to: first)
        for point in pts.dropFirst() { path.addLine(to: point) }
        return path
    }

    static func point(at progress: CGFloat, in size: CGSize, endX: CGFloat) -> CGPoint {
        let pts = points(in: CGRect(origin: .zero, size: size), endX: endX)
        guard pts.count > 1 else { return .zero }
        let clamped = min(max(progress, 0), 1)
        let f = clamped * CGFloat(pts.count - 1)
        let i = min(Int(f), pts.count - 2)
        let u = f - CGFloat(i)
        let a = pts[i], b = pts[i + 1]
        return CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u)
    }

    private static func points(in rect: CGRect, endX: CGFloat) -> [CGPoint] {
        let inset: CGFloat = 3
        let start = CGPoint(x: inset, y: rect.height - inset)
        let corner = CGPoint(x: inset, y: inset)
        let end = CGPoint(x: max(endX, inset + 12), y: inset)
        var pts = jagged(from: start, to: corner, amplitude: 7, phase: 0.4)
        pts.append(contentsOf: jagged(from: corner, to: end, amplitude: 5, phase: 1.7).dropFirst())
        return pts
    }

    /// One point every ~26pt, kicked off the straight line. `sin(tπ)` kills
    /// the offset at both ends.
    private static func jagged(from a: CGPoint, to b: CGPoint,
                               amplitude: CGFloat, phase: CGFloat) -> [CGPoint] {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 1)
        let steps = max(Int(len / 26), 2)
        let nx = -dy / len, ny = dx / len
        return (0...steps).map { i in
            let t = CGFloat(i) / CGFloat(steps)
            let edge = sin(t * .pi)
            let kick = (i % 2 == 0 ? 1 : -1) * amplitude * edge
            let wobble = sin(t * 14 + phase) * amplitude * 0.35 * edge
            return CGPoint(x: a.x + dx * t + nx * (kick + wobble),
                           y: a.y + dy * t + ny * (kick + wobble))
        }
    }
}
