import AppKit
import ApplicationServices
import CoreAudio
import Observation
import os

/// A call that is live right now, as the notch and the Meeting page draw it.
struct Meeting: Equatable {
    /// What the page's tile wears: Meet has no app of its own, so it gets the
    /// glyph on Meet's green; every other call wears its app's real icon.
    enum Tile { case meet, app }

    var tile: Tile
    /// "Google Meet", "Slack huddle", "FaceTime", "Discord" — the small line
    /// above the room.
    var app: String
    /// What names the call: the Meet code, or the call window's title.
    var room: String
    /// The app brought forward on return: the browser holding the call's tab,
    /// or the call app itself.
    var bundleID: String
    /// Whose icon an `.app` tile wears. Differs from `bundleID` for Slack in a
    /// browser, where the browser is what comes forward but Slack is the call.
    var iconBundleID: String
    /// A browser call's tab, found again by this part of its URL because tab
    /// indexes move. Nil for a native app, whose window is found by title.
    var tabMatch: String?
    var startedAt: Date
}

/// Finds a live call and brings its window back: Google Meet and Slack Huddles
/// in Chrome, Arc or Safari, and the FaceTime, Slack and Discord apps.
///
/// The detection is push-first. macOS tells a CoreAudio listener when a process
/// opens or closes an input stream, and that is what normally wakes this up.
/// Measured on a real call, though, those notifications sometimes never arrive
/// on a join, so a two-second read of CoreAudio's capture flags backs them up —
/// flags only, no tab or window polling. Only when one of these apps is
/// capturing does it do real work: one `osascript` call to see whether a
/// browser has a call tab, or one Accessibility read for a native app's window.
///
/// Mute is assumed not to end a call: these apps keep the microphone open while
/// muted. If one turns out not to, the end grace below is the knob — polling is
/// not the answer (see `lifecycles.md`).
@Observable
@MainActor
final class MeetingWatcher {
    private nonisolated static let log = Logger(subsystem: "com.polkka.Vitals", category: "meeting")

    private(set) var meeting: Meeting?
    @ObservationIgnored var onChange: ((Meeting?) -> Void)?

    private enum Family: CaseIterable {
        case chrome, arc, safari, slack, facetime, discord

        /// Audio runs in helper processes whose bundle IDs extend the app's, so
        /// these are prefixes, compared lowercased.
        ///
        /// Safari is the odd one: its capture lives in WebKit's own GPU and
        /// WebContent processes, shared by every WebKit app. A hit there only
        /// means "some WebKit process has the microphone", and the call-tab
        /// lookup is what confirms it is Safari's call.
        ///
        /// ponytail: FaceTime is matched on its own bundle only. Some of its
        /// capture may run in the `avconferenced` daemon, which other things
        /// share; widen this only if a call is ever missed.
        var prefixes: [String] {
            switch self {
            case .chrome: ["com.google.chrome"]
            case .arc: ["company.thebrowser"]
            case .safari: ["com.apple.safari", "com.apple.webkit."]
            case .slack: ["com.tinyspeck.slackmacgap"]
            case .facetime: ["com.apple.facetime"]
            case .discord: ["com.hnc.discord"]
            }
        }
        var appBundleID: String {
            switch self {
            case .chrome: "com.google.Chrome"
            case .arc: "company.thebrowser.Browser"
            case .safari: "com.apple.Safari"
            case .slack: "com.tinyspeck.slackmacgap"
            case .facetime: "com.apple.FaceTime"
            case .discord: "com.hnc.Discord"
            }
        }
        /// The name `tell application` takes; nil for a native call app, which
        /// is read over Accessibility instead.
        var scriptName: String? {
            switch self {
            case .chrome: "Google Chrome"
            case .arc: "Arc"
            case .safari: "Safari"
            default: nil
            }
        }
        /// A tab's title is `title` everywhere but Safari, which calls it `name`.
        var tabTitle: String { self == .safari ? "name" : "title" }

        /// A native app's call: its line above the room, the word that picks the
        /// call window out by title (nil: the first titled window), and what the
        /// room says when no title can be read.
        var native: (label: String, windowKeyword: String?, fallback: String)? {
            switch self {
            case .slack: ("Slack huddle", "huddle", "Huddle")
            case .facetime: ("FaceTime", nil, "FaceTime call")
            case .discord: ("Discord", nil, "Voice call")
            default: nil
            }
        }

        /// How long the microphone must stay open before it is a call. Only
        /// Slack needs any: a voice clip there is a few seconds on the same
        /// microphone a Huddle uses. A browser has its call tab to vouch for it,
        /// and FaceTime and Discord only capture on a call, so none of those
        /// waits — the notch should say so as the call starts.
        var settle: Duration { self == .slack ? .seconds(2) : .zero }

