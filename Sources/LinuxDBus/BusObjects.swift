import DBus
import LinuxHost

/// An interface of an object this process serves on a bus: its methods and
/// properties, answered on the main loop.
public struct BusInterface {

    public var name: String

    public var methods: [BusMethod]

    public var properties: [BusProperty]

    public init(_ name: String, methods: [BusMethod] = [], properties: [BusProperty] = []) {
        self.name = name
        self.methods = methods
        self.properties = properties
    }
}

/// A method of a served interface. `handler` runs on the main loop with
/// the call's arguments, which the bus has checked against `input`; it
/// gives the reply's values, of signature `output`, or an error.
public struct BusMethod {

    public var name: String

    public var input: String

    public var output: String

    public var handler: ([DBusMessageArgument]) -> Result<[DBusMessageArgument], BusError>

    public init(_ name: String, input: String = "", output: String = "",
                _ handler: @escaping ([DBusMessageArgument]) -> Result<[DBusMessageArgument], BusError>) {
        self.name = name
        self.input = input
        self.output = output
        self.handler = handler
    }
}

/// A property of a served interface, read on the main loop each time it's
/// asked for; writable when it has `set`.
public struct BusProperty {

    public var name: String

    /// Its value's signature, such as `s` or `a{sv}`.
    public var type: String

    public var get: () -> DBusMessageArgument

    public var set: ((DBusMessageArgument) -> Result<Void, BusError>)?

    public init(_ name: String, _ type: String, get: @escaping () -> DBusMessageArgument,
                set: ((DBusMessageArgument) -> Result<Void, BusError>)? = nil) {
        self.name = name
        self.type = type
        self.get = get
        self.set = set
    }
}

// MARK: Serving

extension Bus {

    /// Serves an object at `path`, in place of any there: calls to its
    /// methods and reads of its properties go to the main loop, and the
    /// bus answers `Introspectable`, `Peer` and `Properties` for it. It's
    /// served again on a new connection.
    public func export(_ path: String, _ interfaces: [BusInterface]) {
        guard let objectPath = DBusObjectPath(rawValue: path) else {
            HostLog.error("dbus: not an object path: \(path)")
            return
        }
        exports[path] = interfaces
        let object = Self.object(interfaces, loop: loop)
        link.perform { connection in
            await connection.export(object, at: objectPath)
        }
    }

    /// Stops serving the object at `path`.
    public func unexport(_ path: String) {
        guard exports.removeValue(forKey: path) != nil, let objectPath = DBusObjectPath(rawValue: path) else { return }
        link.perform { connection in
            _ = await connection.unexport(at: objectPath)
        }
    }

    /// Asks for a well-known name, without queueing for it: `reply` says
    /// whether this connection owns it. It's asked for again on a new
    /// connection, until `releaseName`.
    public func requestName(_ name: String, reply: @escaping (Result<Bool, BusError>) -> Void = { _ in }) {
        names.insert(name)
        ask(for: name, reply: reply)
    }

