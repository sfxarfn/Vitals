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
            Section("Permissions") { buildAccess }
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
        }
        .formStyle(.grouped)
        .frame(width: 320)
    }

    /// Reading Xcode's toolbar is the only thing here that needs a grant, and it
    /// dies on every re-signed dev build — so this is not a one-time onboarding
    /// row, it comes back.
    @ViewBuilder private var buildAccess: some View {
        if NotchController.shared?.buildAccess == true {
            Label("Accessibility granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        } else {
            LabeledContent("Accessibility") {
                Button("Grant…") { NotchController.shared?.requestBuildAccess() }
            }
            Text("Build progress is read from Xcode's toolbar. Remove and re-add Vitals in the list if it is already checked.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
