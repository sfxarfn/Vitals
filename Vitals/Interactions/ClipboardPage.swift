import AppKit
import SwiftUI

/// The panel's Clipboard page: the latest copy in a card a third of the slot
/// wide, the three before it as rows in the other two thirds. The rows get the
/// width because they are the ones you came for — the latest copy is already
/// on the clipboard, and its card is mostly there to say what that is.
///
/// A press pastes into the app you were typing in and closes the panel; ⌥ copies
/// only and leaves it open. Nothing reorders on a press: the check moves to the
/// row you pressed, and the row stays under the pointer.
extension NotchView {

    var clipboardPage: some View {
        Group {
            if let latest = clipboard.clips.first {
                // Ages tick at minute grain; half a minute keeps "now" honest
                // without a per-second redraw of the whole page.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    GeometryReader { geo in
                        HStack(spacing: 4) {
                            ClipButton(clip: latest, action: pressClip) {
                                latestCard(latest, at: context.date)
                            }
                            // An exact third, not a layout priority: the card
                            // must not widen when the copy is long.
                            .frame(width: (geo.size.width - 4) / 3)

                            VStack(spacing: 1) {
                                ForEach(clipboard.clips.dropFirst().prefix(3)) { clip in
                                    ClipButton(clip: clip, action: pressClip) {
                                        clipRow(clip, at: context.date)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        }
                    }
                    .padding(4)
                }
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "clipboard")
                        .font(.system(size: 16, weight: .medium))
                    Text("Nothing copied")
                        .font(.system(size: 11, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Press

    /// Read at click time, not tracked: ⌥ is a per-press choice. Without the
    /// grant, or with a password field focused, a press can only copy — the
    /// panel then stays open, since nothing happened behind it to look at.
    private func pressClip(_ clip: Clip) {
        clipboard.restore(clip)
        let copyOnly = NSEvent.modifierFlags.contains(.option)
        guard !copyOnly, clipboard.canPaste else { return }
        NotchController.shared?.shrink()
        clipboard.pasteSoon()
    }

    // MARK: Card and rows

    private func latestCard(_ clip: Clip, at now: Date) -> some View {
        // The header row is squeezed to 12pt and the gaps to 2 so the copy gets
        // its third line; at the rows' 16pt header the card only fit two.
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                clipGlyph(clip)
                Spacer(minLength: 0)
                clipAge(clip, at: now)
            }
            .frame(height: 12)
            if let thumb = clip.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(clip.preview)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
    }

    private func clipRow(_ clip: Clip, at now: Date) -> some View {
        HStack(spacing: 6) {
            if let thumb = clip.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                clipGlyph(clip)
            }
            Text(clip.preview)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            clipAge(clip, at: now)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .frame(height: 22)
    }

    private func clipGlyph(_ clip: Clip) -> some View {
        let symbol = switch clip.kind {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        }
        return Image(systemName: symbol)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.white.opacity(0.6))
        .frame(width: 16, height: 16)
    }

    /// The age, or the check on whichever clip a paste would give you now.
    /// Same slot for both, sized to the widest age, so the text beside it does
    /// not shift when the check arrives.
    private func clipAge(_ clip: Clip, at now: Date) -> some View {
        Group {
            if clip.id == clipboard.liveID {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.green)
                    .accessibilityLabel("On the clipboard")
            } else {
                Text(Self.age(now.timeIntervalSince(clip.copiedAt)))
                    .font(.system(size: 10, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(width: 22, alignment: .trailing)
    }

    /// "now", "4m", "3h", "2d" — the least ink that still orders the rows.
    static func age(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: "now"
        case ..<3600: "\(Int(seconds / 60))m"
        case ..<86_400: "\(Int(seconds / 3600))h"
        default: "\(Int(seconds / 86_400))d"
        }
    }
}

/// One clip as a button, with the readout tiles' hover light.
private struct ClipButton<Label: View>: View {
    let clip: Clip
    let action: (Clip) -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button { action(clip) } label: {
            label()
                .hoverSpotlight(cornerRadius: 10, reach: 34)
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(VitalsPressStyle(scales: false))
        .help("Paste · ⌥ to copy only")
        .accessibilityLabel("Paste \(clip.preview)")
        .accessibilityHint("Option-click copies without pasting")
    }
}
