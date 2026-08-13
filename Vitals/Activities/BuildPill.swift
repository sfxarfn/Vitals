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
    func buildPill(_ build: XcodeBuildActivity) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 1) {
                buildIcon(build)
                Text(build.label)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .offset(x: build.progress == nil ? 4 : 0)
            // Balanced on the outer edges, not the inner ones. The counter and
            // its ring opposite are ~14pt wider than this stack, so the wide
            // side goes flush against the housing and this one floats — which
            // lands both blocks the same distance off the bezel. Equalising the
            // inner gaps instead would leave the outer ones 14pt apart, and
            // those are the two edges the eye lines up here.
            .flankSlot(build.progress == nil ? metrics.verdictFlanks.left : metrics.statFlanks.left,
                       .leading, pad: metrics.notchPad, centered: true)
            Spacer(minLength: 0).frame(width: metrics.notch.width)
            Group {
                if let progress = build.progress {
                    HStack(spacing: 5) {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("\(progress.done)")
                            Text("\(progress.total)")
                        }
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .foregroundStyle(.white.opacity(0.85))
                        ring(progress.fraction, tint: .blue)
                    }
                } else {
                    VStack(spacing: 1) {
                        XcodeBuildSpinner()
                        Text("Progress")
                            .font(.system(size: 8, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            .animation(.easeOut(duration: 0.2), value: build.progress != nil)
            .offset(x: build.progress == nil ? 4 : 0)
            // Flush, where every other flank keeps `notchPad`. This is the wide
            // side of the pair described opposite: it goes all the way in so the
            // narrow side's float can bring both outer edges level.
            .flankSlot(build.progress == nil ? metrics.verdictFlanks.right : metrics.statFlanks.right,
                       .trailing, pad: 0)
        }
        .frame(height: metrics.notch.height)
    }

    /// The real Xcode icon from either the running app or its installed bundle;
    /// a hammer only when neither source is available.
    /// 20pt in both pills: the stack under it is a word either way, and 20 + the
    /// 8pt line is what clears the notch's own height with a point to spare.
    ///
    /// Not private: the verdict Event draws the same icon, and the two pills
    /// live in different categories now.
    @ViewBuilder func buildIcon(_ build: XcodeBuildActivity, size: CGFloat = 20) -> some View {
        if let icon = build.icon {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "hammer.fill")
                .font(.system(size: size * 0.8, weight: .medium))
                .foregroundStyle(.white)
                .frame(height: size)
        }
    }

    /// Verdicts still carry the final `BuildProgress` directly.
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

/// A ring in the same 20pt footprint as determinate build progress. Only the
/// arc turns: a long-running Activity should not pulse the whole notch.
private struct XcodeBuildSpinner: View {
    @State private var rotation = 0.0

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.72)
            .stroke(.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(rotation - 90))
            .frame(width: 20, height: 20)
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}
