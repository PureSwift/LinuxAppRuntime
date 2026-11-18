import Bluetooth
import DBUS
import DynamicBluetooth
import LinuxHost

/// The `BluetoothPeripheral` contract over a BlueZ device (`Plan.md` §6).
///
/// BlueZ resolves the whole GATT database when it connects, so discovery
/// reads `GattService1`, `GattCharacteristic1` and `GattDescriptor1`
/// objects under the device. Operations are queued and run one at a time;
/// each reports exactly once, and a disconnect fails what's queued with
/// `notConnected`.
public final class LinuxPeripheral: BluetoothPeripheral {

    let path: String

    /// Process-wide in the app; strong, so objects the guest keeps never
    /// outlive it.
    let hub: BlueZHub

    private(set) var delegate: (any BluetoothPeripheralDelegate)?

    /// Services discovered so far.
    private var discovered: [LinuxService] = []

    private var connectAttempts = 0

    private var disconnecting = false

    /// Operations waiting their turn; the first one is running.
    private var queue: [Operation] = []

    /// Bumped on disconnect, so replies to operations it failed are dropped.
    private var generation = 0

    /// `discoverServices` calls waiting for BlueZ to resolve services.
    private var waitingForServices: [() -> Void] = []

    private struct Operation {
        let run: (_ done: @escaping () -> Void) -> Void
        let fail: (Int32) -> Void
    }

    init(path: String, hub: BlueZHub) {
        self.path = path
        self.hub = hub
    }

    var device: [String: DBusValue] {
        hub.properties(path, BlueZInterface.device) ?? [:]
    }

    var isConnected: Bool {
        device["Connected"]?.boolValue == true
    }

    /// Connected, with its services resolved.
    var isReady: Bool {
        isConnected && device["ServicesResolved"]?.boolValue == true
    }

    // MARK: Peripheral

    public func identifier() -> String {
        device["Address"]?.stringValue ?? path
    }

    public func name() -> String? {
        device["Name"]?.stringValue
    }

    public func state() -> Int32 {
        let state: PeripheralState
        if disconnecting, isConnected {
            state = .disconnecting
        } else if isConnected {
            state = connectAttempts > 0 && !isReady ? .connecting : .connected
        } else {
            state = connectAttempts > 0 ? .connecting : .disconnected
        }
        return state.rawValue
    }

    public func setDelegate(_ delegate: (any BluetoothPeripheralDelegate)?) {
        self.delegate = delegate
    }

    public func discoverServices(_ uuids: [BluetoothUUID]) {
        let wanted = Set(uuids.map(BlueZMapping.bluezUUID))
        enqueue { [self] done in
            let report = { [self] in
                let paths = hub.children(of: path, interface: BlueZInterface.service, parentKey: "Device")
                discovered = paths.filter { path in
                    wanted.isEmpty || wanted.contains(hub.properties(path, BlueZInterface.service)?["UUID"]?.stringValue?.lowercased() ?? "")
                }.map(hub.service)
                delegate?.didDiscoverServices(self, error: 0)
                done()
            }
            if isReady {
                report()
            } else {
                waitingForServices.append(report)
            }
        } fail: { [self] error in
            delegate?.didDiscoverServices(self, error: error)
        }
    }

    public func services() -> [any BluetoothService] {
        discovered
    }

    public func discoverCharacteristics(_ uuids: [BluetoothUUID], for service: any BluetoothService) {
        guard let service = LinuxBluetooth.resolve(service, as: LinuxService.self) else { return }
        let wanted = Set(uuids.map(BlueZMapping.bluezUUID))
        enqueue { [self] done in
            service.discovered = hub.children(of: service.path, interface: BlueZInterface.characteristic, parentKey: "Service")
                .filter { wanted.isEmpty || wanted.contains(hub.properties($0, BlueZInterface.characteristic)?["UUID"]?.stringValue?.lowercased() ?? "") }
                .map(hub.characteristic)
            delegate?.didDiscoverCharacteristics(self, service: service, error: 0)
            done()
        } fail: { [self] error in
            delegate?.didDiscoverCharacteristics(self, service: service, error: error)
        }
    }

    public func discoverDescriptors(for characteristic: any BluetoothCharacteristic) {
        guard let characteristic = LinuxBluetooth.resolve(characteristic, as: LinuxCharacteristic.self) else { return }
        enqueue { [self] done in
            characteristic.discovered = hub.children(of: characteristic.path, interface: BlueZInterface.descriptor, parentKey: "Characteristic")
                .map(hub.descriptor)
            delegate?.didDiscoverDescriptors(self, characteristic: characteristic, error: 0)
            done()
        } fail: { [self] error in
            delegate?.didDiscoverDescriptors(self, characteristic: characteristic, error: error)
        }
    }

