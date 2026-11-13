import Bluetooth
import DBUS
import DynamicBluetooth
import LinuxHost
import Testing
@testable import LinuxBluetooth

/// Serialized: the hub delivers on the shared main loop, which each test
/// drains.
@Suite(.serialized) struct LinuxBluetoothTests {

    func central(_ bus: FakeBus = FakeBus()) -> (LinuxCentral, CentralLog, BlueZHub, FakeBus) {
        settle()
        let hub = BlueZHub(bus: bus)
        let log = CentralLog()
        let central = LinuxCentral.make(log, hub: hub)
        settle()
        return (central, log, hub, bus)
    }

    /// A central connected to the fixture's device.
    func connected() throws -> (LinuxCentral, CentralLog, LinuxPeripheral, PeripheralLog, FakeBus) {
        let (central, log, hub, bus) = self.central()
        let peripheral = hub.peripheral(FakeBus.device)
        central.connect(peripheral, timeout: 0)
        bus.change(FakeBus.device, BlueZInterface.device, ["Connected": .boolean(true), "ServicesResolved": .boolean(true)])
        settle()
        let peripheralLog = PeripheralLog()
        peripheral.setDelegate(peripheralLog)
        log.events = []
        return (central, log, peripheral, peripheralLog, bus)
    }

    // MARK: State

    @Test func reportsStateOnceAndItsChanges() {
        let (central, log, _, bus) = central()
        #expect(log.events == ["state poweredOn"])
        #expect(central.state() == CentralState.poweredOn.rawValue)
        #expect(LinuxCentral.authorizationStatus() == BluetoothAuthorization.allowed.rawValue)
        central.requestAuthorization()
        bus.change(FakeBus.adapter, BlueZInterface.adapter, ["Powered": .boolean(false)])
        settle()
        #expect(log.events == ["state poweredOn", "state poweredOff", "authorization 3"])
    }

    @Test func unavailableBlueZ() {
        let missing = FakeBus(objects: [:])
        let (_, log, _, _) = central(missing)
        #expect(log.events == ["state unsupported"], "no adapter")

        let bus = FakeBus()
        // The hub holds centrals weakly: keep this one.
        let (central, denied, _, _) = central(bus)
        bus.emit(.unavailable(BlueZError(name: "org.freedesktop.DBus.Error.AccessDenied")))
        settle()
        #expect(denied.events == ["state poweredOn", "state unauthorized"])
        #expect(central.state() == CentralState.unauthorized.rawValue)
    }

    // MARK: Scanning

    @Test func scanFiltersAndReportsOncePerScan() throws {
        let (central, log, _, bus) = central()
        central.scan(services: [.bit16(0x180D)], allowDuplicates: false, mode: 0)
        #expect(bus.methods(on: FakeBus.adapter) == ["SetDiscoveryFilter", "StartDiscovery"])
        let filter = try #require(bus.calls.first?.arguments.first?.properties())
        #expect(filter["UUIDs"]?.strings == [FakeBus.heartRate])
        #expect(filter["Transport"]?.stringValue == "le")
        #expect(central.isScanning())

        let advertised: [String: DBusValue] = [
            "RSSI": .int16(-60),
            "ManufacturerData": .dictionary([.uint16(0x004C): .variant(DBusVariant(.byteArray([1, 2])))]),
            "TxPower": .int16(4),
        ]
        bus.change(FakeBus.device, BlueZInterface.device, advertised)
        bus.change(FakeBus.device, BlueZInterface.device, ["RSSI": .int16(-58)])
        // Another device without the service.
        bus.emit(.added(path: FakeBus.adapter + "/dev_11", interfaces: [BlueZInterface.device: [
            "Address": .string("11:11:11:11:11:11"), "RSSI": .int16(-40), "UUIDs": .array([]),
        ]]))
        #expect(log.events == ["state poweredOn", "discover AA:BB:CC:DD:EE:FF -60"])
        let advertisement = try #require(log.discovered.first?.advertisement)
        #expect(advertisement.localName() == "Sensor")
        #expect(advertisement.manufacturerData() == [0x4C, 0x00, 1, 2])
        #expect(try advertisement.serviceUUIDs() == [.bit16(0x180D)])
        #expect(advertisement.txPowerLevel() == 4)

        central.stopScan()
        #expect(bus.methods(on: FakeBus.adapter).last == "StopDiscovery")
        #expect(!central.isScanning())
    }

