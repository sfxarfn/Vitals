//
//  VitalsApp.swift
//  Vitals
//

import SwiftUI
import AppKit
import ServiceManagement

@main
struct VitalsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { SettingsView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = NotchController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        EventEngineSelfCheck.run()
        BuildWatcherSelfCheck.run()
        TelemetrySelfCheck.run()
        NotchExtensionSelfCheck.run()
        #endif
        NSApp.setActivationPolicy(.accessory)
        controller.start()
    }
}

struct SettingsView: View {
    /// Two panes, in the order the notch is built: what it does, then what it
    /// can be made to draw. Anything that is not a preview belongs in General.
    private enum Pane: String, CaseIterable, Identifiable {
        case general = "General"
        case preview = "Preview"

        var id: Self { self }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .preview: "eye"
            }
        }
    }

    @State private var pane: Pane = .general
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("externalDisplay") private var externalDisplay = false

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { item in
                Label(item.rawValue, systemImage: item.symbol)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 176, max: 200)
        } detail: {
            Group {
                switch pane {
                case .general: general
                case .preview: preview
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane.rawValue)
        }
        // The Settings scene has no size of its own, and a split view with no
        // frame collapses to its sidebar.
        .frame(width: 660, height: 440)
        // The window itself, as soon as SwiftUI has put this view in one — the
        // only hook that fires on every open, key or not. See `SettingsWindow`.
        .background(WindowReader { SettingsWindow.attach($0) })
    }

    // MARK: General

    @ViewBuilder private var general: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                Toggle("Show on external displays", isOn: $externalDisplay)
                    .onChange(of: externalDisplay) { _, on in
                        NotchController.shared?.setExternalDisplay(on)
                    }
                Text("The notch follows the pointer between displays. A display without a camera housing gets one drawn at the top of its menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Xcode") { buildAccess }
        }
    }

    // MARK: Preview

    @ViewBuilder private var preview: some View {
        Form {
            // One section per subsystem, in the order `product.md` lists them.
            ForEach(NotchController.previews, id: \.group) { group in
                Section(group.group) {
                    ForEach(group.previews, id: \.label) { item in
                        Button(item.label) {
                            NotchController.shared?.preview(item.state)
                        }
                    }
                }
            }
            Section("Extensions") {
                Button("Claude in progress") {
                    NotchController.shared?.previewExtension("claude")
                }
                Text("The preview stays active for six seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The grant is the only opt-in progress has, and the only thing here that
    /// needs one. Nothing asks for it on its own — the watcher stopped
    /// prompting mid-build — so this row is the whole path to it. It dies on
    /// every re-signed dev build, which is why it is not a one-time onboarding
    /// row: it comes back.
    @ViewBuilder private var buildAccess: some View {
        if NotchController.shared?.buildAccess == true {
            Label("Accessibility granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        } else {
            LabeledContent("Accessibility") {
                Button("Grant…") { NotchController.shared?.requestBuildAccess() }
            }
            Text("Optional. Adds Xcode's live task counter to a running build. Starts, results and cancels work without it. Remove and re-add Vitals in the list if it is already checked.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Settings window

/// Keeps the Settings window impossible to miss. An accessory app opening a
/// window does not activate itself, so Settings used to land behind whatever
/// app was frontmost, and a second click looked like it did nothing.
///
/// While the window is open Vitals becomes a regular app — a Dock icon and a
/// ⌘Tab entry, so you can see it is open and get back to it — and every open
/// activates it and brings the window forward. Closing the window puts the
/// accessory policy back. The notch panel is a nonactivating `NSPanel` and
/// behaves the same under either policy.
@MainActor
enum SettingsWindow {
    private static weak var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?

    /// The window SwiftUI opened, the first time and on every reopen — the
    /// scene may hand back the same window or a new one.
    static func attach(_ newWindow: NSWindow) {
        if newWindow !== window {
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            window = newWindow
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: newWindow, queue: .main
            ) { _ in
                MainActor.assumeIsolated { closed() }
            }
        }
        bringForward()
    }

    /// Activates Vitals and fronts the window. Called after `openSettings`, so
    /// a second click on an open window refocuses it instead of doing nothing;
    /// `openSettings` itself never makes a second window.
    static func bringForward() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
        guard let window else { return }   // not open yet: `attach` will do this
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Back to an accessory app. Deferred a turn so the window has finished
    /// closing; macOS then hands focus back to the app you came from, and the
    /// nonactivating notch panel is not touched.
    private static func closed() {
        window = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard window == nil else { return }   // reopened meanwhile
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

/// Reports the `NSWindow` a SwiftUI view lands in.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // Next turn: the window is mid-setup when this fires, and ordering
            // it front now can be undone by SwiftUI finishing its own open.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onWindow?(window) }
            }
        }
    }
}
