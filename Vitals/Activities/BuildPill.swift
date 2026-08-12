import SwiftUI

/// How the one Activity draws. Unlike an Event it is not passing through: it
/// replaces idle as the resting state and holds for the whole build, which is
/// why it stays one row tall and never grows the notch while you work.
extension NotchView {

    // MARK: Build in progress

    /// One row, both flanks stacked: what is running on the left, how far in on
    /// the right. Everything shrinks to fit the notch's own height rather than
    /// growing the pill for the length of a build.
    func buildPill(_ build: BuildProgress) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 1) {
                buildIcon(build)
                Text(build.label)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .flankSlot(metrics.wideFlank, .leading, pad: metrics.notchPad)
            Spacer(minLength: 0).frame(width: metrics.notch.width)
            // A finished run's counter is stale the moment it stops moving, so
            // the whole right flank becomes the verdict instead. `product.md`
            // files the verdicts under Events, not here — for now they ride out
            // the Activity they belong to.
            Group {
                if let ending = build.ending {
                    Image(systemName: ending == .succeeded ? "checkmark.circle.fill" : "hammer.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(ending == .succeeded ? Color.green : .red)
                } else {
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
                }
            }
            .flankSlot(metrics.wideFlank, .trailing, pad: metrics.notchPad)
        }
        .frame(height: metrics.notch.height)
    }

    /// The real Xcode icon when the watcher caught it, a hammer when the
    /// Accessibility grant is missing and there is nothing to copy it from.
    /// 16pt, not the accessory glyph's 20 — the label stacks under it and the
    /// pair has to clear the notch's own height.
    @ViewBuilder private func buildIcon(_ build: BuildProgress) -> some View {
        if let icon = build.icon {
            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: "hammer.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .frame(height: 16)
        }
    }
}
