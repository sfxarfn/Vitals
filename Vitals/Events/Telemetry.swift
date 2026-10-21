import Foundation
import CoreWLAN
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
    var healthPercent: Int?        // charge the pack still holds, against its design capacity
    var cycleCount: Int?
    /// The firmware's own measure of what the whole machine is drawing, on AC
    /// or off. Nil on a firmware that does not publish `PowerTelemetryData`.
    var systemLoadWatts: Double?

    /// What the machine itself is burning. The firmware's measured load when it
    /// has one. The fallback — the brick's rating minus what reaches the cells —
    /// is a ceiling, not a draw, and only exists on AC; it is kept for
    /// firmwares without the measurement rather than trusted.
    var systemWatts: Double? {
        if let systemLoadWatts { return systemLoadWatts }
        guard let adapterWatts else { return nil }
        return max(adapterWatts - max(batteryWatts, 0), 0)
    }
}

/// The two subsystems that stall a build: the die getting hot and the cores
/// staying pegged. The panel shows both; only the heat drives a Signal.
struct StallSample {
    var cpuPercent: Double = 0
    /// Hottest die sensor, °C. Nil on a machine whose sensor tree we cannot read.
    var tempC: Double?
    /// The same sensors split by which block of the die they sit on, hottest per
    /// block. Only the thermal panel reads this — every pill and glow works off
    /// `tempC`, because an edge can only say one number.
    var dieGroups: [SensorGroup: Double] = [:]
}

/// The half of RAM that cannot simply be handed back: pinned by the kernel, or
/// squeezed to make room. Fractions of physical memory, 0–1 each.
///
/// Split rather than summed because the two mean different things — wired is a
/// fixed cost the machine was born with, compressed is macOS actively working to
/// find room, and only the second one rising is news.
struct MemorySample {
    var wired: Double = 0
    var compressed: Double = 0

    /// Both halves together: how much of the machine's RAM is spoken for.
    var used: Double { min(wired + compressed, 1) }
}

/// Bytes per second through the machine's interfaces, each direction, plus what
/// the Wi-Fi radio will say about the link carrying them.
///
/// The radio half is all optional and all separately so: a machine on Ethernet
/// has no radio to ask, a radio that is off answers nothing, and one that is on
/// but unassociated answers some of it. Every one of those is a dash, not a
/// zero — 0 dBm is a plausible-looking signal and -100 is a real one.
struct NetSample {
    var up: Double = 0
    var down: Double = 0
    /// A tunnel interface is up with an address on it.
    var vpn = false

    /// True when there is a Wi-Fi radio at all, which is what separates
    /// "Ethernet" from "Wi-Fi, not associated".
    var hasWiFi = false
    var linkMbps: Double?
    var rssi: Int?
    var band: String?
    var channel: Int?
}

/// Which part of the machine a temperature sensor sits on, read off the
/// service's `Product` string. What is nameable depends on the chip, and the
/// panel prints whichever set answered:
///
/// - M1 names its blocks: `pACC MTR Temp Sensor0`, `eACC …`, `GPU …`.
/// - M2/M3 do not. The whole die arrives as `PMU tdie1…8` / `PMU2 tdev1…8` —
///   sixteen unlabelled dies with no published mapping onto P, E or GPU. They
///   are `die`, collectively, because inventing that mapping is the one thing
///   worse than not having it.
///
/// `storage` and `battery` are named on both, and neither counts toward `tempC`
/// — a warm pack is not the die getting hot, and `tempC` is what every pill and
/// glow reads. `other` still does: SOC and ANE are die, just unnamed.
///
/// ponytail: prefix match on observed strings. A machine naming them some third
/// way drops everything into `other` and the panel prints "—" rather than lying
/// — the `#if DEBUG` dump in `TemperatureSensors.init` prints every `Product`,
/// so add the prefix from that.
enum SensorGroup: Hashable {
    case pCore, eCore, gpu, die, storage, battery, calibration, other

    /// True for the groups that are the die heating up, which is what `tempC`
    /// means and what the notch's edge reacts to. The pack, the flash and the
    /// calibration reference are none of those.
    var isDie: Bool { self != .storage && self != .battery && self != .calibration }

