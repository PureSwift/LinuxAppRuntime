import Bluetooth
import DBUS
import DynamicBluetooth
import LinuxHost

/// The `Central` contract over BlueZ (`Plan.md` §6).
///
/// - Authorization is always `allowed`: desktop Linux has no prompt, and
///   the sandbox's `bluetooth` capability gates the contract itself.
/// - Discovery is shared: `BlueZHub` runs one discovery for every scanning
///   central, and each central filters what it reports.
/// - `didConnect` comes once BlueZ is connected and has resolved the
///   peripheral's services, so discovery reads them from BlueZ's objects.
/// - Connection timeouts are main-loop timers; BlueZ's own is long.
///
/// Every call that reports through the delegate reports exactly once.
public final class LinuxCentral: Central {

    struct ScanRequest {
        var services: [BluetoothUUID]
        var allowDuplicates: Bool
    }

    let delegate: any CentralDelegate

    let hub: BlueZHub

    private(set) var scanRequest: ScanRequest?

    /// Devices reported during this scan.
    private var seen: Set<String> = []

    private var connecting: [String: (peripheral: LinuxPeripheral, timer: MainLoop.TimerToken?)] = [:]

    private var connected: [String: LinuxPeripheral] = [:]

    /// `cancelConnection` calls waiting for BlueZ's disconnect.
    private var cancelling: Set<String> = []

    private var reportedState: CentralState?

    init(delegate: any CentralDelegate, hub: BlueZHub) {
        self.delegate = delegate
        self.hub = hub
    }

    deinit {
        for (_, attempt) in connecting {
            attempt.timer.map { MainLoop.shared.cancel($0) }
            attempt.peripheral.connectionEnded()
        }
        let hub = self.hub
        LinuxBluetooth.post { hub.updateDiscovery() }
    }

    // MARK: Authorization and state

    public static func authorizationStatus() -> Int32 {
        BluetoothAuthorization.allowed.rawValue
    }

    public static func make(_ delegate: any CentralDelegate) -> LinuxCentral {
        make(delegate, hub: .shared)
    }

    static func make(_ delegate: any CentralDelegate, hub: BlueZHub) -> LinuxCentral {
        let central = LinuxCentral(delegate: delegate, hub: hub)
        hub.add(central)
        LinuxBluetooth.post { [weak central] in
            hub.start {
                guard let central else { return }
                central.stateChanged(hub.state)
            }
        }
        return central
    }

    /// Nothing to ask on Linux: reports `allowed`.
    public func requestAuthorization() {
        LinuxBluetooth.post { [self] in
            delegate.didChangeAuthorization(self, status: BluetoothAuthorization.allowed.rawValue)
        }
    }

    public func state() -> Int32 {
        hub.state.rawValue
    }

    func stateChanged(_ state: CentralState) {
        guard state != reportedState, state != .unknown || reportedState != nil else { return }
        reportedState = state
        delegate.didUpdateState(self, state: state.rawValue)
        if state != .poweredOn, scanRequest != nil {
            scanStopped(error: (hub.readinessError ?? .poweredOff).rawValue)
        }
    }

    // MARK: Scanning

    public func scan(services: [BluetoothUUID], allowDuplicates: Bool, mode: Int32) {
        if let error = hub.readinessError {
            LinuxBluetooth.post { [self] in
                delegate.didStopScanning(self, error: error.rawValue)
            }
            return
        }
        scanRequest = ScanRequest(services: services, allowDuplicates: allowDuplicates)
        seen = []
        hub.updateDiscovery()
    }

    public func stopScan() {
        guard scanRequest != nil else { return }
        scanRequest = nil
        seen = []
        hub.updateDiscovery()
    }

    public func isScanning() -> Bool {
        scanRequest != nil
    }

    /// Discovery stopped on its own.
    func scanStopped(error: Int32) {
        guard scanRequest != nil else { return }
        scanRequest = nil
        seen = []
        delegate.didStopScanning(self, error: error)
    }

    /// BlueZ heard a device while discovering.
    func discovered(_ path: String, _ device: [String: DBusValue]) {
        guard let request = scanRequest else { return }
        if !request.services.isEmpty {
            let advertised = Set(device["UUIDs"]?.strings.map { $0.lowercased() } ?? [])
            guard request.services.contains(where: { advertised.contains(BlueZMapping.bluezUUID($0)) }) else { return }
        }
        if !request.allowDuplicates {
            guard seen.insert(path).inserted else { return }
        }
        let rssi = Int32(device["RSSI"]?.intValue ?? 127)
        let peripheral = hub.peripheral(path)
        delegate.didDiscover(self, peripheral: peripheral, advertisement: LinuxAdvertisement(device), rssi: rssi)
    }

    // MARK: Connections

