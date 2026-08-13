//
//  BuildWatcher.swift
//  Vitals
//

import AppKit
import ApplicationServices

/// What Xcode's toolbar activity view is saying right now.
struct BuildProgress: Equatable {
    /// How a run finished. Always nil on `progress`; non-nil values are used by
    /// preview fixtures and the verdict presentation model.
    ///
    /// Two outcomes, not three: a cancel is filed as a failure. What the notch
    /// is for is telling you the thing you walked away from is done, and a run
    /// you stopped yourself is one you already know about — splitting it out
    /// bought a third word and a third glyph for news nobody was waiting on.
    enum Ending: Equatable { case succeeded, failed }

    var label: String
    /// What kind of run this is, as a noun — "Build", "Archive".
    var job = "Build"
    var done: Int
    var total: Int
    /// Xcode's own icon, off the running app rather than a bundled copy, so a
    /// beta or a renamed Xcode.app still draws itself. Cached, because the pill
    /// is Equatable and a fresh NSImage every tick would redraw forever.
    var icon: NSImage?
    var ending: Ending?

    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

/// The one Xcode build Activity presented by the notch. Its lifecycle comes
/// from Xcode Behaviors; `progress` is optional enrichment from Accessibility,
/// never a prerequisite and never synthesized when the counter cannot be read.
struct XcodeBuildActivity: Equatable {
    var progress: BuildProgress?
    /// Kept separately because the Xcode app icon is available through
    /// NSWorkspace with or without the Accessibility grant.
    var icon: NSImage?

    var label: String { progress?.label ?? "Building" }
}

/// Reads Xcode's live build progress over the Accessibility API.
///
/// There is no other channel: the task counter is Xcode's own internal
/// progress, not written to DerivedData and not announced anywhere, so the
/// toolbar is the only place it exists. Needs the Accessibility grant.
///
/// The signal is the *label*, not the progress bar — the ring beside it may not
/// even be an AX element, and "Building | 3117/6729" is unambiguous on its own.
/// Requiring both a verb and a count is what keeps an idle toolbar (whose Run
/// button describes itself as "Build and run") from reading as a build.
@Observable
@MainActor
final class BuildWatcher {
    private(set) var progress: BuildProgress?
    /// Re-read every tick, never cached: a dev build is re-signed on every
    /// compile, which invalidates the grant while the row in System Settings
    /// stays checked. Settings watches this to know when to offer the button.
    private(set) var trusted = AXIsProcessTrusted()
    var onChange: (() -> Void)?
    /// A Behavior lifecycle is open but the build behind it is gone. Xcode has
    /// no cancel Behavior, so a cancelled run reports no ending at all and the
    /// Activity would sit in the notch until the next build starts.
    var onLifecycleLost: (() -> Void)?

    private var timer: Timer?
    private var stream: FSEventStreamRef?
    private var lastWrite = Date.distantPast
    /// A Behavior result can land while Xcode is still flushing DerivedData.
    /// Ignore those tail writes so a finished Activity cannot briefly return.
    private var ignoreDiskUntil = Date.distantPast
    /// A Behavior lifecycle is open. While it is, the poll runs on its word
    /// rather than on the disk's.
    private var explicit = false
    /// Consecutive reads that found nothing while the disk was still busy, and
    /// the earliest the next read may run. Every way this watcher can go blind —
    /// a localized Xcode, a moved activity view, a layout `skipRoles` hides —
    /// has the same symptom: a full-window walk every second for the length of
    /// the build. Doubling the gap turns the worst case into noise without
    /// giving up the fallback that makes those cases recoverable at all.
    private var misses = 0
    private var nextRead = Date.distantPast
    /// The activity view, kept between ticks. AX refs stay valid while the
    /// element lives, so the toolbar walk happens once per build and every tick
    /// after it re-reads one small subtree.
    private var status: AXUIElement?
    private var icon: NSImage?
    /// Text from the most recent scan, retained for the DEBUG miss report.
    private var lastText = ""
    /// When the counter stopped answering. Nil while it is still being read.
    private var lostAt: Date?

