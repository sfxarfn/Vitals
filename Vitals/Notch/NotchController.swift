import AppKit
import SwiftUI
import Observation

@Observable
@MainActor
final class NotchController {
    /// Settings is its own scene with no path back to the delegate that owns
    /// this, so the running controller publishes itself.
    private(set) static var shared: NotchController?

    private(set) var state: NotchState = .idle
    private(set) var metrics = NotchMetrics(notch: .zero)
    private(set) var cpuGlow: Signal?
    private(set) var thermalGlow: Signal?
    private(set) var extensions = ExtensionSlots.empty

    let telemetry = Telemetry()
    let shelf = Shelf()

    private var engine = EventEngine()
    private var window: NSPanel?
    // Int32.max, not Int.max — the level is a 32-bit value and a 64-bit one
    // truncates to garbage, which renders the space nowhere.
    private let space = CGSSpace(level: Int(Int32.max))
    private var screen: NSScreen?
    private var mouseMonitor: Any?
    private var dwell: Timer?
    private var eventDismiss: Timer?
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
    private var vpnExtension: NotchExtension?
    /// Settings previews use the same allocator as live conditions, but expire
    /// on their own so closing Settings cannot strand a fake persistent icon.
    private var previewExtensions: [String: NotchExtension] = [:]
    private var previewExtensionDismiss: [String: Timer] = [:]
    /// Events waiting for the notch, in the order they arrived.
    private var queue: [NotchState] = []
    /// The one-sided Events currently up, keyed by the side they own, and a
    /// dismiss timer each. Two flanks, two subsystems, two clocks: Events on
    /// different sides show at once, so a left pill arriving while a right one
    /// is up joins it rather than waiting behind it, and each leaves when its
    /// own 2.6s is spent.
    private var sided: [Side: Event] = [:]
    private var sidedDismiss: [Side: Timer] = [:]
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var dragBaseline = -1
    // Global monitors go deaf once the pointer is over our own window, and a
    // drop there never produces a mouse-up we can see — so "still dragging" is
    // measured by how recently drag events arrived, not by mouse-up.
    private var lastDrag = Date.distantPast

    private static let dwellDelay: TimeInterval = 0.25
    private static let eventDuration: TimeInterval = 2.6
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
        metrics = NotchMetrics(notch: notch.size,
                               synthetic: screen.auxiliaryTopLeftArea == nil)

        let isNew = window == nil
        let panel = window ?? makePanel()
        // The hosting view survives a move between displays — rebuilding it
        // would restart every animation the notch is in the middle of.
        if isNew { panel.contentView = NSHostingView(rootView: NotchRoot(controller: self)) }
        place(panel, screen: screen, notch: notch, display: true)
        panel.orderFrontRegardless()
        window = panel

        // The window must exist and be ordered in before it has a windowNumber.
        // Its own private space is what actually pins it during a space swipe;
        // collectionBehavior alone cannot do this. orderFront joins the active
        // desktop, though, and that membership is what a swipe translates —
        // `stick` takes it back. It has to happen *after* orderFront: done
        // first, the order-front puts the panel straight back on the desktop.
        //
        // The space belongs to the display it was created on and cannot follow
        // the panel to another one — a window parked in it draws nowhere else,
        // which is exactly the "moved, but invisible" failure. On a synthetic
        // notch the panel gives the space up and leans on `.canJoinAllSpaces`
        // plus `repin` instead: swipe-proofing is the thing that gets traded.
        // orderFront is first on that path too. Once the panel has been taken
        // off every desktop, releasing the space before ordering would leave
        // it with no Space at all.
        let claim: Set<NSWindow> = screen.auxiliaryTopLeftArea != nil ? [panel] : []
        if space.windows == claim {
            space.stick()
        } else {
            space.windows = claim
        }

