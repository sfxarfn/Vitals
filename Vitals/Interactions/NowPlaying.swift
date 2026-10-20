//
//  NowPlaying.swift
//  Vitals
//

import AppKit
import ImageIO
import Observation
import SwiftUI

/// What is playing, as the panel draws it.
struct NowPlayingTrack: Equatable {
    var title: String
    var artist: String
    var album: String
    /// The app to bring forward when the artwork is clicked — the parent app
    /// when the player is a helper process (Safari's video plays from WebKit's
    /// GPU process, and that is not something you can open).
    var appBundleID: String?
    var playing: Bool
    var playbackRate: Double
    /// Seconds in, as of `timestamp`. The player only reports on change, so the
    /// live position is extrapolated from here — see `position(at:)`.
    var elapsed: Double?
    var timestamp: Date?
    var duration: Double?
    var artwork: NSImage?

    /// Where the track is now, not where it was when the player last spoke.
    func position(at now: Date) -> Double? {
        guard var at = elapsed else { return nil }
        if playing, let timestamp {
            at += now.timeIntervalSince(timestamp) * (playbackRate > 0 ? playbackRate : 1)
        }
        if let duration { at = min(at, duration) }
        return max(at, 0)
    }
}

/// A track that started on its own, as the notch announces it: what it is,
/// the cover and its colour, and when — the queue drops it if it waited.
struct TrackChange: Equatable {
    let title: String
    let artist: String
    let artwork: NSImage?
    let tint: Color?
    let at: Date
}

/// Now Playing, read through ungive/mediaremote-adapter: Apple-signed
/// `/usr/bin/perl` still holds the MediaRemote entitlement macOS 15.4 took from
/// third-party apps, and loads the bundled helper library to print updates.
///
/// One `stream` runs for the life of the app. It has to: the track-change pill
/// fires while the panel is closed, and that needs the changes as they happen.
/// Measured on this Mac it costs nothing worth saving — 0.0% CPU and ~33 MB
/// for the idle perl process, which only wakes when the player says something
/// — and it means opening the panel never spawns anything. Lines are parsed
/// and the artwork decoded off the main thread.
///
/// If the adapter cannot run, or keeps dying, Music and Spotify are polled over
/// AppleScript instead — through `/usr/bin/osascript`, so Vitals needs no Apple
/// Events entitlement of its own under the hardened runtime. That costs one
/// Automation prompt per app, the first time.
@Observable
@MainActor
final class NowPlaying {
    enum Source { case adapter, appleScript }

    /// The adapter's `send` ids, which AppleScript maps onto its own verbs.
    enum Command: Int {
        case togglePlayPause = 2
        case next = 4
        case previous = 5
    }

    private(set) var track: NowPlayingTrack?
    /// The cover's average colour, which the page washes its tile with so it
    /// takes on the record instead of sitting the same grey for every track.
    /// Sampled with the thumbnail, off the main thread, only when a cover
    /// arrives.
    private(set) var artworkTint: Color?
    private(set) var source: Source = .adapter

    /// A track that changed on its own — not from the panel's own prev/next —
    /// while the panel was closed. The controller turns it into a pill.
    var onTrackChange: ((TrackChange) -> Void)?

    /// The panel is open. Suppresses the pill (the page already shows it) and
    /// drives the AppleScript fallback's polling; the adapter stream runs
    /// regardless.
    var active = false {
        didSet {
            guard active != oldValue else { return }
            active ? start() : stop()
        }
    }

    private var process: Process?
    /// The stream's first line is where things stand, not a change — after
    /// launch and after every restart.
    private var seenFirst = false
    /// Title, artist and album of the last track seen.
    private var lastIdentity: String?
    /// When the identity last changed, until that change is announced or goes
    /// stale. A player can send the new title a beat before `playing` — this
    /// lets the pill fire on whichever line completes the picture.
    private var identityChangedAt: Date?
    /// Set by the panel's own prev/next, so the change it causes is not news.
    private var suppressUntil: Date?
    /// The last full payload with every diff since applied — what the adapter's
    /// diff mode expects a reader to keep.
    private var payload: [String: Any] = [:]
    private var deaths: [Date] = []
    private var pollTimer: Timer?

