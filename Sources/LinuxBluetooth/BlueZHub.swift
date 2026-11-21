import DBus
import LinuxDBus
import DynamicBluetooth
import LinuxHost

/// The process's one view of BlueZ (`Plan.md` §6): a copy of the objects it
/// manages, kept current by its signals; one wrapper per object path, so a
/// device is always the same `LinuxPeripheral`; and the discovery every
/// scanning central shares. Main loop only.
public final class BlueZHub {

    nonisolated(unsafe) public static var shared = BlueZHub(bus: SystemBus())

    public let bus: BlueZBus

    enum Phase {
        case idle
        case connecting
        case ready
        case unavailable(BlueZError)
    }

    private(set) var phase = Phase.idle

    /// path → interface → properties.
    public private(set) var objects: [String: BlueZInterfaces] = [:]

    private var centrals: [WeakCentral] = []

    private var peripherals: [String: LinuxPeripheral] = [:]

    private var services: [String: LinuxService] = [:]

    private var characteristics: [String: LinuxCharacteristic] = [:]

    private var descriptors: [String: LinuxDescriptor] = [:]

    /// Whether this process asked BlueZ to discover.
    private var discovering = false

    /// The filter discovery last started with.
    private var discoveryFilter: DiscoveryFilter?

    private var whenReady: [() -> Void] = []

    struct DiscoveryFilter: Equatable {
        var uuids: [String]
        var duplicates: Bool
    }

    public init(bus: BlueZBus) {
        self.bus = bus
    }

    static func log(_ message: String) {
        HostLog.warning(message)
    }

    // MARK: Connection

    /// Connects on first use; `body` runs once the objects are known, or
    /// BlueZ turned out to be unavailable.
    func start(_ body: (() -> Void)? = nil) {
        switch phase {
        case .ready, .unavailable:
            body?()
        case .connecting:
            body.map { whenReady.append($0) }
        case .idle:
            phase = .connecting
            body.map { whenReady.append($0) }
            bus.connect { [weak self] event in
                self?.handle(event)
            }
        }
    }

    /// The first adapter, as BlueZ numbers them (`hci0`).
    var adapterPath: String? {
        objects.keys.filter { objects[$0]?[BlueZInterface.adapter] != nil }.sorted().first
    }

    var adapter: [String: DBusMessageArgument]? {
        adapterPath.flatMap { objects[$0]?[BlueZInterface.adapter] }
    }

    /// The central state BlueZ is in.
    var state: CentralState {
        switch phase {
        case .idle, .connecting:
            return .unknown
        case .unavailable(let error):
            return error.isAccessDenied ? .unauthorized : .unsupported
        case .ready:
            guard let adapter else { return .unsupported }
            return adapter["Powered"]?.flag == true ? .poweredOn : .poweredOff
        }
    }

    /// Why an operation can't run now, if it can't.
    var readinessError: BluetoothError? {
        switch state {
        case .poweredOn: nil
        case .unauthorized: .unauthorized
        case .poweredOff: .poweredOff
        case .unknown, .resetting: .poweredOff
        case .unsupported: .unsupported
        }
    }

    // MARK: Calls

    func call(
        _ path: String,
        _ interface: String,
        _ method: String,
        _ arguments: [DBusMessageArgument] = [],
        signature: String? = nil,
        reply: @escaping (Result<[DBusMessageArgument], BlueZError>) -> Void = { _ in }
    ) {
        bus.call(path, interface, method, arguments, signature: signature, reply: reply)
    }

    func properties(_ path: String, _ interface: String) -> [String: DBusMessageArgument]? {
        objects[path]?[interface]
    }

    /// Objects with `interface` directly under `parent`, by their `parentKey`
    /// property (`Device`, `Service`, `Characteristic`), in path order.
    func children(of parent: String, interface: String, parentKey: String) -> [String] {
        objects.compactMap { path, interfaces in
            interfaces[interface]?[parentKey]?.text == parent ? path : nil
        }.sorted()
    }

    // MARK: Wrappers

    func peripheral(_ path: String) -> LinuxPeripheral {
        if let peripheral = peripherals[path] {
            return peripheral
        }
        let peripheral = LinuxPeripheral(path: path, hub: self)
        peripherals[path] = peripheral
        return peripheral
    }

    func service(_ path: String) -> LinuxService {
        if let service = services[path] { return service }
        let service = LinuxService(path: path, hub: self)
        services[path] = service
        return service
    }

    func characteristic(_ path: String) -> LinuxCharacteristic {
        if let characteristic = characteristics[path] { return characteristic }
        let characteristic = LinuxCharacteristic(path: path, hub: self)
        characteristics[path] = characteristic
        return characteristic
    }

    func descriptor(_ path: String) -> LinuxDescriptor {
        if let descriptor = descriptors[path] { return descriptor }
        let descriptor = LinuxDescriptor(path: path, hub: self)
        descriptors[path] = descriptor
        return descriptor
    }

    /// A known device by its address, on the first adapter.
    func devicePath(address: String) -> String? {
        objects.keys.sorted().first { path in
            guard let device = objects[path]?[BlueZInterface.device] else { return false }
            return device["Address"]?.text?.uppercased() == address.uppercased()
                && (adapterPath == nil || device["Adapter"]?.text == adapterPath)
        }
    }

    var devicePaths: [String] {
        objects.keys.filter { objects[$0]?[BlueZInterface.device] != nil }.sorted()
    }

    // MARK: Centrals

    func add(_ central: LinuxCentral) {
        centrals.removeAll { $0.central == nil }
        centrals.append(WeakCentral(central: central))
    }

    private var liveCentrals: [LinuxCentral] {
        centrals.compactMap(\.central)
    }

