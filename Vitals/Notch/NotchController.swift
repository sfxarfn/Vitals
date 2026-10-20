import AppKit
import SwiftUI
import Observation

/// A file being dragged near the housing. `pull` is 0 at the edge of the
/// reach and 1 on the notch. Where across the reach it sits is deliberately
/// not tracked — the notch grows toward the file, it does not follow it.
struct FileDrag: Equatable {
    var pull: CGFloat
}

@Observable
@MainActor
final class NotchController {
    /// Settings is its own scene with no path back to the delegate that owns
    /// this, so the running controller publishes itself.
    private(set) static var shared: NotchController?

    private(set) var state: NotchState = .idle
    private(set) var metrics = NotchMetrics(notch: .zero)
    private(set) var thermalGlow: Signal?
    private(set) var extensions = ExtensionSlots.empty

    let telemetry = Telemetry()
    let shelf = Shelf()
    let nowPlaying = NowPlaying()
    /// Where a file drag sits relative to the housing. Nil the moment the drag
    /// leaves or ends — a leftover value would keep the silhouette animating
    /// for the rest of the day.
    private(set) var fileDrag: FileDrag?
    /// A file drag is in hand, whether or not it is near the housing. The
    /// pointing-hand tracking must not paint over the drag cursor. Cleared on
    /// mouse-up only — `fileDragEnded` can run while the button is still down
    /// (the drag left the panel, a drop began) and must not give the hand back
    /// the cursor for the rest of the gesture.
    private(set) var draggingFile = false
    /// Resolved once per drag, not per pixel. `dragMenuBarVisible` is the
    /// menu-bar probe from that same moment — fullscreen does not change
    /// under a drag often enough to walk the window list on every move.
    private var dragIsFile: Bool?
    private var dragMenuBarVisible: Bool?
    /// A file drag ended while the button was still down. Mouse-up is what
    /// puts the arrow back. Escape is not part of this: an accessory app does
    /// not see it while Finder is frontmost.
    private var arrowAfterDrag = false

    private var engine = EventEngine()
    private var window: NSPanel?
    // Int32.max, not Int.max — the level is a 32-bit value and a 64-bit one
    // truncates to garbage, which renders the space nowhere.
    private let space = CGSSpace(level: Int(Int32.max))
    private var screen: NSScreen?
    private var mouseMonitor: Any?
    /// Mouse-up over the open panel never reaches the global monitor. This one
    /// does, so a file drag that ends or is cancelled there can put the arrow back.
    private var localDragMonitor: Any?
    private var dwell: Timer?
    private var eventDismiss: Timer?
    /// The last Xcode Behavior lifecycle to end — what the verdict that follows
    /// it is about.
    private var lastXcodeRun: (job: String?, endedAt: Date)?
    private let accessories = AccessoryWatcher()
    private let builds = BuildWatcher()
    private let commands = CommandReceiver()
    /// The application icon does not require Accessibility. Keep one copy so
    /// Behavior-only builds retain Xcode's identity with progress tracking off.
    @ObservationIgnored private lazy var installedXcodeIcon: NSImage? = {
        guard let url = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }()
    /// More than one shell may be doing work. The newest Activity owns the
    /// resting notch; when it stops, the next newest one underneath resumes.
    private var externalActivities: [String: ExternalActivity] = [:]
    /// Explicit Extension lifecycles are keyed by their caller-provided ID so
    /// overlapping Claude sessions do not clear each other. Presentation is
    /// collapsed by name: Claude is one condition even when two sessions work.
    private var reportedExtensions: [String: NotchExtension] = [:]
    private var extensionStartedAt: [String: Date] = [:]
    /// When the current VPN connection came on — or when Vitals first saw it
    /// on, if it was already up at launch. Nil while off.
    private var vpnOnSince: Date?
    /// How many reminder marks this connection has already had.
    private var vpnRemindersShown = 0
    /// The first reading is where things stand: a VPN already on at launch
    /// gets no connect pill.
    private var vpnPrimed = false
    /// Connected-time marks, in minutes, at which a reminder pill shows — each
    /// once, then no more for that connection. Backs off rather than repeating:
    /// the point is catching a tunnel you forgot, and by four hours you have
    /// either seen it or chosen it.
    private static let vpnReminderMarks = [30, 60, 120, 240]
    /// Settings previews use the same allocator as live conditions, but expire
    /// on their own so closing Settings cannot strand a fake persistent icon.
    private var previewExtensions: [String: NotchExtension] = [:]
    private var previewExtensionDismiss: [String: Timer] = [:]
    /// Events waiting for the notch, in the order they arrived.
    private var queue: [NotchState] = []
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var dragBaseline = -1
    // Global monitors go deaf once the pointer is over our own window, and a
    // drop there never produces a mouse-up we can see — so "still dragging" is
    // measured by how recently drag events arrived, not by mouse-up.
    private var lastDrag = Date.distantPast
    /// Armed while a file drag holds a committed approach; opens the panel if
    /// the approach is still there when it fires.
    private var approachTimer: Timer?
    /// How close below the housing a file has to come, as `FileDrag.pull`, and
    /// for how long, before the panel opens to meet it. Half the reach is ~55pt
    /// under the notch — far enough down that the pointer never has to touch
    /// the top edge, where macOS takes the drag for Mission Control. The dwell
    /// is what keeps a drag sweeping across the top of the screen from popping
    /// the panel on the way past.
    private static let approachPull: CGFloat = 0.5
    private static let approachDwell: TimeInterval = 0.12

