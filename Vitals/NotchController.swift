import AppKit
import SwiftUI
import Observation

@Observable
@MainActor
final class NotchController {
    private(set) var mode: NotchMode = .idle
    private(set) var metrics = NotchMetrics(notch: .zero)

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
    private var queue: [NotchMode] = []
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var dragBaseline = -1
    // Global monitors go deaf once the pointer is over our own window, and a
    // drop there never produces a mouse-up we can see — so "still dragging" is
    // measured by how recently drag events arrived, not by mouse-up.
    private var lastDrag = Date.distantPast

    private static let dwellDelay: TimeInterval = 0.25
    private static let eventDuration: TimeInterval = 2.6

    func start() {
        rebuildWindow()
        telemetry.onUpdate = { [weak self] in self?.evaluate() }
        telemetry.start()

        accessories.onConnect = { [weak self] accessory in
            guard let self else { return }
            queue.append(.accessory(accessory))
            presentNext()
        }
        accessories.start()

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

    /// The notch lives between the two auxiliary menu bar areas. No auxiliary
    /// areas means no notch, and v1 is built-in display only.
    private static func notchScreen() -> (NSScreen, CGRect)? {
        for s in NSScreen.screens {
            guard let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea else { continue }
            let rect = CGRect(x: l.maxX, y: s.frame.maxY - l.height,
                              width: r.minX - l.maxX, height: l.height)
            if rect.width > 1 { return (s, rect) }
        }
        return nil
    }

    private func rebuildWindow() {
        guard let (screen, notch) = Self.notchScreen() else {
            window?.orderOut(nil); window = nil; self.screen = nil
            return
        }
        self.screen = screen
        metrics = NotchMetrics(notch: notch.size)

        let size = metrics.windowSize
        let frame = CGRect(x: notch.midX - size.width / 2,
                           y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)

        let panel = window ?? makePanel()
        panel.setFrame(frame, display: true)
        panel.contentView = NSHostingView(rootView: NotchRoot(controller: self))
        panel.orderFrontRegardless()
        window = panel

        // The window must exist and be ordered in before it has a windowNumber.
        // Its own private space is what actually pins it during a space swipe;
        // collectionBehavior alone cannot do this.
        space.windows = [panel]
    }

    private func repin() {
        guard let window, let (screen, notch) = Self.notchScreen() else { return }
        let size = metrics.windowSize
        window.setFrame(CGRect(x: notch.midX - size.width / 2,
                               y: screen.frame.maxY - size.height,
                               width: size.width, height: size.height), display: false)
        window.orderFrontRegardless()
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

    /// Q13: when the menu bar is hidden the notch is someone's content. Tier-2
    /// pills still draw; the resting hairline and hover panel do not.
    /// ponytail: layer-24 probe, swap for a real fullscreen observer if it misreads.
    private func menuBarVisible() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return true }
        return list.contains { ($0[kCGWindowLayer as String] as? Int) == 24 }
    }

    // MARK: Telemetry → events

    private func evaluate() {
        let p = telemetry.power, s = telemetry.stall
        let reading = Reading(
            percent: p.percent,
            onAC: p.onAC,
            batteryWatts: p.batteryWatts,
            pressure: s.pressure,
            thermalIndex: [.nominal: 0, .fair: 1, .serious: 2, .critical: 3][s.thermal] ?? 0,
            cpuSustainedSeconds: telemetry.cpuSustainedSeconds,
            swapGrowthMB: telemetry.swapGrowthMB
        )

        queue.append(contentsOf: engine.update(reading).map(NotchMode.event))
        presentNext()
    }

    private func presentNext() {
        guard case .idle = mode, !queue.isEmpty else { return }
        mode = queue.removeFirst()
        eventDismiss?.invalidate()
        eventDismiss = Timer.scheduledTimer(withTimeInterval: Self.eventDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                // Hovering promotes the pill to the panel, which is the user's
                // to close — the auto-hide only owns the transient states.
                guard let self, self.mode != .expanded, self.mode != .idle else { return }
                self.mode = .idle
                self.presentNext()
            }
        }
    }

    // MARK: Files

    func airDrop(_ urls: [URL]) {
        AirDropper.shared.send(urls, from: window?.contentView)
    }

    /// A collapsed notch cannot be a drag destination — the panel is
    /// mouse-transparent and notch-sized, so AppKit never offers it the drag.
    /// Watching the drag pasteboard is what lets the shelf open under the
    /// cursor; from there the panel is live and SwiftUI's own drop takes over.
    private func dragMoved() {
        guard case .idle = mode, dragBaseline != -1,
              dragPasteboard.changeCount != dragBaseline,
              let notch = notchRect, notch.contains(NSEvent.mouseLocation),
              menuBarVisible() else { return }
        // The count changes the moment any drag starts, window drags included,
        // so the payload still has to be something the shelf can hold.
        guard dragPasteboard.canReadObject(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) else { return }
        expand()
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
        guard let screen, let notch = notchRect else { return }
        let p = NSEvent.mouseLocation

        if mode == .expanded {
            let panel = CGRect(x: screen.frame.midX - metrics.panelWidth / 2,
                               y: screen.frame.maxY - metrics.size(for: .expanded).height,
                               width: metrics.panelWidth, height: metrics.size(for: .expanded).height)
            // Straying outside mid-drag must not slam the shelf shut with the
            // file still in hand — only a mouse-up ends the drag.
            if !panel.insetBy(dx: -8, dy: -8).contains(p),
               Date.now.timeIntervalSince(lastDrag) > 0.5 { collapse() }
            return
        }

        // Q10: a dwell delay, or the panel fires every time you reach for the menu bar.
        guard notch.contains(p), menuBarVisible(), case .idle = mode else {
            dwell?.invalidate(); dwell = nil
            return
        }
        guard dwell == nil else { return }
        dwell = Timer.scheduledTimer(withTimeInterval: Self.dwellDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, notch.contains(NSEvent.mouseLocation), case .idle = self.mode else { return }
                self.expand()
            }
        }
    }

    private func expand() {
        dwell?.invalidate(); dwell = nil
        mode = .expanded
        telemetry.expanded = true
        window?.ignoresMouseEvents = false
    }

    func collapse() {
        dwell?.invalidate(); dwell = nil
        mode = .idle
        telemetry.expanded = false
        window?.ignoresMouseEvents = true
        presentNext()
    }
}

private struct NotchRoot: View {
    @Bindable var controller: NotchController

    var body: some View {
        NotchView(mode: controller.mode,
                  metrics: controller.metrics,
                  shelf: controller.shelf,
                  airDrop: controller.airDrop)
            .contextMenu {
                SettingsLink { Text("Settings…") }
                Divider()
                Button("Quit Vitals") { NSApp.terminate(nil) }
            }
            .onExitCommand { controller.collapse() }
    }
}
