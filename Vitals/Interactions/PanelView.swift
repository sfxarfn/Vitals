import SwiftUI
import UniformTypeIdentifiers

/// What sits in the panel's one body slot. The panel's geometry never changes
/// with it: the row swaps what it holds, the shape stays the one peek grew into.
/// Each readout is reached from the thing in peek that summarises it — the
/// battery line, the left flank's degree — so the panel is always the second
/// half of a glance you already took.
enum PanelBody { case shelf, battery, thermal, network }

/// The panel: peek opened downward into a surface you can work in. One body
/// slot, four things that can sit in it — the shelf, the battery numbers, the
/// die behind peek's one rounded degree, or the link behind its two rates.
extension NotchView {

    // MARK: Body

    var panelContent: some View {
        VStack(spacing: 0) {
            // Camera housing row — anything under it is invisible, so the
            // back button and the gear take a flank each beside it.
            Color.clear.frame(height: metrics.notch.height)
                .overlay(alignment: .leading) { backButton.padding(.leading, 14) }
                .overlay(alignment: .trailing) { settingsButton().padding(.trailing, 14) }
            // One slot, four contents — what put you here swaps the row, never
            // the panel's geometry.
            Group {
                switch panelBody {
                case .shelf:
                    HStack(spacing: 12) {
                        airDropTile
                        shelfBox
                    }
                case .battery: batteryPanel
                case .thermal: thermalPanel
                case .network: networkPanel
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .animation(.snappy(duration: 0.2), value: panelBody)
        }
        // Aiming a file at a 14pt-inset box is darts. The whole open panel
        // takes a drop — the housing row, the padding, and the readout rows the
        // drag has no way to know are up. The AirDrop tile overrides what
        // happens inside its own bounds. The delegate, not `dropDestination`,
        // because the silhouette has to follow the pointer the whole way in.
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], delegate: ShelfFileDrop(
            onMove: { point in
                if !shelfTargeted { shelfTargeted = true }
                followDrag(point)
            },
            onExit: { releaseDragAim() },
            onPerform: { urls, point in catchOnShelf(urls, at: point) }
        ))
        .overlay {
            if let ripplePoint, !reduceMotion {
                ShelfRipple(point: ripplePoint, token: rippleToken) { finished in
                    if rippleToken == finished { ripplePoint = nil }
                }
                .id(rippleToken)
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: Controls

    /// Shrinks the panel back to the peek it grew out of rather than closing it
    /// outright — leaving the pointer where it is, on a shape that is still live.
    private var backButton: some View {
        Button { show(.peek) } label: {
            HStack(spacing: 2) {
                Image(systemName: "chevron.left")
                Text("Back")
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.55))
        }
        .buttonStyle(.plain)
        .vitalsPressable()
    }

    private func settingsButton(size: CGFloat = 12) -> some View {
        HStack(spacing: size * 0.4) {
            // Emptying the box is the only thing the shelf needs a button for —
            // the battery and the die are both reached from the peek line that
            // summarises them, so a second way in bought nothing. Present only
            // while there is something to clear, so the flank is not a dead
            // glyph on an empty tray.
            if panelBody == .shelf, !shelf.urls.isEmpty {
                Button { shelf.clear() } label: {
                    Image(systemName: "trash")
                        .font(.system(size: size, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .vitalsPressable()
                .transition(.opacity)
            }
            SettingsLink {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .vitalsPressable()
        }
    }

    // MARK: Shelf

    /// Drop straight on the tile to send those files; click it to send whatever
    /// is already sitting in the box.
    private var airDropTile: some View {
        VStack(spacing: 4) {
            AirDropMark()
                .stroke(.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: 18, height: 18)
            Text("AirDrop").font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.white)
        .frame(width: 104).frame(maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [.blue, .purple],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .brightness(airDropTargeted ? 0.16 : 0)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(airDropTargeted ? 0.75 : 0), lineWidth: 1.5)
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { airDrop(shelf.urls) }
        .vitalsPressable()
        .onDrop(of: [.fileURL], delegate: ShelfFileDrop(
            onMove: { point in
                if !airDropTargeted { airDropTargeted = true }
                followDrag(point)
            },
            onExit: {
                airDropTargeted = false
                if !shelfTargeted {
                    dragLean = 0
                    endFileDrag()
                }
            },
            onPerform: { urls, _ in catchAirDrop(urls) }
        ))
        .scaleEffect(reduceMotion ? 1 : (airDropTargeted ? 1.06 : 1))
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
                .fill(.white.opacity(landFlash ? 0.16 : shelfTargeted ? 0.11 : 0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(landFlash ? 0.95 : shelfTargeted ? 0.75 : 0.2),
                              style: StrokeStyle(lineWidth: shelfTargeted || landFlash ? 2 : 1.5,
                                                 dash: shelfTargeted ? [] : [6, 4]))
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
        let magnet = shelfTargeted && !lifted && !reduceMotion ? Double(dragLean) * 3.5 : 0
        let freshBefore = shelf.urls.prefix(index).filter { freshURLs.contains($0) }.count
        return ShelfChip(
            url: url,
            fresh: fresh,
            reduceMotion: reduceMotion,
            lifted: lifted,
            tilt: lifted ? liftTilt : magnet,
            delay: fresh ? Double(freshBefore) * 0.045 : 0,
            onSession: { noteDrag(url, $0) },
            onSettled: { freshURLs.remove(url) },
            onRemove: { withAnimation(shelfPop) { shelf.remove(url) } },
            onReveal: { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        )
    }
}
