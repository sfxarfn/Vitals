import SwiftUI

/// Pose for the peek/panel rubber. Identity at rest; the keyframe animator
/// only leaves it when `rubber` changes, and a snap trigger is every value at 1.
private struct RubberPose: Equatable, Animatable {
    var x: CGFloat = 1
    var y: CGFloat = 1

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(x, y) }
        set { x = newValue.first; y = newValue.second }
    }
}

/// What the keyframe closure reads. Passed as the trigger value so the track
/// sees snap versus suck from the change itself, not from state captured earlier.
private struct RubberTrigger: Equatable {
    var tick = 0
    var closing = false
    /// Leaving peek/panel. Every keyframe is identity, so an Event, Activity,
    /// or Extension mark cannot inherit the suck.
    var snap = false
}

/// The shape itself: one black outline that grows and shrinks, whatever is
/// inside it. What goes inside lives beside its category — `Events/`,
/// `Activities/`, `Interactions/` — and is reached through `content` below;
/// concurrent `Extensions/` are composed outboard of that content.
struct NotchView: View {
    let state: NotchState
    let metrics: NotchMetrics
    let extensions: ExtensionSlots
    let telemetry: Telemetry
    /// One per notch edge. Nil is no glow on that side.
    let cpuGlow: Signal?
    let thermalGlow: Signal?
    let shelf: Shelf
    /// Approach cue from the controller. Nil unless a file drag is near the
    /// housing and the panel has not taken the drop over yet.
    let fileDrag: FileDrag?
    let endFileDrag: () -> Void
    /// Sends via AirDrop, anchored on the panel's own NSView for the fallback
    /// share sheet — the controller owns the window, so it owns that call.
    let airDrop: ([URL]) -> Void
    /// Moves between the two Interactions from inside them — the tray button up
    /// to the panel, the back button down to the peek it came from. Hover alone
    /// only ever reaches peek, and a drag is the only other way into the shelf.
    let show: (NotchState) -> Void

    // Extensions cannot add storage, so every piece of view state lives here and
    // is read from whichever category file draws it.
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    @State var shelfTargeted = false
    @State var airDropTargeted = false
    /// Tile origin in the panel drop's coordinate space, so a drag across the
    /// AirDrop tile leans by where it sits in the panel, not inside 104pt.
    @State var airDropOrigin: CGPoint = .zero
    /// Bumped when peek or the panel opens, or when one Interaction becomes the
    /// other. Leaving onto anything else snaps the pose to 1 instead.
    /// Private because `RubberTrigger` is private — an internal property of a
    /// private type does not compile. Nothing outside this file reads it.
    @State private var rubber = RubberTrigger()
    /// -1…1, where the drag sits across the open panel. Only written from a
    /// drop session, so it is idle at rest.
    @State var dragLean: CGFloat = 0
    /// One squash after a drop lands, then back. Never left set.
    @State var landSquash = false
    /// Border flash for the landing, including when motion is reduced.
    @State var landFlash = false
    @State var liftingURL: URL?
    @State var liftTilt: Double = 0
    @State var liftSample: CGPoint?
    @State var freshURLs: Set<URL> = []
    @State var ripplePoint: CGPoint?
    @State var rippleToken = 0
    @State var panelBody: PanelBody = .shelf

    var size: CGSize { metrics.size(for: state, extensions: extensions) }
    private var lifted: Bool {
        state != .idle || visibleExtensions.left != nil || visibleExtensions.right != nil
    }
    /// Only surfaces opened by the pointer lift off the bezel. Activities and
    /// Events remain visually flush, even though their outline grows.
    private var castsShadow: Bool {
        switch state {
        case .peek, .panel: true
        default: false
        }
    }
    /// Both radii are calibrated against a real camera housing, whose height
    /// leaves room for a 22pt outward flare and a 28pt bottom curve to meet.
    /// A synthetic notch is only menu-bar tall — the two curves then pass each
    /// other, the path doubles back, and the sides pinch. Scale them with the
    /// height that is actually there; a real housing is `1` and untouched.
    private var radiusScale: CGFloat {
        metrics.synthetic ? min(1, metrics.notch.height / 38) : 1
    }
    private var topRadius: CGFloat { 22 * radiusScale }
    private var bottomRadius: CGFloat { 28 * radiusScale }