    init(product: String) {
        if product.hasPrefix("pACC")           { self = .pCore }
        else if product.hasPrefix("eACC")      { self = .eCore }
        else if product.hasPrefix("GPU")       { self = .gpu }
        else if product.hasPrefix("NAND")      { self = .storage }
        else if product.hasPrefix("gas gauge") { self = .battery }
        // `tcal` is the calibration reference, not a place on the die.
        else if product.hasSuffix("tcal")  { self = .calibration }
        else if product.hasPrefix("PMU")   { self = .die }
        else                                   { self = .other }
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

        #if DEBUG
        // Every row of the thermal panel but the summary reads "—" when the
        // `Product` prefixes miss, and the strings differ per chip generation.
        // Dump them once so the miss is readable instead of guessed at.
        print("[Vitals] temperature sensors, \(services.count):")
        for svc in found {
            let product = copyProperty?(svc, "Product" as CFString)?
                .takeRetainedValue() as? String ?? "<no Product property>"
            print("[Vitals]   \(product) -> \(SensorGroup(product: product))")
        }
        #endif
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
    /// RAM under pressure, split into its two halves. Nil if the host refuses
    /// the stats.
    ///
    /// Read only by the thermal panel, never by a `Signal` — `.ai/README.md` says
    /// memory is not a thing this app watches, and this does not make it one:
    /// the panel tints the total, but nothing anywhere decides anything from it,
    /// and there is still no threshold, no pill and no glow behind it.
    private(set) var memory: MemorySample?
    /// Throughput, both directions. Read only by the panel, never by a `Signal` — same
    /// standing as `memory`: no threshold, no pill, no glow, just a number in a
    /// surface you had to hover for.
    private(set) var net = NetSample()

    static let historyLength = 120

    private var lastCPUTicks: (user: UInt64, sys: UInt64, idle: UInt64, nice: UInt64)?

    private var lastNetBytes: (up: UInt32, down: UInt32)?
    private var lastNetSampleAt: Date?

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

        // Push: thermal pressure. macOS's state drives Events and the edge; the
        // private die sensors explain it in degrees, so refresh both together at
        // the transition instead of waiting for the next timer tick.
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.sampleStall(force: true); self?.onUpdate?() }

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
        sampleNet()
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
        // One registry read for everything `AppleSmartBattery` knows.
        if let p = Self.smartBatteryProperties() {
            s.systemLoadWatts = Self.systemLoadWatts(p)
            if s.onAC { s.adapterContractWatts = Self.adapterContractWatts(p) }

            if let (mA, mV, mAh) = Self.batteryCurrentAndVoltage(p) {
                var watts = (mA / 1000.0) * (mV / 1000.0)
                // Amperage reads exactly 0 for a while right after unplugging —
                // the gauge has not caught up — and that read as "-0.0 W" on a
                // pack visibly running the machine. Off AC the pack is the only
                // source, so the measured system load *is* its draw. Only then:
                // any non-zero amperage wins, as it always did, and a firmware
                // without `SystemLoad` keeps the amperage reading.
                let gaugeIdle = !s.onAC && mA == 0
                if gaugeIdle, let load = s.systemLoadWatts {
                    watts = -load
                }
                s.batteryWatts = watts
                // IOPS withholds `TimeToEmpty` for the first minute off the
                // charger and any time the draw is still jumping, and a battery
                // with no estimate is exactly when you look. Charge over current
                // is the same arithmetic without the smoothing, so it only fills
                // the gap. The amperage path is the original one; the load path
                // only covers the idle gauge above.
                if s.minutesToEmpty == nil, !s.onAC, mAh > 0 {
                    if mA < -1 {
                        s.minutesToEmpty = Int(mAh / -mA * 60)
                    } else if gaugeIdle, watts < -0.1, mV > 0 {
                        let drawMA = -watts / (mV / 1000.0) * 1000.0
                        s.minutesToEmpty = Int(mAh / drawMA * 60)
                    }
                }
            }

            if let (health, cycles) = Self.batteryHealth(p) {
                s.healthPercent = health
                s.cycleCount = cycles
            }
        }

