import SwiftUI

extension NotchView {
    /// A live call. The glyph says what, the green dot on its corner says it is
    /// live, and the clock says how long — all a glance needs, and nothing that could be
    /// wrong: the microphone's mute state cannot be read, so none is drawn.
    ///
    /// One clock, once a second, only while this state is the resting notch.
    func meetingPill(_ meeting: Meeting) -> some View {
        HStack(spacing: 0) {
            Image(systemName: "video.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
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
            TimelineView(.periodic(from: meeting.startedAt, by: 1)) { context in
                Text(Self.clock(context.date.timeIntervalSince(meeting.startedAt)))
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
