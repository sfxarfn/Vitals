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
    var adapterWatts: Double?         // what the brick is rated for
    var adapterContractWatts: Double? // what the port actually agreed to deliver
    var batteryWatts: Double = 0   // signed: + charging, - draining

    /// What the machine itself is burning: wall input minus what reaches the cells.
    var systemWatts: Double? {
        guard let adapterWatts else { return nil }
        return max(adapterWatts - max(batteryWatts, 0), 0)
    }
}

/// The two subsystems that stall a build: the die getting hot and the cores
/// staying pegged. One each for the notch's two edges.
struct StallSample {
    var cpuPercent: Double = 0
    /// Hottest die sensor, °C. Nil on a machine whose sensor tree we cannot read.
    var tempC: Double?
    /// The same sensors split by which block of the die they sit on, hottest per
    /// block. Only the thermal panel reads this — every pill and glow works off
    /// `tempC`, because one edge can only say one number.
    var dieGroups: [SensorGroup: Double] = [:]
}

/// Which block of the die a temperature sensor sits on, read off the service's
/// `Product` string. Only the three the panel names have a case; everything else
/// — SOC, ANE, NAND, the gas gauge — is `other`. It still counts toward `tempC`,
/// the governor reacts to whichever sensor is hottest regardless of block.
///
/// ponytail: prefix match on observed strings (`pACC MTR Temp Sensor0`). A
/// machine that names them differently drops every sensor into `other`, and the
/// panel prints "—" on those three rows rather than lying — dump `Product` for
/// each service and add the prefix if that happens.
enum SensorGroup: Hashable {
    case pCore, eCore, gpu, other

    init(product: String) {
        if product.hasPrefix("pACC")      { self = .pCore }
        else if product.hasPrefix("eACC") { self = .eCore }
        else if product.hasPrefix("GPU")  { self = .gpu }
        else                              { self = .other }
    }
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
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?

    /// `kIOHIDEventTypeTemperature`. A field id is the event type shifted into
    /// the high half — that packing is how IOHIDEvent addresses a value.
    private static let eventType: Int64 = 15
    private static let field: Int32 = 15 << 16

    private let copyEvent: CopyEvent
    private let floatValue: FloatValue
    /// Held only so the services outlive the initializer — they are the client's.
    private let client: AnyObject
    /// Each service paired with the block it was found to sit on. Classified once
    /// at init: the `Product` string never changes, and copying it per sample
    /// would be a CF allocation per sensor per second while the panel is open.
    private let services: [(group: SensorGroup, service: AnyObject)]

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
        // Optional on purpose: a machine that will not hand over the names still
        // reports temperatures, it just reports them all as `other`.
        let copyProperty: CopyProperty? = sym("IOHIDServiceClientCopyProperty")

        // kHIDPage_AppleVendor / kHIDUsage_AppleVendor_TemperatureSensor. Usage
        // numbers only mean anything paired with their page, and 5 on any other
        // page is something else entirely.
        setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let found = copyServices(client)?.takeRetainedValue() as? [AnyObject],
              !found.isEmpty else { return nil }

        self.copyEvent = copyEvent
        self.floatValue = floatValue
        self.client = client
        self.services = found.map { svc in
            let product = copyProperty?(svc, "Product" as CFString)?
                .takeRetainedValue() as? String ?? ""
            return (group: SensorGroup(product: product), service: svc)
        }
    }

    /// Hottest sensor per block, °C. Empty if nothing answered this tick.
    ///
    /// ponytail: max within a block, not an average of its dies. The hottest
    /// sensor is what the thermal governor is reacting to, which is the number
    /// the throttling pill is trying to explain, and the same holds one block
    /// down. `.other` is kept so the overall hottest still sees every sensor.
    func read() -> [SensorGroup: Double] {
        var out: [SensorGroup: Double] = [:]
        for (group, svc) in services {
            guard let event = copyEvent(svc, Self.eventType, 0, 0)?.takeRetainedValue() else { continue }
            // A sensor whose block is powered down answers zero rather than
            // declining, and a machine at 0°C is not the case worth handling.
            let c = floatValue(event, Self.field)
            guard c > 0 else { continue }
            out[group] = max(out[group] ?? 0, c)
        }
        return out
    }
}

