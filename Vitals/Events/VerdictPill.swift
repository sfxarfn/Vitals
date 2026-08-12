import SwiftUI

/// How a finished run in Xcode draws. An Event, not the tail of the Activity:
/// the build has already handed the notch back by the time this shows, so it
/// queues behind whatever is up and leaves on the Event clock.
extension NotchView {

    /// How the run ended, and what ended. A finished counter is stale the moment
    /// it stops moving, so the verdict takes the slot it leaves on the right and
    /// the left goes on naming the work — two stacks of a glyph over a word,
    /// reading across the housing as "Archive · Failed".
    ///
    /// `ending` is non-nil in this state by construction; the `if let` is what
    /// says so without a second value on the case.
    @ViewBuilder func verdictPill(_ build: BuildProgress) -> some View {
        if let ending = build.ending {
            HStack(spacing: 0) {
                // The noun, not the label — the verdict opposite says only how
                // the run ended, so this is the only thing naming the work.
                VStack(spacing: 1) {
                    buildIcon(build)
                    Text(build.job)
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .foregroundStyle(.white)
                }
                // Centred, not hugging — see the far flank for why both sides are.
                .flankSlot(metrics.verdictFlanks.left, .leading, pad: metrics.notchPad, centered: true)
                Spacer(minLength: 0).frame(width: metrics.notch.width)
                // The same stack the running pill puts in its *left* flank,
                // moved across: the counter's slot is free now, and the verdict
                // reads as the thing that replaced it rather than a new
                // arrangement. Colour is the glyph's job — the word stays white,
                // so which kind of ending it was and what ended are two separate
                // reads.
                VStack(spacing: 1) {
                    // One hammer for both endings, at the size and metrics
                    // `buildIcon` draws Xcode's own icon at — the two flanks are
                    // a matched pair of glyph-over-word, and swapping the shape
                    // as well as the colour made them read as two arrangements.
                    // Colour is the only thing separating a good run from a bad
                    // one, which is the one difference worth carrying.
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(ending == .succeeded ? Color.green : .red)
                        .frame(height: 20)
                    // One of two verdicts off the watcher — "Success" or
                    // "Failed" — never the job, which the noun opposite is
                    // already saying.
                    Text(build.label)
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .foregroundStyle(.white)
                }
                // Centred like the left, now that the two flanks hold the same
                // shape at the same size: a matched pair sits evenly set, and
                // pinning either one against the housing is what would make the
                // outer gaps disagree.
                .flankSlot(metrics.verdictFlanks.right, .trailing, pad: metrics.notchPad, centered: true)
            }
            .frame(height: metrics.notch.height)
        }
    }
}