    /// Starts, changes or stops discovery to match what the centrals ask
    /// for: every service any of them scans for (none if one scans for
    /// all), and duplicates if any wants them.
    func updateDiscovery() {
        guard let adapterPath, case .ready = phase else { return }
        let requests = liveCentrals.compactMap(\.scanRequest)
        guard !requests.isEmpty else {
            if discovering {
                discovering = false
                discoveryFilter = nil
                call(adapterPath, BlueZInterface.adapter, "StopDiscovery")
            }
            return
        }
        let all = requests.contains { $0.services.isEmpty }
        let uuids = all ? [] : Array(Set(requests.flatMap { $0.services.map(BlueZMapping.bluezUUID) })).sorted()
        let filter = DiscoveryFilter(uuids: uuids, duplicates: requests.contains { $0.allowDuplicates })
        guard filter != discoveryFilter || !discovering else { return }
        discoveryFilter = filter
        var options: [String: DBusMessageArgument] = [
            "Transport": .string("le"),
            "DuplicateData": .boolean(filter.duplicates),
        ]
        if !uuids.isEmpty {
            options["UUIDs"] = .stringArray(uuids)
        }
        call(adapterPath, BlueZInterface.adapter, "SetDiscoveryFilter", [.vardict(options)], signature: "a{sv}")
        if !discovering {
            discovering = true
            call(adapterPath, BlueZInterface.adapter, "StartDiscovery") { [weak self] result in
                if case .failure(let error) = result, error.name != "org.bluez.Error.InProgress" {
                    self?.discoveryFailed(error)
                }
            }
        }
    }

    private func discoveryFailed(_ error: BlueZError) {
        discovering = false
        discoveryFilter = nil
        let code = error.name == "org.bluez.Error.NotReady" ? BluetoothError.poweredOff.rawValue : BluetoothError.scanFailed.rawValue
        for central in liveCentrals where central.scanRequest != nil {
            central.scanStopped(error: code)
        }
    }

    // MARK: Events

    private func handle(_ event: BlueZBusEvent) {
        switch event {
        case .connected(let objects):
            self.objects = objects
            phase = .ready
            finishStarting()
        case .unavailable(let error):
            let wasReady: Bool
            if case .ready = phase { wasReady = true } else { wasReady = false }
            phase = .unavailable(error)
            objects = [:]
            discovering = false
            discoveryFilter = nil
            HostLog.debug("BlueZ unavailable: \(error)")
            finishStarting()
            if wasReady {
                stateChanged()
                peripherals.values.forEach { $0.disconnected(error: BluetoothError.peripheralDisconnected.rawValue) }
            }
        case .added(let path, let interfaces):
            objects[path, default: [:]].merge(interfaces) { $1 }
            if interfaces[BlueZInterface.adapter] != nil {
                stateChanged()
                updateDiscovery()
            }
            if let device = interfaces[BlueZInterface.device] {
                deviceChanged(path, device, keys: Set(device.keys))
            }
            if interfaces[BlueZInterface.service] != nil {
                gattChanged(under: path)
            }
        case .removed(let path, let interfaces):
            for interface in interfaces {
                objects[path]?[interface] = nil
            }
            if objects[path]?.isEmpty == true {
                objects[path] = nil
            }
            if interfaces.contains(BlueZInterface.adapter) {
                stateChanged()
            }
            if interfaces.contains(BlueZInterface.service) {
                gattChanged(under: path)
            }
        case .changed(let path, let interface, let changed, let invalidated):
            objects[path, default: [:]][interface, default: [:]].merge(changed) { $1 }
            for key in invalidated {
                objects[path]?[interface]?[key] = nil
            }
            switch interface {
            case BlueZInterface.adapter:
                if changed["Powered"] != nil {
                    stateChanged()
                    if changed["Powered"]?.flag == true {
                        discovering = false
                        updateDiscovery()
                    }
                }
                if changed["Discovering"]?.flag == false, discovering {
                    // Another process, or BlueZ, stopped it: start again.
                    discovering = false
                    discoveryFilter = nil
                    updateDiscovery()
                }
            case BlueZInterface.device:
                deviceChanged(path, objects[path]?[interface] ?? [:], keys: Set(changed.keys).union(invalidated))
            case BlueZInterface.characteristic:
                if let value = changed["Value"]?.bytes {
                    characteristics[path]?.valueChanged(value)
                }
            default:
                break
            }
        }
    }

    private func finishStarting() {
        let waiting = whenReady
        whenReady = []
        waiting.forEach { $0() }
        stateChanged()
        updateDiscovery()
    }

    private var lastState: CentralState?

    private func stateChanged() {
        let state = self.state
        guard state != lastState else { return }
        lastState = state
        for central in liveCentrals {
            central.stateChanged(state)
        }
    }

    private func deviceChanged(_ path: String, _ device: [String: DBusMessageArgument], keys: Set<String>) {
        if !keys.isDisjoint(with: ["RSSI", "ManufacturerData", "ServiceData", "UUIDs", "TxPower"]), device["RSSI"] != nil {
            for central in liveCentrals where central.scanRequest != nil {
                central.discovered(path, device)
            }
        }
        for central in liveCentrals {
            central.deviceChanged(path, device, keys: keys)
        }
        if let peripheral = peripherals[path] {
            peripheral.deviceChanged(device, keys: keys)
        }
    }

    /// GATT objects appeared or went away under a device after it resolved
    /// its services.
    private func gattChanged(under path: String) {
        for (devicePath, peripheral) in peripherals where path.hasPrefix(devicePath + "/") {
            peripheral.servicesChanged()
        }
    }

    private struct WeakCentral {
        weak var central: LinuxCentral?
    }
}
