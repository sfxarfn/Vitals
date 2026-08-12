import SwiftUI

/// How the one Activity draws. Unlike an Event it is not passing through: it
/// replaces idle as the resting state and holds for the whole build, which is
/// why it stays one row tall and never grows the notch while you work.
extension NotchView {

    /// One row, both flanks stacked: what is running on the left, how far in on
    /// the right. Everything shrinks to fit the notch's own height rather than
    /// growing the pill for the length of a build.
    ///
    /// How the run *ended* is not drawn here — that is an Event, and it lives in
    /// `VerdictPill.swift` with the rest of them.
    func buildPill(_ build: BuildProgress) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 1) {
                buildIcon(build)
                Text(build.label)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .foregroundStyle(.white.opacity(0.85))
            }
            // Centred like the verdict's, and for the same reason: the counter
            // and its ring opposite are wider than a verb, so hugging both
            // leaves this side with the bigger outer gap.
            .flankSlot(metrics.statFlanks.left, .leading, pad: metrics.notchPad, centered: true)
            Spacer(minLength: 0).frame(width: metrics.notch.width)
            HStack(spacing: 5) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(build.done)")
                    Text("\(build.total)")
                }
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(.white.opacity(0.85))
                ring(build.fraction, tint: .blue)
            }
            // Flush against the housing, where every other flank keeps
            // `notchPad`. What hugs the notch here is a two-line number stack at
            // 9pt, and a pair of short rows reads as further out than a single
            // 12pt row at the same gap — the ring on the far end is also
            // pulling the eye outward. Giving the pad back is what puts the
            // counter next to the housing instead of adrift beside it.
            .flankSlot(metrics.statFlanks.right, .trailing, pad: 0)
        }
        .frame(height: metrics.notch.height)
    }

    /// The real Xcode icon when the watcher caught it, a hammer when the
    /// Accessibility grant is missing and there is nothing to copy it from.
    /// 20pt in both pills: the stack under it is a word either way, and 20 + the
    /// 8pt line is what clears the notch's own height with a point to spare.
    ///
    /// Not private: the verdict Event draws the same icon, and the two pills
    /// live in different categories now.
    @ViewBuilder func buildIcon(_ build: BuildProgress, size: CGFloat = 20) -> some View {
        if let icon = build.icon {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "hammer.fill")
                .font(.system(size: size * 0.8, weight: .medium))
                .foregroundStyle(.white)
                .frame(height: size)
        }
    }
}
