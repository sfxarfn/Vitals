//
//  Accessory.swift
//  Vitals
//

import Foundation
import IOKit
import SwiftUI

/// A wireless accessory the Mac just picked up. Battery is optional — plenty of
/// devices publish the service without ever filling the key in.
struct Accessory: Equatable {
    var name: String
    var battery: Int?

    var symbol: String {
        let n = name.lowercased()
        if n.contains("airpods max")    { return "airpods.max" }
        if n.contains("airpods pro")    { return "airpodspro" }
        if n.contains("airpods")        { return "airpods" }
        if n.contains("beats")          { return "beats.headphones" }
        if n.contains("mouse")          { return "magicmouse.fill" }
        if n.contains("trackpad")       { return "trackpad.fill" }
        if n.contains("keyboard")       { return "keyboard.fill" }
        return "headphones"
    }

    var batteryTint: Color {
        switch battery ?? 100 {
        case ..<11: .red
        case ..<21: .yellow
        default:    .green
        }
    }
}

/// Announces accessories as they attach. IOKit's matching notification is the
/// push channel; the properties are read a beat later because the battery keys
/// land after the service itself does.
///
/// ponytail: `AppleDeviceManagementHIDEventService` only, which covers Apple
/// gear (AirPods, Beats, Magic mouse/keyboard/trackpad). Third-party Bluetooth
/// audio never publishes it — that needs IOBluetooth plus the
/// `com.apple.security.device.bluetooth` entitlement, so add it if it matters.
@MainActor
final class AccessoryWatcher {
    var onConnect: ((Accessory) -> Void)?

    private let port = IONotificationPortCreate(kIOMainPortDefault)
    private var iterator: io_iterator_t = 0
    /// The first drain reports everything already attached; that is not news.
    private var primed = false

    /// The service publishes before its battery keys do. Calibration knob: raise
    /// it if the ring keeps coming up empty on a real pair of AirPods.
    private static let settle: Duration = .seconds(1.2)

    func start() {
        guard let port else { return }
        IONotificationPortSetDispatchQueue(port, .main)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification,
            IOServiceMatching("AppleDeviceManagementHIDEventService"),
            { ctx, iter in
                guard let ctx else { return }
                MainActor.assumeIsolated {
                    Unmanaged<AccessoryWatcher>.fromOpaque(ctx).takeUnretainedValue().drain(iter)
                }
            }, ctx, &iterator)

        // Draining is also what arms the notification, so this call is required
        // even though everything it finds is deliberately thrown away.
        drain(iterator)
        primed = true
    }

    private func drain(_ iter: io_iterator_t) {
        var services: [io_object_t] = []
        while case let s = IOIteratorNext(iter), s != 0 { services.append(s) }
        defer { services.forEach { IOObjectRelease($0) } }
        guard primed else { return }

        for service in services where Self.read(service) != nil {
            IOObjectRetain(service)
            Task {
                try? await Task.sleep(for: Self.settle)
                defer { IOObjectRelease(service) }
                if let a = Self.read(service) { self.onConnect?(a) }
            }
        }
    }

    private static func read(_ service: io_object_t) -> Accessory? {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let p = props?.takeRetainedValue() as? [String: Any] else { return nil }
        // The built-in keyboard and trackpad publish the same service over a
        // wired transport; only the wireless ones are worth announcing.
        guard (p["Transport"] as? String)?.caseInsensitiveCompare("bluetooth") == .orderedSame else { return nil }

        // AirPods report each bud separately; the emptier one is the honest
        // number. The case is a separate thing and stays out of it.
        let levels = ["BatteryPercent", "BatteryPercentLeft", "BatteryPercentRight"]
            .compactMap { (p[$0] as? NSNumber)?.intValue }
            .filter { $0 > 0 }

        return Accessory(name: (p["Product"] as? String) ?? "Accessory", battery: levels.min())
    }
}