    private static let dwellDelay: TimeInterval = 0.25
    private static let eventDuration: TimeInterval = 2.6

    /// How long a whole-notch Event holds. A track change is two glyphs and no
    /// reading, so it leaves sooner than the ones with words.
    private static func duration(of state: NotchState) -> TimeInterval {
        switch state {
        case .trackChange, .vpn: return 2
        default: break
        }
        return eventDuration
    }
    private static let extensionPreviewDuration: TimeInterval = 6

    func start() {
        Self.shared = self
        rebuildWindow()
        telemetry.onUpdate = { [weak self] in self?.evaluate() }
        telemetry.start()

        accessories.onConnect = { [weak self] accessory in
            guard let self else { return }
            queue.append(.accessory(accessory))
            presentNext()
        }
        accessories.onDisconnect = { [weak self] loudness in
            guard let self else { return }
            queue.append(.audioLost(loudness: loudness))
            presentNext()
        }
        accessories.start()

        // A track change is one pill, and only the newest one: a change still
        // waiting when another arrives is replaced, not queued behind it.
        nowPlaying.onTrackChange = { [weak self] change in
            guard let self else { return }
            queue.removeAll { if case .trackChange = $0 { true } else { false } }
            queue.append(.trackChange(change))
            presentNext()
        }

        commands.start { [weak self] command in self?.handle(command) }

        // A build is an Activity, not an Event: it replaces idle as the resting
        // state and hands it back when the work ends, so nothing here queues.
        builds.onChange = { [weak self] in
            guard let self, self.atRest else { return }
            state = resting
        }
        // The one Activity that can outlive the thing it describes: a cancelled
        // build runs no Behavior script, so `activityStop` never arrives. No
        // Event is queued in its place — a run you stopped yourself is not news,
        // and the notch dropping back to idle is the whole message.
        builds.onLifecycleLost = { [weak self] in
            guard let self else { return }
            externalActivities = externalActivities.filter {
                !self.isXcodeBuildActivity($0.value.name)
            }
            builds.explicitLifecycleEnded()
            if atRest { state = resting }
        }
        builds.start()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.rebuildWindow() } }

        // Insurance: if anything does knock the panel loose, re-pin it once the
        // space settles rather than leaving it parked off-centre.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.repin() } }

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        // Mouse-up over this window never reaches the global monitor. That is
        // the cursor restore. Escape is not: Finder keeps it when Finder is
        // frontmost, and the button-up ends the drag either way. The monitor
        // returns the event unchanged, so it cannot swallow a click.
        localDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerReleased() }
            return event
        }
    }

    // MARK: Window

    /// Off, the notch is the built-in display's, and nowhere else. On, it
    /// follows the pointer's display and a screen with no camera housing gets
    /// one drawn for it. Settings writes this; the controller reads it.
    static var externalDisplay: Bool {
        get { UserDefaults.standard.bool(forKey: "externalDisplay") }
        set { UserDefaults.standard.set(newValue, forKey: "externalDisplay") }
    }

    func setExternalDisplay(_ on: Bool) {
        Self.externalDisplay = on
        rebuildWindow()
    }

    /// What a screen without a housing pretends to have. Nothing sits behind it,
    /// so it only has to read as a notch — this is roughly a 14-inch one.
    private static let syntheticNotchWidth: CGFloat = 180

    /// The notch lives between the two auxiliary menu bar areas. No auxiliary
    /// areas means no housing, and an external display only gets a synthetic one
    /// when the setting says so.
    private static func notchRect(of s: NSScreen) -> CGRect? {
        if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            let rect = CGRect(x: l.maxX, y: s.frame.maxY - l.height,
                              width: r.minX - l.maxX, height: l.height)
            if rect.width > 1 { return rect }
        }
        guard externalDisplay else { return nil }
        // There are no auxiliary areas to measure here, so the menu bar's own
        // height is what keeps the shape flush with it. `visibleFrame` is the
        // only per-screen source for it, and it can come back equal to `frame`
        // on a screen the menu bar is currently hidden on — hence the floor.
        let height = max(s.frame.maxY - s.visibleFrame.maxY, 24)
        return CGRect(x: s.frame.midX - syntheticNotchWidth / 2,
                      y: s.frame.maxY - height,
                      width: syntheticNotchWidth, height: height)
    }

    private static func notchScreen() -> (NSScreen, CGRect)? {
        // The pointer's display wins while the setting is on: the notch belongs
        // on the screen you are already looking at.
        if externalDisplay {
            let p = NSEvent.mouseLocation
            if let s = NSScreen.screens.first(where: { $0.frame.contains(p) }),
               let rect = notchRect(of: s) { return (s, rect) }
        }
        for s in NSScreen.screens {
            if let rect = notchRect(of: s) { return (s, rect) }
        }
        return nil
    }

    private func rebuildWindow() {
        guard let (screen, notch) = Self.notchScreen() else {
            window?.orderOut(nil); window = nil; self.screen = nil
            return
        }
        self.screen = screen
        metrics = .measured(notch.size, synthetic: screen.auxiliaryTopLeftArea == nil)

        let isNew = window == nil
        let panel = window ?? makePanel()
        // The hosting view survives a move between displays — rebuilding it
        // would restart every animation the notch is in the middle of.
        if isNew { panel.contentView = NSHostingView(rootView: NotchRoot(controller: self)) }
        // A rebuilt panel must not come back hit-testing with mouse-moved left
        // on from `makePanel`'s old default. Both flags follow the interaction.
        let interactive = state == .panel
        panel.ignoresMouseEvents = !interactive
        panel.acceptsMouseMovedEvents = interactive
        place(panel, screen: screen, notch: notch, display: true)
        panel.orderFrontRegardless()
        window = panel

        // The window must exist and be ordered in before it has a windowNumber.
        // Its own private space is what actually pins it during a space swipe;
        // collectionBehavior alone cannot do this.
        //
        // The space belongs to the display it was created on and cannot follow
        // the panel to another one — a window parked in it draws nowhere else,
        // which is exactly the "moved, but invisible" failure. On a synthetic
        // notch the panel gives the space up and leans on `.canJoinAllSpaces`
        // plus `repin` instead: swipe-proofing is the thing that gets traded.
        space.windows = screen.auxiliaryTopLeftArea != nil ? [panel] : []

        #if DEBUG
        NSLog("Vitals notch → screen %@ notch %@ frame %@ space %@",
              screen.localizedName, NSStringFromRect(notch),
              NSStringFromRect(panel.frame), space.windows.isEmpty ? "no" : "yes")
        #endif
    }

    private func place(_ panel: NSPanel, screen: NSScreen, notch: CGRect, display: Bool) {
        let size = metrics.screenWindowSize
        panel.setFrame(CGRect(x: notch.midX - size.width / 2,
                              y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: display)
    }

    private func repin() {
        guard let window, let (screen, notch) = Self.notchScreen() else { return }
        place(window, screen: screen, notch: notch, display: false)
        self.screen = screen
        window.orderFrontRegardless()
    }

    /// The pointer crossing to another display takes the notch with it, but only
    /// from rest: pulling the shape out from under a hover, or off a screen an
    /// Event is still being read on, is hostile.
    private func followPointer() {
        guard Self.externalDisplay, window != nil, atRest else { return }
        let p = NSEvent.mouseLocation
        guard let s = NSScreen.screens.first(where: { $0.frame.contains(p) }),
              s != screen else { return }
        rebuildWindow()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.isRestorable = false
        panel.animationBehavior = .none
        panel.isFloatingPanel = true
        panel.level = .mainMenu + 3
        // A nonactivating panel never becomes key, and cursor rects (what
        // `pointerStyle` installs) are ignored until it does. Mouse-moved stays
        // off until an Interaction is actually hit-testing: `grow` sets this
        // and `ignoresMouseEvents = false` together, `shrink` clears both.
        // Rest never has mouse-moved on while the panel is taking hits.
        panel.acceptsMouseMovedEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }

    /// When the menu bar is hidden the notch is someone's content — fullscreen,
    /// which is also when builds run and when the machine stalls. Events still
    /// draw over it; the resting glow and the hover states do not.
    /// ponytail: layer-24 probe, swap for a real fullscreen observer if it misreads.
    private func menuBarVisible() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return true }
        return list.contains { ($0[kCGWindowLayer as String] as? Int) == 24 }
    }

    /// Menu-bar visibility for a pointer event. A file drag already resolved
    /// this once; walking the window list per move is the cost this avoids.
    private func menuBarVisibleNow() -> Bool {
        dragMenuBarVisible ?? menuBarVisible()
    }

    // MARK: Telemetry → Events

    private func evaluate() {
        let reading = Reading(
            percent: telemetry.power.percent,
            onAC: telemetry.power.onAC,
            batteryWatts: telemetry.power.batteryWatts,
            thermalState: telemetry.thermalState
        )

        queue.append(contentsOf: engine.update(reading).map(NotchState.event))

        // The glow is residue on a resting notch, so it goes when the menu bar
        // does.
        // ponytail: re-read on the telemetry tick only, so entering fullscreen
        // leaves a glow up for one poll. Add a fullscreen observer if that shows.
        let visible = menuBarVisible()
        thermalGlow = visible ? engine.thermalGlow : nil

        trackVPN()

        presentNext()
    }

    /// The floor the notch falls back to. Idle, unless an Activity is running —
    /// a build replaces idle as the resting state for as long as it lasts.
    private var resting: NotchState {
        // A Behavior lifecycle supplies the stable start/end underneath. The
        // newest explicit Activity still owns the notch, but an Xcode one gets
        // the dedicated build presentation whether AX progress answers or not.
        if let explicit = externalActivities.values.max(by: { $0.startedAt < $1.startedAt }) {
            if isXcodeBuildActivity(explicit.name) { return xcodeBuildState() }
            return .externalActivity(explicit)
        }
        if let build = builds.progress {
            return xcodeBuildState(progress: build)
        }
        return .idle
    }

    private var xcodeIcon: NSImage? {
        NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.dt.Xcode"
        })?.icon ?? installedXcodeIcon
    }

    private func xcodeBuildState(progress: BuildProgress? = nil) -> NotchState {
        .building(XcodeBuildActivity(
            progress: progress ?? builds.progress,
            icon: progress?.icon ?? builds.progress?.icon ?? xcodeIcon))
    }

    /// Xcode's Behaviors end a run with `xcode-build-succeeded` or `-failed`.
    /// Those are drawn as the build verdict — Xcode's icon, the job, how long
    /// the run took — rather than as a generic command Event. Anything else
    /// stays an `externalEvent`.
    private func xcodeVerdict(_ event: ExternalEvent) -> NotchState? {
        guard isXcodeBuildActivity(event.subject) else { return nil }
        let ending: BuildProgress.Ending
        if event.isFailure {
            ending = .failed
        } else if ["succeeded", "success", "passed", "done"].contains(event.outcome.lowercased()) {
            ending = .succeeded
        } else {
            return nil
        }
        // The lifecycle that just stopped is this run. One older than half a
        // minute is a different run.
        let run = lastXcodeRun.flatMap { Date().timeIntervalSince($0.endedAt) < 30 ? $0 : nil }
        lastXcodeRun = nil
        return .verdict(BuildProgress(
            label: ending == .succeeded ? "Success" : "Failed",
            job: run?.job ?? builds.progress?.job ?? "Build",
            done: 0, total: 0,
            icon: xcodeIcon,
            ending: ending))
    }

    private var atRest: Bool {
        switch state {
        case .idle, .building, .externalActivity: true
        default: false
        }
    }

    // MARK: Explicit commands

    private func handle(_ command: ExternalCommand) {
        switch command {
        case .event(let event):
            queue.append(xcodeVerdict(event) ?? .externalEvent(event))
            presentNext()

        case .activityStart(let activity):
            externalActivities[activity.id] = activity
            if isXcodeBuildActivity(activity.name) { builds.explicitLifecycleStarted() }
            if atRest { state = resting }

        case .activityStop(let id):
            let stopped = externalActivities.removeValue(forKey: id)
            // Noted here: the verdict event follows this stop, and by then the
            // lifecycle — and Xcode's job word — may be gone.
            if let stopped, isXcodeBuildActivity(stopped.name) {
                lastXcodeRun = (builds.progress?.job, Date())
            }
            if let stopped, isXcodeBuildActivity(stopped.name),
               !externalActivities.values.contains(where: { isXcodeBuildActivity($0.name) }) {
                builds.explicitLifecycleEnded()
            }
            if atRest { state = resting }

        case .extensionStart(let item):
            let name = item.name.lowercased()
            if !reportedExtensions.values.contains(where: { $0.name.lowercased() == name }) {
                extensionStartedAt[name] = item.startedAt
            }
            reportedExtensions[item.id] = item
            updateExtensionSlots()

        case .extensionStop(let id):
            guard let stopped = reportedExtensions.removeValue(forKey: id) else { return }
            let name = stopped.name.lowercased()
            if !reportedExtensions.values.contains(where: { $0.name.lowercased() == name }) {
                extensionStartedAt[name] = nil
            }
            updateExtensionSlots()
        }
    }

    private func updateExtensionSlots() {
        var active = reportedExtensions.values.reduce(into: [String: NotchExtension]()) { out, item in
            let name = item.name.lowercased()
            guard out[name] == nil else { return }
            out[name] = NotchExtension(
                id: "reported-\(name)", name: item.name,
                startedAt: extensionStartedAt[name] ?? item.startedAt)
        }
        for (name, item) in previewExtensions where active[name] == nil {
            active[name] = item
        }
        extensions = .arrange(Array(active.values))
    }

    /// VPN is a level reading; only its edges and its age are news. Off → on
    /// queues the connect pill, every time, auto-connect included. While it
    /// stays on, each mark in `vpnReminderMarks` queues one reminder. Off says
    /// nothing and resets the schedule.
    private func trackVPN() {
        let on = telemetry.net.vpn
        defer { vpnPrimed = true }
        guard on else {
            if vpnOnSince != nil {
                vpnOnSince = nil
                vpnRemindersShown = 0
                // A pill about a tunnel that has already closed is wrong news.
                queue.removeAll { if case .vpn = $0 { true } else { false } }
            }
            return
        }
        guard let since = vpnOnSince else {
            vpnOnSince = .now
            vpnRemindersShown = 0
            if vpnPrimed { queue.append(.vpn(VPNNotice(minutesOn: nil))) }
            return
        }
        let minutes = Int(Date().timeIntervalSince(since) / 60)
        // The latest mark passed, not every one: a Mac that slept through two
        // marks gets one reminder, never a stack of them.
        guard let reached = Self.vpnReminderMarks.lastIndex(where: { $0 <= minutes }),
              reached >= vpnRemindersShown else { return }
        vpnRemindersShown = reached + 1
        queue.removeAll { if case .vpn(let n) = $0 { n.minutesOn != nil } else { false } }
        queue.append(.vpn(VPNNotice(minutesOn: Self.vpnReminderMarks[reached])))
    }

    private func isXcodeBuildActivity(_ name: String) -> Bool {
        let words = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        // Only the Xcode Behavior protocol gets Xcode identity. A generic CLI
        // build remains a generic reported Activity and must not suppress or
        // stop the Accessibility watcher for an unrelated Xcode build.
        return words.contains("xcode") &&
            (words.contains("build") || words.contains("archive"))
    }

    // MARK: Arbitration

    private func presentNext() {
        // Walks the queue only to drop what has gone stale on the way; the
        // first live entry takes the notch, and the rest wait their turn.
        while let next = queue.first {
            // A track change shown late is about a song you are already
            // hearing. Past a second it is dropped, not shown.
            if case .trackChange(let change) = next, Date().timeIntervalSince(change.at) > 1 {
                queue.removeFirst()
                continue
            }
            guard atRest else { return }
            queue.removeFirst()
            presentAlone(next)
            return
        }
    }

    /// A state that owns the whole notch for its lifetime and then hands it
    /// straight back — to the Activity it borrowed it from if that is still
    /// running, and to idle if the work finished meanwhile.
    private func presentAlone(_ next: NotchState) {
        state = next
        eventDismiss?.invalidate()
        eventDismiss = Timer.scheduledTimer(withTimeInterval: Self.duration(of: next), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                // Only the pill this timer was armed for may be taken down by
                // it. Anything that happened since — a hover, another pill, the
                // next preview — owns the notch now, and clearing the state out
                // from under it strands that state's bookkeeping: a hover left
                // with the panel still taking the mouse, a flank whose slot is
                // never released.
                //
                // Comparing against the pill also covers the two old guards. A
                // hover is not the pill, so it holds until the user leaves it. A
                // real build *is* the resting state and is never presented this
                // way, so it holds; a previewed one is, so it times out like
                // every other pill.
                guard let self, self.state == next else { return }
                self.state = self.resting
                self.presentNext()
            }
        }
    }

    // MARK: Permissions

    /// Xcode's toolbar is the only source for live progress, and reading it
    /// needs Accessibility. The grant is the whole opt-in — there is no separate
    /// switch — and it flips back to false every time a dev build is re-signed.
    var buildAccess: Bool { builds.trusted }
    func requestBuildAccess() { builds.requestAccess() }

    // MARK: Previews

    typealias Preview = (label: String, state: NotchState)

    /// Every state the notch can show, under the subsystem `product.md` files it
    /// under, so a layout change can be eyeballed without waiting on the hardware
    /// to misbehave. Settings draws one section per group.
    ///
    /// Glow-only signals are absent on purpose: they light an edge for as long as
    /// they hold rather than presenting, so there is nothing to fire. So are the
    /// Interactions — hovering the notch is already the way to see those.
    static let previews: [(group: String, previews: [Preview])] = [
        // Heat is absent with the other glow-only signals: it lights the edges
        // and never presents.
        ("Power",   [pill(.chargingStarted), pill(.charged)]),
        ("Connections", [
            ("AirPods connected", .accessory(Accessory(name: "AirPods Pro", kind: .audio, battery: 72))),
            // No level reported — the flank falls back to the Bluetooth mark.
            ("Keyboard connected", .accessory(Accessory(name: "Magic Keyboard", kind: .keyboard, battery: nil))),
            // Two thirds up, so the preview shows the wave count doing something
            // rather than sitting at either end of its range.
            ("Audio lost", .audioLost(loudness: 0.66)),
        ]),
        ("Xcode", [
            ("Build in Progress (w/o tracking)", .building(XcodeBuildActivity(
                progress: nil,
                icon: xcodePreviewIcon()))),
            ("Build in Progress (tracked)", .building(XcodeBuildActivity(
                progress: buildPreview("Building", nil),
                icon: xcodePreviewIcon()))),
            ("Build failed", .verdict(buildPreview("Failed", .failed))),
            ("Build succeeded", .verdict(buildPreview("Success", .succeeded))),
        ]),
        ("VPN", [
            ("VPN connected", .vpn(VPNNotice(minutesOn: nil))),
            ("VPN on for an hour", .vpn(VPNNotice(minutesOn: 60))),
        ]),
        ("Commands", [
            ("Tests running", .externalActivity(ExternalActivity(
                id: "preview", name: "tests", startedAt: .now))),
            ("Tests passed", .externalEvent(ExternalEvent(name: "tests-passed"))),
            ("Deploy failed", .externalEvent(ExternalEvent(name: "deploy-failed"))),
        ]),
    ]

    private static func pill(_ signal: Signal) -> Preview {
        (signal.title, .event(Event(signal: signal)))
    }

    private static func buildPreview(_ label: String, _ ending: BuildProgress.Ending?) -> BuildProgress {
        BuildProgress(label: label, done: 3019, total: 6766,
                      icon: xcodePreviewIcon(),
                      ending: ending)
    }

    private static func xcodePreviewIcon() -> NSImage? {
        NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode")
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Presents the real concurrent layout rather than inventing a standalone
    /// preview state. Six seconds leaves enough time to press the other button
    /// and inspect activation order; each button refreshes its own clock.
    func previewExtension(_ name: String) {
        let key = name.lowercased()
        previewExtensionDismiss[key]?.invalidate()
        previewExtensions[key] = NotchExtension(
            id: "preview-\(key)", name: name, startedAt: .now)
        updateExtensionSlots()

        previewExtensionDismiss[key] = Timer.scheduledTimer(
            withTimeInterval: Self.extensionPreviewDuration, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.previewExtensions[key] = nil
                self.previewExtensionDismiss[key] = nil
                self.updateExtensionSlots()
            }
        }
    }

    func preview(_ state: NotchState) {
        queue.append(state)
        // Whatever is up loses: pressing a second button is a request to see
        // that state now, not after the current one times out. A press that
        // drains nothing was blocked by something owning the whole notch, and
        // that is exactly the case where it has to be cleared for it: the
        // button has to do something visible every single time it is pressed.
        let queued = queue.count
        if atRest { presentNext() }
        if queue.count == queued { shrink() }
    }

    // MARK: Files

    func airDrop(_ urls: [URL]) {
        AirDropper.shared.send(urls, from: window?.contentView)
    }

    func endFileDrag() {
        approachTimer?.invalidate()
        approachTimer = nil
        guard fileDrag != nil else { return }
        fileDrag = nil
    }

    /// The drag left the panel, a drop landed, or a shelf item's own drag
    /// ended. Does not clear `draggingFile` while the button is still down —
    /// that flag is what stops the pointing hand painting over the drag cursor,
    /// and mouse-up is the only thing that means the drag is actually over.
    func fileDragEnded() {
        let buttonUp = NSEvent.pressedMouseButtons & 1 == 0
        finishFileDrag(clearDragging: buttonUp)
    }

    /// Mouse-up over this window never reaches the global monitor. The button
    /// is up even when `pressedMouseButtons` still reports it for the duration
    /// of the up event, so the drag flag clears here.
    private func pointerReleased() {
        finishFileDrag(clearDragging: true)
    }

    private func finishFileDrag(clearDragging: Bool) {
        let wasDrag = draggingFile || fileDrag != nil || arrowAfterDrag
        dragBaseline = -1
        dragIsFile = nil
        dragMenuBarVisible = nil
        endFileDrag()
        guard clearDragging else {
            if wasDrag { arrowAfterDrag = true }
            return
        }
        draggingFile = false
        if wasDrag { arrowAfterDrag = true }
        restoreCursorAfterDrag()
    }

    /// Arrow only when the pointer is on the shape that is actually taking
    /// hits. The window frame is the full panel plus its shadow in every state,
    /// including while `ignoresMouseEvents` is true, so it is not that shape.
    /// A mouse-up anywhere else leaves the cursor alone.
    private func restoreCursorAfterDrag() {
        let pending = arrowAfterDrag
        arrowAfterDrag = false
        guard pending, pointerOverOpenNotch else { return }
        VitalsCursor.forceArrow()
    }

    /// The panel is up, and only while that window is hit-testing.
    private var pointerOverOpenNotch: Bool {
        guard window?.ignoresMouseEvents == false, let screen,
              state == .panel else { return false }
        let (shape, lean) = metrics.screenShape(for: state, extensions: extensions)
        let rect = CGRect(x: screen.frame.midX - shape.width / 2 + lean,
                          y: screen.frame.maxY - shape.height,
                          width: shape.width, height: shape.height)
        return rect.contains(NSEvent.mouseLocation)
    }

    /// Shelf drops and an item dragged out of the shelf end on the view, which
    /// cannot see a mouse-up once the pointer is over this window.
    func setDraggingFile(_ on: Bool) {
        if draggingFile != on { draggingFile = on }
    }

    /// A file drag inside the reach around the housing, before the panel is a
    /// real drop target. The global monitor goes deaf once the pointer is over
    /// the open panel, so this only covers the approach; SwiftUI's drop takes
    /// over from there. Quantized so a moving pointer does not republish
    /// every pixel — nothing here runs unless a drag is already in hand.
    private func trackFileDrag() {
        // `dragIsFile` and the menu-bar bit were resolved once, on the drag
        // that started this gesture. Probing the pasteboard or the window list
        // here would run on every move.
        guard dragIsFile == true, dragMenuBarVisible == true,
              dragBaseline != -1,
              dragPasteboard.changeCount != dragBaseline,
              let screen, let notch = notchRect else {
            endFileDrag()
            return
        }
        // Same gate as `dragMoved`. A hidden menu bar (fullscreen) and a shape
        // that is not at rest are not an approach — reaching with them would
        // keep a pill or a fullscreen notch reaching for a file it will not take.
        let p = NSEvent.mouseLocation
        let span = notch.width / 2 + 120
        let near = abs(p.x - notch.midX) < span
            && p.y < screen.frame.maxY + 4
            && p.y > notch.minY - 110
        guard atRest, near else {
            endFileDrag()
            return
        }
        let below = max(0, notch.minY - p.y)
        let pull = quant(1 - min(1, below / 110))
        guard pull > 0.02 else {
            endFileDrag()
            return
        }
        let next = FileDrag(pull: min(1, pull))
        if next != fileDrag { fileDrag = next }
        commitApproach(at: p, pull: pull)
    }

    /// Opens the panel under a file that is clearly coming in, before it gets
    /// to the menu bar. Only once the pointer is inside the area the open
    /// panel will cover — so the file is already over the drop target when it
    /// opens — and only if it is still there after the dwell. `dragMoved`'s
    /// in-notch trigger stays as the fallback.
    private func commitApproach(at p: CGPoint, pull: CGFloat) {
        guard pull >= Self.approachPull, let screen, wouldBeInsidePanel(p, on: screen) else {
            approachTimer?.invalidate()
            approachTimer = nil
            return
        }
        guard approachTimer == nil else { return }
        approachTimer = Timer.scheduledTimer(withTimeInterval: Self.approachDwell, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.approachTimer = nil
                // Re-read rather than trusting the arming sample: the drag may
                // have moved on, ended, or something else may own the notch.
                let now = NSEvent.mouseLocation
                guard self.dragIsFile == true, self.atRest,
                      (self.fileDrag?.pull ?? 0) >= Self.approachPull,
                      let screen = self.screen, self.wouldBeInsidePanel(now, on: screen)
                else { return }
                self.grow()
            }
        }
    }

    /// The open panel's shape on this screen — the same rect `mouseMoved`
    /// keeps the pointer inside once it is up.
    private func wouldBeInsidePanel(_ p: CGPoint, on screen: NSScreen) -> Bool {
        let (shape, lean) = metrics.screenShape(for: .panel, extensions: extensions)
        let rect = CGRect(x: screen.frame.midX - shape.width / 2 + lean,
                          y: screen.frame.maxY - shape.height,
                          width: shape.width, height: shape.height)
        return rect.contains(p)
    }

    private func quant(_ value: CGFloat, _ steps: CGFloat = 20) -> CGFloat {
        (value * steps).rounded() / steps
    }

    /// A notch at rest cannot be a drag destination — the panel is
    /// mouse-transparent and notch-sized, so AppKit never offers it the drag.
    /// Watching the drag pasteboard is what lets the shelf open under the
    /// cursor; from there the panel is live and SwiftUI's own drop takes over.
    private func dragMoved() {
        // The count changes the moment any drag starts, window drags included.
        // Whether it is a file, and whether the menu bar is up, was decided
        // once when the drag began.
        guard dragIsFile == true, dragMenuBarVisible == true,
              atRest, dragBaseline != -1,
              dragPasteboard.changeCount != dragBaseline,
              let notch = notchRect, notch.contains(NSEvent.mouseLocation) else { return }
        grow()
    }

    // MARK: Hover

    private var notchRect: CGRect? {
        guard let screen, window != nil else { return nil }
        let notch = CGSize(width: metrics.notch.width * metrics.scale,
                           height: metrics.notch.height * metrics.scale)
        return CGRect(x: screen.frame.midX - notch.width / 2,
                      y: screen.frame.maxY - notch.height,
                      width: notch.width, height: notch.height)
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            // A new click means the previous drag's button is up. The arrow
            // comes back only if this click is on the open shape.
            if draggingFile || arrowAfterDrag {
                finishFileDrag(clearDragging: true)
            }
            dragBaseline = dragPasteboard.changeCount
            dragIsFile = nil
            dragMenuBarVisible = nil
            endFileDrag()
        case .leftMouseUp:
            pointerReleased()
        case .leftMouseDragged:
            lastDrag = .now
            if dragIsFile == nil, dragBaseline != -1,
               dragPasteboard.changeCount != dragBaseline {
                dragIsFile = dragPasteboard.canReadObject(
                    forClasses: [NSURL.self],
                    options: [.urlReadingFileURLsOnly: true]
                )
                dragMenuBarVisible = menuBarVisible()
            }
            if dragIsFile == true { draggingFile = true }
            trackFileDrag()
            dragMoved()
            mouseMoved()
        default: mouseMoved()
        }
    }

    private func mouseMoved() {
        followPointer()
        guard let screen, let notch = notchRect else { return }
        let p = NSEvent.mouseLocation

        if state == .panel {
            // The panel's own shape is the region to stay inside.
            let (grown, lean) = metrics.screenShape(for: state, extensions: extensions)
            // Uneven flanks slide the shape off the notch's centre, so the
            // region to stay inside slides with it — see `NotchMetrics.lean`.
            let rect = CGRect(x: screen.frame.midX - grown.width / 2 + lean,
                              y: screen.frame.maxY - grown.height,
                              width: grown.width, height: grown.height)
            // Straying outside mid-drag must not slam the shelf shut with the
            // file still in hand — only a mouse-up ends the drag.
            if !rect.insetBy(dx: -8, dy: -8).contains(p),
               Date.now.timeIntervalSince(lastDrag) > 0.5 { shrink() }
            return
        }

        // The panel needs a dwell delay, or it opens every time the pointer
        // crosses the notch on its way to the menu bar.
        guard notch.contains(p), menuBarVisibleNow(), atRest else {
            dwell?.invalidate(); dwell = nil
            return
        }
        guard dwell == nil else { return }
        dwell = Timer.scheduledTimer(withTimeInterval: Self.dwellDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, notch.contains(NSEvent.mouseLocation), self.atRest else { return }
                self.grow(.panel)
            }
        }
    }

    /// Into the panel, which takes the mouse — it has the stats, the shelf
    /// and its pages to click. The global monitor goes deaf while the pointer is over it,
    /// but it hears the move that leaves it, which is the one `shrink` needs.
    func grow(_ next: NotchState = .panel) {
        dwell?.invalidate(); dwell = nil
        state = next
        // The panel shows live numbers — its CPU flank would sit up to 10s
        // stale on the resting poll, which is longer than a hover.
        telemetry.grown = true
        // The reader runs only while there is a panel to show it in.
        nowPlaying.active = true
        window?.ignoresMouseEvents = false
        window?.acceptsMouseMovedEvents = true
    }

    /// Back to the floor: idle, or the Activity still running under it.
    func shrink() {
        dwell?.invalidate(); dwell = nil
        // The control under the pointer is about to leave the hierarchy, and
        // its tracking area does not always get mouseExited once this window
        // stops taking events. Drop every hover claim. `forceArrow` leaves the
        // drag cursor alone while a file is still in hand — mouse-up clears
        // `draggingFile`, not this.
        VitalsCursor.forceArrow()
        state = resting
        telemetry.grown = false
        nowPlaying.active = false
        window?.ignoresMouseEvents = true
        window?.acceptsMouseMovedEvents = false
        presentNext()
    }
}

private struct NotchRoot: View {
    @Bindable var controller: NotchController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NotchView(state: controller.state,
                  metrics: controller.metrics,
                  extensions: controller.extensions,
                  telemetry: controller.telemetry,
                  thermalGlow: controller.thermalGlow,
                  shelf: controller.shelf,
                  nowPlaying: controller.nowPlaying,
                  fileDrag: controller.fileDrag,
                  endFileDrag: controller.endFileDrag,
                  airDrop: controller.airDrop,
                  show: controller.grow)
            .contextMenu {
                // Not `SettingsLink`: it opens the window without activating
                // Vitals, so Settings landed behind the frontmost app.
                Button("Settings…") {
                    openSettings()
                    SettingsWindow.bringForward()
                }
                Divider()
                Button("Quit Vitals") { NSApp.terminate(nil) }
            }
            .onExitCommand { controller.shrink() }
    }
}
