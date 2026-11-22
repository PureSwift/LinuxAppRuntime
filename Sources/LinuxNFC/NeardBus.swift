import DBus
import LinuxDBus
import LinuxHost

/// An object's interfaces, each with its properties (variants unwrapped).
public typealias NeardInterfaces = [String: [String: DBusMessageArgument]]

/// What neard reports, on the main loop.
public enum NeardEvent {
    case added(path: String, interfaces: NeardInterfaces)
    case removed(path: String, interfaces: [String])
    case changed(path: String, interface: String, changed: [String: DBusMessageArgument])
    /// A tag's records were read: after it was found, and again after each
    /// write. neard says so with a signal of its own,
    /// `org.neard.Tag.PropertyChanged("Records", …)`.
    case recordsRead(tag: String)
    /// The bus closed.
    case closed
}

/// The connection to neard (`Plan.md` §14): the real system bus, or a fake
/// one in tests. Everything it answers arrives on the main loop.
public protocol NeardBus: AnyObject {

    /// Every object neard manages (`GetManagedObjects`).
    func objects(reply: @escaping (Result<[String: NeardInterfaces], BusError>) -> Void)

    /// The same, waiting for them: for `availability`, which answers at once.
    func objectsAndWait() -> Result<[String: NeardInterfaces], BusError>

    /// Calls a method of one of neard's objects.
    func call(
        _ path: String,
        _ interface: String,
        _ method: String,
        _ arguments: [DBusMessageArgument],
        signature: String?,
        reply: @escaping (Result<Void, BusError>) -> Void
    )

    /// Calls `handler` with each change to neard's objects.
    func subscribe(_ handler: @escaping (NeardEvent) -> Void) -> BusSubscription

    func unsubscribe(_ subscription: BusSubscription)
}

/// neard's names.
enum Neard {
    static let service = "org.neard"
    static let adapter = "org.neard.Adapter"
    static let tag = "org.neard.Tag"
    static let record = "org.neard.Record"
    static let objectManager = "org.freedesktop.DBus.ObjectManager"
    static let properties = "org.freedesktop.DBus.Properties"
}

/// neard on the system bus, through LinuxDBus's `Bus.system`. Main loop
/// only.
public final class SystemNeard: NeardBus {

    private let bus: Bus

    private var subscriptions: [UInt64: [BusSubscription]] = [:]

    private var next: UInt64 = 0

    public init(bus: Bus = .system) {
        self.bus = bus
    }

    public func objects(reply: @escaping (Result<[String: NeardInterfaces], BusError>) -> Void) {
        bus.call(Neard.service, "/", Neard.objectManager, "GetManagedObjects") { result in
            reply(result.map(Self.objects))
        }
    }

    public func objectsAndWait() -> Result<[String: NeardInterfaces], BusError> {
        bus.callAndWait(Neard.service, "/", Neard.objectManager, "GetManagedObjects").map(Self.objects)
    }

    public func call(
        _ path: String,
        _ interface: String,
        _ method: String,
        _ arguments: [DBusMessageArgument],
        signature: String?,
        reply: @escaping (Result<Void, BusError>) -> Void
    ) {
        bus.call(Neard.service, path, interface, method, arguments, signature: signature) { result in
            reply(result.map { _ in })
        }
    }

    public func subscribe(_ handler: @escaping (NeardEvent) -> Void) -> BusSubscription {
        next += 1
        subscriptions[next] = [
            bus.subscribe(MatchRule(sender: Neard.service, path: "/", interface: Neard.objectManager, member: "InterfacesAdded")) { signal in
                guard signal.body.count >= 2, let path = signal.body[0].text else { return }
                handler(.added(path: path, interfaces: Self.interfaces(signal.body[1])))
            },
            bus.subscribe(MatchRule(sender: Neard.service, path: "/", interface: Neard.objectManager, member: "InterfacesRemoved")) { signal in
                guard signal.body.count >= 2, let path = signal.body[0].text else { return }
                handler(.removed(path: path, interfaces: signal.body[1].elements?.compactMap(\.text) ?? []))
            },
            bus.subscribe(MatchRule(sender: Neard.service, interface: Neard.properties, member: "PropertiesChanged")) { signal in
                guard signal.body.count >= 2, let interface = signal.body[0].text else { return }
                handler(.changed(path: signal.path, interface: interface, changed: signal.body[1].entries))
            },
            bus.subscribe(MatchRule(sender: Neard.service, interface: Neard.tag, member: "PropertyChanged", arg0: "Records")) { signal in
                handler(.recordsRead(tag: signal.path))
            },
            bus.subscribe(.disconnected) { _ in
                handler(.closed)
            },
        ]
        return BusSubscription(id: next)
    }

    public func unsubscribe(_ subscription: BusSubscription) {
        subscriptions.removeValue(forKey: subscription.id)?.forEach(bus.unsubscribe)
    }

    /// `a{oa{sa{sv}}}`.
    private static func objects(_ reply: [DBusMessageArgument]) -> [String: NeardInterfaces] {
        var objects: [String: NeardInterfaces] = [:]
        for (path, interfaces) in reply.first?.pairs ?? [] {
            guard let path = path.text else { continue }
            objects[path] = Self.interfaces(interfaces)
        }
        return objects
    }

    /// `a{sa{sv}}`.
    private static func interfaces(_ argument: DBusMessageArgument) -> NeardInterfaces {
        var interfaces: NeardInterfaces = [:]
        for (name, properties) in argument.pairs ?? [] {
            guard let name = name.text else { continue }
            interfaces[name] = properties.entries
        }
        return interfaces
    }
}

// MARK: - Values

extension DBusMessageArgument {

    /// `ay`.
    var bytes: [UInt8]? {
        elements?.compactMap { if case .byte(let byte) = $0.contents { byte } else { nil } }
    }

    /// `ay`.
    static func byteArray(_ bytes: [UInt8]) -> DBusMessageArgument {
        .list(of: .byte, bytes.map { .byte($0) })
    }
}