    public func readValue(_ characteristic: any BluetoothCharacteristic) {
        guard let characteristic = LinuxBluetooth.resolve(characteristic, as: LinuxCharacteristic.self) else { return }
        enqueue { [self] done in
            characteristic.reading = true
            gatt(characteristic.path, BlueZInterface.characteristic, "ReadValue", [.options([:])], "a{sv}") { [self] result in
                characteristic.reading = false
                switch result {
                case .success(let reply):
                    let value = reply.first?.bytes ?? []
                    characteristic.lastValue = value
                    delegate?.didUpdateValue(self, characteristic: characteristic, value: value, error: 0)
                case .failure(let error):
                    delegate?.didUpdateValue(self, characteristic: characteristic, value: [], error: BlueZMapping.errorCode(error))
                }
                done()
            }
        } fail: { [self] error in
            delegate?.didUpdateValue(self, characteristic: characteristic, value: [], error: error)
        }
    }

    public func writeValue(_ value: [UInt8], for characteristic: any BluetoothCharacteristic, type: Int32) {
        guard let characteristic = LinuxBluetooth.resolve(characteristic, as: LinuxCharacteristic.self) else { return }
        let withResponse = type != WriteType.withoutResponse.rawValue
        enqueue { [self] done in
            let options: DBusValue = .options(["type": .string(withResponse ? "request" : "command")])
            gatt(characteristic.path, BlueZInterface.characteristic, "WriteValue", [.byteArray(value), options], "aya{sv}") { [self] result in
                if withResponse {
                    let error: Int32 = if case .failure(let error) = result { BlueZMapping.errorCode(error) } else { 0 }
                    delegate?.didWriteValue(self, characteristic: characteristic, error: error)
                } else if case .failure(let error) = result {
                    HostLog.warning("Bluetooth write without response failed: \(error)")
                }
                done()
            }
        } fail: { [self] error in
            if withResponse {
                delegate?.didWriteValue(self, characteristic: characteristic, error: error)
            }
        }
    }

    public func setNotifyValue(_ enabled: Bool, for characteristic: any BluetoothCharacteristic) {
        guard let characteristic = LinuxBluetooth.resolve(characteristic, as: LinuxCharacteristic.self) else { return }
        enqueue { [self] done in
            gatt(characteristic.path, BlueZInterface.characteristic, enabled ? "StartNotify" : "StopNotify", [], nil) { [self] result in
                var code: Int32 = 0
                if case .failure(let error) = result {
                    // Already in the state asked for is success.
                    if error.name != "org.bluez.Error.InProgress" || characteristic.isNotifying() != enabled {
                        code = BlueZMapping.errorCode(error)
                    }
                }
                if code == 0 {
                    characteristic.notifying = enabled
                }
                delegate?.didUpdateNotificationState(self, characteristic: characteristic, error: code)
                done()
            }
        } fail: { [self] error in
            delegate?.didUpdateNotificationState(self, characteristic: characteristic, error: error)
        }
    }

    public func readDescriptor(_ descriptor: any BluetoothDescriptor) {
        guard let descriptor = LinuxBluetooth.resolve(descriptor, as: LinuxDescriptor.self) else { return }
        enqueue { [self] done in
            gatt(descriptor.path, BlueZInterface.descriptor, "ReadValue", [.options([:])], "a{sv}") { [self] result in
                switch result {
                case .success(let reply):
                    let value = reply.first?.bytes ?? []
                    descriptor.lastValue = value
                    delegate?.didUpdateDescriptorValue(self, descriptor: descriptor, value: value, error: 0)
                case .failure(let error):
                    delegate?.didUpdateDescriptorValue(self, descriptor: descriptor, value: [], error: BlueZMapping.errorCode(error))
                }
                done()
            }
        } fail: { [self] error in
            delegate?.didUpdateDescriptorValue(self, descriptor: descriptor, value: [], error: error)
        }
    }

    public func writeDescriptor(_ value: [UInt8], for descriptor: any BluetoothDescriptor) {
        guard let descriptor = LinuxBluetooth.resolve(descriptor, as: LinuxDescriptor.self) else { return }
        enqueue { [self] done in
            gatt(descriptor.path, BlueZInterface.descriptor, "WriteValue", [.byteArray(value), .options([:])], "aya{sv}") { [self] result in
                let error: Int32 = if case .failure(let error) = result { BlueZMapping.errorCode(error) } else { 0 }
                delegate?.didWriteDescriptorValue(self, descriptor: descriptor, error: error)
                done()
            }
        } fail: { [self] error in
            delegate?.didWriteDescriptorValue(self, descriptor: descriptor, error: error)
        }
    }