    // MARK: Growth

    /// What the growth animates on — the state the notch is in, never the
    /// numbers inside it. An Activity republishes its counter every second, and
    /// a state's own numbers changing is not a state change: re-running a bouncy
    /// animation over the two shadow layers that often is what reads as a
    /// flicker, since the geometry never moves and only the shadow gets
    /// re-rasterized.
    /// Extension activation and slot movement change the shape's width or lean,
    /// so both assigned IDs belong to the growth key. Telemetry numbers remain
    /// absent: their ticks must never replay the shape animation.
    private var growthKey: String {
        "\(shapeKey)|\(visibleExtensions.left?.id ?? "-")|\(visibleExtensions.right?.id ?? "-")"
    }

    private var shapeKey: Int {
        switch state {
        case .idle:                 0
        case .event:                1
        // A lone left and a lone right pill are the same width and differ only
        // in which way they lean, so they must not share a key — growing
        // between them would slide the shape across the notch instead of
        // closing and opening. Both sides up is a third shape again.
        case .sided(let l, let r):  l != nil && r != nil ? 10 : (l != nil ? 9 : 8)
        case .accessory:            3
        case .audioLost:            4
        // The verdict owns its own content transition. An untracked build
        // shares its width; a tracked counter shrinks into it on completion.
        case .verdict:              11
        case .externalEvent:        12
        case .building:             5
        case .externalActivity:     13
        case .peek:                 6
        case .panel:                7
        }
    }

    /// A state that buys more on one side than the other has to slide, or the
    /// extra width would push the camera housing off the notch. Half the
    /// difference, which is zero for every symmetric state. Interpolates with
    /// the width under the same growth, which is what makes a one-sided pill
    /// read as growing sideways rather than growing and then sliding — and what
    /// recentres the shape as a second side arrives.
    private var xOffset: CGFloat { metrics.lean(for: state, extensions: extensions) }