    // MARK: Lifecycle

    init() {
        // The stream is a child process, and macOS does not end children with
        // their parent: quit kills it on the way out. A Vitals killed outright
        // (stopped from Xcode) leaves it until its next write fails on the
        // closed pipe — the next time the player says anything.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                let running = self?.process
                self?.process = nil
                running?.terminate()
            }
        }
        // Unzip the adapter off the main thread, then start the one stream.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = NowPlaying.framework
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.process == nil, self.source == .adapter else { return }
                    self.startStream()
                }
            }
        }
    }

    /// Only the fallback has anything to start: the adapter stream is already
    /// running.
    private func start() {
        if source == .appleScript { startPolling() }
    }

    private func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: Adapter

    nonisolated private static let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl")

    /// The script takes a path ending in `.framework` and loads the binary of
    /// the same name inside it. The binary ships zipped: Xcode recognises a
    /// Mach-O by its contents and links it into Vitals whatever it is named,
    /// and a linked adapter made dyld abort at launch. So the folder the script
    /// wants is unpacked here, in Caches — once per launch, so an updated app
    /// never runs last version's library. 280 KB; `ditto` keeps its signature.
    nonisolated private static let framework: URL? = {
        guard let archive = Bundle.main.url(forResource: "MediaRemoteAdapter", withExtension: "zip"),
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let folder = caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Vitals")
            .appendingPathComponent("MediaRemoteAdapter.framework")
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        guard (try? fm.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, folder.path]
        guard (try? unzip.run()) != nil else { return nil }
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0,
              fm.fileExists(atPath: folder.appendingPathComponent("MediaRemoteAdapter").path)
        else { return nil }
        return folder
    }()

    private func adapterArguments(_ command: [String]) -> [String]? {
        guard let script = Self.script, let framework = Self.framework else { return nil }
        return [script.path, framework.path] + command
    }

    private func startStream() {
        // 100ms merges the burst a track change arrives in — title first,
        // artwork a moment later — into one update.
        guard let arguments = adapterArguments(["stream", "--debounce=100"]) else {
            fallBack()
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        // By identity, not the object: these handlers run off the main thread,
        // and a stream stopped or replaced must not feed the current one.
        let id = ObjectIdentifier(p)
        let lines = LineBuffer()
        seenFirst = false

        // Split, parse and decode here, on the pipe's own queue. A first line
        // carries ~340 KB of base64 artwork; parsing and decoding that on the
        // main thread landed exactly on the open animation. Only the small,
        // parsed result crosses over.
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for parsed in lines.take(data).compactMap(Self.parse) {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.apply(parsed, from: id) }
                }
            }
        }
        p.terminationHandler = { [weak self] _ in
            out.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.streamEnded(id) }
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            fallBack()
        }
    }

    /// A stream that ends while the panel is still open died. Restart it, but
    /// three deaths inside half a minute means the adapter does not work here
    /// — an OS update closing the perl loophole, most likely — and AppleScript
    /// takes over for the rest of the session.
    private func streamEnded(_ ended: ObjectIdentifier) {
        guard let process, ObjectIdentifier(process) == ended else { return }   // stopped on purpose
        self.process = nil
        let now = Date()
        deaths = deaths.filter { now.timeIntervalSince($0) < 30 } + [now]
        if deaths.count >= 3 {
            fallBack()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.process == nil, self.source == .adapter else { return }
                self.startStream()
            }
        }
    }

    private func fallBack() {
        source = .appleScript
        if active { startPolling() }
    }

    /// One `stream` line, parsed off the main thread: the payload without its
    /// artwork, and what happened to the artwork.
    nonisolated private struct StreamLine: @unchecked Sendable {
        enum Artwork { case unchanged, cleared, image(NSImage, Color?) }
        let update: [String: Any]
        let isDiff: Bool
        let artwork: Artwork
    }

    /// Bytes from the pipe until a newline, kept per stream. Only ever touched
    /// from that pipe's readability handler, which runs one call at a time.
    /// `nonisolated` — like `StreamLine` — because the target defaults to the
    /// main actor and both live off it.
    nonisolated private final class LineBuffer: @unchecked Sendable {
        private var data = Data()

        func take(_ chunk: Data) -> [Data] {
            data.append(chunk)
            var lines: [Data] = []
            while let newline = data.firstIndex(of: 0x0A) {
                lines.append(data[data.startIndex..<newline])
                data.removeSubrange(data.startIndex...newline)
            }
            return lines
        }
    }

    nonisolated private static func parse(_ line: Data) -> StreamLine? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              var update = object["payload"] as? [String: Any] else { return nil }
        let isDiff = object["diff"] as? Bool ?? false
        // Artwork is decoded only when it arrived in this line — it is the one
        // heavy key, and diffs mostly carry the play state and position. Kept
        // out of the payload so the merge below never copies it around.
        let artwork: StreamLine.Artwork
        if let encoded = update["artworkData"] as? String,
           let data = Data(base64Encoded: encoded),
           let thumb = thumbnail(data) {
            artwork = .image(NSImage(cgImage: thumb, size: .zero), tint(of: thumb))
        } else if !isDiff || update["artworkData"] != nil {
            artwork = .cleared
        } else {
            artwork = .unchanged
        }
        update.removeValue(forKey: "artworkData")
        return StreamLine(update: update, isDiff: isDiff, artwork: artwork)
    }

    /// The cover at the size it is drawn — 128px covers a 42pt tile at 2x with
    /// room. The full image was a 1280-wide JPEG redrawn into 42pt on every
    /// frame of the panel's spring.
    nonisolated private static func thumbnail(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 128,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// One parsed line, folded in: a full payload replaces the kept one, a diff
    /// updates it, a null removes a key.
    private func apply(_ line: StreamLine, from stream: ObjectIdentifier) {
        guard let process, ObjectIdentifier(process) == stream else { return }
        if line.isDiff {
            for (key, value) in line.update {
                if value is NSNull { payload.removeValue(forKey: key) } else { payload[key] = value }
            }
        } else {
            payload = line.update
        }
        let artwork: NSImage?
        switch line.artwork {
        case .unchanged:
            artwork = track?.artwork
        case .cleared:
            artwork = nil
            artworkTint = nil
        case .image(let image, let tint):
            artwork = image
            artworkTint = tint
        }
        track = Self.track(from: payload, artwork: artwork)
        noticeTrackChange()
    }

    /// Announces a new track that is playing, unless the panel caused it, the
    /// panel is open, or this is the stream's first word. Pause and resume keep
    /// the identity, so they never get here.
    private func noticeTrackChange() {
        let identity = track.map { "\($0.title)\u{0}\($0.artist)\u{0}\($0.album)" }
        guard seenFirst else {
            seenFirst = true
            lastIdentity = identity
            return
        }
        if identity != lastIdentity {
            lastIdentity = identity
            let suppressed = suppressUntil.map { Date() < $0 } ?? false
            // A prev/next from the panel is spent on the first change after it.
            suppressUntil = nil
            identityChangedAt = identity == nil || suppressed ? nil : Date()
        }
        guard let at = identityChangedAt, let t = track, t.playing else { return }
        identityChangedAt = nil
        // A change that took a second to start playing is old news by now.
        guard !active, Date().timeIntervalSince(at) < 1 else { return }
        onTrackChange?(TrackChange(title: t.title, artist: t.artist, artwork: t.artwork,
                                   tint: artworkTint, at: Date()))
    }

    private static let timestampFormat = ISO8601DateFormatter()

    private static func track(from p: [String: Any], artwork: NSImage?) -> NowPlayingTrack? {
        guard let title = p["title"] as? String, !title.isEmpty else { return nil }
        return NowPlayingTrack(
            title: title,
            artist: p["artist"] as? String ?? "",
            album: p["album"] as? String ?? "",
            appBundleID: p["parentApplicationBundleIdentifier"] as? String
                ?? p["bundleIdentifier"] as? String,
            playing: p["playing"] as? Bool ?? false,
            playbackRate: (p["playbackRate"] as? NSNumber)?.doubleValue ?? 0,
            elapsed: (p["elapsedTime"] as? NSNumber)?.doubleValue,
            timestamp: (p["timestamp"] as? String).flatMap { timestampFormat.date(from: $0) },
            duration: (p["duration"] as? NSNumber)?.doubleValue,
            artwork: artwork
        )
    }

    // MARK: Commands

    func send(_ command: Command) {
        // The track this skips to is the user's own doing, not news. Three
        // seconds, or the next change, whichever comes first.
        if command != .togglePlayPause { suppressUntil = Date().addingTimeInterval(3) }
        // Flip the button now; the stream or the next poll confirms it.
        if command == .togglePlayPause, var t = track {
            if t.playing { t.elapsed = t.position(at: Date()) }
            t.playing.toggle()
            t.timestamp = Date()
            track = t
        }
        switch source {
        case .adapter:
            guard let arguments = adapterArguments(["send", String(command.rawValue)]) else { return }
            Self.run("/usr/bin/perl", arguments)
        case .appleScript:
            guard let app = track?.appBundleID else { return }
            let verb: String
            switch command {
            case .togglePlayPause: verb = "playpause"
            case .next: verb = "next track"
            case .previous: verb = "previous track"
            }
            Self.run("/usr/bin/osascript", ["-e", "tell application id \"\(app)\" to \(verb)"])
        }
    }

    /// One pixel's worth of the cover: the image drawn into a 1×1 context
    /// averages itself. Lifted towards the light so a dark sleeve still tints.
    nonisolated private static func tint(of cg: CGImage) -> Color? {
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = pixel.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        let lift = { (c: UInt8) in min(Double(c) / 255 * 1.4 + 0.08, 1) }
        return Color(red: lift(pixel[0]), green: lift(pixel[1]), blue: lift(pixel[2]))
    }

    /// Brings the player forward — the artwork's click.
    func openSourceApp() {
        guard let id = track?.appBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Fire and forget: a command has nothing to say back that the stream will
    /// not say better.
    private static func run(_ tool: String, _ arguments: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    // MARK: AppleScript fallback

    /// The two players that answer AppleScript. Only asked while running —
    /// `tell application` would otherwise launch them.
    private static let scriptablePlayers: [(id: String, durationScale: Double)] = [
        ("com.apple.Music", 1),
        ("com.spotify.client", 1000),   // Spotify reports duration in ms
    ]

    private func startPolling() {
        pollTimer?.invalidate()
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        let running = Self.scriptablePlayers.filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.id).isEmpty
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // A playing player wins over a paused one.
            var found: [NowPlayingTrack] = []
            for player in running {
                if let t = Self.scriptTrack(player.id, durationScale: player.durationScale) {
                    found.append(t)
                }
            }
            let best = found.first(where: \.playing) ?? found.first
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.source == .appleScript, self.active else { return }
                    self.track = best
                    self.artworkTint = nil   // AppleScript sends no cover
                }
            }
        }
    }

    /// One player's state over osascript, tab-separated so a title with a comma
    /// survives. Nil when it is stopped, unanswered, or refused.
    nonisolated private static func scriptTrack(_ id: String, durationScale: Double) -> NowPlayingTrack? {
        let source = """
        tell application id "\(id)"
            if player state is stopped then return ""
            set t to current track
            return (player state as text) & tab & (name of t) & tab & (artist of t) & tab & ¬
                (album of t) & tab & (player position as text) & tab & (duration of t as text)
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        let f = text.components(separatedBy: "\t")
        guard f.count >= 6, !f[1].isEmpty else { return nil }
        // AppleScript prints reals in the user's locale — "12,5" on a comma one.
        let number = { (s: String) in Double(s.replacingOccurrences(of: ",", with: ".")) }
        return NowPlayingTrack(
            title: f[1], artist: f[2], album: f[3],
            appBundleID: id,
            playing: f[0] == "playing",
            playbackRate: 1,
            elapsed: number(f[4]),
            timestamp: Date(),
            duration: number(f[5]).map { $0 / durationScale },
            artwork: nil
        )
    }
}
