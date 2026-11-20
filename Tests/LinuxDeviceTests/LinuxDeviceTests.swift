import DynamicDevice
import DynamicRuntime
import Foundation
import LinuxHost
import Testing
@testable import LinuxDevice

/// Records what the device tells its delegate.
final class RecordingDelegate: DeviceDelegate {

    var events: [String] = []

    func didChangeBatteryLevel(_ device: any Device, level: Float) { events.append("level \(level)") }
    func didChangeBatteryState(_ device: any Device, state: Int32) { events.append("state \(state)") }
    func didChangeLowPowerMode(_ device: any Device, enabled: Bool) { events.append("lowPower \(enabled)") }
    func didChangeThermalState(_ device: any Device, state: Int32) { events.append("thermal \(state)") }
    func didChangeOrientation(_ device: any Device, orientation: Int32) { events.append("orientation \(orientation)") }
    func didChangeProximityState(_ device: any Device, near: Bool) { events.append("proximity \(near)") }
}

/// A machine's files, laid out under a temporary root.
struct Machine {

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("machine-\(UUID().uuidString)").path

    func write(_ path: String, _ text: String) throws {
        let url = URL(fileURLWithPath: root + "/" + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    var system: SystemInfo {
        SystemInfo(root: root)
    }

    /// A laptop: DMI, one battery reporting energy, a charger, a thermal
    /// zone.
    static func laptop() throws -> Machine {
        let machine = Machine()
        try machine.write("etc/hostname", "ada-laptop\n")
        try machine.write("etc/machine-info", "PRETTY_HOSTNAME=\"Ada's Laptop\"\nCHASSIS=laptop\n")
        try machine.write("sys/class/dmi/id/product_family", "ThinkPad X1 Carbon Gen 11\n")
        try machine.write("sys/class/dmi/id/product_name", "21HM\n")
        try machine.write("sys/class/dmi/id/sys_vendor", "LENOVO\n")
        try machine.write("sys/class/power_supply/BAT0/type", "Battery\n")
        try machine.write("sys/class/power_supply/BAT0/scope", "System\n")
        try machine.write("sys/class/power_supply/BAT0/energy_now", "40000000\n")
        try machine.write("sys/class/power_supply/BAT0/energy_full", "50000000\n")
        try machine.write("sys/class/power_supply/BAT0/status", "Discharging\n")
        try machine.write("sys/class/power_supply/AC/type", "Mains\n")
        try machine.write("sys/class/power_supply/AC/online", "0\n")
        // A mouse's battery isn't the machine's.
        try machine.write("sys/class/power_supply/hidpp_battery_0/type", "Battery\n")
        try machine.write("sys/class/power_supply/hidpp_battery_0/scope", "Device\n")
        try machine.write("sys/class/power_supply/hidpp_battery_0/capacity", "5\n")
        try machine.write("sys/class/thermal/thermal_zone0/temp", "45000\n")
        try machine.write("sys/class/thermal/thermal_zone0/trip_point_0_type", "passive\n")
        try machine.write("sys/class/thermal/thermal_zone0/trip_point_0_temp", "85000\n")
        try machine.write("sys/class/thermal/thermal_zone0/trip_point_1_type", "critical\n")
        try machine.write("sys/class/thermal/thermal_zone0/trip_point_1_temp", "105000\n")
        try machine.write("sys/firmware/acpi/platform_profile", "balanced\n")
        return machine
    }
}

/// Serialized: the device is one object, reading one machine.
@Suite(.serialized) struct LinuxDeviceTests {

    // MARK: Identity

    @Test func aLaptop() throws {
        let system = try Machine.laptop().system
        #expect(system.name == "Ada's Laptop")
        #expect(system.model == "ThinkPad X1 Carbon Gen 11")
        #expect(system.modelIdentifier(machine: "x86_64") == "21HM")
        #expect(system.manufacturer == "LENOVO")
        #expect(system.idiom == .desktop)
    }

    @Test func aBoardWithADeviceTree() throws {
        let machine = Machine()
        try machine.write("etc/hostname", "raspberrypi\n")
        try machine.write("proc/device-tree/model", "Raspberry Pi 4 Model B Rev 1.4\0")
        try machine.write("proc/device-tree/compatible", "raspberrypi,4-model-b\0brcm,bcm2711\0")
        // Firmware's placeholders aren't names.
        try machine.write("sys/class/dmi/id/product_name", "To be filled by O.E.M.\n")
        let system = machine.system
        #expect(system.name == "raspberrypi")
        #expect(system.model == "Raspberry Pi 4 Model B Rev 1.4")
        #expect(system.modelIdentifier(machine: "aarch64") == "raspberrypi,4-model-b")
        #expect(system.manufacturer == "raspberrypi")
        #expect(system.idiom == .unspecified)
    }

    @Test func aMachineWithNothingToSay() {
        let system = Machine().system
        #expect(system.name == "Linux")
        #expect(system.model == "Linux")
        #expect(system.modelIdentifier(machine: "aarch64") == "aarch64")
        #expect(system.manufacturer == "")
        #expect(system.batteryLevel == -1)
        #expect(system.batteryState == .unknown)
        #expect(system.thermalState == .nominal)
        #expect(!system.isLowPowerModeEnabled)
    }

    @Test func idioms() throws {
        for (chassis, idiom) in [("handset", DeviceIdiom.phone), ("tablet", .pad), ("watch", .watch), ("server", .desktop), ("embedded", .unspecified)] {
            let machine = Machine()
            try machine.write("etc/machine-info", "CHASSIS=\(chassis)\n")
            #expect(machine.system.idiom == idiom, "\(chassis)")
        }
        let tablet = Machine()
        try tablet.write("sys/class/dmi/id/chassis_type", "30\n")
        #expect(tablet.system.idiom == .pad)
    }

    @Test func kernelVersions() {
        #expect(LinuxDevice.kernelVersion("Linux version 6.12.48+deb13-arm64 (debian-kernel@lists.debian.org)") == "6.12")
        #expect(LinuxDevice.kernelVersion("6.6.31-v8+") == "6.6")
        #expect(LinuxDevice.kernelVersion("5") == "5")
    }

    // MARK: Power and heat

    @Test func batteries() throws {
        let machine = try Machine.laptop()
        #expect(machine.system.batteryLevel == 0.8, "energy, the mouse's left out")
        #expect(machine.system.batteryState == .unplugged)

        try machine.write("sys/class/power_supply/BAT0/status", "Charging\n")
        #expect(machine.system.batteryState == .charging)
        try machine.write("sys/class/power_supply/BAT0/status", "Not charging\n")
        try machine.write("sys/class/power_supply/AC/online", "1\n")
        #expect(machine.system.batteryState == .full, "held below full on the charger")
        try machine.write("sys/class/power_supply/BAT0/status", "Full\n")
        #expect(machine.system.batteryState == .full)

        // A second battery that reports a percentage only.
        let tablet = Machine()
        try tablet.write("sys/class/power_supply/battery/type", "Battery\n")
        try tablet.write("sys/class/power_supply/battery/capacity", "37\n")
        #expect(tablet.system.batteryLevel == 0.37)
    }

    @Test func heat() throws {
        let machine = try Machine.laptop()
        #expect(machine.system.thermalState == .nominal)
        try machine.write("sys/class/thermal/thermal_zone0/temp", "78000\n")
        #expect(machine.system.thermalState == .fair, "within 10 °C of passive")
        try machine.write("sys/class/thermal/thermal_zone0/temp", "90000\n")
        #expect(machine.system.thermalState == .serious)
        try machine.write("sys/class/thermal/thermal_zone0/temp", "105000\n")
        #expect(machine.system.thermalState == .critical)
        // The hottest zone counts.
        try machine.write("sys/class/thermal/thermal_zone0/temp", "40000\n")
        try machine.write("sys/class/thermal/thermal_zone1/temp", "96000\n")
        try machine.write("sys/class/thermal/thermal_zone1/trip_point_0_type", "hot\n")
        try machine.write("sys/class/thermal/thermal_zone1/trip_point_0_temp", "95000\n")
        #expect(machine.system.thermalState == .critical)
    }

    @Test func lowPower() throws {
        let machine = try Machine.laptop()
        #expect(!machine.system.isLowPowerModeEnabled)
        try machine.write("sys/firmware/acpi/platform_profile", "low-power\n")
        #expect(machine.system.isLowPowerModeEnabled)
    }

    // MARK: The contract

    @Test func batteryReadsUnknownUntilMonitored() throws {
        LinuxDevice.reset()
        defer { LinuxDevice.reset() }
        LinuxDevice.system = try Machine.laptop().system
        let device = LinuxDevice.current()
        #expect(LinuxDevice.current() === device)
        #expect(device.batteryLevel() == -1)
        #expect(device.batteryState() == BatteryState.unknown.rawValue)
        device.setBatteryMonitoringEnabled(true)
        #expect(device.batteryLevel() == 0.8)
        #expect(device.batteryState() == BatteryState.unplugged.rawValue)
        #expect(device.systemName() == "Linux")
        #expect(device.apiLevel() == -1)
        #expect(device.physicalMemory() > 0 && device.processorCount() > 0)
        #expect(!device.isSimulator())
        #expect(device.orientation() == DeviceOrientation.unknown.rawValue)
        device.setProximityMonitoringEnabled(true)
        #expect(!device.isProximityMonitoringEnabled())
    }

    @Test func changesReachTheDelegate() throws {
        LinuxDevice.reset()
        defer { LinuxDevice.reset() }
        let machine = try Machine.laptop()
        LinuxDevice.system = machine.system
        let device = LinuxDevice.current()
        let delegate = RecordingDelegate()
        device.setDelegate(delegate)
        device.setBatteryMonitoringEnabled(true)
        #expect(delegate.events.isEmpty, "nothing changed yet")

        try machine.write("sys/class/power_supply/BAT0/energy_now", "25000000\n")
        try machine.write("sys/class/power_supply/BAT0/status", "Charging\n")
        try machine.write("sys/firmware/acpi/platform_profile", "low-power\n")
        try machine.write("sys/class/thermal/thermal_zone0/temp", "90000\n")
        device.update()
        #expect(delegate.events == ["level 0.5", "state \(BatteryState.charging.rawValue)", "lowPower true",
                                    "thermal \(ThermalState.serious.rawValue)"])
        delegate.events = []
        device.update()
        #expect(delegate.events.isEmpty, "each change once")

        // Battery changes stop with monitoring.
        device.setBatteryMonitoringEnabled(false)
        try machine.write("sys/class/power_supply/BAT0/energy_now", "10000000\n")
        device.update()
        #expect(delegate.events.isEmpty)

        // The main loop looks again by itself.
        LinuxDevice.interval = 1_000_000
        defer { LinuxDevice.interval = 5_000_000_000 }
        device.setDelegate(delegate)
        try machine.write("sys/firmware/acpi/platform_profile", "balanced\n")
        let deadline = Date().addingTimeInterval(5)
        MainLoop.shared.run { !delegate.events.isEmpty || Date() > deadline }
        #expect(delegate.events == ["lowPower false"])
        device.setDelegate(nil)
        #expect(MainLoop.shared.pendingTimers == 0)
    }

    @Test func theVendorKeepsItsIdentifier() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)").path
        let environment = ["HOME": home]
        let first = try #require(LinuxDevice.vendorIdentifier(appIdentifier: "org.example.Notes", environment: environment))
        #expect(UUID(uuidString: first) != nil)
        #expect(LinuxDevice.vendorIdentifier(appIdentifier: "org.example.Paint", environment: environment) == first, "one vendor")
        #expect(LinuxDevice.vendorIdentifier(appIdentifier: "com.other.Notes", environment: environment) != first)
        #expect(FileManager.default.fileExists(atPath: home + "/.local/share/linux-app/vendors/org.example"))
        let container = LinuxDevice.vendorIdentifier(appIdentifier: "org.example.Notes", environment: ["LINUXAPPRUNTIME_CONTAINER": home + "/conf"])
        #expect(container != nil && container != first, "a port's is its own")
        #expect(LinuxDevice.vendorIdentifier(appIdentifier: "org.example.Notes", environment: [:]) == nil)
    }

    @Test func moduleRegistersTheContract() {
        #expect(LinuxDeviceModule.contracts.map(\.name) == ["org.pureswift.device.Device", "org.pureswift.device.DeviceDelegate"])
    }
}
