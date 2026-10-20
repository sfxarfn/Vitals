import SwiftUI

/// Pose for the panel's rubber. Identity at rest; the keyframe animator
/// only leaves it when `rubber` changes, and a snap trigger is every value at 1.
private struct RubberPose: Equatable, Animatable {
    var x: CGFloat = 1
    var y: CGFloat = 1

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(x, y) }
        set { x = newValue.first; y = newValue.second }
    }
}

/// What the keyframe tracks read. `keyframeAnimator` restarts when this
/// changes, but its keyframe closure is handed the pose, not this value, so
/// the tracks close over the copy taken for that same call.
private struct RubberTrigger: Equatable {
    var tick = 0
    var closing = false
    /// Leaving the panel. Every keyframe is identity, so an Event, Activity,
    /// or Extension mark cannot inherit the suck.
    var snap = false
}

/// The rubber tracks are their own modifier. Inlined into `NotchView.body`
/// they sit in the same expression as the silhouette, and the type checker
/// does not finish.
/// The notch outline drawn at a given size, centred at the top of whatever
/// it clips. The content layer is window-wide and never moves, so its clip
/// has to carry the shape's own width and height — and animate them.
private struct CentredNotch: Shape {
    var notch: NotchShape
    var width: CGFloat
    var height: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, NotchShape.AnimatableData> {
        get { .init(.init(width, height), notch.animatableData) }
        set {
            width = newValue.first.first
            height = newValue.first.second
            notch.animatableData = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        notch.path(in: CGRect(x: rect.midX - width / 2, y: rect.minY,
                              width: width, height: height))
    }
}

private struct RubberEffect: ViewModifier {
    var trigger: RubberTrigger

