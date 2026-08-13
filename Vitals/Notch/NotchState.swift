import SwiftUI

/// Every exclusive shape the notch can take, in the three categories
/// `product.md` splits them into: **Interactions** end when you leave them,
/// **Events** end on their own clock, an **Activity** ends when the work does.
/// Extensions compose outside this enum so none can replace the current state.
enum NotchState: Equatable {
    /// The floor: the notch at its physical size, saying nothing. Everything
    /// falls back here — except an Activity, which replaces it while it runs.
    case idle

    // MARK: Events

    /// One Event owning the whole notch: glyph in one flank, its value in the
    /// other. Only a centre Signal reaches this — everything with a side is
    /// routed to `sided` before it gets here — and every centre Signal is
    /// compact, so `compactPill` is the one thing that draws it.
    case event(Event)
    /// One Event per flank, each on the side its subsystem owns. They speak for
    /// different subsystems, so neither has any reason to evict the other —
    /// each side comes and goes on its own clock and either may be nil.
    /// See `Signal.side`.
    case sided(left: Event?, right: Event?)
    /// A Bluetooth accessory just connected: what it is, and how full it is.
    case accessory(Accessory)
    /// Sound just fell off a headset back onto the built-in speakers, carrying
    /// how loud they are set — 0 to 1, drawn as the speaker glyph's wave count.
    /// Sampled at the handoff, because that is the moment being reported.
    case audioLost(loudness: Double)
    /// How a run in Xcode ended. The Activity is over by the time this shows —
    /// it queues, waits its turn and leaves on the Event clock like every other
    /// piece of news, rather than riding out the build it reports on.
    /// `BuildProgress.ending` is non-nil in this state by construction.
    case verdict(BuildProgress)
    /// A one-shot reported explicitly by `vitals-notify`, where the process
    /// knows its own outcome and Vitals does not have to infer one.
    case externalEvent(ExternalEvent)

    // MARK: Activity

    /// Xcode is building or archiving. Not an Event — it holds for the whole
    /// build and is the resting state until it ends.
    case building(XcodeBuildActivity)
    /// Long-running work reported explicitly by the process doing it.
    case externalActivity(ExternalActivity)

    // MARK: Interactions

    /// Hover: the notch answers the pointer with the stats worth a glance.
    case peek
    /// Peek opened downward into a surface you can work in — the shelf, or the
    /// numbers behind peek's one-line battery summary.
    case panel
}

/// What each side of a state buys. Separate numbers because a state whose two
/// sides say different-sized things should not pay the wider one twice — but a
/// pair that differs by only a few points reads as a shape that failed to line
/// up, so a family either leans clearly or not at all.
typealias Flanks = (left: CGFloat, right: CGFloat)