    public func connect(_ peripheral: any Peripheral, timeout: Int32) {
        guard let peripheral = LinuxBluetooth.resolve(peripheral, as: LinuxPeripheral.self) else {
            HostLog.warning("connect: not a peripheral of this host")
            return
        }
        let path = peripheral.path
        if let error = hub.readinessError {
            LinuxBluetooth.post { [self] in
                delegate.didFailToConnect(self, peripheral: peripheral, error: error.rawValue)
            }
            return
        }
        guard connecting[path] == nil else { return }
        if peripheral.isReady {
            connected[path] = peripheral
            LinuxBluetooth.post { [self] in
                delegate.didConnect(self, peripheral: peripheral)
            }
            return
        }
        var timer: MainLoop.TimerToken?
        if timeout > 0 {
            timer = MainLoop.shared.schedule(after: Int64(timeout) * 1_000_000) { [weak self] in
                guard let self, self.connecting[path] != nil else { return }
                self.hub.call(path, BlueZInterface.device, "Disconnect")
                self.failConnection(path, error: BluetoothError.connectionTimeout.rawValue)
            }
        }
        connecting[path] = (peripheral, timer)
        peripheral.connectionStarted()
        hub.call(path, BlueZInterface.device, "Connect") { [weak self] result in
            guard let self, self.connecting[path] != nil else { return }
            switch result {
            case .success:
                if peripheral.isReady {
                    self.finishConnection(path)
                }
            case .failure(let error):
                self.failConnection(path, error: BlueZMapping.errorCode(error, connecting: true))
            }
        }
    }

    public func cancelConnection(_ peripheral: any Peripheral) {
        guard let peripheral = LinuxBluetooth.resolve(peripheral, as: LinuxPeripheral.self) else { return }
        let path = peripheral.path
        if let attempt = connecting.removeValue(forKey: path) {
            attempt.timer.map { MainLoop.shared.cancel($0) }
            peripheral.connectionEnded()
            hub.call(path, BlueZInterface.device, "Disconnect")
            LinuxBluetooth.post { [self] in
                delegate.didDisconnect(self, peripheral: peripheral, error: 0)
            }
            return
        }
        guard connected[path] != nil, peripheral.isConnected else {
            connected[path] = nil
            LinuxBluetooth.post { [self] in
                delegate.didDisconnect(self, peripheral: peripheral, error: 0)
            }
            return
        }
        guard cancelling.insert(path).inserted else { return }
        peripheral.disconnectStarted()
        hub.call(path, BlueZInterface.device, "Disconnect") { [weak self] result in
            // A failed disconnect that leaves the device connected still
            // ends the call.
            guard let self, case .failure = result, self.cancelling.contains(path) else { return }
            self.disconnected(path, peripheral)
        }
    }

    public func retrievePeripherals(_ identifiers: [String]) -> [any Peripheral] {
        identifiers.compactMap { hub.devicePath(address: $0).map(hub.peripheral) }
    }

    public func retrieveConnectedPeripherals(_ services: [BluetoothUUID]) -> [any Peripheral] {
        let wanted = Set(services.map(BlueZMapping.bluezUUID))
        return hub.devicePaths.filter { path in
            guard let device = hub.properties(path, BlueZInterface.device), device["Connected"]?.boolValue == true else {
                return false
            }
            return wanted.isEmpty || !wanted.isDisjoint(with: device["UUIDs"]?.strings.map { $0.lowercased() } ?? [])
        }.map(hub.peripheral)
    }

    /// A device's `Connected` or `ServicesResolved` changed.
    func deviceChanged(_ path: String, _ device: [String: DBusValue], keys: Set<String>) {
        if connecting[path] != nil, device["Connected"]?.boolValue == true, device["ServicesResolved"]?.boolValue == true {
            finishConnection(path)
            return
        }
        if keys.contains("Connected"), device["Connected"]?.boolValue != true, let peripheral = connected[path] {
            disconnected(path, peripheral)
        }
    }

    private func disconnected(_ path: String, _ peripheral: LinuxPeripheral) {
        connected[path] = nil
        let cancelled = cancelling.remove(path) != nil
        delegate.didDisconnect(self, peripheral: peripheral, error: cancelled ? 0 : BluetoothError.peripheralDisconnected.rawValue)
    }

    private func finishConnection(_ path: String) {
        guard let attempt = connecting.removeValue(forKey: path) else { return }
        attempt.timer.map { MainLoop.shared.cancel($0) }
        attempt.peripheral.connectionEnded()
        connected[path] = attempt.peripheral
        delegate.didConnect(self, peripheral: attempt.peripheral)
    }

    private func failConnection(_ path: String, error: Int32) {
        guard let attempt = connecting.removeValue(forKey: path) else { return }
        attempt.timer.map { MainLoop.shared.cancel($0) }
        attempt.peripheral.connectionEnded()
        delegate.didFailToConnect(self, peripheral: attempt.peripheral, error: error)
    }
}
