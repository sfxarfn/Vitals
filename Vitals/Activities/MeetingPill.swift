import AppKit
import SwiftUI

extension NotchView {
    /// The call's own app: Meet has no app of its own, so it is a video glyph;
    /// every other call wears its app's real icon, so a glance says which one.
    @ViewBuilder private func callMark(_ meeting: Meeting) -> some View {
        switch meeting.tile {
        case .meet:
            Image(systemName: "video.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
        case .app:
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: meeting.iconBundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .clipShape(RoundedRectangle(cornerRadius: 4.5))
            } else {
                Image(systemName: "headphones")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    /// A live call. The glyph says what, the green dot on its corner says it is
    /// live, and the clock says how long — all a glance needs, and nothing that
    /// could be wrong: the microphone's mute state cannot be read, so none is
    /// drawn.
    ///
    /// The time is coarse on purpose: seconds for the first minute, minutes to
    /// the hour, then whole hours — and it only redraws when that text changes,
    /// so a long call ticks once an hour, not once a second.
    func meetingPill(_ meeting: Meeting) -> some View {
        HStack(spacing: 0) {
            callMark(meeting)
                .frame(width: 20, height: 20)
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(Color.green).frame(width: 6, height: 6).offset(x: 2, y: 2)
                }
                // Centred, not hugged: halfway between the bezel and the housing
                // reads as set, where a glyph pinned to the housing opposite a
                // clock reads as leaning on it. Balanced against the clock, which
                // hugs its own side.
                .flankSlot(metrics.meetingFlanks.left, .leading,
                           pad: metrics.notchPad, centered: true)
            Spacer(minLength: 0).frame(width: metrics.notch.width)
            TimelineView(MeetingClockSchedule(start: meeting.startedAt)) { context in
                Text(Self.compactDuration(context.date.timeIntervalSince(meeting.startedAt)))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(.white)
            }
            .flankSlot(metrics.meetingFlanks.right, .trailing, pad: metrics.notchPad)
        }
        .frame(height: metrics.notch.height)
        .accessibilityLabel("\(meeting.app) in progress")
    }
}

extension NotchView {
    /// "42s", "1m", "15m", "1h+", "12h+": seconds under a minute, whole minutes
    /// under an hour, then whole hours with a "+" — past that it is "a long
    /// call", and the minute it is on is not what the notch is for.
    static func compactDuration(_ seconds: TimeInterval) -> String {
        let t = max(Int(seconds), 0)
        if t < 60 { return "\(t)s" }
        if t < 3600 { return "\(t / 60)m" }
        return "\(t / 3600)h+"
    }
}

/// Fires only when `compactDuration` would read differently: every second for
/// the first minute, every minute to the hour, every hour after. The small
/// offset keeps a tick from landing a hair before its boundary and reading the
/// old value for another interval.
private struct MeetingClockSchedule: TimelineSchedule {
    let start: Date

    func entries(from startDate: Date, mode: Mode) -> some Sequence<Date> {
        sequence(first: startDate) { date in
            let elapsed = max(date.timeIntervalSince(start), 0)
            let step: Double = elapsed < 60 ? 1 : (elapsed < 3600 ? 60 : 3600)
            return start.addingTimeInterval((elapsed / step).rounded(.down) * step + step + 0.05)
        }
    }
}