    /// Stem → what the notch calls it. Stems, because the same job reads
    /// "Build Edgeprop: Edgeprop" one moment and "Building 3117/6729" the next.
    /// Archive is first: an archive runs a build and says both words.
    ///
    /// Indexing is deliberately absent — it runs after nearly every edit, and a
    /// notch lit all day is one nobody reads. Add its stem here if you want it.
    /// `noun` is what the verdict puts under the icon: the pill's other flank
    /// says only how the run ended, so this is the only thing left naming the
    /// work — "Archive · Success".
    private static let jobs: [(stem: String, label: String, noun: String)] = [
        ("archiv", "Archiving", "Archive"), ("build", "Building", "Build"),
        ("test", "Testing", "Test"), ("clean", "Cleaning", "Clean"),
        ("analyz", "Analyzing", "Analyze"),
    ]

    /// Poll rate *while a build is running*. There is no resting rate: with the
    /// disk quiet there is no timer at all.
    private static let live: TimeInterval = 1
    /// How long the disk may stay quiet before the poll gives up. Linking and
    /// the tail of a build both go silent for a few seconds without ending.
    private static let grace: TimeInterval = 6
    /// How long a missing counter is held before progress disappears. One AX
    /// miss must not blink a live Activity; outcomes arrive separately through
    /// Xcode Behaviors and never get guessed here.
    private static let settle: TimeInterval = 2
    /// How long a Behavior lifecycle may run with a counter that was there and
    /// went away, over a disk that has gone quiet, before the run is called
    /// dead. Longer than `grace` on purpose: this one ends an Activity that
    /// Xcode said was running, so it has to outlast every silence a real build
    /// takes — a long link, a stalled single-file compile. Calibration knob.
    private static let abandoned: TimeInterval = 20
    /// The same, for a watcher that never read a counter at all. Much longer,
    /// because the disk is then the only witness and it is the poorer one:
    /// nothing in a quiet DerivedData distinguishes a cancelled run from a long
    /// link. A project that builds outside DerivedData has no witness at all and
    /// gets dropped here — the price of ending cancelled runs without the
    /// Accessibility grant. Calibration knob.
    private static let abandonedBlind: TimeInterval = 90
    /// Ceiling on the miss counter, so the gap tops out at `live << 4` — 16s.
    /// A blind watcher that rechecks every 16s still recovers the moment Xcode
    /// puts the activity view back where the scan can see it.
    private static let maxBackoff = 4

    /// Gap before the next read, after `misses` reads in a row found nothing.
    /// Clamped inside, not at the call site: an unclamped shift is undefined
    /// long before a build is long enough to reach it.
    static func gap(_ misses: Int) -> TimeInterval {
        live * Double(1 << min(max(misses, 0), maxBackoff))
    }

    /// Whether an open Behavior lifecycle has nothing left running behind it.
    ///
    /// Two tiers of evidence, because Xcode has no cancel Behavior and the
    /// alternative is an Activity that sits in the notch until the next build.
    ///
    /// With a counter, both halves are required: it was read and then stopped
    /// answering, over a disk that also went quiet. That is the strong case, and
    /// `abandoned` can be short because of it.
    ///
    /// Without one — no Accessibility grant, a localized Xcode, an activity view
    /// the scan cannot see — the disk is the only witness left and has to stand
    /// alone, over a much longer silence. A blind watcher cannot tell a
    /// cancelled run from a long link, and the cost of being wrong here is
    /// dropping a live build off the notch.
    static func lifecycleLost(lostAt: Date?, lastWrite: Date, now: Date) -> Bool {
        let quiet = now.timeIntervalSince(lastWrite)
        guard let lostAt else { return quiet >= abandonedBlind }
        return now.timeIntervalSince(lostAt) >= abandoned && quiet >= abandoned
    }

    func start() {
        // No timer here. The resting cost of this whole file is one
        // kernel-pushed callback that never arrives until a build writes.
        //
        // The Settings row still needs a fresh answer, and activating Vitals is
        // exactly when someone is looking at it — including on the way back
        // from granting the permission in System Settings.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.trusted = AXIsProcessTrusted() }
        }
        watchDerivedData()
    }

