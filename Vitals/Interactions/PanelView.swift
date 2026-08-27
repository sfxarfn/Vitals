import SwiftUI

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
        // drag has no way to know are up. The AirDrop tile
        // and the box only override what happens inside their own bounds.
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            shelf.add(urls)
            panelBody = .shelf
            return true
        } isTargeted: { shelfTargeted = $0 }
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
            .foregroundStyle(.white.opacity(backHovered ? 0.9 : 0.45))
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { backHovered = $0 }
        .animation(.snappy(duration: 0.15), value: backHovered)
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
                        .foregroundStyle(.white.opacity(clearHovered ? 0.9 : 0.45))
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .onHover { clearHovered = $0 }
                .animation(.snappy(duration: 0.15), value: clearHovered)
                .transition(.opacity)
            }
            SettingsLink {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(.white.opacity(settingsHovered ? 0.9 : 0.45))
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { settingsHovered = $0 }
            .animation(.snappy(duration: 0.15), value: settingsHovered)
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
        // The scroll view is transparent, so without a shape of its own only
        // the placeholder text and the item icons take a drop — the empty
        // slack around them falls through.
        .contentShape(RoundedRectangle(cornerRadius: 14))
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
        // Dragging an item out is the way files leave the box, so the box lets
        // go of it once the drag lands somewhere. Only the shelf entry goes —
        // the drag itself is a copy, so the file stays wherever it came from.
        .draggable(url)
        .onDragSessionUpdated { session in
            guard case .ended(let operation) = session.phase else { return }
            // A drag that was called off, or refused by what it landed on, has
            // to leave the shelf exactly as it found it.
            switch operation {
            case .cancel, .forbidden: break
            // The callback is not declared on the main actor, but AppKit only
            // ever ends a drag session there — same reason the controller's
            // timers assume it.
            default: MainActor.assumeIsolated { shelf.remove(url) }
            }
        }
        .contextMenu {
            Button("Remove") { shelf.remove(url) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}