    func body(content: Content) -> some View {
        let fired = trigger
        return content.keyframeAnimator(initialValue: RubberPose(), trigger: fired) { view, pose in
            view.scaleEffect(x: pose.x, y: pose.y, anchor: .top)
        } keyframes: { _ in
            // One track shape for open, close, and snap — the keyframe
            // builder needs a single type, and the values are what differ.
            // Close: a short stretch, then a dip just under rest, then
            // settle. Open: hold, then a small overshoot, then settle.
            // Snap: identity, immediately.
            let closing = fired.closing && !fired.snap
            let yPeak: CGFloat = fired.snap ? 1 : (closing ? 1.03 : 1)
            let yDip: CGFloat = fired.snap ? 1 : (closing ? 0.973 : 1.016)
            let xPinch: CGFloat = fired.snap ? 1 : (closing ? 0.99 : 1)
            let xOvershoot: CGFloat = fired.snap ? 1 : 1.008
            let first: Double = fired.snap ? 0.01 : 0.08
            let second: Double = fired.snap ? 0.01 : (closing ? 0.26 : 0.02)
            let third: Double = fired.snap ? 0.01 : (closing ? 0.12 : 0.3)
            let fourth: Double = fired.snap ? 0.01 : (closing ? 0.18 : 0.2)
            // A snappy spring asked to cover no distance still bounces.
            // Snap uses a dead spring so the pill is not rubber.
            let spring = fired.snap ? Spring(duration: 0.01, bounce: 0) : .snappy
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
    }
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
    /// Both edges glow it. Nil is no glow. Heat is the one condition that gets
    /// an edge — sustained CPU load once lit the right one, but heat on a
    /// fanless chip *is* sustained load, so the two edges said one thing.
    let thermalGlow: Signal?
    let shelf: Shelf
    let nowPlaying: NowPlaying
    /// Approach cue from the controller. Nil unless a file drag is near the
    /// housing and the panel has not taken the drop over yet.
    let fileDrag: FileDrag?
    let endFileDrag: () -> Void
    /// Sends via AirDrop, anchored on the panel's own NSView for the fallback
    /// share sheet — the controller owns the window, so it owns that call.
    let airDrop: ([URL]) -> Void
    /// Opens a state from inside the view. Nothing in the panel calls it now —
    /// paging and details are local state — but the controller still hands it in.
    let show: (NotchState) -> Void

    // Extensions cannot add storage, so every piece of view state lives here and
    // is read from whichever category file draws it.
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    @State var shelfTargeted = false
    @State var airDropTargeted = false
    /// Where a file being dragged over the AirDrop strip is, in the strip's own
    /// bounds — it holds the strip's light where hover cannot. Nil with no file
    /// aimed there; the pointer's own position lives in `HoverSpotlight`.
    @State var airDropSpot: CGPoint?
    /// Bumped when the panel opens. Leaving it snaps the pose to 1 instead.
    /// Private because `RubberTrigger` is private — an internal property of a
    /// private type does not compile. Nothing outside this file reads it.
    @State private var rubber = RubberTrigger()
    /// One squash after a drop lands, then back. Never left set.
    @State var landSquash = false
    /// Border flash for the landing, including when motion is reduced.
    @State var landFlash = false
    @State var liftingURL: URL?
    @State var freshURLs: Set<URL> = []
    @State var ripplePoint: CGPoint?
    @State var rippleToken = 0
    /// The feature page the arrows and dots are on.
    @State var panelPage: PanelPage = .shelf
    /// A stat's numbers, standing in the slot over the feature page. Nil is
    /// the feature page itself.
    @State var panelDetail: PanelDetail?
    /// Shared by a stat and the detail it opens, so the detail's background
    /// grows out of the tile — or the degree — that was clicked, and shrinks
    /// back into it on the way out.
    @Namespace var panelGrow
    /// Bumped by the Now Playing skip buttons, so their glyphs bounce on the
    /// tap even when the track change takes a moment to arrive.
    @State var skipBounce = 0
    @State var backBounce = 0
    /// Which stat the open detail grew out of — thermal has two, the degree
    /// and the CPU — so it grows from, and shrinks back into, the one clicked.
    @State var detailOrigin: GrowOrigin?

    var size: CGSize { metrics.size(for: state, extensions: extensions) }
    private var lifted: Bool {
        state != .idle || visibleExtensions.left != nil || visibleExtensions.right != nil
    }
    /// Only surfaces opened by the pointer lift off the bezel. Activities and
    /// Events remain visually flush, even though their outline grows.
    private var castsShadow: Bool {
        switch state {
        case .panel: true
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
        case .accessory:            3
        case .audioLost:            4
        case .verdict:              11
        case .externalEvent:        12
        case .trackChange:          14
        case .vpn:                  15
        case .building:             5
        case .externalActivity:     13
        case .panel:                7
        }
    }

    /// A state that buys more on one side than the other has to slide, or the
    /// extra width would push the camera housing off the notch. Half the
    /// difference, which is zero for every symmetric state — today, every state
    /// but one with a single Extension up. Interpolates with the width under
    /// the same growth, so a lean reads as growing sideways rather than growing
    /// and then sliding.
    private var xOffset: CGFloat { metrics.lean(for: state, extensions: extensions) }

    private var shape: NotchShape {
        NotchShape(topCornerRadius: topRadius,
                   bottomCornerRadius: lifted ? bottomRadius : 10 * radiusScale)
    }

    // MARK: Body

    var body: some View {
        // Laid out in layout points, then scaled onto the screen-sized window
        // from the top centre — see `NotchMetrics.scale`. The overlay is what
        // lets the larger layout hang from the window's top edge rather than
        // being centred in it.
        Color.clear
            .frame(width: metrics.screenWindowSize.width, height: metrics.screenWindowSize.height)
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    posed(sizedBox)
                    Spacer(minLength: 0)
                }
                .frame(width: metrics.windowSize.width, height: metrics.windowSize.height,
                       alignment: .top)
                .animation(.bouncy(duration: 0.45, extraBounce: 0.12), value: growthKey)
                .scaleEffect(metrics.scale, anchor: .top)
            }
            .onChange(of: state) { old, new in stateChanged(from: old, to: new) }
    }

    /// Two layers. The silhouette is its own stable view — a Color, not the
    /// state switch — so its frame interpolates and the shape actually grows
    /// and shrinks. The content sits beside it, not in its overlay: an
    /// overlay is placed from the box's origin, and that origin travels left
    /// as the box widens, so everything in it slid in from the right. Here
    /// the content is pinned to the window's fixed centre and the growing
    /// shape only masks it.
    private var sizedBox: some View {
        ZStack(alignment: .top) {
            silhouette
            contentLayer
        }
    }

