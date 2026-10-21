import AppKit
import SwiftUI

/// The panel's Now Playing page: the artwork, what it is and who by, one
/// play/pause button, and a timeline whose two times double as prev and next. A feature page beside the shelf, so it
/// is reached with the arrows, never from a stat.
///
/// It should feel like it is playing. The tile takes the cover's colour, the
/// cover sits forward while the music runs and settles back when it stops, a
/// small equaliser moves beside the title, a new track slides in, and the
/// buttons answer the tap before the player does. Reduce Motion keeps the
/// colour and drops the movement.
extension NotchView {

    var nowPlayingPage: some View {
        Group {
            if let track = nowPlaying.track {
                // 42 + 5 + 18 + 2×6 = 77, the slot's height with the dots up.
                VStack(spacing: 5) {
                    HStack(spacing: 10) {
                        artwork(track)
                        titleBlock(track)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        playPauseButton(track)
                    }
                    timeline(track)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            } else {
                // An invitation would be a lie — Vitals cannot start anything —
                // so the empty page just says what is true.
                VStack(spacing: 4) {
                    Image(systemName: "music.note")
                        .font(.system(size: 16, weight: .medium))
                    Text("Nothing playing")
                        .font(.system(size: 11, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { nowPlayingWash }
        // No hover light on the tile itself: it is not a button, and a lit
        // surface promises a click it would not answer. Its buttons answer.
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .animation(.snappy(duration: 0.3), value: nowPlaying.track?.title)
        .animation(.easeInOut(duration: 0.6), value: nowPlaying.artworkTint)
    }

    /// The tile's grey with the cover's colour washed in from the artwork's
    /// side, fading out across the text so the type stays on near-black.
    private var nowPlayingWash: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(.white.opacity(0.06))
            .overlay {
                if let tint = nowPlaying.artworkTint {
                    LinearGradient(colors: [tint.opacity(0.38), tint.opacity(0.06)],
                                   startPoint: .leading, endPoint: .trailing)
                        .transition(.opacity)
                }
            }
    }

    // MARK: Artwork

    /// The cover, and the way to the player: clicking it brings the app that
    /// is playing forward. Full size and lit with its own colour while
    /// playing; paused, it steps back and dims, the way the player's own does.
    private func artwork(_ track: NowPlayingTrack) -> some View {
        let resting = !track.playing && !reduceMotion
        return Button { nowPlaying.openSourceApp() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08))
                if let image = track.artwork {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                } else {
                    // Stands in until the cover lands — a beat after the title,
                    // and never over AppleScript.
                    Image(systemName: "music.note")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(width: 42, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            // The cover's glow, drawn as a gradient rather than a blurred
            // shadow: a blur is an offscreen pass the GPU repeats whenever the
            // layer repaints, a radial fill is one cheap draw.
            .background {
                if track.playing, let tint = nowPlaying.artworkTint {
                    Circle()
                        .fill(RadialGradient(colors: [tint.opacity(0.5), tint.opacity(0)],
                                             center: .center, startRadius: 16, endRadius: 36))
                        .frame(width: 72, height: 72)
                        .transition(.opacity)
                }
            }
            .scaleEffect(resting ? 0.9 : 1)
            .opacity(track.playing ? 1 : 0.7)
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: track.playing)
        }
        // Grows a touch on hover like every other control; the cover is the
        // one thing on this page you might want to reach past.
        .buttonStyle(VitalsPressStyle())
        .help("Open the player")
    }

    // MARK: Title

    /// Title and artist, keyed by the track so a change slides the new one up
    /// rather than swapping letters in place.
    private func titleBlock(_ track: NowPlayingTrack) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                EqualizerBars(playing: track.playing, reduceMotion: reduceMotion,
                              tint: nowPlaying.artworkTint ?? .white)
                Text(track.title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            Text(track.artist.isEmpty ? track.album : track.artist)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
        }
        .lineLimit(1)
        .id(track.title + "\u{0}" + track.artist)
        .transition(reduceMotion
            ? .opacity
            : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                          removal: .opacity))
    }

    // MARK: Play / pause

    /// The one control in the top row. Prev and next live in the time labels
    /// below, so the row stays a cover, a name and a button.
    private func playPauseButton(_ track: NowPlayingTrack) -> some View {
        Button { nowPlaying.send(.togglePlayPause) } label: {
            Image(systemName: track.playing ? "pause.fill" : "play.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                // Morphs between play and pause instead of cutting, so the tap
                // reads as having done something.
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(VitalsPressStyle())
        .accessibilityLabel(track.playing ? "Pause" : "Play")
    }

    // MARK: Timeline

    /// Elapsed, the line, remaining — and the two times are the skip buttons.
    /// Hovering a time turns it into its arrow; both share one fixed box, so
    /// the line between never changes width. One clock drives all three, once
    /// a second while playing — the times only change per second, and the line
    /// glides between ticks — one still frame when paused.
    private func timeline(_ track: NowPlayingTrack) -> some View {
        TimelineView(.periodic(from: .now, by: track.playing ? 1 : 3600)) { context in
            let at = track.position(at: context.date)
            let duration = track.duration.flatMap { $0 > 0 ? $0 : nil }
            let fraction: Double = {
                guard let at, let duration else { return 0 }
                return min(max(at / duration, 0), 1)
            }()
            HStack(spacing: 6) {
                TimeSkipButton(
                    time: duration == nil ? nil : at.map { Self.clock($0) },
                    symbol: "backward.end.fill", help: "Previous", label: "Previous track",
                    bounce: backBounce, reduceMotion: reduceMotion
                ) {
                    backBounce += 1
                    nowPlaying.send(.previous)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule().fill((nowPlaying.artworkTint ?? .white).opacity(0.9))
                            .frame(width: proxy.size.width * fraction)
                            .animation(reduceMotion ? nil : .linear(duration: 1), value: fraction)
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 3)
                TimeSkipButton(
                    time: { () -> String? in
                        guard let at, let duration else { return nil }
                        return "-" + Self.clock(max(duration - at, 0))
                    }(),
                    symbol: "forward.end.fill", help: "Next", label: "Next track",
                    bounce: skipBounce, reduceMotion: reduceMotion
                ) {
                    skipBounce += 1
                    nowPlaying.send(.next)
                }
            }
        }
    }

}

/// A time that is also a skip button. At rest it shows the time; hovered it
/// cross-fades into its arrow, and a click skips. With no time to show — a live
/// stream has no duration — the arrow is there all the time, dimmed, so skip
/// stays reachable. VoiceOver gets the button by its label, no hover needed.
private struct TimeSkipButton: View {
    let time: String?
    let symbol: String
    let help: String
    let label: String
    let bounce: Int
    let reduceMotion: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        let showGlyph = hovered || time == nil
        Button(action: action) {
            ZStack {
                if let time {
                    Text(time)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .foregroundStyle(.white.opacity(0.6))
                        .opacity(showGlyph ? 0 : 1)
                }
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(hovered ? 0.95 : 0.35))
                    .symbolEffect(.bounce, options: .speed(1.6), value: reduceMotion ? 0 : bounce)
                    .scaleEffect(showGlyph || reduceMotion ? 1 : 0.6)
                    .opacity(showGlyph ? 1 : 0)
            }
            // One box for both, so swapping never moves the line beside it.
            .frame(width: 34, height: 18)
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: showGlyph)
        }
        .buttonStyle(VitalsPressStyle(scales: false))
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(label)
    }
}

/// Three bars beside the title that move while something plays and lie flat
/// when it stops — the page's pulse. Not the audio's real levels (MediaRemote
/// does not publish them), just three out-of-step waves, which is all a glance
/// needs. Reduce Motion holds them still at mid height. Shared with the
/// track-change pill.
///
/// The bars are Core Animation layers, not SwiftUI views. Both SwiftUI ways of
/// moving them were measured and both cost more than the page deserves: a
/// `repeatForever` animation is stepped by SwiftUI on every display frame, and a
/// capped `TimelineView` still re-lays-out and re-renders the whole hosting view
/// on each tick — about 10% CPU in a Debug build either way. A layer animation
/// runs on the render server and costs the app nothing per frame.
struct EqualizerBars: View {
    let playing: Bool
    let reduceMotion: Bool
    let tint: Color

