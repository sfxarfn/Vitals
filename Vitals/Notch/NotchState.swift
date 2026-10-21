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

    /// A power Event owning the whole notch: glyph in one flank, its value in
    /// the other — the only Signals that still present; heat glows instead.
    /// `compactPill` draws it.
    case event(Event)
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
    /// The player moved to a new track on its own — not from the panel's prev
    /// or next, and not while the panel was open. The cover in one flank, the
    /// equaliser in the other; it says what changed, nothing more.
    case trackChange(TrackChange)
    /// The VPN came on (`minutesOn` nil), or has now been on for one of the
    /// reminder marks. Said so a tunnel you forgot about does not route the
    /// rest of your day; nothing is said when it goes off.
    case vpn(VPNNotice)

    // MARK: Activity

    /// Xcode is building or archiving. Not an Event — it holds for the whole
    /// build and is the resting state until it ends.
    case building(XcodeBuildActivity)
    /// Long-running work reported explicitly by the process doing it.
    case externalActivity(ExternalActivity)
    /// A Meet call or Slack Huddle is live. You joined it and it ends when you
    /// leave, so it is the resting state for as long as it lasts: a video
    /// glyph on the left, the time on the call on the right.
    case meeting(Meeting)

    // MARK: Interactions

    /// Hover: the one surface you reach into. The two stats in the flanks,
    /// a summary column, and one slot — a feature page such as the shelf, or a
    /// stat's numbers — one size for all of them, so nothing in it resizes it.
    case panel
}

/// One VPN pill: the connect (`minutesOn` nil) or a reminder at a mark.
struct VPNNotice: Equatable {
    var minutesOn: Int?

    /// "30m", "1h", "4h" — the mark reached, not a running clock. The clock
    /// glyph above it says what the number is.
    var reminderText: String? {
        guard let m = minutesOn else { return nil }
        return m < 60 ? "\(m)m" : "\(m / 60)h"
    }
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
    /// True when there is no camera housing and the notch was drawn for a
    /// display that has none. Only the corner radii care: they are calibrated
    /// against a real housing's height and a menu-bar-tall one is shorter.
    var synthetic = false
    /// Screen points per layout point. Every number in here — `notch`
    /// included — is in layout points, the size Vitals is drawn at on a real
    /// housing; the view is scaled by this from the top centre on its way to
    /// the screen. 1 on a real notch. A synthetic one is only menu-bar tall,
    /// so its layout is a real-sized notch shrunk to fit, and the type, glyphs
    /// and gaps shrink with it instead of crowding a shorter shape.
    var scale: CGFloat = 1
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
    /// Tracked builds and generic reported Activities, the widest one-row
    /// family.
    ///
    /// Ceiling is a "100%" beside a 20pt symbol box, 63pt. The heat side
    /// measures a point under that — a degree sign is narrower than a percent.
    /// Both round to the same number: a lean that comes out of glyph widths is
    /// noise, not a layout, and the two sides are a matched pair.
    ///
    /// Both readings really do reach three digits — a pegged CPU and a hot die —
    /// so the pad is on top of that, not inside it.
    var statFlanks: Flanks = (64, 64)
    /// Untracked Xcode builds, finished Xcode builds and explicit command
    /// verdicts, and the VPN pills. Tracked builds use `statFlanks` for their live counter.
    ///
    /// Ceiling is "Success" at 8pt, level with "Archive" and "Analyze" on the
    /// left and wider than either glyph. The other 18 is clearance, not padding:
    /// a stacked flank puts its word on the bottom row, where `bottomCornerRadius`
    /// is curving back in, and the outline takes 6–9pt of horizontal bite across
    /// the letters. Sized to the word alone, the last one gets shaved off.
    var verdictFlanks: Flanks = (56, 56)
    /// A live meeting: a 20pt glyph (its live dot hangs 2pt off the corner)
    /// opposite the clock. The clock at 12pt is ~34pt for "24:31", plus
    /// `notchPad`. Narrower than `verdictFlanks` because no word sits here, and
    /// the two sides are rounded to one number — a lean of a few points would
    /// read as a shape that failed to line up. Past an hour "1:02:33" is wider;
    /// its `minimumScaleFactor` takes up the difference rather than the shape
    /// growing under a call already in progress.
    var meetingFlanks: Flanks = (42, 42)
    /// The panel. Wider than `statFlanks` because the paged slot below the
    /// housing has to hold a readout's hero tile and its four rows beside the
    /// summary column and both arrows; the flanks above simply hug inward.
    var panelFlanks: Flanks = (82, 82)
    /// One outboard Extension: its mark, the hairline separating it from the
    /// current state, and the gaps around both. Ceiling is now Claude's burst,
    /// the widest mark any Extension draws — 20pt plus the 4pt it is pushed
    /// outward, ~24, against 17 for a plain icon. (The VPN word badge used to
    /// set it at ~25; VPN is a pill now, not a mark.) The rest is outward
    /// slack, and it is not padding: the bottom corner curves back in across
    /// the last few points of every flank, a bite of 6–9pt. Kept at 38 so the
    /// burst clears it with the same margin the badge had.
    var extensionFlank: CGFloat = 38
    /// What the hairline and the air on both sides of it cost, bought only while
    /// the rule is actually drawn — on an idle notch the marks are all there is
    /// and `NotchView.separatesFromState` leaves the rule out, so the slot must
    /// not keep paying for it.
    var extensionSeparatorFlank: CGFloat = 16

