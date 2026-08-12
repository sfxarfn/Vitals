//
//  Accessory.swift
//  Vitals
//

import CoreAudio
import CoreBluetooth
import Foundation
import IOKit
import IOKit.hid
import SwiftUI

/// A wireless accessory the Mac just picked up. Battery is optional: only BLE
/// devices that publish the GATT Battery Service ever report one, so classic
/// Bluetooth headsets arrive with nothing but a name.
struct Accessory: Equatable {
    enum Kind { case audio, keyboard, pointer, gamepad }

    var name: String
    var kind: Kind
    var battery: Int?

    var symbol: String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpods.max" }
        if n.contains("airpods pro") { return "airpods.pro" }
        if n.contains("airpods")     { return "airpods" }
        if n.contains("beats")       { return "beats.headphones" }
        switch kind {
        case .audio:    return n.contains("speaker") ? "hifispeaker.fill" : "headphones"
        case .keyboard: return "keyboard.fill"
        case .pointer:  return "magicmouse.fill"
        case .gamepad:  return "gamecontroller.fill"
        }
    }

    var batteryTint: Color {
        switch battery ?? 100 {
        case ..<11: .red
        case ..<21: .yellow
        default:    .green
        }
    }
}

// MARK: - Watcher

/// Announces accessories as they attach. Two channels, because no single one
/// sees everything: input devices surface in the IORegistry as HID services,
/// and headsets only really announce themselves by becoming the audio output.
///
/// ponytail: audio detection watches the *default output device*, which is what
/// macOS switches to on connect. A headset connected without taking over output
/// is missed — listen on `kAudioHardwarePropertyDevices` and diff the list if
/// that turns out to happen.
@MainActor
final class AccessoryWatcher {
    var onConnect: ((Accessory) -> Void)?
    /// The headset that *was* the output is gone and sound has fallen back to
    /// the built-in speakers. Bluetooth → built-in only: swapping between two
    /// headsets is still a connect, and stays on `onConnect`.
    ///
    /// Carries the speakers' output volume, 0–1. How loudly the room can hear
    /// you is half of what this Event is for, so it is sampled at the moment of
    /// the handoff rather than read later off a device that may have moved on.
    var onDisconnect: ((Double) -> Void)?

    private let battery = BatteryReader()
    private let port = IONotificationPortCreate(kIOMainPortDefault)
    private var iterator: io_iterator_t = 0
    /// The first drain reports everything already attached; that is not news.
    private var primed = false
    private var lastAudioDevice = AudioDeviceID(0)
    /// By the time the callback runs the old device is already out of CoreAudio,
    /// so whether it was Bluetooth has to be remembered, not asked.
    private var lastAudioWasBluetooth = false
    private var recent: [String: Date] = [:]
    private static let dedupe: TimeInterval = 5

    /// The HID service publishes before its properties settle, and a freshly
    /// connected peripheral needs a moment before it will answer a GATT read.
    /// Calibration knob: raise it if names or battery come back empty.
    private static let settle: Duration = .seconds(1.2)

    func start() {
        startHID()
        startAudio()
    }

    // MARK: HID — Bluetooth keyboards, mice, trackpads, controllers

    private func startHID() {
        guard let port else { return }
        IONotificationPortSetDispatchQueue(port, .main)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        // IOProviderClass matching is subclass-inclusive, so this one dictionary
        // covers IOHIDUserDevice, AppleUserHIDDevice and the rest of the family.
        IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, IOServiceMatching("IOHIDDevice"),
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

        for service in services {
            guard let accessory = Self.readHID(service) else { continue }
            announce(accessory)
        }
    }

    private static func readHID(_ service: io_object_t) -> Accessory? {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let p = props?.takeRetainedValue() as? [String: Any],
              // "Bluetooth" and "Bluetooth Low Energy"; everything else is
              // internal (SPU, FIFO, Audio) or wired.
              (p["Transport"] as? String)?.hasPrefix("Bluetooth") == true,
              let name = p["Product"] as? String else { return nil }

        // Usage numbers only mean anything alongside their page: usage 1 is a
        // Pointer on page 1 but a Consumer Control on page 12, and headsets
        // publish exactly that for their AVRCP media keys. Only generic desktop
        // devices are claimed here — anything else, a headset included, is left
        // to the audio channel, which knows what it actually is.
        let page = (p["PrimaryUsagePage"] as? Int) ?? 0
        let usage = (p["PrimaryUsage"] as? Int) ?? 0
        guard page == kHIDPage_GenericDesktop else { return nil }

        let kind: Accessory.Kind? = switch usage {
        case kHIDUsage_GD_Keyboard, kHIDUsage_GD_Keypad:        .keyboard
        case kHIDUsage_GD_Mouse, kHIDUsage_GD_Pointer:          .pointer
        case kHIDUsage_GD_Joystick, kHIDUsage_GD_GamePad:       .gamepad
        default:                                                nil
        }
        guard let kind else { return nil }
        return Accessory(name: name, kind: kind, battery: nil)
    }

    // MARK: Audio — classic Bluetooth headsets

