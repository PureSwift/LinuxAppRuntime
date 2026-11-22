import DBus
import DynamicDevice
import DynamicRuntime
import Foundation
import LinuxDBus
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
/// Orientation and proximity are iio-sensor-proxy's, on the system bus:
/// its accelerometer's orientation and its proximity sensor, claimed while
/// they're enabled. Without it, orientation reads as unknown and proximity
/// monitoring stays off.
public final class LinuxDevice: Device {

    /// The machine's files; replaceable for tests.
    nonisolated(unsafe) static var system = SystemInfo()

    /// iio-sensor-proxy; replaceable for tests.
    nonisolated(unsafe) static var sensorProxy: any SensorProxyBus = SystemSensorProxy()

    /// How often changes are looked for.
    nonisolated(unsafe) static var interval: Int64 = 5_000_000_000

    nonisolated(unsafe) private static var instance: LinuxDevice?

    private var delegate: (any DeviceDelegate)?

    private var batteryMonitoring = false

    private var timer: MainLoop.TimerToken?

    /// What the delegate was last told.
    private var last: (level: Float, state: BatteryState, lowPower: Bool, thermal: ThermalState)?

    /// The app's wish, and whether the proxy has the sensor claimed for it.
    private var orientationUpdates = false
    private var accelerometerClaimed = false
    private var currentOrientation = DeviceOrientation.unknown

    private var proximityMonitoring = false
    private var proximityClaimed = false
    private var near = false

    /// The proxy's `PropertiesChanged`, while either is enabled.
    private var changes: BusSubscription?

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
        if let changes = instance?.changes {
            sensorProxy.unsubscribe(changes)
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

    /// Claims the proxy's accelerometer, if it has one; the orientation
    /// arrives on a later turn, and the delegate hears of it.
    public func setOrientationUpdatesEnabled(_ enabled: Bool) {
        guard enabled != orientationUpdates else { return }
        orientationUpdates = enabled
        if enabled {
            subscribe()
            claim(has: "HasAccelerometer", "ClaimAccelerometer", wanted: { $0.orientationUpdates }) { device, properties in
                device.accelerometerClaimed = true
                device.orient(properties["AccelerometerOrientation"]?.text)
            }
        } else {
            if accelerometerClaimed {
                accelerometerClaimed = false
                release("ReleaseAccelerometer")
            }
            currentOrientation = .unknown
            unsubscribeIfIdle()
        }
    }

    public func orientation() -> Int32 {
        currentOrientation.rawValue
    }

    /// Asks the proxy whether there's a proximity sensor, waiting for the
    /// answer, and claims it if there is; it stays off if not.
    public func setProximityMonitoringEnabled(_ enabled: Bool) {
        guard enabled != proximityMonitoring else { return }
        if enabled {
            guard (try? Self.sensorProxy.propertyAndWait("HasProximity").get())?.flag == true else { return }
            proximityMonitoring = true
            subscribe()
            claim(has: "HasProximity", "ClaimProximity", wanted: { $0.proximityMonitoring }) { device, properties in
                device.proximityClaimed = true
                device.approach(properties["ProximityNear"]?.flag ?? false)
            }
        } else {
            proximityMonitoring = false
            if proximityClaimed {
                proximityClaimed = false
                release("ReleaseProximity")
            }
            near = false
            unsubscribeIfIdle()
        }
    }

    public func isProximityMonitoringEnabled() -> Bool {
        proximityMonitoring
    }

    public func proximityState() -> Bool {
        near
    }

    // MARK: iio-sensor-proxy

    /// Claims a sensor the proxy has, while it's still `wanted`, and hands
    /// over the properties once it's claimed.
    private func claim(has: String, _ method: String, wanted: @escaping (LinuxDevice) -> Bool,
                       claimed: @escaping (LinuxDevice, [String: DBusMessageArgument]) -> Void) {
        let proxy = Self.sensorProxy
        proxy.properties { [weak self] result in
            guard let self, wanted(self) else { return }
            guard case .success(let properties) = result, properties[has]?.flag == true else {
                if case .failure(let error) = result, !error.isServiceMissing {
                    HostLog.error("device: iio-sensor-proxy: \(error)")
                }
                return
            }
            proxy.call(method) { [weak self] result in
                guard let self else { return }
                if case .failure(let error) = result {
                    HostLog.error("device: iio-sensor-proxy: \(method): \(error)")
                    return
                }
                guard wanted(self) else {
                    self.release(method.replacingOccurrences(of: "Claim", with: "Release"))
                    return
                }
                // What it reads now it's claimed.
                proxy.properties { [weak self] result in
                    guard let self, wanted(self), case .success(let properties) = result else { return }
                    claimed(self, properties)
                }
            }
        }
    }

    private func release(_ method: String) {
        Self.sensorProxy.call(method) { result in
            if case .failure(let error) = result {
                HostLog.error("device: iio-sensor-proxy: \(method): \(error)")
            }
        }
    }

    private func subscribe() {
        guard changes == nil else { return }
        changes = Self.sensorProxy.subscribeToChanges { [weak self] changed in
            guard let self else { return }
            if self.accelerometerClaimed, let orientation = changed["AccelerometerOrientation"]?.text {
                self.orient(orientation)
            }
            if self.proximityClaimed, let near = changed["ProximityNear"]?.flag {
                self.approach(near)
            }
        }
    }

    private func unsubscribeIfIdle() {
        guard !orientationUpdates, !proximityMonitoring, let changes else { return }
        Self.sensorProxy.unsubscribe(changes)
        self.changes = nil
    }

    private func orient(_ name: String?) {
        let orientation = SensorProxy.orientation(name ?? "")
        guard orientation != currentOrientation else { return }
        currentOrientation = orientation
        delegate?.didChangeOrientation(self, orientation: orientation.rawValue)
    }

    private func approach(_ near: Bool) {
        guard near != self.near else { return }
        self.near = near
        delegate?.didChangeProximityState(self, near: near)
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
