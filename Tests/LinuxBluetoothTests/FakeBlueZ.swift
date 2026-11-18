import Bluetooth
import DBUS
import DynamicBluetooth
import LinuxHost
@testable import LinuxBluetooth

/// Plays BlueZ: a set of objects, signals on demand, and replies to calls
/// on the next turn of the main loop, as the system bus does.
final class FakeBus: BlueZBus {

    struct Call: Equatable {
        var path: String
        var interface: String
        var method: String
        var arguments: [DBusValue]
    }

    var objects: [String: BlueZInterfaces]

    /// Answers each call; `nil` holds the reply back.
    var responder: (Call) -> Result<[DBusValue], BlueZError>? = { _ in .success([]) }

    private(set) var calls: [Call] = []

    private var handler: ((BlueZBusEvent) -> Void)?

    init(objects: [String: BlueZInterfaces] = FakeBus.fixture) {
        self.objects = objects
    }

    func connect(_ handler: @escaping (BlueZBusEvent) -> Void) {
        self.handler = handler
        let objects = self.objects
        MainLoop.shared.post { handler(.connected(objects)) }
    }

    func call(_ path: String, _ interface: String, _ method: String, _ arguments: [DBusValue],
              signature: String?, reply: @escaping (Result<[DBusValue], BlueZError>) -> Void) {
        let call = Call(path: path, interface: interface, method: method, arguments: arguments)
        calls.append(call)
        if let result = responder(call) {
            MainLoop.shared.post { reply(result) }
        }
    }

    func methods(on path: String? = nil) -> [String] {
        calls.filter { path == nil || $0.path == path }.map(\.method)
    }

    /// A `PropertiesChanged` signal.
    func change(_ path: String, _ interface: String, _ properties: [String: DBusValue]) {
        handler?(.changed(path: path, interface: interface, changed: properties, invalidated: []))
    }

    func emit(_ event: BlueZBusEvent) {
        handler?(event)
    }

    // MARK: Fixture

    static let adapter = "/org/bluez/hci0"
    static let device = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"
    static let service = device + "/service0010"
    static let characteristic = service + "/char0011"
    static let descriptor = characteristic + "/desc0013"
    static let heartRate = "0000180d-0000-1000-8000-00805f9b34fb"
    static let measurement = "00002a37-0000-1000-8000-00805f9b34fb"

    static let fixture: [String: BlueZInterfaces] = [
        adapter: [BlueZInterface.adapter: ["Powered": .boolean(true), "Address": .string("00:11:22:33:44:55")]],
        device: [BlueZInterface.device: [
            "Address": .string("AA:BB:CC:DD:EE:FF"),
            "Adapter": .objectPath(adapter),
            "Name": .string("Sensor"),
            "Connected": .boolean(false),
            "ServicesResolved": .boolean(false),
            "UUIDs": .array([.string(heartRate)]),
        ]],
        service: [BlueZInterface.service: [
            "UUID": .string(heartRate), "Device": .objectPath(device), "Primary": .boolean(true),
        ]],
        characteristic: [BlueZInterface.characteristic: [
            "UUID": .string(measurement), "Service": .objectPath(service),
            "Flags": .array([.string("read"), .string("notify"), .string("write")]), "MTU": .uint16(185),
        ]],
        descriptor: [BlueZInterface.descriptor: [
            "UUID": .string("00002902-0000-1000-8000-00805f9b34fb"), "Characteristic": .objectPath(characteristic),
        ]],
    ]
}

/// Records what a central reports.
final class CentralLog: BluetoothCentralDelegate {

    var events: [String] = []

    var discovered: [(peripheral: any BluetoothPeripheral, advertisement: any BluetoothAdvertisement, rssi: Int32)] = []

    func didChangeAuthorization(_ central: any BluetoothCentral, status: Int32) {
        events.append("authorization \(status)")
    }

    func didUpdateState(_ central: any BluetoothCentral, state: Int32) {
        events.append("state \(CentralState(rawValue: state)!)")
    }

    func didDiscover(_ central: any BluetoothCentral, peripheral: any BluetoothPeripheral, advertisement: any BluetoothAdvertisement, rssi: Int32) {
        events.append("discover \(peripheral.identifier()) \(rssi)")
        discovered.append((peripheral, advertisement, rssi))
    }

    func didStopScanning(_ central: any BluetoothCentral, error: Int32) {
        events.append("stopScanning \(error)")
    }

    func didConnect(_ central: any BluetoothCentral, peripheral: any BluetoothPeripheral) {
        events.append("connect")
    }

    func didFailToConnect(_ central: any BluetoothCentral, peripheral: any BluetoothPeripheral, error: Int32) {
        events.append("failToConnect \(BluetoothError(rawValue: error)!)")
    }

    func didDisconnect(_ central: any BluetoothCentral, peripheral: any BluetoothPeripheral, error: Int32) {
        events.append("disconnect \(error)")
    }
}

/// Records what a peripheral reports.
final class PeripheralLog: BluetoothPeripheralDelegate {

    var events: [String] = []

    func didDiscoverServices(_ peripheral: any BluetoothPeripheral, error: Int32) {
        events.append("services \(error)")
    }

    func didDiscoverCharacteristics(_ peripheral: any BluetoothPeripheral, service: any BluetoothService, error: Int32) {
        events.append("characteristics \(error)")
    }

    func didDiscoverDescriptors(_ peripheral: any BluetoothPeripheral, characteristic: any BluetoothCharacteristic, error: Int32) {
        events.append("descriptors \(error)")
    }

    func didUpdateValue(_ peripheral: any BluetoothPeripheral, characteristic: any BluetoothCharacteristic, value: [UInt8], error: Int32) {
        events.append("value \(value) \(error)")
    }

    func didWriteValue(_ peripheral: any BluetoothPeripheral, characteristic: any BluetoothCharacteristic, error: Int32) {
        events.append("write \(error)")
    }

    func didUpdateNotificationState(_ peripheral: any BluetoothPeripheral, characteristic: any BluetoothCharacteristic, error: Int32) {
        events.append("notifying \(characteristic.isNotifying()) \(error)")
    }

    func didUpdateDescriptorValue(_ peripheral: any BluetoothPeripheral, descriptor: any BluetoothDescriptor, value: [UInt8], error: Int32) {
        events.append("descriptor \(value) \(error)")
    }

    func didWriteDescriptorValue(_ peripheral: any BluetoothPeripheral, descriptor: any BluetoothDescriptor, error: Int32) {
        events.append("descriptorWrite \(error)")
    }

    func didReadRSSI(_ peripheral: any BluetoothPeripheral, rssi: Int32, error: Int32) {
        events.append("rssi \(rssi) \(error)")
    }

    func isReadyToSendWriteWithoutResponse(_ peripheral: any BluetoothPeripheral) {
        events.append("ready")
    }

    func didModifyServices(_ peripheral: any BluetoothPeripheral) {
        events.append("modified")
    }

    func didUpdateName(_ peripheral: any BluetoothPeripheral) {
        events.append("name")
    }
}

/// Runs the main loop until nothing is ready.
func settle() {
    MainLoop.shared.drain()
}
