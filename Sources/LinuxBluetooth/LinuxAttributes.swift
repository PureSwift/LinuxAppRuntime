import Bluetooth
import DBUS
import DynamicBluetooth
import DynamicRuntime

/// A `GattService1` object.
public final class LinuxService: BluetoothService {

    let path: String

    /// Process-wide in the app; strong, so objects the guest keeps never
    /// outlive it.
    let hub: BlueZHub

    var discovered: [LinuxCharacteristic] = []

    init(path: String, hub: BlueZHub) {
        self.path = path
        self.hub = hub
    }

    private var object: [String: DBusValue] {
        hub.properties(path, BlueZInterface.service) ?? [:]
    }

    public func uuid() throws(RuntimeError) -> BluetoothUUID {
        try BlueZMapping.uuid(object["UUID"]?.stringValue)
    }

    public func isPrimary() -> Bool {
        object["Primary"]?.boolValue ?? true
    }

    public func characteristics() -> [any BluetoothCharacteristic] {
        discovered
    }

    public func peripheral() -> any BluetoothPeripheral {
        hub.peripheral(object["Device"]?.stringValue ?? Self.parent(of: path))
    }

    static func parent(of path: String) -> String {
        path.lastIndex(of: "/").map { String(path[..<$0]) } ?? path
    }
}

/// A `GattCharacteristic1` object.
public final class LinuxCharacteristic: BluetoothCharacteristic {

    let path: String

    /// Process-wide in the app; strong, so objects the guest keeps never
    /// outlive it.
    let hub: BlueZHub

    var discovered: [LinuxDescriptor] = []

    var lastValue: [UInt8]?

    /// A read is in flight: BlueZ's `Value` change for it isn't a
    /// notification.
    var reading = false

    /// Set when `StartNotify` succeeds, until `StopNotify` or a disconnect.
    var notifying: Bool?

    init(path: String, hub: BlueZHub) {
        self.path = path
        self.hub = hub
    }

    private var object: [String: DBusValue] {
        hub.properties(path, BlueZInterface.characteristic) ?? [:]
    }

    public func uuid() throws(RuntimeError) -> BluetoothUUID {
        try BlueZMapping.uuid(object["UUID"]?.stringValue)
    }

    public func properties() -> Int32 {
        BlueZMapping.properties(object["Flags"]?.strings ?? [])
    }

    public func value() -> [UInt8]? {
        lastValue ?? object["Value"]?.bytes
    }

    public func isNotifying() -> Bool {
        notifying ?? object["Notifying"]?.boolValue ?? false
    }

    public func descriptors() -> [any BluetoothDescriptor] {
        discovered
    }

    public func service() -> any BluetoothService {
        hub.service(object["Service"]?.stringValue ?? LinuxService.parent(of: path))
    }

    /// BlueZ's `Value` changed: a notification, unless a read asked for it.
    func valueChanged(_ value: [UInt8]) {
        guard !reading, isNotifying() else { return }
        lastValue = value
        let devicePath = LinuxService.parent(of: object["Service"]?.stringValue ?? LinuxService.parent(of: path))
        hub.peripheral(devicePath).notified(self, value)
    }
}

/// A `GattDescriptor1` object.
public final class LinuxDescriptor: BluetoothDescriptor {

    let path: String

    /// Process-wide in the app; strong, so objects the guest keeps never
    /// outlive it.
    let hub: BlueZHub

    var lastValue: [UInt8]?

    init(path: String, hub: BlueZHub) {
        self.path = path
        self.hub = hub
    }

    private var object: [String: DBusValue] {
        hub.properties(path, BlueZInterface.descriptor) ?? [:]
    }

    public func uuid() throws(RuntimeError) -> BluetoothUUID {
        try BlueZMapping.uuid(object["UUID"]?.stringValue)
    }

    public func value() -> [UInt8]? {
        lastValue ?? object["Value"]?.bytes
    }

    public func characteristic() -> any BluetoothCharacteristic {
        hub.characteristic(object["Characteristic"]?.stringValue ?? LinuxService.parent(of: path))
    }
}

/// What a device advertised, as BlueZ has it when it's reported.
public final class LinuxAdvertisement: BluetoothAdvertisement {

    let device: [String: DBusValue]

    init(_ device: [String: DBusValue]) {
        self.device = device
    }

    public func localName() -> String? {
        device["Name"]?.stringValue
    }

    public func manufacturerData() -> [UInt8]? {
        BlueZMapping.manufacturerData(device["ManufacturerData"])
    }

    public func serviceUUIDs() throws(RuntimeError) -> [BluetoothUUID] {
        var uuids: [BluetoothUUID] = []
        for string in device["UUIDs"]?.strings ?? [] {
            uuids.append(try BlueZMapping.uuid(string))
        }
        return uuids
    }

    public func serviceDataUUIDs() throws(RuntimeError) -> [BluetoothUUID] {
        var uuids: [BluetoothUUID] = []
        for entry in BlueZMapping.serviceData(device["ServiceData"]) {
            uuids.append(try BlueZMapping.uuid(entry.uuid))
        }
        return uuids
    }

    public func serviceData(_ uuid: BluetoothUUID) -> [UInt8]? {
        let wanted = BlueZMapping.bluezUUID(uuid)
        return BlueZMapping.serviceData(device["ServiceData"]).first { $0.uuid.lowercased() == wanted }?.data
    }

    public func solicitedServiceUUIDs() throws(RuntimeError) -> [BluetoothUUID] {
        // BlueZ doesn't report solicited UUIDs.
        []
    }

    public func txPowerLevel() -> Int32 {
        device["TxPower"]?.intValue.map(Int32.init) ?? Int32.min
    }

    /// BlueZ doesn't say.
    public func isConnectable() -> Int32 {
        -1
    }
}