    /// Gives up a name `requestName` asked for; `reply` says when the bus
    /// has.
    public func releaseName(_ name: String, reply: @escaping (Result<Void, BusError>) -> Void = { _ in }) {
        guard names.remove(name) != nil else {
            loop.post { reply(.success(())) }
            return
        }
        call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ReleaseName", [.string(name)]) { result in
            reply(result.map { _ in })
        }
    }

    /// Emits a signal from an object this process serves.
    public func emit(_ path: String, _ interface: String, _ member: String, _ arguments: [DBusMessageArgument] = []) {
        guard let objectPath = DBusObjectPath(rawValue: path), let interfaceName = DBusInterface(rawValue: interface),
              let memberName = DBusMember(rawValue: member) else {
            HostLog.error("dbus: not a signal: \(path) \(interface).\(member)")
            return
        }
        let signal = DBusMessage.Signal(path: objectPath, interface: interfaceName, name: memberName)
        link.perform { connection in
            do {
                try await connection.emit(signal, arguments: arguments)
            } catch {
                HostLog.debug("dbus: couldn't emit \(interface).\(member): \(error)")
            }
        }
    }

    /// Emits `Properties.PropertiesChanged` with properties' new values.
    public func emitPropertiesChanged(_ path: String, _ interface: String, _ changed: [String: DBusMessageArgument]) {
        guard !changed.isEmpty, let objectPath = DBusObjectPath(rawValue: path),
              let interfaceName = DBusInterface(rawValue: interface) else { return }
        link.perform { connection in
            do {
                try await connection.emitPropertiesChanged(at: objectPath, interface: interfaceName, changed: changed)
            } catch {
                HostLog.debug("dbus: couldn't emit PropertiesChanged: \(error)")
            }
        }
    }

    /// What this connection served and owned, on a new connection.
    func serveAgain() {
        for (path, interfaces) in exports {
            export(path, interfaces)
        }
        for name in names {
            ask(for: name) { _ in }
        }
    }

    private func ask(for name: String, reply: @escaping (Result<Bool, BusError>) -> Void) {
        // DBUS_NAME_FLAG_DO_NOT_QUEUE; 1 is the primary owner, 4 already
        // the owner.
        call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
             [.string(name), .uint32(4)]) { result in
            reply(result.map { $0.first == .uint32(1) || $0.first == .uint32(4) })
        }
    }

    // MARK: PureSwift/DBus's objects

    /// The main loop's closures, for the connection's threads, which only
    /// post them back to the main loop.
    private final class Handlers: @unchecked Sendable {
        let interfaces: [BusInterface]
        init(_ interfaces: [BusInterface]) { self.interfaces = interfaces }
    }

    static func object(_ interfaces: [BusInterface], loop: MainLoop) -> DBusExportedObject {
        let handlers = Handlers(interfaces)
        var object = DBusExportedObject()
        for (interfaceIndex, interface) in interfaces.enumerated() {
            guard let name = DBusInterface(rawValue: interface.name) else { continue }
            var methods: [DBusInterfaceImplementation.Method] = []
            for (index, method) in interface.methods.enumerated() {
                guard let member = DBusMember(rawValue: method.name), let input = DBusSignature(rawValue: method.input),
                      let output = DBusSignature(rawValue: method.output) else { continue }
                let handler: @Sendable (DBusMethodCall) async throws -> [DBusMessageArgument] = { call in
                    let arguments = call.arguments
                    let result: Result<[DBusMessageArgument], BusError> = await onLoop(loop) {
                        handlers.interfaces[interfaceIndex].methods[index].handler(arguments)
                    }
                    return try result.mapError(Self.dbusError).get()
                }
                methods.append(DBusInterfaceImplementation.Method(name: member, inputSignature: input, outputSignature: output,
                                                                  handler: handler))
            }
            var properties: [DBusInterfaceImplementation.Property] = []
            for (index, property) in interface.properties.enumerated() {
                guard let type = DBusSignature(rawValue: property.type)?.first else { continue }
                let get: @Sendable () async throws -> DBusMessageArgument = {
                    await onLoop(loop) { handlers.interfaces[interfaceIndex].properties[index].get() }
                }
                var set: (@Sendable (DBusMessageArgument) async throws -> Void)?
                if property.set != nil {
                    set = { value in
                        let result: Result<Void, BusError> = await onLoop(loop) {
                            handlers.interfaces[interfaceIndex].properties[index].set?(value) ?? .success(())
                        }
                        try result.mapError(Self.dbusError).get()
                    }
                }
                properties.append(DBusInterfaceImplementation.Property(name: property.name, type: type,
                                                                       access: set == nil ? .read : .readwrite, get: get, set: set))
            }
            object.add(DBusInterfaceImplementation(name: name, methods: methods, properties: properties))
        }
        return object
    }

    /// A handler's error, as PureSwift/DBus replies with it.
    private static func dbusError(_ error: BusError) -> DBusError {
        let failed = DBusError.Name(rawValue: "org.freedesktop.DBus.Error.Failed")!
        return DBusError(name: DBusError.Name(rawValue: error.name) ?? failed, message: error.message)
    }

    /// Runs `body` on the main loop, and waits for what it gives.
    private static func onLoop<T: Sendable>(_ loop: MainLoop, _ body: @escaping () -> T) async -> T {
        let box = Box(body)
        return await withCheckedContinuation { continuation in
            loop.post { continuation.resume(returning: box.body()) }
        }
    }

    private final class Box<T>: @unchecked Sendable {
        let body: () -> T
        init(_ body: @escaping () -> T) { self.body = body }
    }
}