// MARK: - Telemetry

@Observable
final class Telemetry {
    private(set) var power = PowerSample()
    private(set) var stall = StallSample()
    private(set) var cpuHistory: [Double] = []

    /// macOS's own verdict on the heat. Four words and no numbers, which is why
    /// nothing decides a threshold from it — but it is the only source that says
    /// the machine *is* trading clocks away, as opposed to being close to it.
    private(set) var thermalState = ProcessInfo.processInfo.thermalState
    /// Fraction of RAM under pressure, 0–1. Nil if the host refuses the stats.
    ///
    /// Read only by the thermal panel, never by a `Signal` — `.ai/README.md` says
    /// memory is not a thing this app watches, and this does not make it one:
    /// there is no threshold, no pill and no glow behind it, just a number in a
    /// surface you had to click twice to reach.
    private(set) var memoryUsed: Double?

    /// Seconds of continuous CPU load above the sustained threshold.
    private(set) var cpuSustainedSeconds: Double = 0
    /// True for the single sample where a long busy stretch has gone quiet — the
    /// closest thing to "your build finished" without a hook into Xcode.
    private(set) var loadFinished = false

    static let historyLength = 120
    private static let sustainedCPUThreshold = 85.0

    /// Calibration knobs for the finished-load heuristic. Idle on this machine
    /// sits well under 30% with Chrome open; the 10s hold is what stops a build
    /// pausing between targets from reading as the end of the build.
    private static let quietCPUThreshold = 30.0
    private static let quietDuration: TimeInterval = 10
    private static let sustainedDuration: TimeInterval = 60

    private var cpuQuietSeconds: Double = 0
    private var sawSustainedLoad = false

    private var lastCPUTicks: (user: UInt64, sys: UInt64, idle: UInt64, nice: UInt64)?
    private var lastCPUSampleAt: Date?

    /// Built once: enumerating the sensor tree is the expensive half, reading it
    /// is not. Nil if the private symbols ever go away, and everything downstream
    /// treats that as "no temperature" rather than failing.
    private static let temperature = TemperatureSensors()

    private var timer: Timer?
    private var powerSource: CFRunLoopSource?

    /// Fires whenever any source produces fresh numbers.
    var onUpdate: (() -> Void)?

    /// True while the notch is showing an Interaction, which is the only time
    /// anything here is being read at a glance — the poll goes to 1s for it and
    /// back to 10s the moment the notch shrinks. A power monitor must not cost
    /// power: push where the OS offers it, poll only CPU.
    var grown = false { didSet { if grown != oldValue { restartTimer() } } }

    func start() {
        sampleAll()
        restartTimer()

        // Push: thermal state. The four words themselves are no longer used —
        // the die reading drives everything now — but a state change is a free
        // nudge to go re-read that sensor at the moment it matters.
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
        let interval: TimeInterval = grown ? 1 : 10
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.sampleAll()
            self?.onUpdate?()
        }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Sampling

    private func sampleAll() {
        samplePower()
        sampleStall()
    }

    // MARK: Power

    private func samplePower() {
        // Keep the last good sample rather than publishing a default one. A miss
        // here used to read as 0%, which clears `charged` — so the next
        // successful read fired a "Charged" pill for a battery that had been
        // full the whole time.
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
        if s.onAC { s.adapterContractWatts = Self.adapterContractWatts() }

        // Signed battery power. Sandbox-safe path first, raw registry as the richer fallback.
        if let (mA, mV, mAh) = Self.batteryCurrentAndVoltage() {
            s.batteryWatts = (mA / 1000.0) * (mV / 1000.0)
            // IOPS withholds `TimeToEmpty` for the first minute off the charger
            // and any time the draw is still jumping, and a battery with no
            // estimate is exactly when you look. Charge over current is the same
            // arithmetic without the smoothing, so it only fills the gap.
            if s.minutesToEmpty == nil, !s.onAC, mA < -1, mAh > 0 {
                s.minutesToEmpty = Int(mAh / -mA * 60)
            }
        }

        power = s
    }