    /// One Extension slot's width in a given state, separator included when that
    /// state draws one. `NotchView` sizes the mark with this too, so the frame
    /// and the shape growth cannot disagree.
    /// Builds the metrics for a measured notch, in screen points. Only a
    /// synthetic notch scales: a real housing is what the layout was drawn
    /// for. Calibrated against a 38pt housing — the same height the corner
    /// radii are — and floored, because a 24pt menu bar would take the 12pt
    /// readings below 8pt.
    static func measured(_ notch: CGSize, synthetic: Bool) -> NotchMetrics {
        let scale = synthetic ? max(0.75, min(1, notch.height / 38)) : 1
        return NotchMetrics(notch: CGSize(width: notch.width / scale,
                                          height: notch.height / scale),
                            synthetic: synthetic, scale: scale)
    }

    /// The window, in screen points. Whole points: a scaled size comes out
    /// fractional, AppKit rounds the frame, and the window's top lands a
    /// sliver below the screen edge — invisible across the thick middle, a
    /// clipped tip where each flare thins out to meet the edge.
    var screenWindowSize: CGSize {
        CGSize(width: (windowSize.width * scale).rounded(.up),
               height: (windowSize.height * scale).rounded(.up))
    }

    /// The shape a state draws and how far it sits off centre, in screen
    /// points — for hit regions the controller tests the pointer against.
    func screenShape(for state: NotchState, extensions: ExtensionSlots) -> (size: CGSize, lean: CGFloat) {
        let s = size(for: state, extensions: extensions)
        return (CGSize(width: s.width * scale, height: s.height * scale),
                lean(for: state, extensions: extensions) * scale)
    }

    func extensionFlank(for state: NotchState) -> CGFloat {
        extensionFlank + (state == .idle ? 0 : extensionSeparatorFlank)
    }
    var panelBodyHeight: CGFloat = 94

    // MARK: What a state buys

    /// Interactions already own the full surface and draw their richer summaries;
    /// Extensions accompany the horizontal resting, Activity and Event shapes.
    func visibleExtensions(_ state: NotchState, _ extensions: ExtensionSlots) -> ExtensionSlots {
        switch state {
        case .panel: .empty
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
        let slot = extensionFlank(for: state)
        if visible.left != nil { f.left += slot }
        if visible.right != nil { f.right += slot }
        return f
    }

    /// What the state itself asks for, before Extensions.
    func baseFlanks(for state: NotchState) -> Flanks {
        switch state {
        case .idle: (0, 0)
        // A centre Event is always compact — a glyph against one short value —
        // so it buys the same flanks the accessory pill does. The track-change
        // pill is a cover against bars, a glyph against a glyph.
        case .event, .accessory, .audioLost, .trackChange: (glyphFlank, glyphFlank)
        case .verdict, .externalEvent, .vpn: verdictFlanks
        // An Activity holds for minutes, so it stays one row tall — the flanks
        // carry everything and the notch never grows while you work.
        case .building(let build):
            build.progress == nil ? verdictFlanks : statFlanks
        case .externalActivity: statFlanks
        case .meeting: meetingFlanks
        // Paging swaps the slot, never the shape — these flanks are sized for
        // the widest slot: summary column, both arrows, a hero tile and rows.
        case .panel: panelFlanks
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

    /// Height is what separates the categories on sight, so only the
    /// Interaction is allowed to use it.
    private func height(for state: NotchState) -> CGFloat {
        switch state {
        // The only state that grows past one row: the housing row plus the
        // body — summary column, paged slot and its dots.
        case .panel: notch.height + panelBodyHeight
        default:     notch.height
        }
    }

    /// The window is sized once to the largest state; everything else insets into
    /// it. The slack has to cover the shape's top flare on both sides, the lean
    /// of the widest uneven state, *and* the ambient shadow past all of it —
    /// radius 24 blurs ~36pt out, plus its 12pt drop.
    /// The widest shape is either the panel or a `statFlanks` Activity with
    /// both Extension slots up. Both slots are reserved whether or not they are
    /// active: the window's frame is set once, while conditions can change
    /// afterwards.
    var windowSize: CGSize {
        let slot = extensionFlank + extensionSeparatorFlank
        let widest = notch.width + max(statFlanks.left + statFlanks.right + slot * 2,
                                       panelFlanks.left + panelFlanks.right)
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
