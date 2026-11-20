import DynamicDevice
import Foundation

/// What Linux says about the machine, read from files: `/etc`, DMI,
/// the device tree, `power_supply` and `thermal` in sysfs.
///
/// `root` is `/`, or a directory laid out the same way, for tests.
struct SystemInfo {

    var root: String

    init(root: String = "/") {
        self.root = root.hasSuffix("/") ? root : root + "/"
    }

    /// A file's contents without surrounding whitespace and the device
    /// tree's NULs; nil if it's missing, empty, or one of the placeholders
    /// firmware leaves in DMI.
    func read(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: root + path) else {
            return nil
        }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        guard !text.isEmpty, !Self.placeholders.contains(text.lowercased()) else {
            return nil
        }
        return text
    }

    static let placeholders: Set<String> = [
        "to be filled by o.e.m.", "default string", "system product name", "system manufacturer",
        "not applicable", "not specified", "none", "unknown", "0", "o.e.m.", "oem",
    ]

    /// `KEY=value` lines, as `/etc/os-release` and `/etc/machine-info` have
    /// them, with quotes removed.
    func keyValues(_ path: String) -> [String: String] {
        guard let text = FileManager.default.contents(atPath: root + path).map({ String(decoding: $0, as: UTF8.self) }) else {
            return [:]
        }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, !line.hasPrefix("#") else { continue }
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            values[parts[0].trimmingCharacters(in: .whitespaces)] = value
        }
        return values
    }

    /// The entries of a directory, sorted.
    func list(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root + path)) ?? []).sorted()
    }

    // MARK: Identity

    /// The name the user gave the machine (`PRETTY_HOSTNAME`), else its
    /// host name.
    var name: String {
        keyValues("etc/machine-info")["PRETTY_HOSTNAME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? read("etc/hostname")
            ?? read("proc/sys/kernel/hostname")
            ?? "Linux"
    }

    /// The device tree's `compatible` strings: `raspberrypi,4-model-b`,
    /// then the SoC's.
    var compatible: [String] {
        guard let data = FileManager.default.contents(atPath: root + "proc/device-tree/compatible") else {
            return []
        }
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.filter { !$0.isEmpty }
    }

    /// The product family (DMI), else its name, else the device tree's
    /// model: "ThinkPad X1 Carbon Gen 11", "Raspberry Pi 4 Model B Rev 1.4".
    var model: String {
        read("sys/class/dmi/id/product_family")
            ?? read("sys/class/dmi/id/product_name")
            ?? read("proc/device-tree/model")
            ?? "Linux"
    }

    /// The product's own identifier: DMI's product name, else the device
    /// tree's first `compatible` string, else the machine's architecture.
    func modelIdentifier(machine: String) -> String {
        read("sys/class/dmi/id/product_name") ?? compatible.first ?? machine
    }

    /// DMI's system vendor, else the vendor in the device tree's
    /// `compatible`.
    var manufacturer: String {
        read("sys/class/dmi/id/sys_vendor")
            ?? compatible.first.flatMap { $0.split(separator: ",").first.map(String.init) }
            ?? ""
    }

    /// From the chassis systemd records (`CHASSIS` in `/etc/machine-info`),
    /// else DMI's chassis type (SMBIOS 3.0, table 17).
    var idiom: DeviceIdiom {
        if let chassis = keyValues("etc/machine-info")["CHASSIS"] {
            switch chassis {
            case "handset": return .phone
            case "tablet": return .pad
            case "watch": return .watch
            case "desktop", "laptop", "convertible", "server", "vm", "container": return .desktop
            default: return .unspecified
            }
        }
        guard let type = read("sys/class/dmi/id/chassis_type").flatMap(Int.init) else {
            return .unspecified
        }
        switch type {
        case 30: return .pad
        case 3...17, 23, 24, 31, 32, 33, 34, 35, 36: return .desktop
        default: return .unspecified
        }
    }

    // MARK: Power

    /// The batteries in `power_supply` that power the machine, rather than
    /// a mouse's or a headset's (`scope` `Device`).
    var batteries: [String] {
        list("sys/class/power_supply").filter { supply in
            let path = "sys/class/power_supply/\(supply)/"
            return read(path + "type") == "Battery" && read(path + "scope") != "Device" && read(path + "present") != "0"
        }
    }

    /// The level, 0 to 1, of all batteries together; -1 without one.
    var batteryLevel: Float {
        var now = 0.0, full = 0.0
        var capacities: [Double] = []
        for battery in batteries {
            let path = "sys/class/power_supply/\(battery)/"
            if let energy = read(path + "energy_now").flatMap(Double.init), let total = read(path + "energy_full").flatMap(Double.init), total > 0 {
                now += energy
                full += total
            } else if let charge = read(path + "charge_now").flatMap(Double.init), let total = read(path + "charge_full").flatMap(Double.init), total > 0 {
                now += charge
                full += total
            } else if let capacity = read(path + "capacity").flatMap(Double.init) {
                capacities.append(capacity / 100)
            }
        }
        if full > 0 {
            return Float(min(max(now / full, 0), 1))
        }
        if !capacities.isEmpty {
            return Float(min(max(capacities.reduce(0, +) / Double(capacities.count), 0), 1))
        }
        return -1
    }

    var batteryState: BatteryState {
        let states = batteries.compactMap { read("sys/class/power_supply/\($0)/status") }
        if states.isEmpty {
            return .unknown
        }
        if states.contains("Charging") {
            return .charging
        }
        if states.contains("Discharging") {
            return .unplugged
        }
        if states.allSatisfy({ $0 == "Full" }) {
            return .full
        }
        // "Not charging": plugged in, held below full.
        return isOnLinePower ? .full : .unplugged
    }

    /// Whether a mains supply is plugged in.
    var isOnLinePower: Bool {
        list("sys/class/power_supply").contains { supply in
            let path = "sys/class/power_supply/\(supply)/"
            return ["Mains", "USB", "USB_PD", "USB_C"].contains(read(path + "type") ?? "") && read(path + "online") == "1"
        }
    }

    /// The firmware's power-saving profile (`platform_profile`), which
    /// power-profiles-daemon sets for its power-saver mode.
    var isLowPowerModeEnabled: Bool {
        ["low-power", "quiet", "cool"].contains(read("sys/firmware/acpi/platform_profile") ?? "")
    }

    // MARK: Thermal

    /// How hot the hottest zone is against its own trip points: at or past
    /// a `critical` or `hot` trip, critical; past `passive`, serious;
    /// within 10 °C of it, fair.
    var thermalState: ThermalState {
        var state = ThermalState.nominal
        for zone in list("sys/class/thermal") where zone.hasPrefix("thermal_zone") {
            let path = "sys/class/thermal/\(zone)/"
            guard let temperature = read(path + "temp").flatMap(Int.init) else { continue }
            var trips: [String: Int] = [:]
            for index in 0..<16 {
                guard let type = read(path + "trip_point_\(index)_type"),
                      let value = read(path + "trip_point_\(index)_temp").flatMap(Int.init), value > 0 else { continue }
                trips[type] = min(trips[type] ?? .max, value)
            }
            let zoneState: ThermalState
            if let limit = [trips["critical"], trips["hot"]].compactMap({ $0 }).min(), temperature >= limit {
                zoneState = .critical
            } else if let passive = trips["passive"] {
                zoneState = temperature >= passive ? .serious : temperature >= passive - 10_000 ? .fair : .nominal
            } else {
                zoneState = .nominal
            }
            if zoneState.rawValue > state.rawValue {
                state = zoneState
            }
        }
        return state
    }
}