    /// Watts of the USB-C contract actually in force, which the brick's rating
    /// does not tell you — a 35W charger on a port sharing its lane settles at
    /// 27W. Only `AppleSmartBattery`'s `AdapterDetails` carries the negotiated
    /// voltage and current; the IOPS adapter dictionary stops at the rating.
    private static func adapterContractWatts() -> Double? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let p = props?.takeRetainedValue() as? [String: Any],
              let ad = p["AdapterDetails"] as? [String: Any],
              let mV = (ad["Voltage"] as? NSNumber)?.doubleValue,
              let mA = (ad["Current"] as? NSNumber)?.doubleValue,
              mV > 0, mA > 0 else { return nil }
        return (mV / 1000) * (mA / 1000)
    }

    /// Returns (milliamps signed, millivolts, charge left in mAh — 0 if the
    /// firmware does not publish it).
    private static func batteryCurrentAndVoltage() -> (Double, Double, Double)? {
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
        // `AppleRawCurrentCapacity` is mAh; the plain `CurrentCapacity` on this
        // node is a percentage, which would read as a nearly flat pack.
        let mAh = (p["AppleRawCurrentCapacity"] as? NSNumber)?.doubleValue ?? 0
        return (external ? signed : -abs(signed), mV, mAh)
    }

    // MARK: Stall risk

    private func sampleStall() {
        var s = StallSample()
        s.cpuPercent = cpuPercent() ?? stall.cpuPercent
        // Keep the last good split rather than blanking the panel on a tick where
        // every sensor happened to decline — same reason `samplePower` holds.
        let groups = Self.temperature?.read() ?? [:]
        s.dieGroups = groups.isEmpty ? stall.dieGroups : groups
        s.tempC = groups.values.max() ?? stall.tempC
        stall = s
        thermalState = ProcessInfo.processInfo.thermalState
        memoryUsed = Self.memoryUsedFraction() ?? memoryUsed

        cpuHistory.append(s.cpuPercent)
        if cpuHistory.count > Self.historyLength { cpuHistory.removeFirst(cpuHistory.count - Self.historyLength) }
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

    // MARK: Memory

    /// Wired plus compressed over physical RAM — the ratio Activity Monitor's
    /// pressure bar is drawn from, and the one that means "the machine is out of
    /// room" rather than "the machine is using the room it has". Plain used
    /// memory on macOS is always near full and says nothing.
    ///
    /// `kern.memorystatus_vm_pressure_level` is the other candidate and is worse
    /// for a readout: three steps, and it sits on "normal" through everything
    /// short of a swap storm.
    private static func memoryUsedFraction() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return nil }
        let page = Double(vm_kernel_page_size)
        let held = (Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        return min(held / total, 1)
    }
}

// MARK: - Self-check

#if DEBUG
enum TelemetrySelfCheck {
    static func run() {
        // The sensor names are the whole basis for the panel's three rows, and
        // they are a prefix match on a private string — the one thing here that
        // silently goes wrong if macOS renames a block.
        assert(SensorGroup(product: "pACC MTR Temp Sensor3") == .pCore)
        assert(SensorGroup(product: "eACC MTR Temp Sensor0") == .eCore)
        assert(SensorGroup(product: "GPU MTR Temp Sensor1") == .gpu)
        assert(SensorGroup(product: "SOC MTR Temp Sensor0") == .other)
        // Unnamed is not a crash and not a fourth meaning: it lands in `other`,
        // where it still counts toward the hottest reading.
        assert(SensorGroup(product: "") == .other)
        print("Telemetry self-check passed")
    }
}
#endif
