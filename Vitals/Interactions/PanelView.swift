import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The panel's feature pages, in the order the arrows and the dots walk them.
/// Now Playing is the main page; which one the panel opens on is decided in
/// one place, `openingPage`. Features sit side by side here; the stats'
/// numbers are not pages, they are `PanelDetail`s. The arrows only go live,
/// and the dots only appear, while there is a second case. Meeting is always a
/// page; with no call it says so, and a live one is what makes it the opener.
enum PanelPage: CaseIterable { case nowPlaying, shelf, meeting }

/// The numbers behind a stat, opened from the stat itself — the die's flank or
/// a summary tile — over whatever feature page was up. Not in the page cycle.
enum PanelDetail { case battery, thermal, network }

/// The panel: what hovering the notch opens. The housing row carries the die
/// and the CPU in a flank each; under it, a thin summary column, then one slot
/// that holds a feature page — or, while a stat is opened, that stat's numbers.
/// The panel's geometry never changes with either: the slot swaps what it
/// holds, the shape stays the one the hover grew.
extension NotchView {

    // MARK: Body

    var panelContent: some View {
        VStack(spacing: 0) {
            // Camera housing row — anything under it is invisible, so the two
            // stats take a flank each beside it. The degree is the way into
            // the thermal detail, the same move the summary column makes below;
            // while any detail is up the left flank is the way back out.
            HStack(spacing: 0) {
                ZStack(alignment: .leading) {
                    if panelDetail != nil {
                        backButton.transition(.opacity)
                    } else {
                        Button { toggleDetail(.thermal, from: .detail(.thermal)) } label: {
                            readout("thermometer.medium", tempValue, tint: tempTint)
                                // No fill of its own, but a frame to grow from:
                                // the thermal detail starts as this flank.
                                .background {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(.clear)
                                        .modifier(GrowAnchor(id: .detail(.thermal), in: panelGrow,
                                                             enabled: !reduceMotion))
                                }
                        }
                        .buttonStyle(VitalsPressStyle())
                        .transition(.opacity)
                    }
                }
                // Not `flankSlot`: balanced against the body below, not the
                // housing — the outer edges line up with the summary column on
                // the left and the right arrow, and the slack falls inward.
                .padding(.leading, panelInset)
                .frame(width: metrics.panelFlanks.left, alignment: .leading)
                Spacer(minLength: 0).frame(width: metrics.notch.width)
                // Load is half of what the thermal detail explains, so the CPU
                // opens it too — and it grows out of this flank, not the degree.
                // The CPU stays up while the detail is, so its anchor steps
                // aside then rather than claiming the detail's frame.
                Button { toggleDetail(.thermal, from: .cpu) } label: {
                    readout("cpu", "\(Int(telemetry.stall.cpuPercent.rounded()))%", tint: .white)
                        .background {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(.clear)
                                .modifier(GrowAnchor(id: panelDetail == nil ? .cpu : .cpuAtRest,
                                                     in: panelGrow, enabled: !reduceMotion))
                        }
                }
                .buttonStyle(VitalsPressStyle())
                .padding(.trailing, panelInset)
                .frame(width: metrics.panelFlanks.right, alignment: .trailing)
            }
            .frame(height: metrics.notch.height)

            // The body. A detail takes all of it — the summary column goes —
            // and grows out of whatever opened it; the panel's own shape never
            // changes, only what is inside the body moves. Three siblings, not
            // one branch, so the background can grow on the spring while the
            // numbers wait to fade in until there is room for them.
            ZStack {
                if panelDetail == nil {
                    VStack(spacing: 5) {
                        HStack(spacing: 6) {
                            summaryColumn
                            // Always on the feature page, even with one page —
                            // dimmed and dead until there is a second to reach.
                            pageArrow(by: -1)
                            Group {
                                switch panelPage {
                                case .shelf:
                                    HStack(spacing: 6) {
                                        airDropTile
                                        shelfBox
                                    }
                                case .nowPlaying:
                                    nowPlayingPage
                                case .meeting:
                                    meetingPage
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            pageArrow(by: 1)
                        }
                        // Hidden with one page: the slot takes the dots'
                        // height rather than the body growing a row it has
                        // nothing to say in.
                        if canPage { pageDots }
                    }
                    .transition(.opacity)
                }
                if let detail = panelDetail {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.white.opacity(0.06))
                        .modifier(GrowAnchor(id: detailOrigin ?? .detail(detail),
                                             in: panelGrow, enabled: !reduceMotion))
                        .transition(.opacity)
                }
                if let detail = panelDetail {
                    detailView(detail)
                        .padding(6)
                        .transition(.asymmetric(
                            insertion: .opacity.animation(
                                .easeOut(duration: 0.16).delay(reduceMotion ? 0 : 0.16)),
                            removal: .opacity.animation(.easeIn(duration: 0.08))
                        ))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, panelInset)
            .padding(.bottom, 8)
            .animation(.snappy(duration: 0.2), value: panelPage)
        }
        // Aiming a file at an inset box is darts. The whole open panel takes a
        // drop — the housing row, the padding, and the readout pages the drag
        // has no way to know are up. The AirDrop strip overrides what happens
        // inside its own bounds. The delegate, not `dropDestination`, because
        // the ripple needs the point the file landed at.
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], delegate: ShelfFileDrop(
            onMove: { _ in
                if !shelfTargeted { shelfTargeted = true }
                // A file in hand is headed for the shelf, whatever was up.
                if panelPage != .shelf || panelDetail != nil { showShelf() }
            },
            onExit: { releaseDragAim() },
            onPerform: { urls, point in catchOnShelf(urls, at: point) }
        ))
        .overlay {
            // `if let ripplePoint` would bind an immutable copy of the state
            // property. Clearing that copy is not a write to the state, and
            // Swift 6.4 crashes while diagnosing the assignment.
            if let point = ripplePoint, !reduceMotion {
                ShelfRipple(point: point, token: rippleToken) { finished in
                    if rippleToken == finished { ripplePoint = nil }
                }
                .id(rippleToken)
                .allowsHitTesting(false)
            }
        }
    }

