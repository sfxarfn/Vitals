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
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
            }
            Section("Xcode") { buildAccess }
            // One section per subsystem, in the order `product.md` lists them.
            // Two buttons on opposite sides fire together, which is the only way
            // to see a sided pair without waiting for the machine to produce one.
            ForEach(NotchController.previews, id: \.group) { group in
                Section("Preview · \(group.group)") {
                    ForEach(group.previews, id: \.label) { preview in
                        Button(preview.label) {
                            NotchController.shared?.preview(preview.state)
                        }
                    }
                }
            }
            Section("Preview · Extensions") {
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
        .formStyle(.grouped)
        .frame(width: 320)
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