    var body: some View {
        EqualizerLayers(playing: playing, reduceMotion: reduceMotion, tint: NSColor(tint))
            .frame(width: 9, height: 9)
            .opacity(playing ? 1 : 0.5)
            .animation(.easeOut(duration: 0.25), value: playing)
            .accessibilityHidden(true)
    }
}

private struct EqualizerLayers: NSViewRepresentable {
    let playing: Bool
    let reduceMotion: Bool
    let tint: NSColor

    func makeNSView(context: Context) -> EqualizerNSView { EqualizerNSView() }

    func updateNSView(_ view: EqualizerNSView, context: Context) {
        view.update(playing: playing, reduceMotion: reduceMotion, tint: tint)
    }
}

/// Three 2×9pt bars, bottom-anchored, scaled in height. Out of step: a different
/// peak and period each, so no two move together.
private final class EqualizerNSView: NSView {
    private static let rest: CGFloat = 2.0 / 9
    private static let still: CGFloat = 5.0 / 9
    private static let swings: [(peak: CGFloat, period: Double)] = [(0.9, 0.32), (1.0, 0.46), (0.72, 0.39)]

    private let bars: [CALayer] = (0..<3).map { _ in CALayer() }
    private var moving = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: 2, height: 9)
            bar.cornerRadius = 1
            // Grows up from its foot rather than out from its middle.
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            bar.position = CGPoint(x: 1 + CGFloat(i) * 3.5, y: 0)
            layer?.addSublayer(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 9, height: 9) }

    func update(playing: Bool, reduceMotion: Bool, tint: NSColor) {
        let shouldMove = playing && !reduceMotion
        // The resting height: flat when stopped, mid height when motion is
        // reduced. While the wave runs it overrides this model value.
        let level = playing && reduceMotion ? Self.still : Self.rest
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars {
            bar.backgroundColor = tint.cgColor
            bar.transform = CATransform3DMakeScale(1, level, 1)
        }
        CATransaction.commit()

        guard shouldMove != moving else { return }
        moving = shouldMove
        if shouldMove {
            for (i, bar) in bars.enumerated() {
                let swing = Self.swings[i]
                let wave = CABasicAnimation(keyPath: "transform.scale.y")
                wave.fromValue = Self.rest
                wave.toValue = swing.peak
                wave.duration = swing.period
                wave.autoreverses = true
                wave.repeatCount = .infinity
                wave.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bar.add(wave, forKey: "wave")
            }
        } else {
            for bar in bars { bar.removeAllAnimations() }
        }
    }
}

extension NotchView {
    /// "1:42", "12:05", "1:02:33" — hours only once there are some.
    static func clock(_ seconds: Double) -> String {
        let s = max(Int(seconds.rounded(.down)), 0)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