    /// An explicit Xcode Behavior lifecycle owns the start and finish. Progress
    /// may enrich it while it runs, but a previous build's tail must not leak
    /// into the next one.
    ///
    /// This also starts the poll outright. The disk gate is a *guess* that
    /// something is compiling; a Behavior is Xcode saying so, and it is the
    /// better gate of the two — a build whose products land outside
    /// `~/Library/Developer/Xcode/DerivedData` (a project-level Build Location
    /// override) writes nothing the stream can see, and waiting on it means the
    /// counter is never read at all.
    func explicitLifecycleStarted() {
        ignoreDiskUntil = .distantPast
        explicit = true
        // Start the blind cancel clock from the Behavior itself. `lastWrite` is
        // "when the build was last known alive", and Xcode saying it started is
        // exactly that. Without the seed it is still `.distantPast` here, and a
        // project whose products land outside DerivedData — nothing to reset
        // it — would be abandoned on its first tick.
        lastWrite = .now
        poll()
    }

    func explicitLifecycleEnded() {
        explicit = false
        stop()
        ignoreDiskUntil = .now + 10
    }

    /// Xcode is writing build products, so something is compiling. Cheap enough
    /// to be the gate: the kernel pushes this, and it stays silent all day when
    /// no build runs.
    private func diskActivity() {
        guard Date.now >= ignoreDiskUntil else { return }
        lastWrite = .now
        poll()
    }

