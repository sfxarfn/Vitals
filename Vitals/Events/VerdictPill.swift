import SwiftUI

/// How a finished run in Xcode draws. An Event, not the tail of the Activity:
/// the build has already handed the notch back by the time this shows, so it
/// queues behind whatever is up and leaves on the Event clock.
///
/// The same grown shape as an agent turn: Xcode's own icon large on the left,
/// a tick as large on the right, and one line under the housing — "Succeeded -
/// 12m 23s". The outline glow is Xcode's blue, in `NotchView`. A failure keeps
/// the same shape and the same blue; the tick goes red and the line says Failed,
/// because colour on the glow would make two apps look like two outcomes.
extension NotchView {

    /// `ending` is non-nil in this state by construction; the `if let` is what
    /// says so without a second value on the case.
    @ViewBuilder func verdictPill(_ build: BuildProgress) -> some View {
        if let ending = build.ending {
            let glyph = metrics.agentGlyph
            let succeeded = ending == .succeeded
            ZStack(alignment: .bottom) {
                HStack(spacing: 0) {
                    buildIcon(build, size: glyph)
                        .frame(width: glyph, height: glyph)
                        // Hugging, the default: on the housing's edge, with
                        // `agentAir` left outboard. Same slot the agent mark uses.
                        .flankSlot(metrics.agentFlanks.left, .leading, pad: metrics.notchPad)
                    Spacer(minLength: 0).frame(width: metrics.notch.width)
                    Image(systemName: succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .resizable().scaledToFit()
                        .foregroundStyle(succeeded ? Color.green : .red)
                        .frame(width: glyph, height: glyph)
                        .flankSlot(metrics.agentFlanks.right, .trailing, pad: metrics.notchPad)
                }
                .frame(height: metrics.agentHeight)
                Text(verdictLine(ending, build.elapsed))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(.white.opacity(0.8))
                    // Under the housing, not across the glyphs. A long time
                    // shrinks to the dead space rather than running into the
                    // icon or the tick.
                    .frame(maxWidth: metrics.notch.width)
                    // Baseline, not the line box — see the agent pill. The same
                    // margin under the glyphs is the margin under this line.
                    .alignmentGuide(.bottom) { $0[.lastTextBaseline] + metrics.agentAir }
            }
            .frame(height: metrics.agentHeight)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(verdictLine(ending, build.elapsed))
        }
    }

    /// "Succeeded - 12m 23s". Seconds under a minute, minutes and seconds under
    /// an hour, then hours and minutes — past that the seconds are not the news.
    /// No elapsed time at all when the run's start was never seen, rather than
    /// a zero that would say the build took nothing.
    private func verdictLine(_ ending: BuildProgress.Ending, _ elapsed: TimeInterval?) -> String {
        let word = ending == .succeeded ? "Succeeded" : "Failed"
        guard let elapsed else { return word }
        return "\(word) - \(Self.verdictDuration(elapsed))"
    }

    private static func verdictDuration(_ seconds: TimeInterval) -> String {
        let t = max(Int(seconds.rounded()), 0)
        if t < 60 { return "\(t)s" }
        if t < 3600 {
            let m = t / 60, s = t % 60
            return s == 0 ? "\(m)m" : "\(m)m \(s)s"
        }
        let h = t / 3600, m = (t % 3600) / 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}
