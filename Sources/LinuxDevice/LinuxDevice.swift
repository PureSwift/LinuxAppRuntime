import DynamicDevice
import DynamicRuntime
import Foundation
import LinuxHost

/// The `Device` contract on Linux (`Plan.md` §10): identity from
/// `/etc/machine-info`, DMI and the device tree, the kernel's version,
/// power from `power_supply` and `platform_profile`, and the thermal state
/// from the thermal zones' trip points. Main loop only.
///
/// Changes are found by looking again every few seconds while the app has a
/// delegate: battery level and state while battery monitoring is on, and
/// low power and thermal state always, as on other hosts.
///
/// Orientation and proximity read as unknown: they come from
/// iio-sensor-proxy, with the motion contracts.
public final class LinuxDevice: Device {

    /// The machine's files; replaceable for tests.
    nonisolated(unsafe) static var system = SystemInfo()

    /// How often changes are looked for.
    nonisolated(unsafe) static var interval: Int64 = 5_000_000_000

    nonisolated(unsafe) private static var instance: LinuxDevice?

    private var delegate: (any DeviceDelegate)?

    private var batteryMonitoring = false

    private var timer: MainLoop.TimerToken?

    /// What the delegate was last told.
    private var last: (level: Float, state: BatteryState, lowPower: Bool, thermal: ThermalState)?

    init() { }

    public static func current() -> LinuxDevice {
        if let instance {
            return instance
        }
        let device = LinuxDevice()
        instance = device
        return device
    }

    /// Starts afresh, for tests.
    static func reset() {
        if let timer = instance?.timer {
            MainLoop.shared.cancel(timer)
        }
        instance = nil
    }

    public func setDelegate(_ delegate: (any DeviceDelegate)?) {
        self.delegate = delegate
        last = nil
        update()
        schedule()
    }

    // MARK: Identity

    public func name() -> String {
        Self.system.name
    }

    public func model() -> String {
        Self.system.model
    }

    public func modelIdentifier() -> String {
        Self.system.modelIdentifier(machine: LinuxTarget.machineName)
    }

    public func manufacturer() -> String {
        Self.system.manufacturer
    }

    public func systemName() -> String {
        "Linux"
    }

    /// The kernel's version: `6.12` of `6.12.48+deb13-arm64`.
    public func systemVersion() -> String {
        Self.kernelVersion(ProcessInfo.processInfo.operatingSystemVersionString)
    }

    public func apiLevel() -> Int32 {
        -1
    }

    public func idiom() -> Int32 {
        Self.system.idiom.rawValue
    }

    /// A random UUID kept for the app's vendor: its identifier without the
    /// last component (`org.example` of `org.example.App`).
    public func vendorIdentifier() -> String? {
        Self.vendorIdentifier(appIdentifier: LinuxBundle.info.identifier, environment: LinuxFiles.environment)
    }

    public func isSimulator() -> Bool {
        false
    }

    // MARK: Resources

    public func physicalMemory() -> Int64 {
        Int64(clamping: ProcessInfo.processInfo.physicalMemory)
    }

    public func processorCount() -> Int32 {
        Int32(clamping: ProcessInfo.processInfo.activeProcessorCount)
    }

    /// Since boot, counting time asleep (`CLOCK_BOOTTIME`).
    public func uptime() -> Int64 {
        var time = timespec()
        clock_gettime(CLOCK_BOOTTIME, &time)
        return Int64(time.tv_sec) * 1000 + Int64(time.tv_nsec) / 1_000_000
    }

    // MARK: Power

    public func setBatteryMonitoringEnabled(_ enabled: Bool) {
        batteryMonitoring = enabled
        last = nil
        update()
        schedule()
    }

    public func batteryLevel() -> Float {
        batteryMonitoring ? Self.system.batteryLevel : -1
    }

    public func batteryState() -> Int32 {
        (batteryMonitoring ? Self.system.batteryState : .unknown).rawValue
    }

    public func isLowPowerModeEnabled() -> Bool {
        Self.system.isLowPowerModeEnabled
    }

