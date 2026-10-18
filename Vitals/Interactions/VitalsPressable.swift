//
//  VitalsPressable.swift
//  Vitals
//
//  Hover, press, and the pointing-hand cursor for everything you can click
//  in peek and the panel. One modifier so the controls cannot drift.

import AppKit
import SwiftUI

enum VitalsCursor {
    /// How many controls are currently under the pointer. The arrow only comes
    /// back at zero, so moving from the tray to the gear does not flash it.
    private static var claims = 0

    private static var dragOwnsCursor: Bool {
        NotchController.shared?.draggingFile == true
    }

    static func claim() {
        claims += 1
        hand()
    }

    static func release() {
        claims = max(0, claims - 1)
        if claims == 0 { arrow() }
    }

    static func hand() {
        guard !dragOwnsCursor else { return }
        NSCursor.pointingHand.set()
    }

    static func arrow() {
        guard !dragOwnsCursor else { return }
        NSCursor.arrow.set()
    }

    /// Hover ended on a control whose tracking area may still be claimed by
    /// the one the pointer moved onto. Only the last claim puts the arrow back.
    static func arrowIfIdle() {
        if claims == 0 { arrow() }
    }

    /// The panel went away under the pointer. Drops every claim so a missed
    /// mouseExited cannot leave the hand up.
    static func forceArrow() {
        claims = 0
        NSCursor.arrow.set()
    }
}

extension View {
    /// Spring scale and a soft highlight while the pointer is over a control,
    /// a slight scale-down while it is held, and a pointing-hand cursor.
    /// `tracksPress` is off for a row that is also a drag source — a zero-distance
    /// drag on a shelf chip would take the scroll and the file drag with it.
    func vitalsPressable(tracksPress: Bool = true) -> some View {
        modifier(VitalsPressable(tracksPress: tracksPress))
    }
}

private struct VitalsPressable: ViewModifier {
    var tracksPress: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false
    @State private var holding = false

    @ViewBuilder func body(content: Content) -> some View {
        if tracksPress {
            styled(content).simultaneousGesture(press)
        } else {
            styled(content)
        }
    }

    private func styled(_ content: Content) -> some View {
        content
            .scaleEffect(scale)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(hovered && !holding ? 0.12 : 0))
                    .allowsHitTesting(false)
            }
            .animation(motion, value: hovered)
            .animation(motion, value: holding)
            .background { PointingCursor() }
            .onContinuousHover { phase in
                guard isEnabled else {
                    hovered = false
                    holding = false
                    VitalsCursor.arrowIfIdle()
                    return
                }
                switch phase {
                case .active:
                    if !hovered { hovered = true }
                    // Backup for the tracking area: SwiftUI hover sees the
                    // control when the window is taking mouse-moved events.
                    VitalsCursor.hand()
                case .ended:
                    hovered = false
                    holding = false
                    VitalsCursor.arrowIfIdle()
                }
            }
            .onDisappear {
                // The panel can close under the pointer. Hover-ended does not
                // always arrive once the window stops taking mouse events.
                hovered = false
                holding = false
                VitalsCursor.arrowIfIdle()
            }
    }

    private var scale: CGFloat {
        guard !reduceMotion else { return 1 }
        if holding { return 0.95 }
        if hovered { return 1.06 }
        return 1
    }

    private var motion: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.26, dampingFraction: 0.7)
    }

    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if !holding { holding = true }
            }
            .onEnded { _ in holding = false }
    }
}

/// `pointerStyle` draws its cursor rects only while the window is key. This
/// panel is nonactivating, so it never is — including when Vitals is not the
/// front app. A tracking area with `.activeAlways` and `.cursorUpdate` is
/// what AppKit still consults. `hitTest` stays nil so the area does not take
/// the click away from the SwiftUI control behind it.
private struct PointingCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ nsView: TrackingView, context: Context) {}

    final class TrackingView: NSView {
        private var claimed = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        override func cursorUpdate(with event: NSEvent) {
            // Re-assert on every cursor pass. AppKit asks again whenever the
            // window is not key, which is always, and would otherwise put the
            // arrow back. The claim is once per visit so a neighbouring
            // control can still be the last one holding the hand.
            if !claimed {
                claimed = true
                VitalsCursor.claim()
            } else {
                VitalsCursor.hand()
            }
        }

        override func mouseExited(with event: NSEvent) {
            guard claimed else { return }
            claimed = false
            VitalsCursor.release()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, claimed {
                claimed = false
                VitalsCursor.release()
            }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}