    private var silhouette: some View {
        Color.clear
            // The shape flares outward by topRadius per side, so the
            // body lines up with the notch only if the frame is wider.
            .frame(width: size.width + topRadius * 2, height: size.height)
            // Opaque black in every state so the panel reads as an
            // extension of the bezel instead of showing the desktop
            // through it.
            .background(shape.fill(.black))
            .overlay { shelfRim }
            .background(alignment: .top) { shelfUnderglow }
            // Interactions lift off the bezel; Activities and Events stay
            // flush with it. Two layers, the way glass casts: a tight
            // contact shadow at the edge plus a wide diffuse ambient one.
            // Radii and opacities interpolate as the Interaction opens.
            //
            // Cast off a bare copy of the shape, not off the content: the
            // blur source is then a solid path with nothing in it, so a build
            // republishing its counter every second does not re-blur two
            // full-window offscreen passes.
            //
            // Fixed radii, faded as a layer: interpolating the blur radius
            // re-rasterised both blurs on every frame. Always in the tree,
            // never inserted or removed — the shadow source is a black copy
            // of the shape, and a transitioning copy sits at its final size
            // (or its old one, on the way out) while the real shape is still
            // growing, which flashed as a blink around the notch.
            .background {
                shape.fill(.black)
                    .shadow(color: .black.opacity(0.55), radius: 6, y: 3)
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                    .opacity(castsShadow ? 1 : 0)
            }
            // Behind the black shape, so only the half that escapes past
            // each edge is ever seen — that overlap is what reads as light
            // leaking out rather than a colored border.
            //
            // Only in the tree while a glow is up — a clear bar still costs a
            // 20pt blur on every frame the shape grows. Both edges carry the
            // heat, one bar each, so the notch warms as a whole.
            .background {
                ZStack {
                    if thermalGlow != nil {
                        glowBar(thermalGlow).offset(x: -glowInset).transition(.opacity)
                        glowBar(thermalGlow).offset(x: glowInset).transition(.opacity)
                    }
                }
            }
            // States that last twenty minutes must not announce themselves;
            // fading is the whole difference between a glow and a pill.
            .animation(.easeInOut(duration: 0.5), value: thermalGlow)
    }

