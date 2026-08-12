import SwiftUI

/// Every shape the notch can take, in the three categories `product.md` splits
/// them into: **Interactions** end when you leave them, **Events** end on their
/// own clock, an **Activity** ends when the work does.
enum NotchState: Equatable {
    /// The floor: the notch at its physical size, saying nothing. Everything
    /// falls back here — except an Activity, which replaces it while it runs.
    case idle

    // MARK: Events

    /// One message across both flanks: glyph on one side, title on the other.
    case event(Event)
    /// One Event per flank, each on the side its subsystem owns. They speak for
    /// different subsystems, so neither has any reason to evict the other —
    /// each side comes and goes on its own clock and either may be nil.
    /// See `Signal.side`.
    case sided(left: Event?, right: Event?)
    /// A Bluetooth accessory just connected: what it is, and how full it is.
    case accessory(Accessory)
    /// Sound just fell off a headset back onto the built-in speakers.
    case audioLost

    // MARK: Activity

    /// Xcode is building or archiving. Not an Event — it holds for the whole
    /// build and is the resting state until it ends.
    case building(BuildProgress)

    // MARK: Interactions

    /// Hover: the notch answers the pointer with the stats worth a glance.
    case peek
    /// Peek opened downward into a surface you can work in — the shelf, or the
    /// numbers behind peek's one-line battery summary.
    case panel
}

/// Every width the shape can take. The notch stays as narrow as its content
/// allows: each family below is a ceiling, set by the longest string that family
/// can ever draw, and both flanks take the same one so the shape never leans by
/// a few points. Change the string and the ceiling moves with it.
struct NotchMetrics {
    /// Physical notch, measured from the screen's auxiliary areas.
    var notch: CGSize
    // Every flank below is its content's measured width plus `notchPad`, at the
    // point sizes that state actually draws at. Grow the number if the string or
    // the glyph that sets the ceiling changes.

    /// What a flank keeps between its content and the camera housing. Content
    /// hugs the notch, so this is the gap you see; the slack a short flank does
    /// not use falls outward against the bezel instead. See `flankSlot`.
    var notchPad: CGFloat = 4
    /// A lone glyph, a ring, or a short reading: the compact event pill, the
    /// accessory pill, the audio handoff. Ceiling is "100%" at 12pt, 33pt — and
    /// the compact pill is the charged pill, so that is the string it draws.
    var glyphFlank: CGFloat = 42
    /// The sided pills fit a glyph *and* its value in one flank, so they need
    /// more than a lone glyph does. Ceiling is the thermal pair, 12 + 4 + 28.
    var sidedFlank: CGFloat = 56
    /// The build Activity and peek, which stack a pair of values in each flank.
    /// Shared on purpose: peek can replace a build under a resting pointer, and
    /// the shape must not resize under the cursor. That is the one case where
    /// matching beats shrinking. Ceiling is peek's readout: 20pt symbol box + 4
    /// + "100%". Both readings really do reach three digits — a pegged CPU and a
    /// hot die — so the pad is on top of that, not inside it.
    var wideFlank: CGFloat = 66
    /// The full event pill puts a whole title in a flank. Ceiling is "Memory
    /// pressure" at 11pt, 94pt. Derived off the notch rather than fixed, so the
    /// title gets the same room on a machine whose notch is wider.
    var eventFlank: CGFloat = 106
    var panelBodyHeight: CGFloat = 94
    /// The widest the notch ever goes: a title in one flank and a glyph in the
    /// other. It overlaps the tail of the focused app's menus, which is accepted
    /// because it is transient and macOS offers no way to reserve the space.
    var pillWidth: CGFloat { notch.width + eventFlank * 2 }
    /// The panel is peek's width — opening it out of a hover only drops the
    /// shelf down, it never widens the shape under the pointer. Its body needs
    /// ~215pt for the AirDrop tile and the shelf, which peek's own flanks
    /// already clear.
    var panelWidth: CGFloat { notch.width + wideFlank * 2 }

    func size(for state: NotchState) -> CGSize {
        switch state {
        case .idle:      notch
        case .event(let event):
            if event.signal.isCompact {
                CGSize(width: notch.width + glyphFlank * 2, height: notch.height)
            } else {
                CGSize(width: pillWidth, height: notch.height)
            }
        // One flank per live side — see `Signal.side`. Nothing to say on the far
        // flank means nothing is bought there, so the notch leans all the way
        // and the lean is what says which subsystem is talking. A second side
        // arriving buys the same width on its edge rather than resizing the
        // first, and the shape is symmetric again.
        case .sided(let left, let right):
            CGSize(width: notch.width + sidedFlank * CGFloat([left, right].compactMap { $0 }.count),
                   height: notch.height)
        case .accessory,
             .audioLost: CGSize(width: notch.width + glyphFlank * 2, height: notch.height)
        // An Activity holds for minutes, so it stays one row tall — the flanks
        // carry everything and the notch never grows while you work.
        case .building:  CGSize(width: notch.width + wideFlank * 2, height: notch.height)
        // Same width as the build Activity, twice as tall — enough to read as
        // "it noticed you" without claiming the screen the way the panel does.
        case .peek:      CGSize(width: notch.width + wideFlank * 2, height: notch.height * 2)
        // The only state that grows past two rows. Roughly the three notch
        // heights `design.md` asks for — `panelBodyHeight` is what the AirDrop
        // tile and the shelf actually need, and that runs a little over.
        case .panel:     CGSize(width: panelWidth, height: notch.height + panelBodyHeight)
        }
    }

    /// The window is sized once to the largest state; everything else insets into
    /// it. The slack has to cover the shape's top flare on both sides *and* the
    /// ambient shadow past it — radius 24 blurs ~36pt out, plus its 12pt drop.
    var windowSize: CGSize {
        CGSize(width: max(pillWidth, panelWidth) + 160, height: notch.height + panelBodyHeight + 72)
    }
}

extension View {
    /// One flank of a pill, `side` naming which side of the notch it is. Content
    /// pins to the *inner* edge, `pad` off the camera housing, and the slack a
    /// short flank does not use falls outward toward the bezel.
    ///
    /// Hugging the notch is what makes the two sides read as one tight cluster
    /// rather than two things pushed apart. It costs the matched outer gap: the
    /// margin you can see against the bezel now differs by however much the two
    /// contents differ in width.
    ///
    /// The notch's own width in the middle is dead space — the camera housing
    /// sits over it — so every pill is two of these with nothing between them.
    func flankSlot(_ width: CGFloat, _ side: HorizontalEdge, pad: CGFloat) -> some View {
        padding(side == .leading ? .trailing : .leading, pad)
            .frame(width: width, alignment: side == .leading ? .trailing : .leading)
    }
}
