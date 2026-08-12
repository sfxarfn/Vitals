import SwiftUI

/// The shape itself: one black outline that grows and shrinks, whatever is
/// inside it. What goes inside lives beside its category — `Events/`,
/// `Activities/`, `Interactions/` — and is reached through `content` below.
struct NotchView: View {
    let state: NotchState
    let metrics: NotchMetrics
    let telemetry: Telemetry
    /// One per notch edge. Nil is no glow on that side.
    let cpuGlow: Signal?
    let thermalGlow: Signal?
    let shelf: Shelf
    /// Sends via AirDrop, anchored on the panel's own NSView for the fallback
    /// share sheet — the controller owns the window, so it owns that call.
    let airDrop: ([URL]) -> Void
    /// Moves between the two Interactions from inside them — the tray button up
    /// to the panel, the back button down to the peek it came from. Hover alone
    /// only ever reaches peek, and a drag is the only other way into the shelf.
    let show: (NotchState) -> Void

    // Extensions cannot add storage, so every piece of view state lives here and
    // is read from whichever category file draws it.
    @State var shelfTargeted = false
    @State var airDropTargeted = false
    @State var settingsHovered = false
    @State var trayHovered = false
    @State var backHovered = false
    @State var panelBody: PanelBody = .shelf
    @State var batteryHovered = false
    @State var thermalHovered = false

    var size: CGSize { metrics.size(for: state) }
    private var lifted: Bool { state != .idle }
    private let topRadius: CGFloat = 22
    private let bottomRadius: CGFloat = 28

    // MARK: Growth

    /// What the growth animates on — the state the notch is in, never the
    /// numbers inside it. An Activity republishes its counter every second, and
    /// a state's own numbers changing is not a state change: re-running a bouncy
    /// animation over the two shadow layers that often is what reads as a
    /// flicker, since the geometry never moves and only the shadow gets
    /// re-rasterized.
    /// The badge changes the shape's width, so it has to be part of the growth
    /// key or a tunnel coming up hard-cuts the notch wider instead of growing it.
    /// Rare enough to be a state change in its own right — unlike the numbers
    /// this key deliberately ignores, it does not tick.
    private var growthKey: Int { shapeKey * 2 + (vpnWidth > 0 ? 1 : 0) }

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
        // The verdict is narrower than the counter it follows, so it is its own
        // shape — sharing the key would swap the content without the shrink.
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
    private var xOffset: CGFloat { metrics.lean(for: state) }

    private var shape: NotchShape {
        NotchShape(topCornerRadius: topRadius,
                   bottomCornerRadius: state == .idle ? 10 : bottomRadius)
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
                    // The badge is outboard of the state, never inside it: every
                    // pill lays its flanks out against the camera housing, so
                    // content has to keep the width it would have had and the
                    // badge takes the strip the shape grew for it.
                    HStack(spacing: 0) {
                        content.frame(width: size.width - vpnWidth)
                        if vpnWidth > 0 { vpnMark }
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
                // Grown states lift off the bezel; idle is flush with it, so no
                // shadow there. Two layers, the way glass casts: a tight contact
                // shadow at the edge plus a wide diffuse ambient one. Radii and
                // opacities interpolate with the growth.
                //
                // Cast off a bare copy of the shape behind the clipped box, not
                // off the box itself: the blur source is then a solid path with
                // no content in it, so a build republishing its counter every
                // second no longer re-blurs two full-window offscreen passes.
                .background {
                    shape.fill(.black)
                        .shadow(color: .black.opacity(lifted ? 0.55 : 0),
                                radius: lifted ? 6 : 0, y: lifted ? 3 : 0)
                        .shadow(color: .black.opacity(lifted ? 0.35 : 0),
                                radius: lifted ? 24 : 0, y: lifted ? 12 : 0)
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
                // Last, so it moves the shape, its shadows and its glows as one
                // piece rather than shifting the box out from under them.
                .offset(x: xOffset)
            Spacer(minLength: 0)
        }
        .frame(width: metrics.windowSize.width, height: metrics.windowSize.height, alignment: .top)
        .animation(.bouncy(duration: 0.45, extraBounce: 0.12), value: growthKey)
        // The shelf is what the panel is for; a readout left up from the last
        // hover would greet the next drag with the wrong one.
        .onChange(of: state) { if state == .idle { panelBody = .shelf } }
    }

    // MARK: Content

    /// One state, one drawing, each defined next to the category it belongs to.
    /// The fades live here rather than inside them, so the whole timing table is
    /// one column: content that has to clear a growing shape waits 0.06s, and
    /// the panel — the only state with a body to fill — takes longer to arrive.
    @ViewBuilder private var content: some View {
        switch state {
        case .idle:
            EmptyView()

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
            peekContent.transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.06)))
        case .panel:
            panelContent.transition(.opacity.animation(.easeOut(duration: 0.28).delay(0.06)))
        }
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

    // MARK: VPN badge

    private var vpnWidth: CGFloat { metrics.showsVPN(state) ? metrics.vpnFlank : 0 }

    /// The tunnel, on the outer right edge of everything the notch says while it
    /// is up. A hairline separates it from the state's own right flank, because
    /// the two are unrelated: one is news with a clock on it, the other is a
    /// condition that outlasts every pill it will sit beside.
    ///
    /// Peek draws its own, taller, in the network row — see `PeekView`. Not
    /// shared: this one hugs its letters inside a one-row flank, that one tracks
    /// the height of the pair of readings beside it.
    private var vpnMark: some View {
        HStack(spacing: 6) {
            Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 14)
            Text("VPN")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                // Filled, not just outlined: a hairline box this small on black
                // reads as nothing at all next to a pill carrying a glyph.
                .background {
                    RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.12))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.35), lineWidth: 1)
                }
        }
        // Its own flank, and it obeys the same rule as every other one: pinned
        // inward, slack falling outward. Centred, the box lands in the last few
        // points of the shape, which is exactly where `bottomCornerRadius` is
        // curving back in and eating the border.
        .flankSlot(metrics.vpnFlank, .trailing, pad: metrics.notchPad)
        .frame(height: metrics.notch.height)
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
    func statLine(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.white.opacity(0.45))
            Spacer(minLength: 0)
            Text(value).monospacedDigit().foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
    }
}