    private var contentLayer: some View {
        // Extensions are outboard of the state, never inside it: every pill
        // keeps its calibrated flanks against the camera housing while the
        // icons take the strips grown beyond it.
        HStack(spacing: 0) {
            if let left = visibleExtensions.left {
                extensionMark(left, side: .leading)
            }
            content.frame(width: metrics.baseSize(for: state).width)
            if let right = visibleExtensions.right {
                extensionMark(right, side: .trailing)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        // The window's width never changes, so this frame never moves: the
        // content's centre is the housing's centre on every frame of growth.
        .frame(width: metrics.windowSize.width, alignment: .top)
        // Content is laid out at its final size the instant the state flips;
        // the mask is what reveals it as the shape grows. Without this it
        // interpolates too, and every frame of the growth re-runs the whole
        // content's layout at a new width — text scale-fitting, the panel's
        // ScrollView, all of it, ~50 times per growth. Scoped to growthKey so
        // anything animating on its own clock in here — the audio-lost
        // turnover, the battery swap — is untouched. Every fade that *does*
        // fire on a state change must now carry its own `.animation()`, or
        // this nils it into a hard cut.
        .transaction(value: growthKey) { $0.animation = nil }
        // Outside the transaction, so the clip grows on the bouncy curve with
        // the silhouette while the content under it stands still. A path
        // clip, not `.mask`: a mask is an offscreen alpha pass the size of
        // the window on every frame of every growth.
        .clipShape(CentredNotch(notch: shape,
                                width: size.width + topRadius * 2,
                                height: size.height))
    }

    /// Drag feedback sits on the drawn silhouette, not on a new layout size:
    /// the window and the hover rect stay where they are, and the outline
    /// swells evenly as the file comes in, without following it. Gone the
    /// moment the drag is — `reach` is 0 at rest, so none of this ticks while
    /// the notch is idle.
    ///
    /// Rubber is scale, not a second layout size: the frame above is still
    /// the bouncy growth. Anchor is the top edge so the housing stays on the
    /// bezel. Reduce Motion never bumps `rubber`, so the pose stays 1. A snap
    /// trigger is every keyframe at 1 — that is what runs when an Event,
    /// Activity, or Extension takes the silhouette, so the suck cannot play
    /// on the pill.
    private func posed(_ box: some View) -> some View {
        box
            .scaleEffect(silhouetteScale, anchor: .top)
            .offset(x: xOffset)
            .animation(shelfFollow, value: fileDrag)
            .animation(shelfFollow, value: shelfTargeted)
            .animation(shelfFollow, value: airDropTargeted)
            .modifier(RubberEffect(trigger: rubber))
    }

    /// A page or detail left up from the last hover would greet the next one,
    /// or the next drag, with the wrong slot. Reset on the way out and again on
    /// the way in — the shelf may have filled, or a drag begun, in between —
    /// with `openingPage` the one place that picks the page.
    private func stateChanged(from old: NotchState, to new: NotchState) {
        if old != new, old == .panel || new == .panel { resetPanelSlot() }
        // A targeted flag left over from a drag the panel closed under
        // would keep the resting notch swollen.
        if new != .panel {
            shelfTargeted = false
            airDropTargeted = false
            airDropSpot = nil
            landSquash = false
            liftingURL = nil
            // A landing that finishes after the panel has gone must not be
            // waiting here to replay the ripple and the fresh-chip scale
            // the next time the shelf opens.
            freshURLs = []
            ripplePoint = nil
            landFlash = false
        }
        if new != .panel { VitalsCursor.forceArrow() }
        guard !reduceMotion, old != new else { return }
        let was = old == .panel
        let now = new == .panel
        // Rubber only on opening. Leaving onto an Event, an Activity, or idle
        // (where Extension marks come back) snaps to rest instead of sucking
        // the pill.
        guard was || now else { return }
        rubber = RubberTrigger(
            tick: rubber.tick + 1,
            closing: false,
            snap: was && !now
        )
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

    private var landingSquash: Bool { state == .panel && landSquash }

    /// One factor for both axes. A different x and y stretched everything the
    /// panel holds — text and glyphs read as smeared, not as a shape reaching.
    /// The landing is a small press-in, not a squash.
    var silhouetteScale: CGFloat {
        guard !reduceMotion else { return 1 }
        let awake = 1 + reach * 0.025
        return landingSquash ? awake * 0.98 : awake
    }

    /// The rim is the pull — a file approaching a notch that has not opened
    /// yet. Once the panel is up the shelf box and the AirDrop tile are the
    /// target, and a lit outline around them as well stacked three rings.
    var rimOpacity: Double {
        guard state != .panel, !reduceMotion else { return 0 }
        return Double(reach) * 0.65
    }

    /// The one accent of the drop: rim, shelf target and AirDrop share it.
    var shelfAccent: Color { .accentColor }

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
                    startPoint: .top,
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
    /// one column: every pill — Event or Activity — fades in the same 0.2s as
    /// the shape grows around it, and the Interactions bring their own.
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
        case .trackChange(let change):
            trackChangePill(change).transition(.opacity.animation(.easeOut(duration: 0.2)))
        case .vpn(let notice):
            vpnPill(notice).transition(.opacity.animation(.easeOut(duration: 0.2)))

        // Activity.
        case .building(let build):
            buildPill(build).transition(.opacity.animation(.easeOut(duration: 0.2)))
        case .externalActivity(let activity):
            externalActivityPill(activity).transition(.opacity.animation(.easeOut(duration: 0.2)))

        // Interactions.
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

    /// One mark per condition. The one Vitals ships is Claude's own burst,
    /// bundled as an asset and turning slowly — not a system symbol. (VPN had
    /// a word badge here; it is an Event pill now, and the idle notch no
    /// longer leans for it.)
    ///
    /// Anything else falls through to the generic symbol, which is what an
    /// Extension nobody has drawn a mark for looks like.
    @ViewBuilder private func extensionGlyph(_ item: NotchExtension) -> some View {
        switch item.name.lowercased() {
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
        default: .white.opacity(0.85)
        }
    }

    // MARK: Shared parts

    /// Shared by the accessory Event and the build Activity. The floor keeps 1%
    /// a ring rather than a dot; the ease is what makes a build's arc creep
    /// instead of jumping a step per poll.
    func ring(_ fraction: Double, tint: Color, size: CGFloat = 20, line: CGFloat = 3) -> some View {
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: line)
            Circle()
                .trim(from: 0, to: max(0.03, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
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
