import Foundation
import IOKit
import IOKit.ps
import Darwin
import Observation

// MARK: - Samples

struct PowerSample {
    var percent = 0
    var onAC = false
    var isCharging = false
    var minutesToFull: Int?
    var minutesToEmpty: Int?
    var adapterName: String?
    var adapterWatts: Double?      // negotiated at the wall
    var batteryWatts: Double = 0   // signed: + charging, - draining

    /// What the machine itself is burning: wall input minus what reaches the cells.
    var systemWatts: Double? {
        guard let adapterWatts else { return nil }
        return max(adapterWatts - max(batteryWatts, 0), 0)
    }
}

struct StallSample {
    var pressure: Int32 = 1        // 1 normal, 2 warn, 4 critical
    var swapUsedMB: Double = 0
    var thermal: ProcessInfo.ThermalState = .nominal
    var cpuPercent: Double = 0
    /// Hottest die sensor, °C. Nil on a machine whose sensor tree we cannot read.
    var tempC: Double?
}

// MARK: - Die temperature

/// There is no public API for it. `ProcessInfo.thermalState` is four words, and
/// on Apple Silicon the SMC keys everyone quotes from the Intel era are gone —
/// every sensor is published through the private IOHIDEventSystem tree instead.
/// Those symbols live in the IOKit binary this app already links, they just ship
/// no headers, so they are looked up at runtime rather than imported.
private final class TemperatureSensors {
    private typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Void
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, UInt64) -> Unmanaged<AnyObject>?
    private typealias FloatValue = @convention(c) (AnyObject, Int32) -> Double

    /// `kIOHIDEventTypeTemperature`. A field id is the event type shifted into
    /// the high half — that packing is how IOHIDEvent addresses a value.
    private static let eventType: Int64 = 15
    private static let field: Int32 = 15 << 16

    private let copyEvent: CopyEvent
    private let floatValue: FloatValue
    /// Held only so the services outlive the initializer — they are the client's.
    private let client: AnyObject
    private let services: [AnyObject]

    init?() {
        guard let image = dlopen(nil, RTLD_LAZY) else { return nil }
        func sym<T>(_ name: String) -> T? { dlsym(image, name).map { unsafeBitCast($0, to: T.self) } }

        guard let create: Create = sym("IOHIDEventSystemClientCreate"),
              let setMatching: SetMatching = sym("IOHIDEventSystemClientSetMatching"),
              let copyServices: CopyServices = sym("IOHIDEventSystemClientCopyServices"),
              let copyEvent: CopyEvent = sym("IOHIDServiceClientCopyEvent"),
              let floatValue: FloatValue = sym("IOHIDEventGetFloatValue"),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }

        // kHIDPage_AppleVendor / kHIDUsage_AppleVendor_TemperatureSensor. Usage
        // numbers only mean anything paired with their page, and 5 on any other
        // page is something else entirely.
        setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let found = copyServices(client)?.takeRetainedValue() as? [AnyObject],
              !found.isEmpty else { return nil }

        self.copyEvent = copyEvent
        self.floatValue = floatValue
        self.client = client
        self.services = found
    }

    /// Hottest sensor on the machine, °C.
    ///
    /// ponytail: max, not an average of the named core dies. The match already
    /// narrows this to temperature sensors, and the hottest one is what the
    /// thermal governor is reacting to — which is the number the throttling pill
    /// is trying to explain. Filter on each service's `Product` string (the
    /// P-core dies are `pACC MTR Temp Sensor…`) if a specific one is ever needed.
    func read() -> Double? {
        services.lazy.compactMap { svc -> Double? in
            guard let event = self.copyEvent(svc, Self.eventType, 0, 0)?.takeRetainedValue() else { return nil }
            // A sensor whose block is powered down answers zero rather than
            // declining, and a machine at 0°C is not the case worth handling.
            let c = self.floatValue(event, Self.field)
            return c > 0 ? c : nil
        }.max()
    }
}

// MARK: - Telemetry

@Observable
final class Telemetry {
    private(set) var power = PowerSample()
    private(set) var stall = StallSample()
    private(set) var cpuHistory: [Double] = []