    /// The body's side inset, which the housing row's stats line up with.
    private var panelInset: CGFloat { 12 }

    // MARK: Slot

    /// The page a panel opens on, by context. A file in hand is headed for the
    /// shelf, and a shelf already holding something is why you came back —
    /// both open on Shelf. Failing that a live meeting, then Now Playing, the
    /// floor. Decided fresh on every open; the last page is not remembered.
    var openingPage: PanelPage {
        let dragging = fileDrag != nil || NotchController.shared?.draggingFile == true
        if dragging || !shelf.urls.isEmpty { return .shelf }
        // A live call outranks the music, never a file you are holding.
        return meetings.meeting != nil ? .meeting : .nowPlaying
    }

    /// The slot as a fresh open finds it: the opening page, no detail.
    func resetPanelSlot() {
        panelPage = openingPage
        panelDetail = nil
    }

    /// Shelf with no detail over it — what a file in hand wants, whatever page
    /// it found the panel on.
    func showShelf() {
        panelPage = .shelf
        panelDetail = nil
    }

    /// The stat that opened a detail closes it again; another stat switches to
    /// its own. `origin` is what it grows out of. Closing keeps the origin, so
    /// the detail shrinks back into the stat it came from.
    private func toggleDetail(_ detail: PanelDetail, from origin: GrowOrigin) {
        withAnimation(detailMotion) {
            if panelDetail == detail {
                panelDetail = nil
            } else {
                detailOrigin = origin
                panelDetail = detail
            }
        }
    }