        /// The lines that bring one tab forward, given the loop's window `w`
        /// and tab number `i`.
        ///
        /// ponytail: Arc's is unverified. Its dictionary has `select` on a tab,
        /// but `tabs of window` may only list the active Space — a call in
        /// another Space would not be found. Upgrade path is to read Arc's own
        /// dictionary and walk its spaces.
        var selectTab: String {
            switch self {
            case .chrome: "set active tab index of w to i\n set index of w to 1"
            case .arc: "tell (tab i of w) to select"
            case .safari: "set current tab of w to (tab i of w)\n set index of w to 1"
            default: ""
            }
        }
    }

    /// How long it must stay closed before the meeting is over. Covers a
    /// device switch, which closes and reopens the stream in well under a
    /// second. Longer than that is a call you left, and the notch should say
    /// so at once.
    private static let endGrace: Duration = .seconds(2)

    @ObservationIgnored private var listeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    @ObservationIgnored private var listListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var identifying: Task<Void, Never>?
    @ObservationIgnored private var ending: Task<Void, Never>?
    @ObservationIgnored private var lastMiss: [Family: Date] = [:]
    /// The default input device and its "running somewhere" listener — the
    /// signal that fires whenever any process starts or stops capturing on it,
    /// which the per-process listeners alone were not reliably delivering.
    @ObservationIgnored private var inputDevice: AudioObjectID = 0
    @ObservationIgnored private var deviceListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var deviceChangeListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var recheck: Task<Void, Never>?
    @ObservationIgnored private var safetyNet: Timer?
    @ObservationIgnored private var lastReading = ""
    /// Every audio process already looked at, and which of them are an app this
    /// watches. A process's bundle ID never changes, so it is read once; every
    /// look after that reads only the few matching processes' capture flag, not
    /// the forty-odd the system keeps.
    @ObservationIgnored private var known: Set<AudioObjectID> = []
    @ObservationIgnored private var familyOf: [AudioObjectID: Family] = [:]

    // MARK: Lifecycle

    func start() {
        guard listListener == nil else { return }
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        listListener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, block)

