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
        #endif
        NSApp.setActivationPolicy(.accessory)
        controller.start()
    }
}

struct SettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            Section("Xcode builds") {
                if let controller = NotchController.shared, controller.buildAccess {
                    Label("Accessibility granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    // The grant dies on every re-signed dev build, so this row
                    // is not a one-time onboarding step — it comes back.
                    LabeledContent("Accessibility") {
                        Button("Grant…") { NotchController.shared?.requestBuildAccess() }
                    }
                    Text("Build progress is read from Xcode's toolbar. Remove and re-add Vitals in the list if it is already checked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Preview") {
                ForEach(NotchController.previews, id: \.label) { preview in
                    Button(preview.label) {
                        NotchController.shared?.preview(preview.mode)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 320)
    }
}