        power = s
    }

    private static func smartBatteryProperties() -> [String: Any]? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS
        else { return nil }
        return props?.takeRetainedValue() as? [String: Any]
    }

    /// A battery key from the top level, else from `BatteryData`. macOS 27 moved
    /// the capacity keys (`DesignCapacity`, `NominalChargeCapacity`,
    /// `AppleRawMaxCapacity`) under `BatteryData`, so a top-level-only read found
    /// nothing. The top level is still asked first: that is where every earlier
    /// macOS keeps them, and it must keep reading them from there.
    private static func batteryNumber(_ p: [String: Any], _ key: String) -> NSNumber? {
        p[key] as? NSNumber ?? (p["BatteryData"] as? [String: Any])?[key] as? NSNumber
    }

    /// `PowerTelemetryData.SystemLoad`, in mW: the firmware's measured draw of
    /// the whole machine. Measured, unlike the adapter rating the System row
    /// used to subtract from. Nil where the key is missing, so those Macs keep
    /// the old derivation in `PowerSample.systemWatts`.
    private static func systemLoadWatts(_ p: [String: Any]) -> Double? {
        guard let mW = ((p["PowerTelemetryData"] as? [String: Any])?["SystemLoad"] as? NSNumber)?
                .doubleValue, mW > 0 else { return nil }
        return mW / 1000
    }

    /// Pack health as a percentage of its design capacity, plus the cycle count
    /// behind it. `NominalChargeCapacity` is the figure System Settings shows;
    /// `AppleRawMaxCapacity` is the older key and drifts from it on Apple
    /// silicon, so it is only the fallback — a machine publishing neither gets
    /// no row rather than a wrong one.
    private static func batteryHealth(_ p: [String: Any]) -> (Int, Int)? {
        guard let design = batteryNumber(p, "DesignCapacity")?.doubleValue, design > 0,
              let now = (batteryNumber(p, "NominalChargeCapacity")
                         ?? batteryNumber(p, "AppleRawMaxCapacity"))?.doubleValue, now > 0
        else { return nil }
        let cycles = batteryNumber(p, "CycleCount")?.intValue ?? 0
        return (Int((now / design * 100).rounded()), cycles)
    }

    /// Watts of the USB-C contract actually in force, which the brick's rating
    /// does not tell you — a 35W charger on a port sharing its lane settles at
    /// 27W. Only `AppleSmartBattery`'s `AdapterDetails` carries the negotiated
    /// voltage and current; the IOPS adapter dictionary stops at the rating.
    private static func adapterContractWatts(_ p: [String: Any]) -> Double? {
        guard let ad = p["AdapterDetails"] as? [String: Any],
              let mV = (ad["Voltage"] as? NSNumber)?.doubleValue,
              let mA = (ad["Current"] as? NSNumber)?.doubleValue,
              mV > 0, mA > 0 else { return nil }
        return (mV / 1000) * (mA / 1000)
    }

    /// Returns (milliamps signed, millivolts, charge left in mAh — 0 if the
    /// firmware does not publish it).
    private static func batteryCurrentAndVoltage(_ p: [String: Any]) -> (Double, Double, Double)? {
        guard let mV = (p["Voltage"] as? NSNumber)?.doubleValue else { return nil }
        // Two's complement either way. This firmware stores a negative current
        // as a 64-bit unsigned (18446744073709550893 is -2723 mA), which
        // `doubleValue` read as 1.8e19; `int64Value` takes the bits as signed.
        // Older firmwares store it in 32 bits, which still needs folding back.
        let bits = (p["InstantAmperage"] as? NSNumber ?? p["Amperage"] as? NSNumber)?.int64Value ?? 0
        let signed = Double(bits > Int64(UInt32.max / 2) && bits <= Int64(UInt32.max)
                            ? bits - Int64(UInt32.max) - 1 : bits)
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
        // node is a percentage, which would read as a nearly flat pack. macOS 27
        // dropped the raw key and keeps the mAh as `BatteryData.RemainingCapacity`;
        // the raw key is still asked first for every earlier macOS.
        let mAh = (p["AppleRawCurrentCapacity"] as? NSNumber
                   ?? (p["BatteryData"] as? [String: Any])?["RemainingCapacity"] as? NSNumber)?
            .doubleValue ?? 0
        return (external ? signed : -abs(signed), mV, mAh)
    }

    // MARK: Stall risk

    /// The die sensors are the dearest read on the timer — an IOHID sweep, many
    /// times the cost of the CPU counters — and a die moves in degrees over
    /// seconds. With the notch grown the timer ticks every second for the CPU's
    /// sake; the sensors are read on every third of those. A thermal transition
    /// forces a read, so an Event never explains itself with a stale degree.
    private static let temperatureInterval: TimeInterval = 2.5
    private var lastTemperatureRead = Date.distantPast

    private func sampleStall(force: Bool = false) {
        var s = StallSample()
        s.cpuPercent = cpuPercent() ?? stall.cpuPercent
        if force || Date().timeIntervalSince(lastTemperatureRead) >= Self.temperatureInterval {
            lastTemperatureRead = Date()
            // Keep the last good split rather than blanking the panel on a tick
            // where every sensor happened to decline — same reason `samplePower`
            // holds.
            let groups = Self.temperature?.read() ?? [:]
            s.dieGroups = groups.isEmpty ? stall.dieGroups : groups
            s.tempC = groups.filter { $0.key.isDie }.values.max() ?? stall.tempC
        } else {
            s.dieGroups = stall.dieGroups
            s.tempC = stall.tempC
        }
        stall = s
        thermalState = ProcessInfo.processInfo.thermalState
        memory = Self.memorySample() ?? memory

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
        return busy / (busy + idle) * 100
    }

    // MARK: Network

    /// Rate is the delta between two reads, so the first one after launch only
    /// primes the counters — there is nothing to subtract from yet.
    private func sampleNet() {
        sampleWiFi()
        guard let scan = Self.scanInterfaces() else { return }
        let totals = (up: scan.up, down: scan.down)
        let now = Date()
        defer { lastNetBytes = totals; lastNetSampleAt = now }
        // The tunnel is a level reading, not a rate — it does not have to wait for
        // a second sample the way the throughput does.
        net.vpn = scan.vpn
        guard let prev = lastNetBytes, let then = lastNetSampleAt else { return }
        let dt = now.timeIntervalSince(then)
        guard dt > 0 else { return }
        // `if_data`'s counters are 32-bit and wrap every 4GB, so the subtraction
        // has to wrap with them — a plain `-` traps on the tick after a big
        // download. An interface that goes down resets its counter instead, which
        // wrapping cannot tell from real traffic; the ceiling throws that away.
        let up = Double(totals.up &- prev.up) / dt
        let down = Double(totals.down &- prev.down) / dt
        let ceiling = 12.5e9  // 100 Gbit/s: past any port this machine has
        net.up = up < ceiling ? up : 0
        net.down = down < ceiling ? down : 0
    }

    /// What the Wi-Fi radio says about the link. CoreWLAN answers all of this
    /// without the Location grant — only the SSID is gated behind it, which is
    /// the whole reason the panel names the interface rather than the network.
    ///
    /// Called from `sampleNet` so the throughput and the link it runs over are
    /// always the same tick old.
    private func sampleWiFi() {
        guard let iface = CWWiFiClient.shared().interface() else {
            net.hasWiFi = false
            return
        }
        net.hasWiFi = true
        // An unassociated or powered-down radio reports 0 for both, and 0 is a
        // legal-looking value for neither — a link does not run at 0 Mbps and a
        // station does not sit at 0 dBm.
        let rate = iface.transmitRate()
        net.linkMbps = rate > 0 ? rate : nil
        let rssi = iface.rssiValue()
        net.rssi = rssi < 0 ? rssi : nil
        let channel = iface.wlanChannel()
        net.channel = channel?.channelNumber
        net.band = channel.map {
            switch $0.channelBand {
            case .band2GHz: "2.4 GHz"
            case .band5GHz: "5 GHz"
            case .band6GHz: "6 GHz"
            // A band this SDK has no name for is still a real channel, and the
            // number beside it is the half worth printing.
            default: "—"
            }
        }
    }

    /// Bytes in and out summed over every non-loopback interface, and whether any
    /// tunnel among them is a real VPN. One walk of the list, because both
    /// answers are in it and the walk is the expensive half.
    ///
    /// ponytail: a flat sum double-counts a full-tunnel VPN — those bytes are
    /// counted once on `utun` and again on the `en` carrying them. Filter by name
    /// if that matters; the reading is "is the network busy", not an audit.
    private static func scanInterfaces() -> (up: UInt32, down: UInt32, vpn: Bool)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return nil }
        defer { freeifaddrs(head) }

        var up: UInt32 = 0, down: UInt32 = 0, vpn = false
        for ptr in sequence(first: head, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let name = String(cString: ifa.ifa_name)
            guard !name.hasPrefix("lo"), let family = ifa.ifa_addr?.pointee.sa_family else { continue }

            // Every interface is listed once per address family; only the AF_LINK
            // entry carries `if_data`, the rest hold a sockaddr instead.
            if family == UInt8(AF_LINK), let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self) {
                up &+= data.pointee.ifi_obytes
                down &+= data.pointee.ifi_ibytes
            }

            // A tunnel being up is not a VPN: macOS keeps `utun0`–`utun5` running
            // for Handoff, Private Relay and friends, and the default route stays
            // on `en0` for any split tunnel — which is why the primary interface
            // cannot answer this either. What separates the two is an IPv4
            // address: the system's own tunnels only ever carry link-local IPv6.
            //
            // ponytail: misses an IPv6-only VPN. Accepting a global IPv6 as well
            // is the fix, and it costs the Private Relay exclusion this buys.
            if family == UInt8(AF_INET), Self.tunnelPrefixes.contains(where: name.hasPrefix) {
                vpn = true
            }
        }
        return (up, down, vpn)
    }

    private static let tunnelPrefixes = ["utun", "ppp", "ipsec", "tun", "tap"]

    // MARK: Memory

    /// Wired plus compressed over physical RAM — the ratio Activity Monitor's
    /// pressure bar is drawn from, and the one that means "the machine is out of
    /// room" rather than "the machine is using the room it has". Plain used
    /// memory on macOS is always near full and says nothing.
    ///
    /// `kern.memorystatus_vm_pressure_level` is the other candidate and is worse
    /// for a readout: three steps, and it sits on "normal" through everything
    /// short of a swap storm.
    private static func memorySample() -> MemorySample? {
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
        return MemorySample(
            wired: min(Double(stats.wire_count) * page / total, 1),
            compressed: min(Double(stats.compressor_page_count) * page / total, 1))
    }
}

