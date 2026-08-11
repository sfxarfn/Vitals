import SwiftUI

enum NotchMode: Equatable {
    case idle
    case event(Signal)
    case accessory(Accessory)
    case expanded
}

struct NotchMetrics {
    /// Physical notch, measured from the screen's auxiliary areas.
    var notch: CGSize
    /// Q5: symmetric pill, capped so it only reaches the tail of the menus.
    var pillWidth: CGFloat = 440
    var panelWidth: CGFloat = 540
    var panelBodyHeight: CGFloat = 94
    /// The accessory pill only carries a glyph and a ring, so it stops well
    /// short of the event pill's width.
    var accessoryFlank: CGFloat = 62

    func size(for mode: NotchMode) -> CGSize {
        switch mode {
        case .idle:      notch
        case .event:     CGSize(width: pillWidth, height: notch.height)
        case .accessory: CGSize(width: notch.width + accessoryFlank * 2, height: notch.height)
        case .expanded:  CGSize(width: panelWidth, height: notch.height + panelBodyHeight)
        }
    }

    /// The window is sized once to the largest state; everything else insets into
    /// it. The slack has to cover the shape's top flare on both sides *and* the
    /// ambient shadow past it — radius 24 blurs ~36pt out, plus its 12pt drop.
    var windowSize: CGSize {
        CGSize(width: max(pillWidth, panelWidth) + 160, height: notch.height + panelBodyHeight + 72)
    }
}

struct NotchView: View {
    let mode: NotchMode
    let metrics: NotchMetrics
    let shelf: Shelf
    /// Sends via AirDrop, anchored on the panel's own NSView for the fallback
    /// share sheet — the controller owns the window, so it owns that call.
    let airDrop: ([URL]) -> Void

    @State private var shelfTargeted = false
    @State private var airDropTargeted = false
    @State private var settingsHovered = false

    private var size: CGSize { metrics.size(for: mode) }
    private var lifted: Bool { mode != .idle }
    private let topRadius: CGFloat = 22
    private let bottomRadius: CGFloat = 28

    private var shape: NotchShape {
        NotchShape(topCornerRadius: topRadius,
                   bottomCornerRadius: mode == .idle ? 10 : bottomRadius)
    }

