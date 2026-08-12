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
                    // Two circles, same size and same metrics `buildIcon` draws
                    // Xcode's own icon at, so the flanks stay a matched pair —
                    // but the mark inside them differs, because colour on its
                    // own is the wrong channel for this. The pill lives 2.6s in
                    // the corner of your eye, where shape resolves and hue does
                    // not, and the word underneath scales to 5pt before it gives
                    // up. A hammer for both would have left the two endings
                    // separated by nothing you can see from there.
                    Image(systemName: ending == .succeeded ? "checkmark.circle.fill"
                                                           : "xmark.circle.fill")
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
                // Centred like the left, then pulled two points back toward the
                // housing. The two stacks measure the same but do not weigh the
                // same: Xcode's icon is a filled colour square and this is a
                // thin ring, so centring both leaves the lighter side reading as
                // if it had drifted outward. Two points is what settles it.
                .offset(x: -2)
                .flankSlot(metrics.verdictFlanks.right, .trailing, pad: metrics.notchPad, centered: true)
            }
            .frame(height: metrics.notch.height)
        }
    }
}