        #if DEBUG
        NSLog("Vitals notch → screen %@ notch %@ frame %@ space %@",
              screen.localizedName, NSStringFromRect(notch),
              NSStringFromRect(panel.frame), space.windows.isEmpty ? "no" : "yes")
        #endif
    }

    private func place(_ panel: NSPanel, screen: NSScreen, notch: CGRect, display: Bool) {
        let size = metrics.windowSize
        panel.setFrame(CGRect(x: notch.midX - size.width / 2,
                              y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: display)
    }

    private func repin() {
        guard let window, let (screen, notch) = Self.notchScreen() else { return }
        place(window, screen: screen, notch: notch, display: false)
        self.screen = screen
        window.orderFrontRegardless()
        // The Space change, and this order-front, both put the panel back on
        // the desktop that just activated. Re-claim it before the next swipe.
        space.stick()
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

    // MARK: Telemetry → Events

    private func evaluate() {
        let reading = Reading(
            percent: telemetry.power.percent,
            onAC: telemetry.power.onAC,
            batteryWatts: telemetry.power.batteryWatts,
            thermalState: telemetry.thermalState,
            cpuSustainedSeconds: telemetry.cpuSustainedSeconds
        )

        queue.append(contentsOf: engine.update(reading).map(NotchState.event))

        // The glow is residue on a resting notch, so it goes when the menu bar
        // does.
        // ponytail: re-read on the telemetry tick only, so entering fullscreen
        // leaves a glow up for one poll. Add a fullscreen observer if that shows.
        let visible = menuBarVisible()
        cpuGlow = visible ? engine.cpuGlow : nil
        thermalGlow = visible ? engine.thermalGlow : nil

        // VPN is a level reading, but its false→true edge supplies the timestamp
        // that lets it keep arrival order against explicitly reported Extensions.
        if telemetry.net.vpn, vpnExtension == nil {
            vpnExtension = NotchExtension(id: "telemetry-vpn", name: "vpn", startedAt: .now)
            updateExtensionSlots()
        } else if !telemetry.net.vpn, vpnExtension != nil {
            vpnExtension = nil
            updateExtensionSlots()
        }

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

    private func xcodeBuildState(progress: BuildProgress? = nil) -> NotchState {
        let liveIcon = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.dt.Xcode"
        })?.icon
        return .building(XcodeBuildActivity(
            progress: progress ?? builds.progress,
            icon: progress?.icon ?? builds.progress?.icon ?? liveIcon ?? installedXcodeIcon))
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
            queue.append(.externalEvent(event))
            presentNext()

        case .activityStart(let activity):
            externalActivities[activity.id] = activity
            if isXcodeBuildActivity(activity.name) { builds.explicitLifecycleStarted() }
            if atRest { state = resting }

        case .activityStop(let id):
            let stopped = externalActivities.removeValue(forKey: id)
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
        if let vpnExtension { active["vpn"] = vpnExtension }
        extensions = .arrange(Array(active.values))
    }

    private func isXcodeBuildActivity(_ name: String) -> Bool {
        let words = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        // Only the Xcode Behavior protocol gets Xcode identity. A generic CLI
        // build remains a generic reported Activity and must not suppress or
        // stop the Accessibility watcher for an unrelated Xcode build.
        return words.contains("xcode") &&
            (words.contains("build") || words.contains("archive"))
    }

    private var showingSided: Bool {
        if case .sided = state { return true }
        return false
    }

    // MARK: Arbitration

    private func presentNext() {
        // Walks the queue rather than taking one: Events on different sides show
        // at once, so several entries may be presentable on the same pass.
        // Anything that owns the whole notch still stops the walk — it has to
        // wait for the flanks to clear, and for the ones behind it to keep their
        // order behind it.
        while let next = queue.first {
            if case .event(let event) = next, event.signal.side != .center {
                guard atRest || showingSided else { return }
                queue.removeFirst()
                present(event, on: event.signal.side)
                continue
            }
            guard atRest else { return }
            queue.removeFirst()
            presentAlone(next)
            return
        }
    }

    /// One Event into one flank. A side already speaking is replaced rather than
    /// queued behind: two Events on one side are the same subsystem talking
    /// twice, and the newer thing it has to say is the true one.
    private func present(_ event: Event, on side: Side) {
        sidedDismiss[side]?.invalidate()
        sided[side] = event
        state = .sided(left: sided[.left], right: sided[.right])
        sidedDismiss[side] = Timer.scheduledTimer(withTimeInterval: Self.eventDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The flank is released whether or not these pills are still the
                // thing on screen — this timer is the only owner of the slot, so
                // bailing out early strands it and leaves a side marked busy
                // that nothing will ever free.
                self.sided[side] = nil
                self.sidedDismiss[side] = nil
                if self.showingSided {
                    self.state = self.sided.isEmpty ? self.resting
                                                   : .sided(left: self.sided[.left], right: self.sided[.right])
                }
                self.presentNext()
            }
        }
    }

    /// Drops both flanks at once — for the paths that take the notch away from
    /// the pills entirely, where letting the timers fire later would put a
    /// stale pill back over whatever replaced it.
    private func clearSided() {
        sidedDismiss.values.forEach { $0.invalidate() }
        sidedDismiss.removeAll()
        sided.removeAll()
    }

    /// A state that owns the whole notch for its lifetime and then hands it
    /// straight back — to the Activity it borrowed it from if that is still
    /// running, and to idle if the work finished meanwhile.
    private func presentAlone(_ next: NotchState) {
        state = next
        eventDismiss?.invalidate()
        eventDismiss = Timer.scheduledTimer(withTimeInterval: Self.eventDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                // Only the pill this timer was armed for may be taken down by
                // it. Anything that happened since — a hover, a sided pill, the
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
        ("Power",   [pill(.chargingStarted), pill(.charged)]),
        ("Thermal", [
            pill(.thermalSerious),
            pill(.thermalCritical),
            allClear(.thermalCritical),
        ]),
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

    private static func allClear(_ signal: Signal) -> Preview {
        (signal.recoveryTitle, .event(Event(signal: signal, recovered: true)))
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
        // that state now, not after the current one times out. Sided Events are
        // the exception — they are the thing you press two buttons to see
        // together, so the queue gets first refusal. A press that drains nothing
        // was blocked by something owning the whole notch, and that is exactly
        // the case where it has to be cleared for it: the button has to do
        // something visible every single time it is pressed.
        let queued = queue.count
        if atRest || showingSided { presentNext() }
        if queue.count == queued { shrink() }
    }

    // MARK: Files

    func airDrop(_ urls: [URL]) {
        AirDropper.shared.send(urls, from: window?.contentView)
    }

    /// A notch at rest cannot be a drag destination — the panel is
    /// mouse-transparent and notch-sized, so AppKit never offers it the drag.
    /// Watching the drag pasteboard is what lets the shelf open under the
    /// cursor; from there the panel is live and SwiftUI's own drop takes over.
    private func dragMoved() {
        guard atRest || state == .peek, dragBaseline != -1,
              dragPasteboard.changeCount != dragBaseline,
              let notch = notchRect, notch.contains(NSEvent.mouseLocation),
              menuBarVisible() else { return }
        // The count changes the moment any drag starts, window drags included,
        // so the payload still has to be something the shelf can hold.
        guard dragPasteboard.canReadObject(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) else { return }
        grow()
    }

    // MARK: Hover

    private var notchRect: CGRect? {
        guard let screen, window != nil else { return nil }
        return CGRect(x: screen.frame.midX - metrics.notch.width / 2,
                      y: screen.frame.maxY - metrics.notch.height,
                      width: metrics.notch.width, height: metrics.notch.height)
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown: dragBaseline = dragPasteboard.changeCount
        case .leftMouseUp:   dragBaseline = -1
        case .leftMouseDragged: lastDrag = .now; dragMoved(); mouseMoved()
        default: mouseMoved()
        }
    }

    private func mouseMoved() {
        followPointer()
        guard let screen, let notch = notchRect else { return }
        let p = NSEvent.mouseLocation

        if state == .panel || state == .peek {
            // Whichever shape is on screen is the region to stay inside; peek is
            // a good deal smaller than the panel.
            let grown = metrics.size(for: state, extensions: extensions)
            // Uneven flanks slide the shape off the notch's centre, so the
            // region to stay inside slides with it — see `NotchMetrics.lean`.
            let rect = CGRect(x: screen.frame.midX - grown.width / 2
                              + metrics.lean(for: state, extensions: extensions),
                              y: screen.frame.maxY - grown.height,
                              width: grown.width, height: grown.height)
            // Straying outside mid-drag must not slam the shelf shut with the
            // file still in hand — only a mouse-up ends the drag.
            if !rect.insetBy(dx: -8, dy: -8).contains(p),
               Date.now.timeIntervalSince(lastDrag) > 0.5 { shrink() }
            return
        }

        // An Interaction needs a dwell delay, or peek fires every time the
        // pointer crosses the notch on its way to the menu bar.
        guard notch.contains(p), menuBarVisible(), atRest else {
            dwell?.invalidate(); dwell = nil
            return
        }
        guard dwell == nil else { return }
        dwell = Timer.scheduledTimer(withTimeInterval: Self.dwellDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, notch.contains(NSEvent.mouseLocation), self.atRest else { return }
                // A loaded shelf is why you came back: peek would only make you
                // press the tray button to see what you already know is in there.
                // Empty, there is nothing to open onto and peek is the floor.
                self.grow(self.shelf.urls.isEmpty ? .peek : .panel)
            }
        }
    }

    /// Into an Interaction. Both of them take the mouse — peek has the gear to
    /// click. The global monitor goes deaf while the pointer is over the panel,
    /// but it hears the move that leaves it, which is the one `shrink` needs.
    func grow(_ next: NotchState = .panel) {
        dwell?.invalidate(); dwell = nil
        state = next
        // Both Interactions show live numbers — peek's CPU readout would sit up
        // to 10s stale on the resting poll, which is longer than a hover.
        telemetry.grown = true
        window?.ignoresMouseEvents = false
    }

    /// Back to the floor: idle, or the Activity still running under it.
    func shrink() {
        dwell?.invalidate(); dwell = nil
        clearSided()
        state = resting
        telemetry.grown = false
        window?.ignoresMouseEvents = true
        presentNext()
    }
}

private struct NotchRoot: View {
    @Bindable var controller: NotchController

    var body: some View {
        NotchView(state: controller.state,
                  metrics: controller.metrics,
                  extensions: controller.extensions,
                  telemetry: controller.telemetry,
                  cpuGlow: controller.cpuGlow,
                  thermalGlow: controller.thermalGlow,
                  shelf: controller.shelf,
                  airDrop: controller.airDrop,
                  show: controller.grow)
            .contextMenu {
                SettingsLink { Text("Settings…") }
                Divider()
                Button("Quit Vitals") { NSApp.terminate(nil) }
            }
            .onExitCommand { controller.shrink() }
    }
}