    private var shape: NotchShape {
        NotchShape(topCornerRadius: topRadius,
                   bottomCornerRadius: lifted ? bottomRadius : 10 * radiusScale)
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            // The sized box is its own stable view — a Color, not the state
            // switch. Hanging the frame off `content` instead makes the whole
            // thing change identity on every state change, and SwiftUI hard-cuts
            // to the new size and only cross-fades. This way the frame
            // interpolates and the box actually grows and shrinks.
            Color.clear
                // The shape flares outward by topRadius per side, so the
                // body lines up with the notch only if the frame is wider.
                .frame(width: size.width + topRadius * 2, height: size.height)
                // Opaque black in every state so the panel reads as an
                // extension of the bezel instead of showing the desktop
                // through it.
                .background(shape.fill(.black))
                .overlay(alignment: .top) {
                    // Extensions are outboard of the state, never inside it:
                    // every pill keeps its calibrated flanks against the camera
                    // housing while the icons take the strips grown beyond it.
                    HStack(spacing: 0) {
                        if let left = visibleExtensions.left {
                            extensionMark(left, side: .leading)
                        }
                        content.frame(width: metrics.baseSize(for: state).width)
                        if let right = visibleExtensions.right {
                            extensionMark(right, side: .trailing)
                        }
                    }
                        .frame(width: size.width)
                        // Content is laid out at its final size the instant the
                        // state flips; the clip is what reveals it as the shape
                        // grows. Without this it interpolates too, and every
                        // frame of the growth re-runs the whole content's layout
                        // at a new width — text scale-fitting, the panel's
                        // ScrollView, all of it, ~50 times per growth.
                        // Scoped to growthKey so anything animating on its own
                        // clock in here — the audio-lost turnover, the battery
                        // swap — is untouched. Every fade that *does* fire on a
                        // state change must now carry its own `.animation()`, or
                        // this nils it into a hard cut.
                        .transaction(value: growthKey) { $0.animation = nil }
                }
                .clipShape(shape)
                // Interactions lift off the bezel; Activities and Events stay
                // flush with it. Two layers, the way glass casts: a tight
                // contact shadow at the edge plus a wide diffuse ambient one.
                // Radii and opacities interpolate as the Interaction opens.
                //
                // Cast off a bare copy of the shape behind the clipped box, not
                // off the box itself: the blur source is then a solid path with
                // no content in it, so a build republishing its counter every
                // second no longer re-blurs two full-window offscreen passes.
                .background {
                    shape.fill(.black)
                        .shadow(color: .black.opacity(castsShadow ? 0.55 : 0),
                                radius: castsShadow ? 6 : 0, y: castsShadow ? 3 : 0)
                        .shadow(color: .black.opacity(castsShadow ? 0.35 : 0),
                                radius: castsShadow ? 24 : 0, y: castsShadow ? 12 : 0)
                }
                // Behind the black shape and outside its clip, so only the half
                // that escapes past each edge is ever seen — that overlap is
                // what reads as light leaking out rather than a colored border.
                .background {
                    ZStack {
                        glowBar(thermalGlow).offset(x: -glowInset)
                        glowBar(cpuGlow).offset(x: glowInset)
                    }
                }
                // States that last twenty minutes must not announce themselves;
                // fading is the whole difference between a glow and a pill.
                .animation(.easeInOut(duration: 0.5), value: [thermalGlow, cpuGlow])
                // Drag feedback sits on the drawn silhouette, not on a new
                // layout size: the window and the hover rect stay where they
                // are, and the outline leans toward the file in hand. Gone the
                // moment the drag is — `reach` is 0 at rest, so none of this
                // ticks while the notch is idle.
                .overlay { shelfRim }
                .background(alignment: .top) { shelfUnderglow }
                .scaleEffect(x: silhouetteX, y: silhouetteY, anchor: .top)
                .offset(x: xOffset + silhouetteNudge)
                .animation(shelfFollow, value: fileDrag)
                .animation(shelfFollow, value: shelfTargeted)
                .animation(shelfFollow, value: airDropTargeted)
                .animation(shelfFollow, value: dragLean)
                // Rubber on the way in and the suck between peek and the panel.
                // Scale, not a second layout size: the frame above is still the
                // bouncy growth. Anchor is the top edge so the housing stays on
                // the bezel. Reduce Motion never bumps `rubber`, so the pose
                // stays 1. A snap trigger is every keyframe at 1 — that is what
                // runs when an Event, Activity, or Extension takes the silhouette,
                // so the suck cannot play on the pill.
                .keyframeAnimator(initialValue: RubberPose(), trigger: rubber) { view, pose in
                    view.scaleEffect(x: pose.x, y: pose.y, anchor: .top)
                } keyframes: { trigger in
                    // One track shape for open, close, and snap — the keyframe
                    // builder needs a single type, and the values are what differ.
                    // Close: a short stretch, then a dip just under rest, then
                    // settle. Open: hold, then a small overshoot, then settle.
                    // Snap: identity, immediately.
                    let closing = trigger.closing && !trigger.snap
                    let yPeak: CGFloat = trigger.snap ? 1 : (closing ? 1.03 : 1)
                    let yDip: CGFloat = trigger.snap ? 1 : (closing ? 0.973 : 1.016)
                    let xPinch: CGFloat = trigger.snap ? 1 : (closing ? 0.99 : 1)
                    let xOvershoot: CGFloat = trigger.snap ? 1 : 1.008
                    let first: Double = trigger.snap ? 0.01 : 0.08
                    let second: Double = trigger.snap ? 0.01 : (closing ? 0.26 : 0.02)
                    let third: Double = trigger.snap ? 0.01 : (closing ? 0.12 : 0.3)
                    let fourth: Double = trigger.snap ? 0.01 : (closing ? 0.18 : 0.2)
                    // A snappy spring asked to cover no distance still bounces.
                    // Snap uses a dead spring so the pill is not rubber.
                    let spring = trigger.snap ? Spring(duration: 0.01, bounce: 0) : .snappy
                    KeyframeTrack(\.y) {
                        CubicKeyframe(yPeak, duration: first)
                        CubicKeyframe(CGFloat(1), duration: second)
                        SpringKeyframe(yDip, duration: third, spring: spring)
                        SpringKeyframe(CGFloat(1), duration: fourth, spring: spring)
                    }
                    KeyframeTrack(\.x) {
                        CubicKeyframe(xPinch, duration: first)
                        CubicKeyframe(CGFloat(1), duration: second)
                        SpringKeyframe(xOvershoot, duration: third, spring: spring)
                        SpringKeyframe(CGFloat(1), duration: fourth, spring: spring)
                    }
                }
            Spacer(minLength: 0)
        }
        .frame(width: metrics.windowSize.width, height: metrics.windowSize.height, alignment: .top)
        .animation(.bouncy(duration: 0.45, extraBounce: 0.12), value: growthKey)
        // The shelf is what the panel is for; a readout left up from the last
        // hover would greet the next drag with the wrong one.
        .onChange(of: state) { old, new in
            if new == .idle { panelBody = .shelf }
            // A targeted flag left over from a drag the panel closed under
            // would keep the resting notch swollen.
            if new != .panel {
                shelfTargeted = false
                airDropTargeted = false
                dragLean = 0
                landSquash = false
                liftingURL = nil
                liftTilt = 0
                // A landing that finishes after the panel has gone must not be
                // waiting here to replay the ripple and the fresh-chip scale
                // the next time the shelf opens.
                freshURLs = []
                ripplePoint = nil
                landFlash = false
            }
            if new != .peek && new != .panel { VitalsCursor.forceArrow() }
            guard !reduceMotion, old != new else { return }
            let was = old == .peek || old == .panel
            let now = new == .peek || new == .panel
            // Rubber only while the silhouette stays an Interaction. Opening
            // peek, and panel back to peek, are that. Leaving onto an Event,
            // an Activity, or idle (where Extension marks come back) snaps to
            // rest instead of sucking the pill.
            guard was || now else { return }
            rubber = RubberTrigger(
                tick: rubber.tick + 1,
                closing: old == .panel && new == .peek,
                snap: was && !now
            )
        }
    }

    // MARK: Shelf gesture

    /// How far the silhouette is reaching. Pinned while the landing squash
    /// plays, so clearing the drag cue in the same turn does not collapse it
    /// out from under the jelly.
    var reach: CGFloat {
        // Landing and targeting belong to the open panel. A flag still set for
        // the frame after the notch leaves it must not keep a pill reached.
        if state == .panel, landSquash || shelfTargeted || airDropTargeted { return 1 }
        return fileDrag?.pull ?? 0
    }

    var lean: CGFloat {
        guard !reduceMotion else { return 0 }
        if state == .panel, shelfTargeted || airDropTargeted || landSquash { return dragLean }
        return (fileDrag?.lean ?? 0) * (fileDrag?.pull ?? 0)
    }

    private var landingSquash: Bool { state == .panel && landSquash }

    var silhouetteX: CGFloat {
        guard !reduceMotion else { return 1 }
        let awake = 1 + reach * 0.03 + abs(lean) * reach * 0.015
        return landingSquash ? awake * 1.06 : awake
    }

    var silhouetteY: CGFloat {
        guard !reduceMotion else { return 1 }
        let awake = 1 + reach * 0.055
        return landingSquash ? awake * 0.92 : awake
    }

    /// A few points toward the file. Anchored at the top edge, so the housing
    /// stays on the bezel and the bottom is what moves.
    var silhouetteNudge: CGFloat {
        guard !reduceMotion else { return 0 }
        return lean * reach * 9
    }

    var rimOpacity: Double {
        let onPanel = state == .panel
        if reduceMotion {
            return (onPanel && (shelfTargeted || airDropTargeted || landFlash)) ? 0.35 : 0
        }
        if onPanel && (landSquash || landFlash) { return 0.85 }
        return Double(reach) * 0.65
    }

    private var shelfAccent: Color { Color(red: 0.62, green: 0.86, blue: 1) }

    var shelfFollow: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.22, dampingFraction: 0.72)
    }

    /// Insertion and the gap closing when a file leaves. Shorter, and with no
    /// scale, when motion is reduced.
    var shelfPop: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.4, dampingFraction: 0.62)
    }

    @ViewBuilder private var shelfRim: some View {
        if rimOpacity > 0.01 {
            shape.stroke(
                LinearGradient(
                    colors: [
                        Color.white.opacity(rimOpacity * 0.22),
                        shelfAccent.opacity(rimOpacity),
                        Color.white.opacity(rimOpacity * 0.9)
                    ],
                    startPoint: UnitPoint(x: 0.5 + lean * 0.25, y: 0),
                    endPoint: .bottom
                ),
                lineWidth: 2
            )
            .allowsHitTesting(false)
        }
    }

    /// Soft light under the bottom curve, only while a drag is reaching.
    /// Behind the black fill, so the part inside the silhouette disappears and
    /// what clears the edge reads as a rim. Not in the tree at rest.
    @ViewBuilder private var shelfUnderglow: some View {
        if !reduceMotion, rimOpacity > 0.04 {
            Ellipse()
                .fill(shelfAccent.opacity(rimOpacity * 0.5))
                .frame(width: max(72, size.width * 0.58), height: 18)
                .blur(radius: 12)
                .offset(y: size.height - 8)
                .allowsHitTesting(false)
        }
    }

    // MARK: Content

    /// One state, one drawing, each defined next to the category it belongs to.
    /// The fades live here rather than inside them, so the whole timing table is
    /// one column: content that has to clear a growing shape waits 0.06s, and
    /// the panel — the only state with a body to fill — takes longer to arrive.
    @ViewBuilder private var content: some View {
        switch state {
        // `Color.clear`, not `EmptyView` — the frame this is given is what holds
        // the state's own width open between the two Extension strips, and a
        // frame on `EmptyView` takes no space at all. Empty, the row collapsed
        // to the icon and centred it over the camera housing, where there are no
        // pixels to draw on: the shape grew and nothing appeared in it.
        case .idle:
            Color.clear

        // Events.
        case .sided(let left, let right):
            sidedPill(left, right).transition(.opacity.animation(.easeOut(duration: 0.2)))
        case .event(let event):
            compactPill(event).transition(.opacity.animation(.easeOut(duration: 0.2)))
        case .accessory(let accessory):
            accessoryPill(accessory).transition(.opacity.animation(.easeOut(duration: 0.2)))
        case .audioLost(let loudness):
            audioLostPill(loudness).transition(.opacity.animation(.easeOut(duration: 0.2)))
        case .verdict(let build):
            verdictPill(build).transition(.opacity.animation(.easeOut(duration: 0.2)))
        case .externalEvent(let event):
            externalEventPill(event).transition(.opacity.animation(.easeOut(duration: 0.2)))

        // Activity.
        case .building(let build):
            buildPill(build).transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.06)))
        case .externalActivity(let activity):
            externalActivityPill(activity).transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.06)))

        // Interactions.
        case .peek:
            peekContent.transition(interactionTransition(reduceDuration: 0.2))
        case .panel:
            panelContent.transition(interactionTransition(reduceDuration: 0.28))
        }
    }

    /// Content leaves before the outline finishes collapsing, or the suck
    /// clips it. On the way in it waits, slightly small, until the shape has
    /// room. Reduce Motion keeps the fade the outline has always used.
    private func interactionTransition(reduceDuration: Double) -> AnyTransition {
        if reduceMotion {
            return .opacity.animation(.easeOut(duration: reduceDuration).delay(0.06))
        }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.92, anchor: .top))
                .animation(.spring(response: 0.34, dampingFraction: 0.84).delay(0.1)),
            removal: .opacity
                .combined(with: .scale(scale: 0.86, anchor: .top))
                .animation(.easeOut(duration: 0.1))
        )
    }

    // MARK: Glow

    /// Where each bar's centre sits — *inside* the straight edge, so the black
    /// shape covers the bar itself and only the blur's tail clears the flare.
    /// A source you can see is a smudge sitting next to the notch; a source you
    /// can't is light coming from behind it.
    ///
    /// Calibration knob, and it moves against `glowBlur`: further in or a
    /// tighter blur and nothing escapes at all, further out and the bright core
    /// crosses the edge and detaches again.
    private var glowInset: CGFloat { size.width / 2 - 6 }
    private let glowBlur: CGFloat = 20

    private func glowBar(_ signal: Signal?) -> some View {
        Capsule()
            // `glowTint`, not `tint`: the edge is orange or dark, never red.
            .fill(signal?.glowTint ?? .clear)
            // Exactly the shape's height, never more: the blur already carries
            // the spill past the bottom corner, whereas an overhanging bar puts
            // its unmasked core down there and the blob comes back.
            .frame(width: 26, height: size.height)
            .blur(radius: glowBlur)
    }

    // MARK: Extensions

    private var visibleExtensions: ExtensionSlots {
        metrics.visibleExtensions(state, extensions)
    }

    /// One icon beyond the state it accompanies. The separator always faces the
    /// state, while the icon hugs that same inner edge and unused width falls
    /// outward — the same geometry rule as a normal flank.
    private func extensionMark(_ item: NotchExtension, side: HorizontalEdge) -> some View {
        HStack(spacing: 7) {
            if side == .trailing, separatesFromState { extensionSeparator }
            extensionGlyph(item)
                .foregroundStyle(extensionTint(item))
                // Optical, and only the burst needs it: its spokes reach the
                // edge of the box on every side, so it comes closer to the
                // housing than a bordered word or a symbol with its own margin.
                // Pushed outward here rather than by widening the slot, which
                // would move both marks.
                .padding(side == .leading ? .trailing : .leading,
                         item.name.lowercased() == "claude" ? 4 : 0)
            if side == .leading, separatesFromState { extensionSeparator }
        }
        .frame(width: metrics.extensionFlank(for: state),
               alignment: side == .leading ? .trailing : .leading)
        .frame(height: metrics.notch.height)
        .accessibilityLabel("\(item.name) active")
    }

    /// One mark per condition. The two Vitals actually ships are drawn by hand
    /// in `Marks.swift` — neither is a system symbol:
    ///
    /// - **VPN** — the three letters in a box, the way iOS marks the same
    ///   condition. Outlined, not filled, because that is the mark people
    ///   already know. Widest thing a slot draws, and it sets `extensionFlank`.
    ///   Every lock and shield SF Symbols offers reads as "encrypted" rather
    ///   than "routed elsewhere".
    /// - **Claude** — its own burst, bundled as an asset and turning slowly.
    ///
    /// Anything else falls through to the generic symbol, which is what an
    /// Extension nobody has drawn a mark for looks like.
    @ViewBuilder private func extensionGlyph(_ item: NotchExtension) -> some View {
        switch item.name.lowercased() {
        case "vpn":
            Text("VPN")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .overlay {
                    RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.5), lineWidth: 1)
                }
        case "claude":
            // Bigger than the symbol box beside it: a burst is mostly the gaps
            // between its spokes, so the same measured size reads smaller.
            ClaudeWorkingMark().frame(width: 20, height: 20)
        default:
            Image(systemName: item.symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 17, height: 18)
        }
    }

    /// The hairline says "this is a different thing from what is beside it", so
    /// it only exists while something *is* beside it. On an idle notch the marks
    /// are all there is, and a rule with nothing on the far side of it reads as
    /// a stray line across the bezel.
    private var separatesFromState: Bool { state != .idle }

    private var extensionSeparator: some View {
        Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 14)
    }

    private func extensionTint(_ item: NotchExtension) -> Color {
        switch item.name.lowercased() {
        case "claude": .orange
        // Deliberately not tinted: the VPN mark is a bordered word, and a
        // coloured one reads as a status light rather than the badge iOS draws.
        default: .white.opacity(0.85)
        }
    }

    // MARK: Shared parts

    /// Shared by the accessory Event and the build Activity. The floor keeps 1%
    /// a ring rather than a dot; the ease is what makes a build's arc creep
    /// instead of jumping a step per poll.
    func ring(_ fraction: Double, tint: Color) -> some View {
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.03, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 20, height: 20)
        .animation(.easeOut(duration: 0.5), value: fraction)
    }

    /// One labelled row of the panel's right-hand block, shared by the battery
    /// numbers and the thermal ones so the two readouts cannot drift apart in
    /// weight or spacing — they occupy the same slot and swap under each other.
    /// `dot` puts a small filled circle after the label, for a row whose news is
    /// a state rather than a number — the value keeps saying what it measured
    /// and the dot says whether that is the good version of it. Nil on every
    /// row that has nothing to say, which is most of them.
    func statLine(_ label: String, _ value: String, tint: Color = .white,
                  dot: Color? = nil) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.white.opacity(0.45))
                .lineLimit(1).minimumScaleFactor(0.8)
            if let dot {
                Circle().fill(dot).frame(width: 5, height: 5)
                    // The label is followed by 8pt of nothing on every other
                    // row, so the dot sits closer than that or it reads as its
                    // own column instead of a mark on the label.
                    .padding(.leading, -4)
            }
            Spacer(minLength: 0)
            Text(value).monospacedDigit().foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
    }
}