        var defaultInput = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        let change: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.watchInputDevice(); self?.poke("default input") }
        }
        deviceChangeListener = change
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultInput, .main, change)
        watchInputDevice()
        reconcile()

        // Catches what the notifications miss: a read of the capture flags, a
        // few dozen property reads — microseconds. Tolerance lets macOS fold it
        // into other wake-ups. The process list is re-reconciled too, so a
        // helper that appeared without a notification gets its listener.
        safetyNet = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile(poke: false) }
        }
        safetyNet?.tolerance = 1
    }

    /// Looks now, and again a moment later. A notification can arrive before
    /// the property it announces reads back its new value, and then nothing
    /// follows to correct it — the second look is what catches that. Both are
    /// reactions to a notification; neither is a poll.
    private func poke(_ reason: String) {
        evaluate()
        recheck?.cancel()
        recheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.evaluate()
        }
    }

    /// Keeps one listener on whichever device is the default input now.
    private func watchInputDevice() {
        let current = Self.defaultInputDevice()
        guard current != inputDevice else { return }
        if let block = deviceListener, inputDevice != 0 {
            var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(inputDevice, &address, .main, block)
        }
        inputDevice = current
        deviceListener = nil
        guard current != 0 else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.poke("input device") }
        }
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        if AudioObjectAddPropertyListenerBlock(current, &address, .main, block) == noErr {
            deviceListener = block
        }
    }

    /// Keeps an input listener on each audio process that is an app this
    /// watches, then looks at who is capturing. The list changes whenever a
    /// process starts or stops talking to the audio server; the per-process
    /// listener is what hears one of ours open or close its microphone.
    private func reconcile(poke notify: Bool = true) {
        let ids = Set(Self.processes())
        for id in known.subtracting(ids) {
            known.remove(id)
            familyOf[id] = nil
            if let block = listeners.removeValue(forKey: id) {
                var address = Self.address(kAudioProcessPropertyIsRunningInput)
                AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
            }
        }
        for id in ids.subtracting(known) {
            known.insert(id)
            guard let bundle = Self.bundleID(id)?.lowercased(),
                  let family = Family.allCases.first(where: { $0.prefixes.contains { bundle.hasPrefix($0) } })
            else { continue }
            familyOf[id] = family
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.poke("process input") }
            }
            var address = Self.address(kAudioProcessPropertyIsRunningInput)
            if AudioObjectAddPropertyListenerBlock(id, &address, .main, block) == noErr {
                listeners[id] = block
            }
        }
        if notify { poke("process list") } else { evaluate() }
    }

    private func evaluate() {
        let capturing = capturingFamilies()
        lastMiss = lastMiss.filter { capturing.contains($0.key) }
        let reading = "capturing \(capturing.map { "\($0)" }.sorted().joined(separator: ",")); meeting \(meeting?.room ?? "none")"
        if reading != lastReading {
            lastReading = reading
            Self.log.info("\(reading, privacy: .public)")
        }

        if let current = meeting {
            let family = Family.allCases.first { $0.appBundleID == current.bundleID }!
            if capturing.contains(family) {
                ending?.cancel(); ending = nil
                return
            }
            // Another call app took the microphone: identify it, and let that
            // replace this one rather than waiting out the grace.
            if let other = Family.allCases.first(where: capturing.contains) {
                identify(other)
                return
            }
            guard ending == nil else { return }
            ending = Task { [weak self] in
                try? await Task.sleep(for: Self.endGrace)
                guard !Task.isCancelled, let self else { return }
                self.ending = nil
                // Re-read rather than trust the moment the timer was armed.
                guard self.capturingFamilies().isEmpty else { return }
                self.set(nil)
            }
            return
        }

        guard let family = Family.allCases.first(where: capturing.contains) else {
            identifying?.cancel(); identifying = nil
            return
        }
        guard identifying == nil else { return }
        identify(family)
    }

    private func set(_ next: Meeting?) {
        guard meeting != next else { return }
        meeting = next
        onChange?(next)
    }

    // MARK: Identify

    private func identify(_ family: Family) {
        // A browser capturing for something that is not a call stays that way for
        // a while, and every unrelated audio event re-asks. Once is enough.
        if let miss = lastMiss[family], Date.now.timeIntervalSince(miss) < 30 {
            Self.log.info("identify \("\(family)", privacy: .public) skipped: missed \(Int(Date.now.timeIntervalSince(miss)))s ago")
            return
        }
        Self.log.info("identify \("\(family)", privacy: .public)")
        identifying?.cancel()
        identifying = Task { [weak self] in
            if family.settle > .zero { try? await Task.sleep(for: family.settle) }
            guard !Task.isCancelled, let self else { return }
            defer { self.identifying = nil }
            guard self.capturingFamilies().contains(family) else { return }

            let found: Meeting?
            if let app = family.scriptName {
                let tabs = await Task.detached { Self.callTabs(in: app, title: family.tabTitle) }.value
                found = Self.call(in: tabs, family: family)
            } else if let native = family.native {
                found = Meeting(tile: .app, app: native.label,
                                room: Self.callWindow(of: family)?.title ?? native.fallback,
                                bundleID: family.appBundleID, iconBundleID: family.appBundleID,
                                tabMatch: nil, startedAt: .now)
            } else {
                found = nil
            }
            guard !Task.isCancelled else { return }
            Self.log.info("identified \("\(family)", privacy: .public): \(found?.room ?? "nothing", privacy: .public)")
            if found == nil { self.lastMiss[family] = .now }
            if let found {
                // A call that is already known keeps its own start time.
                if let current = self.meeting, current.bundleID == found.bundleID, current.room == found.room { return }
                self.ending?.cancel(); self.ending = nil
                self.set(found)
            }
        }
    }

    // MARK: Return

    /// Brings the call's own window to the front: for a browser call the tab,
    /// found again by its URL because indexes move; for a native app its call
    /// window, raised before the app itself comes forward.
    func returnToMeeting() {
        guard let meeting,
              let family = Family.allCases.first(where: { $0.appBundleID == meeting.bundleID })
        else { return }
        if let name = family.scriptName, let match = meeting.tabMatch {
            let script = Self.focusScript(app: name, select: family.selectTab, match: match)
            Task.detached { _ = Self.osascript(script) }
            return
        }
        if let window = Self.callWindow(of: family) {
            AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: family.appBundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: CoreAudio

    private func capturingFamilies() -> Set<Family> {
        var out = Set<Family>()
        for (id, family) in familyOf where Self.isCapturing(id) { out.insert(family) }
        return out
    }

    private nonisolated static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private nonisolated static func defaultInputDevice() -> AudioObjectID {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &device) == noErr else { return 0 }
        return device
    }

    private nonisolated static func processes() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private nonisolated static func isCapturing(_ id: AudioObjectID) -> Bool {
        var address = address(kAudioProcessPropertyIsRunningInput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private nonisolated static func bundleID(_ id: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var ref: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &ref) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    // MARK: Browsers

    /// A tab that might be a call: its URL and title.
    private struct Tab { var url: String; var title: String }

    /// Every open tab that might be a call, one `url<TAB>title` per line. Only
    /// asked while the browser is running — `tell application` would otherwise
    /// launch it.
    private nonisolated static func callTabs(in app: String, title: String) -> [Tab] {
        // One Apple Event per window for every URL, not one per tab: a window
        // with a hundred tabs would otherwise take seconds to answer.
        let out = osascript("""
        if application "\(app)" is not running then return ""
        -- Outside the tell: inside it, `tab` is the browser's tab class, not
        -- the character, and the whole script fails.
        set sep to ASCII character 9
        set out to ""
        tell application "\(app)"
            repeat with w in windows
                set urls to URL of tabs of w
                set i to 0
                repeat with u in urls
                    set i to i + 1
                    if u contains "meet.google.com/" or u contains "slack.com/huddle" then
                        set out to out & u & sep & (\(title) of (tab i of w)) & linefeed
                    end if
                end repeat
            end repeat
        end tell
        return out
        """) ?? ""
        return out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let url = f.first else { return nil }
            return Tab(url: String(url), title: f.count > 1 ? String(f[1]) : "")
        }
    }

    /// The first call among the tabs, as a Meeting. A second call open at the
    /// same time is not told apart — the first wins.
    ///
    /// ponytail: a Slack Huddle in a browser is recognised by its popup's
    /// `slack.com/huddle` URL, which is unverified against what Slack really
    /// opens. Upgrade path is to read the URL a browser Huddle shows and match
    /// on that.
    private nonisolated static func call(in tabs: [Tab], family: Family) -> Meeting? {
        let meet = try? NSRegularExpression(pattern: #"meet\.google\.com/([a-z]{3}-[a-z]{4}-[a-z]{3})"#)
        for tab in tabs {
            if let meet,
               let m = meet.firstMatch(in: tab.url, range: NSRange(tab.url.startIndex..., in: tab.url)),
               let range = Range(m.range(at: 1), in: tab.url) {
                let code = String(tab.url[range])
                return Meeting(tile: .meet, app: "Google Meet", room: code,
                               bundleID: family.appBundleID, iconBundleID: family.appBundleID,
                               tabMatch: "meet.google.com/\(code)", startedAt: .now)
            }
            if tab.url.contains("slack.com/huddle") {
                // The URL without its query: what stays the same across loads.
                let match = tab.url.split(separator: "?").first.map(String.init) ?? tab.url
                let title = tab.title.trimmingCharacters(in: .whitespaces)
                return Meeting(tile: .app, app: "Slack huddle",
                               room: title.isEmpty ? "Huddle" : title,
                               bundleID: family.appBundleID,
                               iconBundleID: Family.slack.appBundleID,
                               tabMatch: match, startedAt: .now)
            }
        }
        return nil
    }

    private nonisolated static func focusScript(app: String, select: String, match: String) -> String {
        """
        if application "\(app)" is not running then return ""
        tell application "\(app)"
            repeat with w in windows
                set urls to URL of tabs of w
                set i to 0
                repeat with u in urls
                    set i to i + 1
                    if u contains "\(match)" then
                        \(select)
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return ""
        """
    }

    private nonisolated static func osascript(_ source: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe()
        p.standardOutput = out
        let err = Pipe()
        p.standardError = err
        guard (try? p.run()) != nil else {
            log.error("osascript did not start")
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            log.error("osascript exit \(p.terminationStatus): \(String(data: errData, encoding: .utf8) ?? "", privacy: .public)")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Native apps

    /// A native call app's window, by title. Needs the Accessibility grant the
    /// Xcode watcher already uses; without it the room says the app's fallback
    /// and a click only brings the app forward.
    ///
    /// ponytail: unverified against any of these apps' own windows — the one
    /// guess in this file. Slack is matched on the word "huddle" in a title;
    /// FaceTime and Discord take their first titled window, which for Discord
    /// is the channel being viewed, not necessarily the voice channel. Upgrade
    /// path is to log the titles each app publishes during a call and match on
    /// what they really say.
    private static func callWindow(of family: Family) -> (element: AXUIElement, title: String)? {
        guard let native = family.native, AXIsProcessTrusted(),
              let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: family.appBundleID).first
        else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        // A hung app must not hang the notch with it.
        AXUIElementSetMessagingTimeout(root, 0.5)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement] else { return nil }
        for window in list {
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
                  let text = title as? String, !text.isEmpty else { continue }
            if let word = native.windowKeyword, !text.localizedCaseInsensitiveContains(word) { continue }
            return (window, text)
        }
        return nil
    }
}