    @Test func duplicatesWhenAsked() {
        let (central, log, _, bus) = central()
        central.scan(services: [], allowDuplicates: true, mode: 0)
        bus.change(FakeBus.device, BlueZInterface.device, ["RSSI": .int16(-60)])
        bus.change(FakeBus.device, BlueZInterface.device, ["RSSI": .int16(-61)])
        #expect(log.events.filter { $0.hasPrefix("discover") }.count == 2)
    }

    @Test func scanningWhilePoweredOffFails() {
        let bus = FakeBus()
        bus.objects[FakeBus.adapter]?[BlueZInterface.adapter]?["Powered"] = .boolean(false)
        let (central, log, _, _) = central(bus)
        central.scan(services: [], allowDuplicates: false, mode: 0)
        settle()
        #expect(log.events == ["state poweredOff", "stopScanning \(BluetoothError.poweredOff.rawValue)"])
    }

    // MARK: Connections

    @Test func connectsOnceServicesAreResolved() {
        let (central, log, hub, bus) = central()
        let peripheral = hub.peripheral(FakeBus.device)
        #expect(peripheral.identifier() == "AA:BB:CC:DD:EE:FF")
        #expect(peripheral.name() == "Sensor")
        central.connect(peripheral, timeout: 0)
        #expect(peripheral.state() == PeripheralState.connecting.rawValue)
        settle()
        #expect(bus.methods(on: FakeBus.device) == ["Connect"])
        bus.change(FakeBus.device, BlueZInterface.device, ["Connected": .boolean(true)])
        #expect(!log.events.contains("connect"), "not resolved yet")
        bus.change(FakeBus.device, BlueZInterface.device, ["ServicesResolved": .boolean(true)])
        #expect(log.events.last == "connect")
        #expect(peripheral.state() == PeripheralState.connected.rawValue)
        #expect(central.retrieveConnectedPeripherals([.bit16(0x180D)]).count == 1)
        #expect(central.retrievePeripherals(["aa:bb:cc:dd:ee:ff", "00:00:00:00:00:00"]).count == 1)

        central.cancelConnection(peripheral)
        bus.change(FakeBus.device, BlueZInterface.device, ["Connected": .boolean(false), "ServicesResolved": .boolean(false)])
        #expect(log.events.last == "disconnect 0")
    }

    @Test func connectionFailuresAndTimeouts() {
        let bus = FakeBus()
        bus.responder = { call in
            switch call.method {
            case "Connect" where call.path == FakeBus.device: nil
            default: .success([])
            }
        }
        let (central, log, hub, _) = central(bus)
        let peripheral = hub.peripheral(FakeBus.device)
        central.connect(peripheral, timeout: 5)
        let start = MainLoop.now()
        MainLoop.shared.run { log.events.count > 1 || MainLoop.now() - start > 2_000_000_000 }
        #expect(log.events.last == "failToConnect connectionTimeout")
        #expect(bus.methods(on: FakeBus.device) == ["Connect", "Disconnect"])
        #expect(peripheral.state() == PeripheralState.disconnected.rawValue)

        bus.responder = { _ in .failure(BlueZError(name: "org.bluez.Error.Failed", message: "le-connection-abort-by-local")) }
        central.connect(peripheral, timeout: 0)
        settle()
        #expect(log.events.last == "failToConnect connectionFailed")
    }

