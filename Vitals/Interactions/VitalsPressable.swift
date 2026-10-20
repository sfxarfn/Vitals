//
//  VitalsPressable.swift
//  Vitals
//
//  Hover, press, and the pointing-hand cursor for everything you can click
//  in the panel. One style so the controls cannot drift.

import AppKit
import SwiftUI

enum VitalsCursor {
    /// Controls currently under the pointer. One `mouseExited` must not put the
    /// arrow back while a neighbour is still hovered. `forceArrow` zeroes this
    /// and bumps `generation`, so a missed exit cannot leak the way the old
    /// counter did — a claim from before the reset no longer decrements it.
    private static var hovered = 0
    private static var generation = 0

    private static var dragOwnsCursor: Bool {
        NotchController.shared?.draggingFile == true
    }

    /// Record one control under the pointer and show the hand. Returns the
    /// generation the caller must pass back to `release`.
    @discardableResult
    static func claim() -> Int {
        hovered += 1
        hand()
        return generation
    }

    /// Whether `claimedGeneration` is still the live one. `forceArrow` retires
    /// every claim it did not see released.
    fileprivate static func matches(_ claimedGeneration: Int) -> Bool {
        claimedGeneration == generation
    }

    /// Drop one claim from `claim()`. A generation that `forceArrow` has
    /// already retired does nothing — that is the missed-exit case.
    static func release(_ claimedGeneration: Int) {
        guard claimedGeneration == generation else { return }
        hovered = max(0, hovered - 1)
        arrow()
    }

    /// Pointing hand, unless a file drag is in progress — that cursor belongs
    /// to the drag, and painting over it is how the hand gets stuck later.
    static func hand() {
        guard !dragOwnsCursor else { return }
        NSCursor.pointingHand.set()
    }

    /// The arrow, unless a file drag owns the cursor or a control is still
    /// hovered. A drag cursor and a neighbour's hand both win over this.
    /// A suppressed arrow is not remembered: mouse-up outside the open shape
    /// must not paint it later.
    static func arrow() {
        guard !dragOwnsCursor else { return }
        guard hovered == 0 else { return }
        NSCursor.arrow.set()
    }

    /// Panel close, the view leaving its window, and a drag ending over the
    /// open shape. Drops every claim so a missed `mouseExited` cannot leave the
    /// hand up, then the arrow — unless a file drag still owns the cursor.
    static func forceArrow() {
        hovered = 0
        generation &+= 1
        guard !dragOwnsCursor else { return }
        NSCursor.arrow.set()
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
    /// Off for a control with no room to grow into — the AirDrop tile sits
    /// against the camera housing, so it answers hover with its own light
    /// instead, and a press dims it rather than shrinking it.
    var scales = true

    func makeBody(configuration: Configuration) -> some View {
        PressableChrome(pressed: configuration.isPressed, scales: scales) {
            configuration.label
        }
    }
}

private struct VitalsPressable: ViewModifier {
    func body(content: Content) -> some View {
        PressableChrome(pressed: false) { content }
    }
}

/// Shared hover and cursor. Hover grows the control; it does not wash it.
/// `pressed` comes from a button style; rows that are only hovered pass false
/// and never see a drag gesture.
private struct PressableChrome<Content: View>: View {
    var pressed: Bool
    var scales = true
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false
    /// Generation returned by `VitalsCursor.claim`, so leaving this control
    /// releases only its own claim and a reset cannot be decremented twice.
    @State private var claimGeneration: Int?

    var body: some View {
        content()
            .scaleEffect(scale)
            .opacity(!scales && pressed ? 0.8 : 1)
            .animation(motion, value: hovered)
            .animation(motion, value: pressed)
            // A disabled control gets no hand: the tracking view would claim
            // the cursor on enter without asking whether it can be clicked.
            .background { if isEnabled { PointingCursor() } }
            .onContinuousHover { phase in
                guard isEnabled else {
                    hovered = false
                    releaseCursor()
                    return
                }
                switch phase {
                case .active:
                    if !hovered { hovered = true }
                    // Backup for the tracking area: SwiftUI hover sees the
                    // control when the window is taking mouse-moved events.
                    claimCursor()
                case .ended:
                    hovered = false
                    releaseCursor()
                }
            }
            .onDisappear {
                // The panel can close under the pointer. Hover-ended does not
                // always arrive once the window stops taking mouse events.
                hovered = false
                releaseCursor()
            }
    }

    private func claimCursor() {
        // A `forceArrow` since we claimed retired that generation. Claim again
        // rather than treating a stale token as still held.
        if let generation = claimGeneration, VitalsCursor.matches(generation) {
            VitalsCursor.hand()
            return
        }
        claimGeneration = VitalsCursor.claim()
    }

    private func releaseCursor() {
        // Nothing claimed: this control never set the hand, so it must not
        // clear a neighbour or latch a drag restore.
        guard let generation = claimGeneration else { return }
        claimGeneration = nil
        VitalsCursor.release(generation)
    }

    private var scale: CGFloat {
        guard scales, !reduceMotion else { return 1 }
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
        /// Set in `detach`. `updateTrackingAreas` runs again as the view leaves
        /// and must not install a new area — the area retains its owner.
        private var detached = false
        private var claimGeneration: Int?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            // No window, or already detached: adding an area here would retain
            // this view (`NSTrackingArea` retains its owner) after the hierarchy
            // has dropped it.
            guard !detached, window != nil else {
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

        override func mouseEntered(with event: NSEvent) {
            claim()
        }

        override func cursorUpdate(with event: NSEvent) {
            // Re-assert on every cursor pass. AppKit asks again whenever the
            // window is not key, which is always, and would otherwise put the
            // arrow back. Claiming is once per generation, not once per pass.
            claim()
            VitalsCursor.hand()
        }

        override func mouseExited(with event: NSEvent) {
            release()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                detach()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        /// Drop the tracking area before the view leaves the window, then this
        /// view's claim. The area retains its owner, so leaving it installed
        /// leaks the view and can set the hand again after the panel has closed.
        func detach() {
            guard !detached else { return }
            detached = true
            detachAreas()
            release()
        }

        private func claim() {
            guard !detached else { return }
            if let generation = claimGeneration, VitalsCursor.matches(generation) { return }
            claimGeneration = VitalsCursor.claim()
        }

        private func release() {
            guard let generation = claimGeneration else { return }
            claimGeneration = nil
            VitalsCursor.release(generation)
        }

        private func detachAreas() {
            for area in trackingAreas {
                removeTrackingArea(area)
            }
        }
    }
}
