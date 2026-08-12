import SwiftUI

/// What sits in the panel's one body slot. The panel's geometry never changes
/// with it: the row swaps what it holds, the shape stays the one peek grew into.
/// Each readout is reached from the thing in peek that summarises it — the
/// battery line, the left flank's degree — so the panel is always the second
/// half of a glance you already took.
enum PanelBody { case shelf, battery, thermal }

/// The panel: peek opened downward into a surface you can work in. One body
/// slot, three things that can sit in it — the shelf, the battery numbers, or
/// the die behind peek's one rounded degree.
extension NotchView {

    // MARK: Body

    var panelContent: some View {
        VStack(spacing: 0) {
            // Camera housing row — anything under it is invisible, so the
            // back button and the gear take a flank each beside it.
            Color.clear.frame(height: metrics.notch.height)
                .overlay(alignment: .leading) { backButton.padding(.leading, 14) }
                .overlay(alignment: .trailing) { settingsButton().padding(.trailing, 14) }
            // One slot, three contents — what put you here swaps the row, never
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
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .animation(.snappy(duration: 0.2), value: panelBody)
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
            .foregroundStyle(.white.opacity(backHovered ? 0.9 : 0.45))
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { backHovered = $0 }
        .animation(.snappy(duration: 0.15), value: backHovered)
    }

    private func settingsButton(size: CGFloat = 12) -> some View {
        HStack(spacing: size * 0.4) {
            // Charge reads off how full the glyph is, not a number — the pill
            // already carries the percentage when it is worth interrupting for.
            // Pressing it swaps the panel's row over to the numbers.
            Button { panelBody = panelBody == .battery ? .shelf : .battery } label: {
                Image(systemName: telemetry.power.isCharging
                      ? "battery.100percent.bolt"
                      : "battery.\(batteryStep)percent")
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(.white.opacity(panelBody == .battery || batteryHovered ? 0.9 : 0.45))
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { batteryHovered = $0 }
            .animation(.snappy(duration: 0.15), value: batteryHovered)
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