    public func thermalState() -> Int32 {
        Self.system.thermalState.rawValue
    }

    // MARK: Orientation and proximity

    public func setOrientationUpdatesEnabled(_ enabled: Bool) { }

    public func orientation() -> Int32 {
        DeviceOrientation.unknown.rawValue
    }

    /// There's no proximity sensor to turn on.
    public func setProximityMonitoringEnabled(_ enabled: Bool) { }

    public func isProximityMonitoringEnabled() -> Bool {
        false
    }

    public func proximityState() -> Bool {
        false
    }

    // MARK: Changes

    /// Looks again in `interval` while there's a delegate to tell.
    private func schedule() {
        if let timer {
            MainLoop.shared.cancel(timer)
            self.timer = nil
        }
        guard delegate != nil else { return }
        timer = MainLoop.shared.schedule(after: Self.interval) { [weak self] in
            self?.timer = nil
            self?.update()
            self?.schedule()
        }
    }

    /// Tells the delegate what changed since it was last told.
    func update() {
        guard let delegate else { return }
        let system = Self.system
        let now = (level: batteryLevel(), state: BatteryState(rawValue: batteryState()) ?? .unknown,
                   lowPower: system.isLowPowerModeEnabled, thermal: system.thermalState)
        let previous = last
        last = now
        guard let previous else { return }
        if now.level != previous.level {
            delegate.didChangeBatteryLevel(self, level: now.level)
        }
        if now.state != previous.state {
            delegate.didChangeBatteryState(self, state: now.state.rawValue)
        }
        if now.lowPower != previous.lowPower {
            delegate.didChangeLowPowerMode(self, enabled: now.lowPower)
        }
        if now.thermal != previous.thermal {
            delegate.didChangeThermalState(self, state: now.thermal.rawValue)
        }
    }

    // MARK: Helpers

    /// `6.12` of a kernel release or `uname -v`-style string.
    static func kernelVersion(_ string: String) -> String {
        let release = string.split(separator: " ").first { $0.first?.isNumber == true } ?? Substring(string)
        let numbers = release.split(whereSeparator: { !$0.isNumber }).prefix(2)
        return numbers.isEmpty ? String(release) : numbers.joined(separator: ".")
    }

    /// The vendor's identifier, kept in `<data>/vendors/<vendor>` (the
    /// container's `Vendors`, or `$XDG_DATA_HOME/linux-app/vendors`) and
    /// made the first time it's asked for.
    static func vendorIdentifier(appIdentifier: String, environment: [String: String]) -> String? {
        let parts = appIdentifier.split(separator: ".")
        let vendor = parts.count > 1 ? parts.dropLast().joined(separator: ".") : appIdentifier
        guard !vendor.isEmpty, vendor != ".", vendor != "..", !vendor.contains("/") else {
            return nil
        }
        let directory: String
        if let container = environment["LINUXAPPRUNTIME_CONTAINER"], container.hasPrefix("/") {
            directory = container + "/Vendors"
        } else if let data = environment["XDG_DATA_HOME"], data.hasPrefix("/") {
            directory = data + "/linux-app/vendors"
        } else if let home = environment["HOME"], home.hasPrefix("/") {
            directory = home + "/.local/share/linux-app/vendors"
        } else {
            return nil
        }
        let file = directory + "/" + vendor
        if let text = FileManager.default.contents(atPath: file).map({ String(decoding: $0, as: UTF8.self) }),
           let uuid = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return uuid.uuidString
        }
        let uuid = UUID().uuidString
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try Data((uuid + "\n").utf8).write(to: URL(fileURLWithPath: file), options: .atomic)
        } catch {
            HostLog.error("device: can't keep the vendor identifier in \(file): \(error)")
            return nil
        }
        return uuid
    }
}

/// The `Device` contract and its delegate interface.
public enum LinuxDeviceModule: HostModule {

    public static var contracts: [ContractDescriptor] {
        [DeviceProxy.descriptor, DeviceDelegateProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        DeviceProxy.register(LinuxDevice.self, in: registrar)
        DeviceDelegateProxy.registerInterface(in: registrar)
    }
}
