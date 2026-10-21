import AppKit
import SwiftUI

/// The panel's Meeting page: which call is live and the way back to it. A
/// feature page that only exists while a call does, and the one the panel opens
/// on then. The app tile and the room's name are one button — there is nothing
/// else to press, because the page's whole job is "take me back".
extension NotchView {

    var meetingPage: some View {
        Group {
            if let meeting = meetings.meeting {
                HStack(spacing: 10) {
                    MeetingLink(meeting: meeting, tile: meetingTile(meeting),
                                reduceMotion: reduceMotion) { meetings.returnToMeeting() }

                    meetingClock(since: meeting.startedAt)
                }
                .padding(.horizontal, 10)
            } else {
                // The page outlives the call by the moment it takes the panel
                // to notice; say what is true rather than go blank.
                VStack(spacing: 4) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 16, weight: .medium))
                    Text("No meeting")
                        .font(.system(size: 11, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// Meet has no app of its own, so its tile is the glyph on Meet's green;
    /// every other call wears its app's real icon.
    @ViewBuilder private func meetingTile(_ meeting: Meeting) -> some View {
        switch meeting.tile {
        case .meet:
            Image(systemName: "video.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.06, green: 0.43, blue: 0.34)))
        case .app:
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: meeting.iconBundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 42, height: 42)
            } else {
                Image(systemName: "headphones")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.12)))
            }
        }
    }

    /// The live dot and the time on the call. One clock, once a second, and only
    /// while this page is on screen.
    private func meetingClock(since start: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text(Self.clock(context.date.timeIntervalSince(start)))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
        }
    }
}

/// The tile and the room as one button. Hovered, the room underlines and a
/// return arrow slides in on its left — the answer to "what does this do". The
/// name moves over for it only while hovered, so at rest it still lines up
/// with the app's name above it.
private struct MeetingLink: View {
    let meeting: Meeting
    let tile: AnyView
    let reduceMotion: Bool
    let action: () -> Void

    @State private var hovered = false

    init<Tile: View>(meeting: Meeting, tile: Tile, reduceMotion: Bool,
                     action: @escaping () -> Void) {
        self.meeting = meeting
        self.tile = AnyView(tile)
        self.reduceMotion = reduceMotion
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                tile
                VStack(alignment: .leading, spacing: 3) {
                    Text(meeting.app)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                    HStack(spacing: 4) {
                        if hovered {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.7))
                                .transition(.move(edge: .leading).combined(with: .opacity))
                        }
                        Text(meeting.room)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .underline(hovered)
                    }
                }
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        }
        .buttonStyle(VitalsPressStyle(scales: false))
        .onHover { hovered = $0 }
        .help("Return to meeting")
        .accessibilityLabel("Return to \(meeting.app), \(meeting.room)")
    }
}
