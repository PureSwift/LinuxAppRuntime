import DBus

/// An error a service, or the bus, answered with: a D-Bus error name and
/// its message.
public struct BusError: Error, Equatable, Sendable, CustomStringConvertible {

    public var name: String

    public var message: String

    public init(name: String, message: String = "") {
        self.name = name
        self.message = message
    }

    public var description: String {
        message.isEmpty ? name : "\(name): \(message)"
    }

    /// There's no bus to connect to.
    public static func noServer(_ message: String) -> BusError {
        BusError(name: "org.freedesktop.DBus.Error.NoServer", message: message)
    }

    /// The connection closed before the reply came.
    public static let disconnected = BusError(name: "org.freedesktop.DBus.Error.Disconnected", message: "the bus closed")

    /// The bus or the service refused this process.
    public var isAccessDenied: Bool {
        name == "org.freedesktop.DBus.Error.AccessDenied" || name.hasSuffix(".NotAuthorized")
    }

    /// The service isn't on the bus and can't be started, or there's no bus.
    public var isServiceMissing: Bool {
        [
            "org.freedesktop.DBus.Error.ServiceUnknown",
            "org.freedesktop.DBus.Error.NameHasNoOwner",
            "org.freedesktop.DBus.Error.NoServer",
            "org.freedesktop.DBus.Error.Disconnected",
        ].contains(name) || name.hasPrefix("org.freedesktop.DBus.Error.Spawn.")
    }

    /// The object has no such method or property: an older service.
    public var isUnknownMember: Bool {
        [
            "org.freedesktop.DBus.Error.UnknownMethod",
            "org.freedesktop.DBus.Error.UnknownProperty",
            "org.freedesktop.DBus.Error.UnknownInterface",
            "org.freedesktop.DBus.Error.InvalidArgs",
        ].contains(name)
    }
}

/// Which signals to receive: a D-Bus match rule (`type='signal'`).
///
/// The bus filters by every field. This side tells signals apart again by
/// path, interface, member and `arg0`; a well-known `sender` is left to the
/// bus, since signals carry the sender's unique name.
public struct MatchRule: Hashable, Sendable, CustomStringConvertible {

    public var sender: String?

    public var path: String?

    public var interface: String?

    public var member: String?

    /// The first argument, when it's a string: a name, for
    /// `NameOwnerChanged`.
    public var arg0: String?

    public init(sender: String? = nil, path: String? = nil, interface: String? = nil, member: String? = nil, arg0: String? = nil) {
        self.sender = sender
        self.path = path
        self.interface = interface
        self.member = member
        self.arg0 = arg0
    }

    /// The bus's own `Disconnected` signal, which its subscribers get when
    /// its connection closes, or can't be made, with why as its argument.
    /// It's local: the bus isn't asked for it.
    public static let disconnected = MatchRule(path: "/org/freedesktop/DBus/Local", interface: "org.freedesktop.DBus.Local",
                                               member: "Disconnected")

    /// The rule as `AddMatch` takes it.
    public var description: String {
        var parts = ["type='signal'"]
        for (key, value) in [("sender", sender), ("path", path), ("interface", interface), ("member", member), ("arg0", arg0)] {
            if let value {
                parts.append("\(key)='\(Self.escape(value))'")
            }
        }
        return parts.joined(separator: ",")
    }

    /// Whether a signal the bus delivered is one of this rule's.
    public func matches(_ signal: BusSignal) -> Bool {
        if let path, path != signal.path { return false }
        if let interface, interface != signal.interface { return false }
        if let member, member != signal.member { return false }
        if let sender, sender.hasPrefix(":"), sender != signal.sender { return false }
        if let arg0, arg0 != signal.body.first?.text { return false }
        return true
    }

    /// A quote inside a value ends it, and is written `'\''`.
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }
}

/// A signal the bus delivered.
public struct BusSignal: Sendable, Equatable {

    /// The sender's unique name (`:1.42`).
    public var sender: String?

    public var path: String

    public var interface: String

    public var member: String

    public var body: [DBusMessageArgument]

    public init(sender: String? = nil, path: String, interface: String, member: String, body: [DBusMessageArgument] = []) {
        self.sender = sender
        self.path = path
        self.interface = interface
        self.member = member
        self.body = body
    }
}

// MARK: - Values

/// Reading values out of replies, and making the ones requests need.
public extension DBusMessageArgument {

    /// The value inside any variants.
    var contents: DBusMessageArgument {
        if case .variant(let variant) = self { return variant.element.contents }
        return self
    }

    /// A string or an object path.
    var text: String? {
        switch contents {
        case .string(let string): string
        case .objectPath(let path): path.rawValue
        default: nil
        }
    }

    var flag: Bool? {
        if case .boolean(let value) = contents { return value }
        return nil
    }

    /// A double, or any integer as one.
    var doubleValue: Double? {
        if case .double(let value) = contents { return value }
        return int64Value.map(Double.init)
    }

    /// Any integer that fits.
    var int64Value: Int64? {
        switch contents {
        case .byte(let value): Int64(value)
        case .int16(let value): Int64(value)
        case .uint16(let value): Int64(value)
        case .int32(let value): Int64(value)
        case .uint32(let value): Int64(value)
        case .int64(let value): value
        case .uint64(let value): Int64(exactly: value)
        default: nil
        }
    }

    /// A struct's fields.
    var fields: [DBusMessageArgument]? {
        if case .struct(let structure) = contents { return Swift.Array(structure) }
        return nil
    }

    /// An array's elements.
    var elements: [DBusMessageArgument]? {
        if case .array(let array) = contents { return Swift.Array(array) }
        return nil
    }

    /// A dictionary's entries, in the order they came.
    var pairs: [(key: DBusMessageArgument, value: DBusMessageArgument)]? {
        if case .dictionary(let dictionary) = contents { return dictionary.map { ($0.key, $0.value) } }
        return nil
    }

    /// `a{sv}` with string keys, the variants unwrapped.
    var entries: [String: DBusMessageArgument] {
        var entries: [String: DBusMessageArgument] = [:]
        for (key, value) in pairs ?? [] {
            guard let key = key.text else { continue }
            entries[key] = value.contents
        }
        return entries
    }

    /// `a{sv}`, its keys in order.
    static func vardict(_ entries: [String: DBusMessageArgument]) -> DBusMessageArgument {
        let entries = entries.sorted { $0.key < $1.key }.map { key, value in
            Dictionary.Entry(key: .string(key), value: .variant(Variant(value)))
        }
        return .dictionary(Dictionary(keyType: .string, valueType: .variant, entries)!)
    }

    /// An object path, which must be a valid one.
    static func path(_ path: String) -> DBusMessageArgument {
        guard let path = DBusObjectPath(rawValue: path) else {
            preconditionFailure("not an object path: \(path)")
        }
        return .objectPath(path)
    }

    /// An array of `type`, which each element must be.
    static func list(of type: DBusSignature.ValueType, _ elements: [DBusMessageArgument]) -> DBusMessageArgument {
        guard let array = Array(type: type, elements) else {
            preconditionFailure("not all \(String(type)): \(elements)")
        }
        return .array(array)
    }

    /// `as`.
    static func stringArray(_ strings: [String]) -> DBusMessageArgument {
        list(of: .string, strings.map { .string($0) })
    }

    /// A struct, of at least one field.
    static func structure(_ fields: [DBusMessageArgument]) -> DBusMessageArgument {
        guard let structure = Structure(fields) else {
            preconditionFailure("a struct without fields")
        }
        return .struct(structure)
    }
}