    private func startAudio() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        lastAudioDevice = Self.defaultOutputDevice()
        lastAudioWasBluetooth = Self.isBluetooth(lastAudioDevice)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.audioChanged() }
        }
    }

    private func audioChanged() {
        let device = Self.defaultOutputDevice()
        guard device != lastAudioDevice else { return }
        let wasBluetooth = lastAudioWasBluetooth
        lastAudioDevice = device
        lastAudioWasBluetooth = Self.isBluetooth(device)

        // Dropping off a headset onto the built-in speakers is the event: the
        // battery died mid-call and you are now talking to the room. Choosing
        // that switch by hand looks identical from here — CoreAudio reports the
        // route, not the reason — and the pill is cheap enough to be wrong.
        guard lastAudioWasBluetooth else {
            if wasBluetooth { onDisconnect?(Double(Self.outputVolume(device))) }
            return
        }
        guard let name = Self.name(of: device) else { return }
        announce(Accessory(name: name, kind: .audio, battery: nil))
    }

    /// A device's output volume, 0–1, for the speaker glyph's wave count.
    ///
    /// Two reads, because devices disagree about where the value lives: the main
    /// element answers on the built-in speakers, and the ones that only publish
    /// per-channel volume are averaged across the stereo pair instead.
    ///
    /// A device that answers neither reports 1. The pill exists to tell you the
    /// room can hear you, so guessing quiet is the only guess that can do harm.
    ///
    /// ponytail: reads the scalar, not the mute flag — a muted machine draws
    /// full waves. Add `kAudioDevicePropertyMute` if that false alarm shows up.
    private static func outputVolume(_ device: AudioDeviceID) -> Float {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var volume: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr {
            return volume
        }

        var sum: Float = 0
        var answered = 0
        for channel in UInt32(1)...2 {
            address.mElement = channel
            var channelVolume: Float = 0
            size = UInt32(MemoryLayout<Float>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &channelVolume) == noErr {
                sum += channelVolume
                answered += 1
            }
        }
        return answered > 0 ? sum / Float(answered) : 1
    }

    private static func defaultOutputDevice() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    private static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func name(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name as String
    }

    // MARK: Presentation

    private func announce(_ accessory: Accessory) {
        // One physical device can publish several HID services (a keyboard with
        // consumer controls, say), and a headset lands on both channels. The
        // pill should still only appear once for it.
        let now = Date()
        recent = recent.filter { now.timeIntervalSince($0.value) < Self.dedupe }
        guard recent.updateValue(now, forKey: accessory.name) == nil else { return }

        Task {
            try? await Task.sleep(for: Self.settle)
            var a = accessory
            a.battery = await battery.level(for: a.name)
            onConnect?(a)
        }
    }
}

// MARK: - Battery

/// Reads the GATT Battery Service off a connected BLE peripheral. Classic
/// Bluetooth headsets report battery over HFP into `bluetoothd`, which has no
/// public API, so those simply come back nil.
///
/// ponytail: one lookup at a time — a second call while the first is in flight
/// gets nil. Connects are seconds apart in practice; key the continuations by
/// peripheral identifier if that stops being true.
@MainActor
final class BatteryReader: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let service = CBUUID(string: "180F")
    private static let level = CBUUID(string: "2A19")
    private static let timeout: Duration = .seconds(3)

    private lazy var central = CBCentralManager(delegate: self, queue: .main)
    private var finish: ((Int?) -> Void)?
    private var powerWaiters: [CheckedContinuation<Bool, Never>] = []

    func level(for name: String) async -> Int? {
        guard await poweredOn(),
              let peripheral = central
                  .retrieveConnectedPeripherals(withServices: [Self.service])
                  .first(where: { $0.name == name })
        else { return nil }

        peripheral.delegate = self
        return await withCheckedContinuation { continuation in
            var resumed = false
            let done: (Int?) -> Void = { [weak self] value in
                guard !resumed else { return }
                resumed = true
                self?.finish = nil
                self?.central.cancelPeripheralConnection(peripheral)
                continuation.resume(returning: value)
            }
            finish = done
            central.connect(peripheral)

            // A peripheral can accept the connection and then never answer;
            // without this the pill would wait on it forever.
            Task {
                try? await Task.sleep(for: Self.timeout)
                done(nil)
            }
        }
    }

    /// Resolves false when Bluetooth is off or the user denied the prompt.
    private func poweredOn() async -> Bool {
        switch central.state {
        case .poweredOn:            return true
        case .unknown, .resetting:  return await withCheckedContinuation { powerWaiters.append($0) }
        default:                    return false
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state != .unknown, central.state != .resetting else { return }
        let waiters = powerWaiters
        powerWaiters = []
        waiters.forEach { $0.resume(returning: central.state == .poweredOn) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finish?(nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first else { finish?(nil); return }
        peripheral.discoverCharacteristics([Self.level], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristic = service.characteristics?.first else { finish?(nil); return }
        peripheral.readValue(for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // The Battery Level characteristic is a single byte, 0…100.
        finish?(characteristic.value?.first.map(Int.init))
    }
}