    /// The grow and its reverse. Reduce Motion keeps the swap as a crossfade —
    /// `GrowAnchor` is off then, so there is no geometry to move.
    private var detailMotion: Animation {
        reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.35, dampingFraction: 0.85)
    }

    /// Whether there is another feature page to go to. The arrows show on the
    /// feature page either way and only go live with this; the dots need it to
    /// show at all. A detail hides both, along with the rest of the page.
    private var canPage: Bool { PanelPage.allCases.count > 1 }

    @ViewBuilder private func detailView(_ detail: PanelDetail) -> some View {
        switch detail {
        case .battery: batteryPanel
        case .thermal: thermalPanel
        case .network: networkPanel
        }
    }

    /// The way out that does not need you to remember which stat you clicked.
    /// Back to the feature page the detail was opened over; the stat itself
    /// closing its own detail stays as the second way.
    private var backButton: some View {
        Button { withAnimation(detailMotion) { panelDetail = nil } } label: {
            HStack(spacing: 2) {
                Image(systemName: "chevron.left")
                Text("Back")
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.55))
        }
        .buttonStyle(VitalsPressStyle())
    }

    // MARK: Summary column

    /// The two readings that have no flank of their own, one short value each.
    /// Each opens its detail, which grows out of the tile and takes the body —
    /// column included — until Back.
    private var summaryColumn: some View {
        VStack(spacing: 6) {
            summaryTile(.battery) {
                Image(systemName: batteryMiniSymbol)
                    .font(.system(size: 12, weight: .medium))
                Text(batteryMiniValue)
            }
            summaryTile(.network) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .bold))
                Text(Self.compactRate(telemetry.net.down))
            }
            // While a tunnel carries the traffic, the tile that summarises the
            // link says so — the one place in the panel you glance at for it.
            .overlay(alignment: .topTrailing) {
                if telemetry.net.vpn {
                    Text("VPN")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(white: 0.12))
                        .padding(.horizontal, 3)
                        .background { RoundedRectangle(cornerRadius: 4).fill(.orange) }
                        // Over the tile's corner, not inside it: the rate stays
                        // where it was, and the badge reads as attached.
                        .offset(x: 7, y: -5)
                        .allowsHitTesting(false)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: telemetry.net.vpn)
        }
        .frame(width: 44)
    }

    private func summaryTile<Content: View>(_ detail: PanelDetail,
                                            @ViewBuilder _ content: () -> Content) -> some View {
        Button { toggleDetail(detail, from: .detail(detail)) } label: {
            VStack(spacing: 2) { content() }
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(0.08))
                        .modifier(GrowAnchor(id: .detail(detail), in: panelGrow,
                                             enabled: !reduceMotion))
                }
                // The AirDrop strip's answer to hover, sized to a 44pt tile.
                // On the tile, not the matched background, so the light never
                // rides along with the grow.
                .hoverSpotlight(cornerRadius: 10, reach: 34)
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(VitalsPressStyle(scales: false))
    }

    // MARK: Paging

    /// Walks the feature pages in order and wraps, so either arrow reaches all.
    private func pageArrow(by step: Int) -> some View {
        PageArrow(step: step, live: canPage, reduceMotion: reduceMotion) {
            let walk = PanelPage.allCases
            let here = walk.firstIndex(of: panelPage) ?? 0
            panelPage = walk[(here + step + walk.count) % walk.count]
        }
    }

    /// Which feature page the slot is on. Under the slot only, so the dots centre
    /// on what they count rather than on the whole row.
    private var pageDots: some View {
        HStack(spacing: 4) {
            ForEach(PanelPage.allCases, id: \.self) { page in
                // Each dot is also a way to its page. The hit box is taller
                // than the 4pt mark, which would be a target in name only.
                Button { panelPage = page } label: {
                    Capsule()
                        .fill(.white.opacity(page == panelPage ? 0.9 : 0.25))
                        .frame(width: page == panelPage ? 10 : 4, height: 4)
                        .frame(height: 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 4)
        // Centred under the slot: past the summary column, its gap and an arrow
        // on the left, balanced by the arrow alone on the right.
        .padding(.leading, 44 + 6)
    }

    // MARK: Flank stats

    /// Glyph plus one short value. Same 17/12 pair the compact pill uses, so a
    /// stat reads at the same weight whether you hovered for it or it came to
    /// you — the glyph is the only thing that says which stat this is.
    private func readout(_ symbol: String, _ value: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                // SF Symbols do not share a bounding box — `cpu` is near-square
                // and `thermometer.medium` narrow and tall — so at one point
                // size the two flanks take different room and their values stop
                // lining up. A fixed box is what makes the pair symmetric.
                .frame(width: 20)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(.white)
        }
    }

    /// Shared by the network page and the summary column, so neither can start
    /// rounding the same rate a different way.
    ///
    /// Bytes never sits below KB — a row that flips between "812 bytes/s" and
    /// "1.2 MB/s" changes width on every idle tick. Non-numeric formatting off for
    /// the same reason: the default zero is the word "Zero".
    static let rateFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    /// The summary column's rate: a number and a unit letter, because 44pt has
    /// no room for "KB/s". Same decimal units as `rateFormatter`.
    static func compactRate(_ bytesPerSecond: Double) -> String {
        let kb = max(bytesPerSecond, 0) / 1000
        if kb < 1000 { return "\(Int(kb.rounded()))K" }
        let mb = kb / 1000
        if mb < 1000 { return mb < 10 ? String(format: "%.1fM", mb) : "\(Int(mb.rounded()))M" }
        return String(format: "%.1fG", mb / 1000)
    }

    // MARK: Shelf

    /// Drop straight on the tile to send those files; click it to send whatever
    /// is already sitting in the box.
    private var airDropTile: some View {
        Button {
            airDrop(shelf.urls)
        } label: {
            // A strip, not a tile: the shelf is what the panel is for, so
            // AirDrop takes the least width that still holds its mark. The
            // mark is the label — the name lives in the tooltip and VoiceOver.
            AirDropMark()
                .stroke(airDropTargeted ? Color.white : shelfAccent,
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: 20, height: 20)
                .frame(width: 40).frame(maxHeight: .infinity)
                .background {
                    // Quiet like the shelf box beside it, and the accent only
                    // when a file is actually aimed here.
                    RoundedRectangle(cornerRadius: 14)
                        .fill(airDropTargeted ? AnyShapeStyle(shelfAccent)
                                              : AnyShapeStyle(Color.white.opacity(0.09)))
                }
            // Under the pointer on hover; under the file, and brighter, while
            // one is aimed here — that holds even once hover has ended.
            .hoverSpotlight(cornerRadius: 14, reach: 64,
                            aimed: airDropSpot, bright: airDropTargeted)
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.white.opacity(airDropTargeted ? 0.5 : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        // No hover growth: the tile is against the camera housing, and
        // growing put its corner under it. The spotlight is the answer.
        .buttonStyle(VitalsPressStyle(scales: false))
        .help("AirDrop")
        .accessibilityLabel("AirDrop")
        .onDrop(of: [.fileURL], delegate: ShelfFileDrop(
            onMove: { point in
                if !airDropTargeted { airDropTargeted = true }
                airDropSpot = point
            },
            onExit: {
                airDropTargeted = false
                airDropSpot = nil
                if !shelfTargeted {
                    if NSEvent.pressedMouseButtons & 1 == 0 {
                        NotchController.shared?.fileDragEnded()
                    } else {
                        endFileDrag()
                    }
                }
            },
            onPerform: { urls, _ in catchAirDrop(urls) }
        ))
        .animation(shelfFollow, value: airDropTargeted)
    }

    private var shelfBox: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                if shelf.urls.isEmpty {
                    Text("Drop files here")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.white.opacity(shelfTargeted || landFlash ? 0.85 : 0.4))
                        .scaleEffect(!reduceMotion && shelfTargeted ? 1.05 : 1)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(Array(shelf.urls.enumerated()), id: \.element) { index, url in
                        shelfChip(url, index: index)
                    }
                    // The slot the drop will actually fill — files append.
                    // A gap drawn in the middle would promise an insertion the
                    // box does not do. Hidden when motion is reduced: the
                    // border is the affordance then, not a moving slot.
                    if shelfTargeted, !reduceMotion {
                        ShelfGhost()
                            .transition(.scale(scale: 0.5, anchor: .bottom).combined(with: .opacity))
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .animation(shelfPop, value: shelf.urls)
            .animation(shelfPop, value: shelfTargeted)
            .animation(shelfPop, value: liftingURL)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.white.opacity(landFlash ? 0.14 : shelfTargeted ? 0.10 : 0.06))
        }
        .overlay {
            // The one drop signal once the panel is open: a thin accent line
            // and a soft glow inside it. No heavy white ring — the silhouette
            // no longer lights up around this, so nothing competes with it.
            let lit = shelfTargeted || landFlash
            let shape = RoundedRectangle(cornerRadius: 14)
            ZStack {
                shape.strokeBorder(
                    lit ? AnyShapeStyle(shelfAccent.opacity(landFlash ? 0.85 : 0.6))
                        : AnyShapeStyle(Color.white.opacity(0.2)),
                    style: StrokeStyle(lineWidth: lit ? 1 : 1.5, dash: lit ? [] : [6, 4])
                )
                if lit {
                    shape.strokeBorder(shelfAccent.opacity(landFlash ? 0.45 : 0.3), lineWidth: 8)
                        .blur(radius: 8)
                        .clipShape(shape)
                }
            }
            .allowsHitTesting(false)
        }
        .animation(shelfFollow, value: shelfTargeted)
        .animation(shelfFollow, value: landFlash)
        .contextMenu {
            Button("Clear shelf") { shelf.clear() }.disabled(shelf.urls.isEmpty)
        }
    }

    private func shelfChip(_ url: URL, index: Int) -> some View {
        let fresh = freshURLs.contains(url)
        let lifted = liftingURL == url
        let freshBefore = shelf.urls.prefix(index).filter { freshURLs.contains($0) }.count
        return ShelfChip(
            url: url,
            fresh: fresh,
            reduceMotion: reduceMotion,
            lifted: lifted,
            delay: fresh ? Double(freshBefore) * 0.045 : 0,
            onSession: { noteDrag(url, $0) },
            onSettled: { freshURLs.remove(url) },
            onRemove: { withAnimation(shelfPop) { shelf.remove(url) } },
            onReveal: { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        )
    }
}

/// One end of a detail's grow: the stat that opens it, or the detail's own
/// background. Off under Reduce Motion, where the swap is a crossfade.
/// What a detail can grow out of. Each detail's own stat, plus the CPU flank,
/// which opens the thermal detail too. `cpuAtRest` is the CPU flank's id while
/// a detail is up: it stays on screen then, and must not share the detail's.
enum GrowOrigin: Hashable {
    case detail(PanelDetail)
    case cpu
    case cpuAtRest
}

private struct GrowAnchor: ViewModifier {
    let id: GrowOrigin
    let namespace: Namespace.ID
    let enabled: Bool

    init(id: GrowOrigin, in namespace: Namespace.ID, enabled: Bool) {
        self.id = id
        self.namespace = namespace
        self.enabled = enabled
    }

    func body(content: Content) -> some View {
        if enabled {
            content.matchedGeometryEffect(id: id, in: namespace)
        } else {
            content
        }
    }
}

/// A soft white light under the pointer, for a control that answers hover with
/// light instead of growth. It follows the pointer directly — only its arrival
/// and leaving fade. `aimed` holds it somewhere hover cannot, such as a file
/// dragged over the control, and `bright` raises it for that.
private struct HoverSpotlight: ViewModifier {
    let cornerRadius: CGFloat
    let reach: CGFloat
    let aimed: CGPoint?
    let bright: Bool
    /// The pointer, in the control's own bounds. Local to each control, so two
    /// lit controls cannot share one position.
    @State private var hover: CGPoint?

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    let spot = aimed ?? hover
                    let point = spot ?? CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    // Faint on purpose. At 24% the light read as a glow you
                    // were meant to look at; it only has to say "this is live".
                    // A file aimed here is the louder case, and still well
                    // under the old hover.
                    RadialGradient(
                        colors: [.white.opacity(bright ? 0.2 : 0.09), .white.opacity(0)],
                        center: UnitPoint(x: point.x / max(proxy.size.width, 1),
                                          y: point.y / max(proxy.size.height, 1)),
                        startRadius: 0,
                        endRadius: reach
                    )
                    .opacity(spot == nil ? 0 : 1)
                    .animation(.easeOut(duration: 0.18), value: spot == nil)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .allowsHitTesting(false)
            }
            // The edge does most of the work now: a hairline that comes up on
            // hover, the way a macOS control answers the pointer, with the
            // light only filling in under it.
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.white.opacity(hover == nil ? 0 : 0.14), lineWidth: 1)
                    .animation(.easeOut(duration: 0.18), value: hover == nil)
                    .allowsHitTesting(false)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hover = point
                case .ended: hover = nil
                }
            }
    }
}