    /// Seconds of continuous CPU load above the sustained threshold.
    private(set) var cpuSustainedSeconds: Double = 0
    /// Swap gained over the trailing window, in MB.
    private(set) var swapGrowthMB: Double = 0
    /// True for the single sample where a long busy stretch has gone quiet — the
    /// closest thing to "your build finished" without a hook into Xcode.
    private(set) var loadFinished = false

    static let historyLength = 120
    private static let sustainedCPUThreshold = 85.0
    private static let swapWindow: TimeInterval = 300

    /// Calibration knobs for the finished-load heuristic. Idle on this machine
    /// sits well under 30% with Chrome open; the 10s hold is what stops a build
    /// pausing between targets from reading as the end of the build.
    private static let quietCPUThreshold = 30.0
    private static let quietDuration: TimeInterval = 10
    private static let sustainedDuration: TimeInterval = 60

    private var cpuQuietSeconds: Double = 0
    private var sawSustainedLoad = false

    private var swapHistory: [(at: Date, mb: Double)] = []
    private var lastCPUTicks: (user: UInt64, sys: UInt64, idle: UInt64, nice: UInt64)?
    private var lastCPUSampleAt: Date?

    /// Built once: enumerating the sensor tree is the expensive half, reading it
    /// is not. Nil if the private symbols ever go away, and everything downstream
    /// treats that as "no temperature" rather than failing.
    private static let temperature = TemperatureSensors()

    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var powerSource: CFRunLoopSource?

    /// Fires whenever any source produces fresh numbers.
    var onUpdate: (() -> Void)?

    // Q8: push where the OS offers it, poll only CPU.
    var expanded = false { didSet { if expanded != oldValue { restartTimer() } } }

    func start() {
        sampleAll()
        restartTimer()

        // Push: memory pressure.
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in self?.sampleStall(); self?.onUpdate?() }
        src.resume()
        pressureSource = src

