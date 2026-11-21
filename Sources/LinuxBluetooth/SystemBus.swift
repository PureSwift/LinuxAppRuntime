import DBus
import LinuxDBus
import LinuxHost

/// BlueZ on the system bus, through LinuxDBus's `Bus.system`, so the
/// process has one connection to it, whichever modules use it. Main loop
/// only.
///
/// It subscribes to BlueZ's signals, then reads its objects; signals that
/// come before the objects wait for them. When the bus closes, BlueZ is
/// unavailable from then on.
public final class SystemBus: BlueZBus {

    private let bus: Bus

    private let loop: MainLoop

    private enum Phase {
        case idle
        /// Reading the objects; the signals that came meanwhile.
        case connecting([BlueZBusEvent])
        case connected
        case closed
    }

    private var phase = Phase.idle

    private var handler: (BlueZBusEvent) -> Void = { _ in }

    private var subscriptions: [BusSubscription] = []

    public init(bus: Bus = .system, loop: MainLoop = .shared) {
        self.bus = bus
        self.loop = loop
    }

    static let service = "org.bluez"

    public func connect(_ handler: @escaping (BlueZBusEvent) -> Void) {
        guard case .idle = phase else { return }
        self.handler = handler
        phase = .connecting([])
        // Signals from BlueZ only; subscribing before reading the objects
        // misses none.
        subscriptions = [
            bus.subscribe(MatchRule(sender: Self.service, path: "/", interface: BlueZInterface.objectManager, member: "InterfacesAdded")) { [weak self] signal in
                guard signal.body.count >= 2, let path = signal.body[0].text else { return }
                self?.report(.added(path: path, interfaces: signal.body[1].interfaces()))
            },
            bus.subscribe(MatchRule(sender: Self.service, path: "/", interface: BlueZInterface.objectManager, member: "InterfacesRemoved")) { [weak self] signal in
                guard signal.body.count >= 2, let path = signal.body[0].text else { return }
                self?.report(.removed(path: path, interfaces: signal.body[1].strings))
            },
            bus.subscribe(MatchRule(sender: Self.service, interface: BlueZInterface.properties, member: "PropertiesChanged")) { [weak self] signal in
                guard signal.body.count >= 2, let interface = signal.body[0].text, interface.hasPrefix("org.bluez.") else { return }
                let invalidated = signal.body.count >= 3 ? signal.body[2].strings : []
                self?.report(.changed(path: signal.path, interface: interface, changed: signal.body[1].entries, invalidated: invalidated))
            },
            bus.subscribe(.disconnected) { [weak self] signal in
                self?.closed(BlueZError(name: "org.freedesktop.DBus.Error.Disconnected", message: "the system bus closed"))
            },
        ]

        bus.call(Self.service, "/", BlueZInterface.objectManager, "GetManagedObjects") { [weak self] result in
            guard let self, case .connecting(let waiting) = self.phase else { return }
            switch result {
            case .success(let reply):
                var objects: [String: BlueZInterfaces] = [:]
                for (path, interfaces) in reply.first?.pairs ?? [] {
                    guard let path = path.text else { continue }
                    objects[path] = interfaces.interfaces()
                }
                self.phase = .connected
                self.handler(.connected(objects))
                waiting.forEach(self.handler)
            case .failure(let error):
                self.closed(Self.error(error))
            }
        }
    }

    private func report(_ event: BlueZBusEvent) {
        switch phase {
        case .connecting(let waiting):
            phase = .connecting(waiting + [event])
        case .connected:
            handler(event)
        case .idle, .closed:
            break
        }
    }

    /// BlueZ is unavailable from now on.
    private func closed(_ error: BlueZError) {
        switch phase {
        case .connecting, .connected:
            break
        case .idle, .closed:
            return
        }
        phase = .closed
        subscriptions.forEach(bus.unsubscribe)
        subscriptions = []
        handler(.unavailable(error))
    }

    private static func error(_ error: BusError) -> BlueZError {
        BlueZError(name: error.name, message: error.message)
    }

    public func call(
        _ path: String,
        _ interface: String,
        _ method: String,
        _ arguments: [DBusMessageArgument],
        signature: String?,
        reply: @escaping (Result<[DBusMessageArgument], BlueZError>) -> Void
    ) {
        guard case .connected = phase else {
            loop.post { reply(.failure(BlueZError(name: "org.freedesktop.DBus.Error.ServiceUnknown", message: "BlueZ isn't connected"))) }
            return
        }
        bus.call(Self.service, path, interface, method, arguments, signature: signature) { result in
            reply(result.mapError(Self.error))
        }
    }
}