extension View {
    func hoverSpotlight(cornerRadius: CGFloat, reach: CGFloat,
                        aimed: CGPoint? = nil, bright: Bool = false) -> some View {
        modifier(HoverSpotlight(cornerRadius: cornerRadius, reach: reach,
                                aimed: aimed, bright: bright))
    }
}

/// A page arrow that answers the pointer: hovered, it brightens, leans a
/// couple of points the way it would take you, and sits in a small circle.
/// The hit area stays the full-height 14pt strip, but only the circle is
/// drawn — a lit column the height of the slot read as one more empty tile
/// beside AirDrop. Dead arrows (one page) answer nothing.
private struct PageArrow: View {
    let step: Int
    let live: Bool
    let reduceMotion: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        let lit = hovered && live
        Button(action: action) {
            Image(systemName: step < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(live ? (lit ? 1 : 0.6) : 0.2))
                .frame(width: 20, height: 20)
                .background {
                    Circle()
                        .fill(.white.opacity(lit ? 0.12 : 0))
                        .scaleEffect(lit || reduceMotion ? 1 : 0.6)
                }
                .offset(x: lit && !reduceMotion ? CGFloat(step) * 2 : 0)
                // Drawn 20pt, laid out 14pt: the circle overhangs into the gap
                // beside it rather than widening the strip and moving the slot.
                .frame(width: 14)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: lit)
        }
        .buttonStyle(VitalsPressStyle(scales: false))
        // Disabled, `PressableChrome` gives it no hand, no hover and no press.
        .disabled(!live)
        .onHover { hovered = $0 }
        .accessibilityLabel(step < 0 ? "Previous page" : "Next page")
    }
}
