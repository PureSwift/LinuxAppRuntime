import DBus
import LinuxDBus

/// An object's interfaces, each with its properties (variants unwrapped).
public typealias BlueZInterfaces = [String: [String: DBusMessageArgument]]

/// A D-Bus error BlueZ, or the bus, answered with.
public struct BlueZError: Error, Equatable, Sendable, CustomStringConvertible {

    public var name: String

    public var message: String

    public init(name: String, message: String = "") {
        self.name = name
        self.message = message
    }

    public var description: String {
        message.isEmpty ? name : "\(name): \(message)"
    }

    /// The bus or BlueZ refused this process.
    public var isAccessDenied: Bool {
        name == "org.freedesktop.DBus.Error.AccessDenied" || name.hasSuffix(".NotAuthorized")
    }
}

/// What the bus reports, on the main loop.
public enum BlueZBusEvent {
    /// Connected: every object BlueZ manages (`GetManagedObjects`).
    case connected([String: BlueZInterfaces])
    /// There's no system bus, BlueZ isn't on it, or this process may not
    /// talk to it.
    case unavailable(BlueZError)
    case added(path: String, interfaces: BlueZInterfaces)
    case removed(path: String, interfaces: [String])
    case changed(path: String, interface: String, changed: [String: DBusMessageArgument], invalidated: [String])
}

/// The connection to BlueZ (`Plan.md` §6): the real system bus, or a fake
/// one in tests. Everything it reports arrives on the main loop.
public protocol BlueZBus: AnyObject {

    /// Connects, then reports the objects BlueZ manages and every change to
    /// them.
    func connect(_ handler: @escaping (BlueZBusEvent) -> Void)

    /// Calls a method of one of BlueZ's objects; the reply's values, or its
    /// error, arrive on the main loop.
    func call(
        _ path: String,
        _ interface: String,
        _ method: String,
        _ arguments: [DBusMessageArgument],
        signature: String?,
        reply: @escaping (Result<[DBusMessageArgument], BlueZError>) -> Void
    )
}

enum BlueZInterface {
    static let adapter = "org.bluez.Adapter1"
    static let device = "org.bluez.Device1"
    static let service = "org.bluez.GattService1"
    static let characteristic = "org.bluez.GattCharacteristic1"
    static let descriptor = "org.bluez.GattDescriptor1"
    static let objectManager = "org.freedesktop.DBus.ObjectManager"
    static let properties = "org.freedesktop.DBus.Properties"
}

// MARK: - Values

/// BlueZ's values; the rest are LinuxDBus's (`text`, `flag`, `entries`,
/// `vardict`).
public extension DBusMessageArgument {

    var intValue: Int? {
        int64Value.map(Int.init)
    }

    /// `ay`.
    var bytes: [UInt8]? {
        elements?.compactMap { if case .byte(let byte) = $0.contents { byte } else { nil } }
    }

    /// `as` or `ao`.
    var strings: [String] {
        elements?.compactMap(\.text) ?? []
    }

    /// `ay`.
    static func byteArray(_ bytes: [UInt8]) -> DBusMessageArgument {
        .list(of: .byte, bytes.map { .byte($0) })
    }

    /// `a{sa{sv}}` as interfaces and their properties.
    func interfaces() -> BlueZInterfaces {
        var interfaces: BlueZInterfaces = [:]
        for (name, properties) in pairs ?? [] {
            guard let name = name.text else { continue }
            interfaces[name] = properties.entries
        }
        return interfaces
    }
}