    /// Start the 1s read, if it is not already running. Both gates land here —
    /// a disk write and an explicit Behavior — and neither restarts a live timer.
    private func poll() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.live, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Principle 5: let the OS coalesce this wakeup with whatever else it is
        // already waking for.
        timer?.tolerance = Self.live * 0.25
        tick()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        status = nil
        misses = 0
        nextRead = .distantPast
        lostAt = nil
        lastText = ""
        lastWrite = .distantPast
        publish(nil)
    }

    /// End a lifecycle nobody is going to end. Stops first, so a watcher with no
    /// listener still puts its timer down; the listener then drops the Activity
    /// and calls `explicitLifecycleEnded()`, which lands back in `stop()` as a
    /// no-op.
    private func abandon() {
        let wasExplicit = explicit
        stop()
        if wasExplicit { onLifecycleLost?() }
    }

    private func tick() {
        // Before the backoff gate, not after: this is the healthy end of a
        // build, and it must not wait out a gap that only exists because the
        // toolbar went unreadable.
        //
        // Nothing on the toolbar and nothing on the disk: the build is over and
        // the timer has no reason to exist until the next one starts.
        // Not while a Behavior says a build is running: the disk going quiet is
        // only evidence when the disk is all we have. Stopping there would also
        // be terminal, since nothing but a write restarts the timer.
        if !explicit, progress == nil,
           Date.now.timeIntervalSince(lastWrite) > Self.grace { stop(); return }

        // Same reasoning one level up, for the case the Behaviors cannot cover:
        // Xcode has no cancel Behavior, so a quiet disk — with the counter gone
        // too, when there is one to go — is the only end a cancelled run ever
        // gets. Before the backoff gate for the same reason as the check above,
        // and before the `trusted` guard below so it still runs without the
        // grant, which is the only way that case ever ends.
        if explicit, Self.lifecycleLost(lostAt: lostAt, lastWrite: lastWrite, now: .now) {
            abandon(); return
        }
        guard Date.now >= nextRead else { return }

        trusted = AXIsProcessTrusted()

        // Xcode quitting mid-build is the other way a Behavior lifecycle is left
        // without an ending — the succeeded/failed script it would have run went
        // with it.
        guard let xcode = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.dt.Xcode"
        }) else { abandon(); return }

        guard trusted else {
            #if DEBUG
            print("[BuildWatcher] no Accessibility grant — a re-signed dev build "
                  + "loses it while the System Settings row stays checked")
            #endif
            // No prompt from here. Progress is enrichment nobody asked for at
            // this moment, and `requestAccess()` activates the app and opens
            // System Settings — fine from the button in Settings, hostile in the
            // middle of a build. The grant stays the Settings row's business.
            //
            // The grant can be given mid-build, and stopping is terminal under a
            // Behavior lifecycle — nothing but a disk write brings the timer
            // back. Keep the slowest recheck instead.
            if explicit { publish(nil); nextRead = .now + Self.gap(Self.maxBackoff) } else { stop() }
            return
        }

        icon = icon ?? xcode.icon
        let hit = read(pid: xcode.processIdentifier)

        // The counter was there and is gone now. Hold the last progress briefly
        // because one failed AX read is not a lifecycle event. After that the
        // Activity may fall back to the explicit Behavior lifecycle underneath.
        if hit == nil, progress != nil {
            let lost = lostAt ?? .now
            lostAt = lost
            #if DEBUG
            print("[BuildWatcher] counter gone — \(lastText)")
            #endif
            guard Date.now.timeIntervalSince(lost) >= Self.settle else {
                nextRead = .now + Self.live
                return
            }
        }
        if hit != nil { lostAt = nil }

        // Only a busy disk gets here, so backing off costs nothing on a build
        // that reads fine — a hit resets to the live rate on the next tick.
        misses = hit == nil ? misses + 1 : 0
        nextRead = .now + Self.gap(misses)
        publish(hit)
    }

    /// Ask for the Accessibility grant, loudly.
    ///
    /// The system prompt fires at most once per TCC record — dismiss it and no
    /// later call brings it back — so the pane is opened alongside it rather
    /// than trusting the dialog to land. The activate matters too: an accessory
    /// app has no Dock icon, so its dialog can open behind whatever is in front.
    func requestAccess() {
        NSApp.activate()
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        if let pane = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(pane)
        }
    }

    private func publish(_ next: BuildProgress?) {
        guard next != progress else { return }
        progress = next
        onChange?()
    }

    // MARK: Reading

    private func read(pid: pid_t) -> BuildProgress? {
        // Cheap path: re-read whatever answered last tick, a subtree of a dozen
        // elements. A dead or silent ref is also how the end of a build is
        // detected — the counter goes away and the pill goes with it.
        //
        // Same limits as the discovery walk below, deliberately. A shorter
        // re-read cannot reproduce what a longer walk found, so a cached
        // element sitting deeper than it allowed would fail every tick and
        // send every tick back through the full walk — the one path that
        // actually costs Xcode anything. These are ceilings, not costs: the
        // cached subtree is a dozen elements whatever the budget says.
        // Everything read this tick, across every window walked, because a
        // localized or rearranged activity view may move the counter elsewhere.
        lastText = ""

        if let status {
            var scan = Scan(budget: Self.budget)
            walk(status, depth: Self.depth, into: &scan)
            lastText = scan.text
            if let hit = parse(scan.text) { return hit }
            self.status = nil
        }

        let app = AXUIElementCreateApplication(pid)
        // Cap how long one unanswered read can hold this thread. Vitals is
        // @MainActor and AX reads are synchronous, so without this a beachballed
        // Xcode freezes the notch with it.
        AXUIElementSetMessagingTimeout(app, 0.25)

        for window in children(app) ?? [] {
            // Prefer the toolbar, but never *require* it — a window whose
            // toolbar is not exposed as AXToolbar used to fall through here
            // silently, which is the one failure mode this watcher must not
            // have. `skipRoles` and the budget are what make the whole-window
            // fallback affordable.
            let root = descendant(window, role: kAXToolbarRole, depth: 3) ?? window
            var scan = Scan(budget: Self.budget)
            walk(root, depth: Self.depth, into: &scan)
            lastText += scan.text

            guard let hit = parse(scan.text) else {
                #if DEBUG
                report(scan)
                #endif
                continue
            }
            // Prefer the one element that carried the whole string: next tick
            // then costs a handful of reads instead of a walk. Xcode splitting
            // the verb and the counter into siblings falls back to re-scanning
            // the toolbar, which the budget still bounds.
            status = scan.match ?? root
            return hit
        }
        return nil
    }

    /// Subtrees that cannot hold the activity view and cost thousands of
    /// elements to walk: the navigator, the source editor, the console.
    private static let skipRoles: Set<String> = [
        kAXOutlineRole, kAXTableRole, kAXTextAreaRole, kAXScrollAreaRole, kAXRowRole,
    ]

    /// Ceiling on elements visited per scan. Xcode's toolbar is a few dozen, so
    /// this is only ever reached by the whole-window fallback — and reaching it
    /// costs a known ~400 reads rather than an unbounded walk of an IDE.
    ///
    /// ponytail: a fixed budget, not a smart traversal. If a real Xcode layout
    /// ever hides the activity view past element 400, cache the path to it
    /// instead of raising this.
    private static let budget = 400
    /// How deep a scan descends. Shared by both walks — see `read(pid:)` for
    /// why they must not differ.
    private static let depth = 8

    /// One pass, one visit per element — labels and children read exactly once
    /// each. The earlier version re-read every subtree from each of its
    /// ancestors, which is the difference between a few hundred IPC round trips
    /// and several thousand, on Xcode's own main thread.
    private struct Scan {
        var budget: Int
        var text = ""
        /// The element whose own labels parsed on their own, if any.
        var match: AXUIElement?
        var visited = 0
    }

    private func walk(_ el: AXUIElement, depth: Int, into scan: inout Scan) {
        guard depth > 0, scan.budget > 0 else { return }
        scan.budget -= 1
        scan.visited += 1

        var own: [String] = []
        for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let s = string(of: el, attr), !s.isEmpty { own.append(s) }
        }
        if !own.isEmpty {
            let line = own.joined(separator: " ")
            if scan.match == nil, parse(line) != nil { scan.match = el }
            scan.text += line + " "
        }

        for k in children(el) ?? [] {
            guard !Self.skipRoles.contains(string(of: k, kAXRoleAttribute) ?? "") else { continue }
            walk(k, depth: depth - 1, into: &scan)
        }
    }

    private func parse(_ text: String) -> BuildProgress? {
        guard let job = Self.jobs.first(where: { text.localizedCaseInsensitiveContains($0.stem) }),
              let m = text.firstMatch(of: /(\d+)\s*(?:\/|of)\s*(\d+)/),
              let done = Int(m.1), let total = Int(m.2), total > 0
        else { return nil }
        return BuildProgress(label: job.label, job: job.noun, done: done, total: total, icon: icon)
    }

    // MARK: The gate

    /// Watches DerivedData for build products landing. This is what keeps the
    /// AX poll from existing at rest: no writes, no timer, no reads out of
    /// Xcode at all.
    ///
    /// Directory-level events, not file events — an order of magnitude fewer
    /// callbacks for a signal that only has to answer "is something compiling".
    /// The `/Build/` filter is what separates a build from indexing, which
    /// writes next door in `Index.noindex` after nearly every keystroke.
    private func watchDerivedData() {
        guard stream == nil else { return }
        // Honour a moved DerivedData; Xcode keeps the override in its own
        // defaults, and an absolute path there wins over the default location.
        let custom = UserDefaults(suiteName: "com.apple.dt.Xcode")?
            .string(forKey: "IDECustomDerivedDataLocation")
        let path = (custom?.hasPrefix("/") == true ? custom! : "~/Library/Developer/Xcode/DerivedData")
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        guard let stream = FSEventStreamCreate(
            nil,
            { _, info, count, paths, _, _ in
                guard let info, count > 0,
                      let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
                guard paths.contains(where: { $0.contains("/Build/") }) else { return }
                // Unretained is safe: the watcher outlives the app's use of it,
                // and a retained one would be a cycle that never breaks.
                let watcher = Unmanaged<BuildWatcher>.fromOpaque(info).takeUnretainedValue()
                MainActor.assumeIsolated { watcher.diskActivity() }
            },
            &context,
            [NSString(string: path).expandingTildeInPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            // Half a second of coalescing. The pill is a second late to a build
            // that runs for minutes, and the callback rate drops by orders.
            0.5,
            // UseCFTypes is what makes the callback's `paths` a CFArray of
            // strings. Without it the parameter is a C `char **`, the cast up
            // there reads it as an object graph, and the first path dereference
            // is a wild pointer.
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    // MARK: AX plumbing

    private func descendant(_ el: AXUIElement, role: String, depth: Int) -> AXUIElement? {
        guard depth > 0 else { return nil }
        if string(of: el, kAXRoleAttribute) == role { return el }
        for k in children(el) ?? [] {
            if let found = descendant(k, role: role, depth: depth - 1) { return found }
        }
        return nil
    }

    private func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    private func children(_ el: AXUIElement) -> [AXUIElement]? {
        attribute(el, kAXChildrenAttribute) as? [AXUIElement]
    }

    private func string(of el: AXUIElement, _ name: String) -> String? {
        attribute(el, name) as? String
    }

    #if DEBUG
    private var lastDump = ""

    /// What the scan saw when it found no build, printed on change only. Two
    /// jobs: the labels say why a build went unnoticed, and `visited` is the
    /// actual cost of a walk — the number to look at before believing any claim
    /// about what this costs Xcode.
    private func report(_ scan: Scan) {
        guard scan.text != lastDump else { return }
        lastDump = scan.text
        print("[BuildWatcher] no match, \(scan.visited) elements — \(scan.text)")
    }
    #endif
}

#if DEBUG
enum BuildWatcherSelfCheck {
    static func run() {
        // A readable build polls at the live rate; nothing here may slow down a
        // build that is being read fine.
        assert(BuildWatcher.gap(0) == 1, "a hit must return to the live rate")

        // A blind watcher backs off, and stops backing off. The ceiling is the
        // whole point: unbounded doubling means a build that recovers at minute
        // three is not noticed until minute forty.
        assert(BuildWatcher.gap(1) == 2 && BuildWatcher.gap(4) == 16, "gap doubles per miss")
        assert(BuildWatcher.gap(1000) == BuildWatcher.gap(4), "the gap must be capped")

        // `1 << misses` is undefined for a negative shift, and `misses` is a
        // plain counter one edit away from being decremented somewhere.
        assert(BuildWatcher.gap(-1) == BuildWatcher.gap(0), "a negative count must not shift")

        let now = Date.now
        let old = now.addingTimeInterval(-60)

        // A blind watcher ends a run on the disk alone, but only after a silence
        // no real build takes — a minute of quiet is still a long link phase.
        assert(!BuildWatcher.lifecycleLost(lostAt: nil, lastWrite: old, now: now),
               "a minute of quiet is not yet a blind cancel")
        assert(!BuildWatcher.lifecycleLost(lostAt: nil, lastWrite: now, now: now),
               "a busy disk means the build is alive, counter or not")
        assert(BuildWatcher.lifecycleLost(
                lostAt: nil, lastWrite: now.addingTimeInterval(-120), now: now),
               "a long enough silence is the only end a blind cancelled run gets")

        // The blind window must stay the looser of the two, or the strong case
        // never fires first and the counter buys nothing.
        assert(!BuildWatcher.lifecycleLost(lostAt: nil, lastWrite: old, now: now)
               && BuildWatcher.lifecycleLost(lostAt: old, lastWrite: old, now: now),
               "a read counter must end a run sooner than the disk alone")

        // Both halves, or neither. A build that is still writing has not been
        // cancelled, and a counter that came back a second ago has not either.
        assert(!BuildWatcher.lifecycleLost(lostAt: old, lastWrite: now, now: now),
               "a busy disk means the build is alive")
        assert(!BuildWatcher.lifecycleLost(lostAt: now, lastWrite: old, now: now),
               "a counter lost this instant is one AX miss, not a cancel")
        assert(BuildWatcher.lifecycleLost(lostAt: old, lastWrite: old, now: now),
               "counter gone and disk quiet is a cancelled run")
    }
}
#endif