    @Test func unexpectedDisconnectsFailWhatsQueued() throws {
        let (central, log, peripheral, peripheralLog, bus) = try connected()
        bus.responder = { call in call.method == "ReadValue" ? nil : .success([]) }
        peripheral.discoverServices([])
        settle()
        let characteristic = LinuxCharacteristic(path: FakeBus.characteristic, hub: peripheral.hub)
        peripheral.readValue(characteristic)
        peripheral.readRSSI()
        settle()
        bus.change(FakeBus.device, BlueZInterface.device, ["Connected": .boolean(false)])
        settle()
        #expect(peripheralLog.events == [
            "services 0",
            "value [] \(BluetoothError.notConnected.rawValue)",
            "rssi 127 \(BluetoothError.notConnected.rawValue)",
        ])
        #expect(log.events == ["disconnect \(BluetoothError.peripheralDisconnected.rawValue)"])
        _ = central
    }

    // MARK: GATT

    @Test func discoversTheResolvedDatabase() throws {
        let (_, _, peripheral, log, _) = try connected()
        peripheral.discoverServices([.bit16(0x180D)])
        settle()
        let service = try #require(peripheral.services().first)
        #expect(try service.uuid() == .bit16(0x180D))
        #expect(service.isPrimary())
        peripheral.discoverCharacteristics([], for: service)
        settle()
        let characteristic = try #require(service.characteristics().first)
        #expect(try characteristic.uuid() == .bit16(0x2A37))
        #expect(characteristic.properties() == 0x02 | 0x08 | 0x10)
        peripheral.discoverDescriptors(for: characteristic)
        settle()
        #expect(try characteristic.descriptors().first?.uuid() == .bit16(0x2902))
        #expect(log.events == ["services 0", "characteristics 0", "descriptors 0"])
        #expect(peripheral.maximumWriteLength(WriteType.withoutResponse.rawValue) == 182)
        #expect(peripheral.maximumWriteLength(WriteType.withResponse.rawValue) == 512)

        // Discovering a service that isn't there finds nothing.
        peripheral.discoverServices([.bit16(0x1234)])
        settle()
        #expect(peripheral.services().isEmpty)
    }

    @Test func readsWritesAndNotifications() throws {
        let (_, _, peripheral, log, bus) = try connected()
        bus.responder = { call in
            switch call.method {
            case "ReadValue": .success([.byteArray([0x06, 0x48])])
            case "WriteValue" where call.arguments.last?.properties()["type"]?.stringValue == "request":
                .failure(BlueZError(name: "org.bluez.Error.NotPermitted"))
            default: .success([])
            }
        }
        let characteristic = peripheral.hub.characteristic(FakeBus.characteristic)
        peripheral.readValue(characteristic)
        // BlueZ's own Value change for the read isn't a notification.
        bus.change(FakeBus.characteristic, BlueZInterface.characteristic, ["Value": .byteArray([0x06, 0x48])])
        settle()
        peripheral.writeValue([1], for: characteristic, type: WriteType.withResponse.rawValue)
        peripheral.writeValue([2], for: characteristic, type: WriteType.withoutResponse.rawValue)
        peripheral.setNotifyValue(true, for: characteristic)
        settle()
        bus.change(FakeBus.characteristic, BlueZInterface.characteristic, ["Value": .byteArray([0x06, 0x50])])
        #expect(log.events == [
            "value [6, 72] 0",
            "write \(BluetoothError.insufficientAuthentication.rawValue)",
            "notifying true 0",
            "value [6, 80] 0",
        ])
        #expect(characteristic.value() == [0x06, 0x50])
        let writes = bus.calls.filter { $0.method == "WriteValue" }
        #expect(writes.map { $0.arguments.first?.bytes } == [[1], [2]])
        #expect(writes.last?.arguments.last?.properties()["type"]?.stringValue == "command")
    }

    @Test func operationsWhileDisconnectedFail() {
        let (_, _, hub, _) = central()
        let peripheral = hub.peripheral(FakeBus.device)
        let log = PeripheralLog()
        peripheral.setDelegate(log)
        peripheral.discoverServices([])
        settle()
        #expect(log.events == ["services \(BluetoothError.notConnected.rawValue)"])
    }

    // MARK: Mapping

    @Test func mappings() {
        #expect(BlueZMapping.shortestUUID("0000180d-0000-1000-8000-00805f9b34fb") == .bit16(0x180D))
        #expect(BlueZMapping.shortestUUID("12345678-0000-1000-8000-00805f9b34fb") == .bit32(0x12345678))
        #expect(BlueZMapping.bluezUUID(.bit16(0x2A37)) == "00002a37-0000-1000-8000-00805f9b34fb")
        #expect(BlueZMapping.properties(["read", "write-without-response", "indicate", "encrypt-read"]) == 0x02 | 0x04 | 0x20)
        #expect(BlueZMapping.errorCode(BlueZError(name: "org.bluez.Error.NotConnected")) == BluetoothError.notConnected.rawValue)
        #expect(BlueZMapping.errorCode(BlueZError(name: "org.bluez.Error.NotSupported")) == BluetoothError.operationNotSupported.rawValue)
        #expect(BlueZMapping.errorCode(BlueZError(name: "org.bluez.Error.Failed"), connecting: true) == BluetoothError.connectionFailed.rawValue)
        #expect(BlueZMapping.manufacturerData(.dictionary([
            .uint16(0x0102): .variant(DBusVariant(.byteArray([9]))),
            .uint16(0x0001): .variant(DBusVariant(.byteArray([7]))),
        ])) == [0x01, 0x00, 7], "the lowest company identifier first")
    }
}
