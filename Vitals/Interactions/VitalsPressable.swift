//
//  VitalsPressable.swift
//  Vitals
//
//  Hover, press, and the pointing-hand cursor for everything you can click
//  in peek and the panel. One style so the controls cannot drift.

import AppKit
import SwiftUI

enum VitalsCursor {
    private static var dragOwnsCursor: Bool {
        NotchController.shared?.draggingFile == true
    }

    /// Pointing hand, unless a file drag is in progress — that cursor belongs
    /// to the drag, and painting over it is how the hand gets stuck later.
    static func hand() {
        guard !dragOwnsCursor else { return }
        NSCursor.pointingHand.set()
    }

    /// Always the arrow. A claim count used to skip this, which is how the
    /// hand survived leaving a control, closing the panel, and cancelling a drag.
    static func arrow() {
        NSCursor.arrow.set()
    }

    static func forceArrow() {
        arrow()
    }
}

extension View {
    /// Hover scale and the pointing hand for a row that is not a `Button`.
    /// Press scale lives on `VitalsPressStyle` — a zero-distance drag here
    /// steals `onTapGesture` and `SettingsLink`.
    func vitalsPressable() -> some View {
        modifier(VitalsPressable())
    }
}

/// Press scale for real buttons, including `SettingsLink`, which takes a
/// button style. `configuration.isPressed` is the click, so nothing installs
/// a drag gesture beside it.
struct VitalsPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressableChrome(pressed: configuration.isPressed) {
            configuration.label
        }
    }
}

private struct VitalsPressable: ViewModifier {
    func body(content: Content) -> some View {
        PressableChrome(pressed: false) { content }
    }
}

/// Shared hover, highlight, and cursor. `pressed` comes from a button style;
/// rows that are only hovered pass false and never see a drag gesture.
private struct PressableChrome<Content: View>: View {
    var pressed: Bool
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        content()
            .scaleEffect(scale)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(hovered && !pressed ? 0.12 : 0))
                    .allowsHitTesting(false)
            }
            .animation(motion, value: hovered)
            .animation(motion, value: pressed)
            .background { PointingCursor() }
            .onContinuousHover { phase in
                guard isEnabled else {
                    hovered = false
                    VitalsCursor.arrow()
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
                    VitalsCursor.arrow()
                }
            }
            .onDisappear {
                // The panel can close under the pointer. Hover-ended does not
                // always arrive once the window stops taking mouse events.
                hovered = false
                VitalsCursor.arrow()
            }
    }

    private var scale: CGFloat {
        guard !reduceMotion else { return 1 }
        if pressed { return 0.95 }
        if hovered { return 1.06 }
        return 1
    }

    private var motion: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.26, dampingFraction: 0.7)
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

    static func dismantleNSView(_ nsView: TrackingView, coordinator: Coordinator) {
        nsView.detach()
    }

    final class TrackingView: NSView {
        private var updating = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            // No window means the view is on its way out. Adding an area here
            // would retain this view (`NSTrackingArea` retains its owner) after
            // the hierarchy has already dropped it.
            guard window != nil else {
                detachAreas()
                return
            }
            guard !updating else { return }
            updating = true
            defer { updating = false }
            detachAreas()
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
            // arrow back.
            VitalsCursor.hand()
        }

        override func mouseExited(with event: NSEvent) {
            VitalsCursor.arrow()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                detach()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        /// Drop the tracking area before the view leaves the window, then the
        /// arrow. The area retains its owner, so leaving it installed leaks the
        /// view and can set the hand again after the panel has closed.
        func detach() {
            detachAreas()
            VitalsCursor.arrow()
        }

        private func detachAreas() {
            for area in trackingAreas {
                removeTrackingArea(area)
            }
        }
    }
}