    /// The last RSSI BlueZ heard, which it reports while discovering.
    public func readRSSI() {
        enqueue { [self] done in
            if let rssi = device["RSSI"]?.intValue {
                delegate?.didReadRSSI(self, rssi: Int32(rssi), error: 0)
            } else {
                delegate?.didReadRSSI(self, rssi: 127, error: BluetoothError.operationNotSupported.rawValue)
            }
            done()
        } fail: { [self] error in
            delegate?.didReadRSSI(self, rssi: 127, error: error)
        }
    }

    /// The ATT MTU − 3 without response, from any characteristic's `MTU`
    /// (BlueZ 5.62+); 512, the longest attribute value, with response.
    public func maximumWriteLength(_ type: Int32) -> Int32 {
        guard type == WriteType.withoutResponse.rawValue else { return 512 }
        let mtu = hub.objects.lazy
            .filter { $0.key.hasPrefix(self.path + "/") }
            .compactMap { $0.value[BlueZInterface.characteristic]?["MTU"]?.intValue }
            .first ?? 23
        return Int32(max(mtu - 3, 20))
    }

    public func canSendWriteWithoutResponse() -> Bool {
        true
    }

    // MARK: Queue

    private func enqueue(_ run: @escaping (_ done: @escaping () -> Void) -> Void, fail: @escaping (Int32) -> Void) {
        let operation = Operation(run: run, fail: fail)
        guard isConnected else {
            let code = (hub.readinessError ?? .notConnected).rawValue
            LinuxBluetooth.post { operation.fail(code == BluetoothError.poweredOff.rawValue ? BluetoothError.notConnected.rawValue : code) }
            return
        }
        queue.append(operation)
        if queue.count == 1 {
            // Results arrive after the call that asked, as on other hosts.
            LinuxBluetooth.post { [self] in runNext() }
        }
    }

    private func runNext() {
        guard let operation = queue.first else { return }
        let generation = self.generation
        operation.run { [weak self] in
            guard let self, self.generation == generation else { return }
            self.queue.removeFirst()
            self.runNext()
        }
    }

    /// A GATT call whose reply is dropped if a disconnect already failed it.
    private func gatt(
        _ path: String, _ interface: String, _ method: String, _ arguments: [DBusValue], _ signature: String?,
        reply: @escaping (Result<[DBusValue], BlueZError>) -> Void
    ) {
        let generation = self.generation
        hub.call(path, interface, method, arguments, signature: signature) { [weak self] result in
            guard let self, self.generation == generation else { return }
            reply(result)
        }
    }

    // MARK: Hub events

    func connectionStarted() {
        connectAttempts += 1
    }

    func connectionEnded() {
        connectAttempts = max(connectAttempts - 1, 0)
    }

    func disconnectStarted() {
        disconnecting = true
    }

    func deviceChanged(_ device: [String: DBusValue], keys: Set<String>) {
        if keys.contains("Name") || keys.contains("Alias") {
            delegate?.didUpdateName(self)
        }
        if device["ServicesResolved"]?.boolValue == true, device["Connected"]?.boolValue == true, !waitingForServices.isEmpty {
            let waiting = waitingForServices
            waitingForServices = []
            waiting.forEach { $0() }
        }
        if keys.contains("Connected"), device["Connected"]?.boolValue != true {
            disconnected(error: BluetoothError.notConnected.rawValue)
        }
    }

    /// Fails everything queued.
    func disconnected(error: Int32) {
        disconnecting = false
        generation += 1
        waitingForServices = []
        let failed = queue
        queue = []
        failed.forEach { $0.fail(BluetoothError.notConnected.rawValue) }
        for service in discovered {
            for characteristic in service.discovered {
                characteristic.notifying = false
            }
        }
    }

    /// The device's GATT database changed after it was resolved.
    func servicesChanged() {
        guard isReady, !discovered.isEmpty else { return }
        delegate?.didModifyServices(self)
    }

    /// A notification or indication.
    func notified(_ characteristic: LinuxCharacteristic, _ value: [UInt8]) {
        delegate?.didUpdateValue(self, characteristic: characteristic, value: value, error: 0)
    }
}
