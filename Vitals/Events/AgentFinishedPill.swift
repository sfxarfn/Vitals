import SwiftUI

/// Which coding agent stopped, and when. `at` keeps two finishes of the same
/// agent from comparing equal — the dismiss timer only takes down the state it
/// was armed for.
struct AgentFinish: Equatable {
    enum Agent: String {
        case claude, cursor
    }

    var agent: Agent
    var at: Date = .now

    var name: String { agent == .claude ? "Claude" : "Cursor" }

    /// Who finished, said in light: Claude's own orange, and silver for Cursor,
    /// whose mark is monochrome — and which no other state in the notch uses.
    var nsTint: NSColor {
        switch agent {
        case .claude: .systemOrange
        case .cursor: NSColor(srgbRed: 0.875, green: 0.906, blue: 1, alpha: 1)
        }
    }
    var tint: Color { Color(nsColor: nsTint) }
}

/// How "Claude task finished" draws: the agent's mark on the left, a check on
/// the right, and the words in small type in the middle under the housing, their
/// baseline level with the bottom of the mark. The mark and the glow's colour say
/// who finished and the green check says that it did — the same green for both
/// agents, so the tick is the outcome and the mark is who; the caption says both in words
/// for a glance that did not catch either. The mark and check are drawn large,
/// so the shape grows to twice its height to hold them. Each sits against the
/// camera housing — the middle is dead space anyway, so hugging it costs nothing
/// and keeps the pair tight — and the black around each glyph is one margin,
/// `agentAir`, above, below and outboard. The caption shares the bottom one.
/// The outline glow is the silhouette's, in `NotchView`.
extension NotchView {

    @ViewBuilder func agentFinishedPill(_ finish: AgentFinish) -> some View {
        let glyph = metrics.agentGlyph
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                agentMark(finish)
                    .frame(width: glyph, height: glyph)
                    // Hugging, the default: on the housing's edge, with
                    // `agentAir` left outboard.
                    .flankSlot(metrics.agentFlanks.left, .leading, pad: metrics.notchPad)
                Spacer(minLength: 0).frame(width: metrics.notch.width)
                // Resizable, so the circle fills the same slot as the mark
                // rather than whatever a point size happens to draw at.
                Image(systemName: "checkmark.circle.fill")
                    .resizable().scaledToFit()
                    // Green for both agents. The mark and the glow already say
                    // who finished; the tick only says that the turn ended.
                    .foregroundStyle(.green)
                    .frame(width: glyph, height: glyph)
                    .flankSlot(metrics.agentFlanks.right, .trailing, pad: metrics.notchPad)
            }
            // Centred in the height, which is what makes the margin above and
            // below the glyph equal.
            .frame(height: metrics.agentHeight)
            // The words sit in the band under the dead housing row, centred on
            // it, with the glyphs' bottom margin: the guide puts the point
            // `agentAir` below the last baseline on the shape's bottom edge.
            // Baseline, not the line box — the box's bottom is a descender's
            // room, and this sentence has no descenders. A guide rather than
            // padding: padding passes the baseline guide straight through and
            // only pushes the box out past the bottom, which grows the stack
            // and drags the glyphs up with it.
            Text("\(finish.name) task finished")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(.white.opacity(0.8))
                .alignmentGuide(.bottom) { $0[.lastTextBaseline] + metrics.agentAir }
        }
        .frame(height: metrics.agentHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(finish.name) task finished")
    }

    /// The agent's own mark in its own colour, filling the glyph slot. Claude's
    /// is the bundled burst, still — it is a result, not a turn in progress.
    @ViewBuilder private func agentMark(_ finish: AgentFinish) -> some View {
        switch finish.agent {
        case .claude:
            Image("ClaudeLogo")
                .renderingMode(.template)
                .resizable().scaledToFit()
                .foregroundStyle(finish.tint)
        case .cursor:
            CursorMark()
                .stroke(finish.tint, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
        }
    }
}