// MARK: - Self-check

#if DEBUG
enum TelemetrySelfCheck {
    static func run() {
        // The sensor names are the whole basis for the panel's rows, and they
        // are a prefix match on a private string — the one thing here that
        // silently goes wrong if macOS renames a block. It already has once:
        // M1's three named blocks are gone on M2 and M3.
        assert(SensorGroup(product: "pACC MTR Temp Sensor3") == .pCore)
        assert(SensorGroup(product: "eACC MTR Temp Sensor0") == .eCore)
        assert(SensorGroup(product: "GPU MTR Temp Sensor1") == .gpu)
        assert(SensorGroup(product: "SOC MTR Temp Sensor0") == .other)
        // M2/M3's unlabelled tree, plus the two parts every chip does name.
        assert(SensorGroup(product: "PMU tdie4") == .die)
        assert(SensorGroup(product: "PMU2 tdev1") == .die)
        assert(SensorGroup(product: "PMU tcal") == .calibration)
        assert(!SensorGroup.calibration.isDie)
        assert(SensorGroup(product: "NAND CH0 temp") == .storage)
        assert(SensorGroup(product: "gas gauge battery") == .battery)
        // Only the die is the die: a warm pack must not raise `tempC`.
        assert(!SensorGroup.battery.isDie && !SensorGroup.storage.isDie)
        assert(SensorGroup.die.isDie && SensorGroup.other.isDie)
        // Unnamed is not a crash and not a fourth meaning: it lands in `other`,
        // where it still counts toward the hottest reading.
        assert(SensorGroup(product: "") == .other)
        print("Telemetry self-check passed")
    }
}
#endif