    var body: some View {
        VStack(spacing: 0) {
            // The sized box is its own stable view — a Color, not the mode
            // switch. Hanging the frame off `content` instead makes the whole
            // thing change identity on every mode change, and SwiftUI hard-cuts
            // to the new size and only cross-fades. This way the frame
            // interpolates and the box actually grows and shrinks.
            Color.clear
                // The shape flares outward by topRadius per side, so the
                // body lines up with the notch only if the frame is wider.
                .frame(width: size.width + topRadius * 2, height: size.height)
                // Opaque black in every mode so the panel reads as an
                // extension of the bezel instead of showing the desktop
                // through it.
                .background(shape.fill(.black))
                .overlay(alignment: .top) { content.frame(width: size.width) }
                // Content is laid out at its final size the instant the mode
                // flips; the clip is what makes it get revealed by the growing
                // shape rather than spilling outside it mid-morph.
                .clipShape(shape)
                // Grown states lift off the bezel; idle is flush with it, so no
                // shadow there. Two layers, the way glass casts: a tight contact
                // shadow at the edge plus a wide diffuse ambient one. Radii and
                // opacities interpolate with the morph.
                .shadow(color: .black.opacity(lifted ? 0.55 : 0),
                        radius: lifted ? 6 : 0, y: lifted ? 3 : 0)
                .shadow(color: .black.opacity(lifted ? 0.35 : 0),
                        radius: lifted ? 24 : 0, y: lifted ? 12 : 0)
            Spacer(minLength: 0)
        }
        .frame(width: metrics.windowSize.width, height: metrics.windowSize.height, alignment: .top)
        .animation(.bouncy(duration: 0.45, extraBounce: 0.12), value: mode)
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .idle:
            EmptyView()
        case .event(let signal):
            // Anything behind the camera housing is invisible, so the pill puts
            // its glyph and label in the two flanks and leaves the middle empty.
            HStack(spacing: 0) {
                Image(systemName: signal.symbol)
                    .foregroundStyle(signal.tint)
                    .frame(width: flank)
                Spacer(minLength: 0).frame(width: metrics.notch.width)
                Text(signal.title)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(.white)
                    .frame(width: flank)
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .frame(height: metrics.notch.height)
            .transition(.opacity)
        case .accessory(let accessory):
            // Same two-flank trick as the event pill: the camera housing owns
            // the middle, so the glyph and the ring take a side each.
            HStack(spacing: 0) {
                Image(systemName: accessory.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: metrics.accessoryFlank)
                Spacer(minLength: 0).frame(width: metrics.notch.width)
                batteryRing(accessory).frame(width: metrics.accessoryFlank)
            }
            .frame(height: metrics.notch.height)
            .transition(.opacity)
        case .expanded:
            VStack(spacing: 0) {
                // Camera housing row — anything under it is invisible, so the
                // gear sits in the right flank beside it.
                Color.clear.frame(height: metrics.notch.height)
                    .overlay(alignment: .trailing) { settingsButton }
                HStack(spacing: 12) {
                    airDropTile
                    shelfBox
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
            // Content fades in behind the shape rather than appearing at full
            // opacity the instant the geometry starts moving.
            .transition(.opacity.animation(.easeOut(duration: 0.28).delay(0.06)))
        }
    }

    private var flank: CGFloat { (metrics.pillWidth - metrics.notch.width) / 2 }

    /// Nothing is drawn for a device that never reported a level — an empty
    /// ring would read as a flat battery.
    @ViewBuilder private func batteryRing(_ accessory: Accessory) -> some View {
        if let level = accessory.battery {
            ZStack {
                Circle().stroke(.white.opacity(0.18), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0.03, Double(level) / 100))
                    .stroke(accessory.batteryTint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 20, height: 20)
        }
    }

    private var settingsButton: some View {
        SettingsLink {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(settingsHovered ? 0.9 : 0.45))
        }
        .buttonStyle(.plain)
        .padding(.trailing, 14)
        .onHover { settingsHovered = $0 }
        .animation(.snappy(duration: 0.15), value: settingsHovered)
    }

    // MARK: Shelf

    /// Drop straight on the tile to send those files; click it to send whatever
    /// is already sitting in the box.
    private var airDropTile: some View {
        VStack(spacing: 4) {
            Image(systemName: "dot.radiowaves.up.forward")
                .font(.system(size: 17, weight: .medium))
            Text("AirDrop").font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.white)
        .frame(width: 104).frame(maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [.blue, .purple],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .brightness(airDropTargeted ? 0.12 : 0)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { airDrop(shelf.urls) }
        .dropDestination(for: URL.self) { urls, _ in
            airDrop(urls)
            return true
        } isTargeted: { airDropTargeted = $0 }
        .scaleEffect(airDropTargeted ? 1.04 : 1)
        .animation(.snappy(duration: 0.18), value: airDropTargeted)
    }

    private var shelfBox: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                if shelf.urls.isEmpty {
                    Text("Drop files here")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(shelf.urls, id: \.self, content: item)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(shelfTargeted ? 0.55 : 0.2),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }
        .dropDestination(for: URL.self) { urls, _ in
            shelf.add(urls)
            return true
        } isTargeted: { shelfTargeted = $0 }
        .animation(.snappy(duration: 0.18), value: shelfTargeted)
        .contextMenu {
            Button("Clear shelf") { shelf.clear() }.disabled(shelf.urls.isEmpty)
        }
    }

    private func item(_ url: URL) -> some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 30, height: 30)
            Text(url.lastPathComponent)
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1).truncationMode(.middle)
                .frame(width: 68)
        }
        // Dragging an item out is the way files leave the box; the copy stays
        // put until it is removed by hand or the app quits.
        .draggable(url)
        .contextMenu {
            Button("Remove") { shelf.remove(url) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}
