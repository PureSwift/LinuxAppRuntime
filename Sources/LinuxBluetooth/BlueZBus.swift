import DBUS

/// An object's interfaces, each with its properties (variants unwrapped).
public typealias BlueZInterfaces = [String: [String: DBusValue]]

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
    case changed(path: String, interface: String, changed: [String: DBusValue], invalidated: [String])
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
        _ arguments: [DBusValue],
        signature: String?,
        reply: @escaping (Result<[DBusValue], BlueZError>) -> Void
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

public extension DBusValue {

    /// The value inside any variants.
    var unwrapped: DBusValue {
        if case .variant(let variant) = self { return variant.value.unwrapped }
        return self
    }

    var stringValue: String? {
        switch unwrapped {
        case .string(let string), .objectPath(let string): string
        default: nil
        }
    }

    var boolValue: Bool? {
        if case .boolean(let value) = unwrapped { return value }
        return nil
    }

    var intValue: Int? {
        switch unwrapped {
        case .byte(let value): Int(value)
        case .int16(let value): Int(value)
        case .uint16(let value): Int(value)
        case .int32(let value): Int(value)
        case .uint32(let value): Int(value)
        case .int64(let value): Int(value)
        case .uint64(let value): Int(value)
        default: nil
        }
    }

    /// `ay`.
    var bytes: [UInt8]? {
        guard case .array(let elements) = unwrapped else { return nil }
        return elements.compactMap { if case .byte(let byte) = $0.unwrapped { byte } else { nil } }
    }

    /// `as` or `ao`.
    var strings: [String] {
        guard case .array(let elements) = unwrapped else { return [] }
        return elements.compactMap(\.stringValue)
    }

    static func byteArray(_ bytes: [UInt8]) -> DBusValue {
        .array(bytes.map { .byte($0) })
    }

    /// `a{sv}`.
    static func options(_ entries: [String: DBusValue]) -> DBusValue {
        var dictionary: [DBusValue: DBusValue] = [:]
        for (key, value) in entries {
            dictionary[.string(key)] = .variant(DBusVariant(value))
        }
        return .dictionary(dictionary)
    }

    /// `a{sa{sv}}` as interfaces and their properties.
    func interfaces() -> BlueZInterfaces {
        guard case .dictionary(let entries) = unwrapped else { return [:] }
        var interfaces: BlueZInterfaces = [:]
        for (name, properties) in entries {
            guard let name = name.stringValue else { continue }
            interfaces[name] = properties.properties()
        }
        return interfaces
    }

    /// `a{sv}`, the variants unwrapped.
    func properties() -> [String: DBusValue] {
        guard case .dictionary(let entries) = unwrapped else { return [:] }
        var properties: [String: DBusValue] = [:]
        for (name, value) in entries {
            guard let name = name.stringValue else { continue }
            properties[name] = value.unwrapped
        }
        return properties
    }
}
