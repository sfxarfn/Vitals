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
            // Two buttons on opposite sides fire together, which is the only way
            // to see a sided pair without waiting for the machine to produce one.
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
                Button("VPN connected") {
                    NotchController.shared?.previewExtension("vpn")
                }
                Text("Each preview stays active for six seconds. Press both to inspect activation order.")
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
