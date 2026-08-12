import SwiftUI

extension NotchView {
    /// An explicit Activity has no inferred counter to pretend is progress. Its
    /// right flank says only that the lifecycle is still open; the command that
    /// started it is the command that eventually removes it.
    func externalActivityPill(_ activity: ExternalActivity) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 1) {
                Image(systemName: activity.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(height: 20)
                Text(activity.title)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .flankSlot(metrics.statFlanks.left, .leading,
                       pad: metrics.notchPad, centered: true)
            Spacer(minLength: 0).frame(width: metrics.notch.width)
            VStack(spacing: 1) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.blue)
                    .frame(height: 20)
                Text("Running")
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            }
            // The spinner is much lighter than the filled process glyph, so a
            // centred slot settles the pair better than pinning both inward.
            .flankSlot(metrics.statFlanks.right, .trailing,
                       pad: metrics.notchPad, centered: true)
        }
        .frame(height: metrics.notch.height)
    }
}