/// Every width the shape can take. The notch stays as narrow as its content
/// allows: each family below is a ceiling, set by the longest string that family
/// can ever draw. Change the string and the ceiling moves with it.
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
    /// accessory pill, the audio handoff. Ceiling is "100°" at 12pt, the hottest
    /// the thermal pill can read — the value side, not the glyph side. The
    /// battery pill used to set it at "100%" and no longer can: full says "Full",
    /// and charging is gated under 95%. The widest glyph any of them draws is
    /// `battery.100percent.bolt` at 29pt, which fits inside that.
    var glyphFlank: CGFloat = 40
    /// The sided pills fit a glyph *and* its value in one flank, so they need
    /// more than a lone glyph does. Ceiling is the thermal pair at its hottest:
    /// `thermometer.high` 12 + 4 + "100°" at 12pt, 32pt.
    var sidedFlank: CGFloat = 52
    /// Peek and generic reported Activities, the widest one-row family.
    ///
    /// Shared between those two states on purpose: peek can replace an Activity
    /// under a resting pointer, and the shape must not resize under the cursor.
    /// So each side here is the wider of what the two states ask of it, not what
    /// either asks on its own.
    ///
    /// Ceiling is peek's "100%" beside its 20pt symbol box, 63pt. The heat side
    /// measures a point under that — a degree sign is narrower than a percent.
    /// Both round to the same number: a lean that comes out of glyph widths is
    /// noise, not a layout, and the two sides are a matched pair.
    ///
    /// Both readings really do reach three digits — a pegged CPU and a hot die —
    /// so the pad is on top of that, not inside it.
    var statFlanks: Flanks = (64, 64)
    /// Untracked Xcode builds, finished Xcode builds and explicit command
    /// verdicts. Tracked builds use `statFlanks` for their live counter.
    ///
    /// Ceiling is "Success" at 8pt, level with "Archive" and "Analyze" on the
    /// left and wider than either glyph. The other 18 is clearance, not padding:
    /// a stacked flank puts its word on the bottom row, where `bottomCornerRadius`
    /// is curving back in, and the outline takes 6–9pt of horizontal bite across
    /// the letters. Sized to the word alone, the last one gets shaved off.
    var verdictFlanks: Flanks = (56, 56)
    /// One outboard Extension: its mark, the hairline separating it from the
    /// current state, and the gaps around both. Ceiling is the VPN badge, the
    /// widest mark any Extension draws — ~25 with its box, against 17 for a
    /// plain icon. The rest is outward slack, and it is not padding: the bottom
    /// corner curves back in across the last few points of every flank, and a
    /// bordered box is a shape whose edge shows the bite.
    var extensionFlank: CGFloat = 46
    var panelBodyHeight: CGFloat = 94

    // MARK: What a state buys

    /// Interactions already own the full surface and draw their richer summaries;
    /// Extensions accompany the horizontal resting, Activity and Event shapes.
    func visibleExtensions(_ state: NotchState, _ extensions: ExtensionSlots) -> ExtensionSlots {
        switch state {
        case .peek, .panel: .empty
        default: extensions
        }
    }

    /// The two flanks a state grows, in the order they sit on screen. Whatever
    /// this returns, the notch's own width sits untouched between them.
    ///
    /// Extensions are added here rather than by their view, so shape growth,
    /// lean and the hover region all follow the same allocation.
    func flanks(for state: NotchState, extensions: ExtensionSlots) -> Flanks {
        var f = baseFlanks(for: state)
        let visible = visibleExtensions(state, extensions)
        if visible.left != nil { f.left += extensionFlank }
        if visible.right != nil { f.right += extensionFlank }
        return f
    }

    /// What the state itself asks for, before Extensions.
    func baseFlanks(for state: NotchState) -> Flanks {
        switch state {
        case .idle: (0, 0)
        // A centre Event is always compact — a glyph against one short value —
        // so it buys the same flanks the accessory pill does.
        case .event: (glyphFlank, glyphFlank)
        // One flank per live side — see `Signal.side`. Nothing to say on the far
        // flank means nothing is bought there, so the notch leans all the way
        // and the lean is what says which subsystem is talking. A second side
        // arriving buys the same width on its edge rather than resizing the
        // first, and the shape is symmetric again.
        case .sided(let left, let right):
            (left == nil ? 0 : sidedFlank, right == nil ? 0 : sidedFlank)
        case .accessory, .audioLost: (glyphFlank, glyphFlank)
        case .verdict, .externalEvent: verdictFlanks
        // An Activity holds for minutes, so it stays one row tall — the flanks
        // carry everything and the notch never grows while you work.
        case .building(let build):
            build.progress == nil ? verdictFlanks : statFlanks
        case .externalActivity: statFlanks
        // The panel is peek opened further — it only drops the shelf down and
        // never widens the shape under the pointer. Its body needs ~215pt for
        // the AirDrop tile and shelf, which these flanks already clear.
        case .peek, .panel: statFlanks
        }
    }

    /// How far the shape sits off the notch's own centre. Uneven flanks are
    /// still drawn centred in the window, which would slide the camera housing
    /// out from under the middle; putting half the difference back is what keeps
    /// the dead space over the housing where it physically is.
    func lean(for state: NotchState, extensions: ExtensionSlots) -> CGFloat {
        let f = flanks(for: state, extensions: extensions)
        return (f.right - f.left) / 2
    }

    func size(for state: NotchState, extensions: ExtensionSlots) -> CGSize {
        let f = flanks(for: state, extensions: extensions)
        return CGSize(width: notch.width + f.left + f.right, height: height(for: state))
    }

    func baseSize(for state: NotchState) -> CGSize {
        let f = baseFlanks(for: state)
        return CGSize(width: notch.width + f.left + f.right, height: height(for: state))
    }

    /// Height is what separates the categories on sight, so only the two
    /// Interactions are allowed to use it.
    private func height(for state: NotchState) -> CGFloat {
        switch state {
        // Twice the notch — enough to read as "it noticed you" without claiming
        // the screen the way the panel does.
        case .peek:  notch.height * 2
        // The only state that grows past two rows. Roughly the three notch
        // heights `design.md` asks for — `panelBodyHeight` is what the AirDrop
        // tile and the shelf actually need, and that runs a little over.
        case .panel: notch.height + panelBodyHeight
        default:     notch.height
        }
    }

    /// The window is sized once to the largest state; everything else insets into
    /// it. The slack has to cover the shape's top flare on both sides, the lean
    /// of the widest uneven state, *and* the ambient shadow past all of it —
    /// radius 24 blurs ~36pt out, plus its 12pt drop.
    /// `statFlanks` is the widest pair any state buys — peek, the panel and the
    /// running build all sit on it, and every other family is narrower.
    /// Both Extension slots are reserved whether or not they are active: the
    /// window's frame is set once, while conditions can change afterwards.
    var windowSize: CGSize {
        let widest = notch.width + statFlanks.left + statFlanks.right + extensionFlank * 2
        return CGSize(width: widest + 160, height: notch.height + panelBodyHeight + 72)
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
    ///
    /// `centered` opts out, splitting the slack instead of dropping it all
    /// outward. It is for the flank that holds a lone glyph opposite one holding
    /// a value: hugging is what makes a *pair* of contents read as one cluster,
    /// but a glyph against a three-digit number is not a pair, and pinning both
    /// leaves the narrow side with a visibly bigger outer gap than the wide one.
    /// Centring costs the pad, which is the point — the glyph sits halfway
    /// between the housing and the bezel rather than against either.
    func flankSlot(_ width: CGFloat, _ side: HorizontalEdge, pad: CGFloat,
                   centered: Bool = false) -> some View {
        let innerEdge: Edge.Set = side == .leading ? .trailing : .leading
        let innerAlignment: Alignment = side == .leading ? .trailing : .leading
        return padding(centered ? [] : innerEdge, pad)
            .frame(width: width, alignment: centered ? .center : innerAlignment)
    }
}