        // Push: thermal state.
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.sampleStall(); self?.onUpdate?() }

        // Push: power sources.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let s = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<Telemetry>.fromOpaque(ctx).takeUnretainedValue()
            me.samplePower()
            me.onUpdate?()
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), s, .defaultMode)
            powerSource = s
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        let interval: TimeInterval = expanded ? 1 : 10
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.sampleAll()
            self?.onUpdate?()
        }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func sampleAll() {
        samplePower()
        sampleStall()
    }

    // MARK: Power

    private func samplePower() {
        // Keep the last good sample rather than publishing a default one. A miss
        // here used to read as 0% on battery, which clears `charged` and asserts
        // `chargerDisconnected` — so the next successful read fired a "Charged"
        // pill for a battery that had been full the whole time.
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let raw = list.lazy.compactMap({
                  IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any]
              }).first
        else { return }

        var s = PowerSample()
        let maxCap = raw[kIOPSMaxCapacityKey] as? Int ?? 100
        let cur = raw[kIOPSCurrentCapacityKey] as? Int ?? 0
        s.percent = maxCap > 0 ? Int((Double(cur) / Double(maxCap) * 100).rounded()) : 0
        s.isCharging = raw[kIOPSIsChargingKey] as? Bool ?? false
        s.onAC = (raw[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        if let m = raw[kIOPSTimeToFullChargeKey] as? Int, m > 0 { s.minutesToFull = m }
        if let m = raw[kIOPSTimeToEmptyKey] as? Int, m > 0 { s.minutesToEmpty = m }

        if let ad = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            s.adapterWatts = (ad["Watts"] as? NSNumber)?.doubleValue
            s.adapterName = (ad["Name"] as? String)?.trimmingCharacters(in: .whitespaces)
        }

        // Signed battery power. Sandbox-safe path first, raw registry as the richer fallback.
        if let (mA, mV) = Self.batteryCurrentAndVoltage() {
            s.batteryWatts = (mA / 1000.0) * (mV / 1000.0)
        }

        power = s
    }

    /// Returns (milliamps signed, millivolts).
    private static func batteryCurrentAndVoltage() -> (Double, Double)? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let p = props?.takeRetainedValue() as? [String: Any],
              let mV = (p["Voltage"] as? NSNumber)?.doubleValue else { return nil }
        let raw = (p["InstantAmperage"] as? NSNumber ?? p["Amperage"] as? NSNumber)?.doubleValue ?? 0
        let signed = raw > 4e9 ? raw - 4294967296 : raw  // some firmwares report two's complement
        // `IsCharging` cannot supply the sign, in either direction. It reads
        // false through adapter negotiation, above ~95%, and for every top-off
        // pulse of a hold at full — so inverting a positive reading by it turned
        // each of those pulses into current flowing the wrong way. Verified on
        // this machine: `AC; Not Charging; 100%` while the pack is being topped
        // back up is the steady state at full, not an edge case.
        //
        // Only the direction of power flow can settle this, and off AC there is
        // just one direction, so that is where a bare-magnitude firmware gets
        // its sign. On AC the firmware's own sign stands.
        let external = (p["ExternalConnected"] as? Bool) ?? true
        return (external ? signed : -abs(signed), mV)
    }

    // MARK: Stall risk

    private func sampleStall() {
        var s = StallSample()
        s.pressure = Self.sysctlInt32("kern.memorystatus_vm_pressure_level") ?? 1
        s.swapUsedMB = Self.swapUsedMB()
        s.thermal = ProcessInfo.processInfo.thermalState
        s.cpuPercent = cpuPercent() ?? stall.cpuPercent
        s.tempC = Self.temperature?.read() ?? stall.tempC
        stall = s

        cpuHistory.append(s.cpuPercent)
        if cpuHistory.count > Self.historyLength { cpuHistory.removeFirst(cpuHistory.count - Self.historyLength) }

        let now = Date()
        swapHistory.append((now, s.swapUsedMB))
        swapHistory.removeAll { now.timeIntervalSince($0.at) > Self.swapWindow }
        swapGrowthMB = s.swapUsedMB - (swapHistory.first?.mb ?? s.swapUsedMB)
    }

    private func cpuPercent() -> Double? {
        var count = mach_msg_type_number_t(0)
        var cpus: natural_t = 0
        var info: processor_info_array_t?
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size)) }

        var t = (user: UInt64(0), sys: UInt64(0), idle: UInt64(0), nice: UInt64(0))
        for i in 0..<Int(cpus) {
            let base = i * Int(CPU_STATE_MAX)
            t.user += UInt64(info[base + Int(CPU_STATE_USER)])
            t.sys  += UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            t.idle += UInt64(info[base + Int(CPU_STATE_IDLE)])
            t.nice += UInt64(info[base + Int(CPU_STATE_NICE)])
        }

        defer { lastCPUTicks = t }
        guard let prev = lastCPUTicks else { return nil }
        let busy = Double((t.user - prev.user) + (t.sys - prev.sys) + (t.nice - prev.nice))
        let idle = Double(t.idle - prev.idle)
        guard busy + idle > 0 else { return nil }
        let pct = busy / (busy + idle) * 100

        let now = Date()
        let elapsed = lastCPUSampleAt.map { now.timeIntervalSince($0) } ?? 0
        lastCPUSampleAt = now
        cpuSustainedSeconds = pct >= Self.sustainedCPUThreshold ? cpuSustainedSeconds + elapsed : 0
        cpuQuietSeconds = pct < Self.quietCPUThreshold ? cpuQuietSeconds + elapsed : 0

        // ponytail: CPU shape, not a build hook — a long render or a Docker
        // image reads the same as a compile. Watch Xcode's build log or an
        // XCBBuildService notification if it has to mean specifically "build".
        //
        // One-shot: armed by a long busy stretch, spent the moment the machine
        // goes quiet. Disarming here is what lets the next build fire again
        // without the engine having to know a build ever happened.
        if cpuSustainedSeconds >= Self.sustainedDuration { sawSustainedLoad = true }
        loadFinished = sawSustainedLoad && cpuQuietSeconds >= Self.quietDuration
        if loadFinished { sawSustainedLoad = false }

        return pct
    }

    // MARK: sysctl helpers

    private static func sysctlInt32(_ name: String) -> Int32? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? v : nil
    }

    private static func swapUsedMB() -> Double {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return Double(usage.xsu_used) / 1_048_576
    }
}
