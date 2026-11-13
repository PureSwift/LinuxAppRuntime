import DBUS
import Foundation
import LinuxHost
import Logging

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// BlueZ on the system bus (`DBUS_SYSTEM_BUS_ADDRESS`, or
/// `/var/run/dbus/system_bus_socket`), through `wendylabsinc/dbus`.
///
/// The connection lives on D-Bus's own threads for the life of the
/// process; everything it reports is posted to the main loop.
public final class SystemBus: BlueZBus {

    private let loop: MainLoop

    private let state = State()

    public init(loop: MainLoop = .shared) {
        self.loop = loop
    }

    /// The connection, once there is one; shared with D-Bus's threads.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var connection: DBusClient.Connection?

        func set(_ connection: DBusClient.Connection?) {
            lock.lock()
            self.connection = connection
            lock.unlock()
        }

        func get() -> DBusClient.Connection? {
            lock.lock()
            defer { lock.unlock() }
            return connection
        }
    }

    private static let logger: Logger = {
        var logger = Logger(label: "linux-app-host.bluez")
        logger.logLevel = HostLog.verbose ? .debug : .critical
        return logger
    }()

    public func connect(_ handler: @escaping (BlueZBusEvent) -> Void) {
        let loop = self.loop
        let state = self.state
        let post: @Sendable (BlueZBusEvent) -> Void = { event in
            loop.post { handler(event) }
        }
        Task.detached {
            do {
                try await DBusClient.withSystemBus(auth: .external(userID: String(getuid())), logger: Self.logger) { connection in
                    try await Self.run(connection, state: state, post: post)
                }
                post(.unavailable(BlueZError(name: "org.freedesktop.DBus.Error.Disconnected", message: "the system bus closed")))
            } catch let error as BlueZError {
                post(.unavailable(error))
            } catch {
                post(.unavailable(BlueZError(name: "org.freedesktop.DBus.Error.NoServer", message: String(describing: error))))
            }
            state.set(nil)
        }
    }

    private static func run(
        _ connection: DBusClient.Connection,
        state: State,
        post: @escaping @Sendable (BlueZBusEvent) -> Void
    ) async throws {
        // Signals from BlueZ only; subscribing before reading the objects
        // misses none.
        for rule in [
            "type='signal',sender='org.bluez',interface='\(BlueZInterface.objectManager)'",
            "type='signal',sender='org.bluez',interface='\(BlueZInterface.properties)',member='PropertiesChanged'",
        ] {
            _ = try await connection.send(.createMethodCall(
                destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
                interface: "org.freedesktop.DBus", method: "AddMatch", body: [.string(rule)]))
        }
        let added = await connection.subscribeToSignal(interface: BlueZInterface.objectManager, member: "InterfacesAdded")
        let removed = await connection.subscribeToSignal(interface: BlueZInterface.objectManager, member: "InterfacesRemoved")
        let changed = await connection.subscribeToSignal(interface: BlueZInterface.properties, member: "PropertiesChanged")

        let reply = try await send(connection, path: "/", interface: BlueZInterface.objectManager, method: "GetManagedObjects")
        var objects: [String: BlueZInterfaces] = [:]
        if case .dictionary(let managed)? = reply.first {
            for (path, interfaces) in managed {
                guard let path = path.stringValue else { continue }
                objects[path] = interfaces.interfaces()
            }
        }
        state.set(connection)
        post(.connected(objects))

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await message in added where message.body.count >= 2 {
                    guard let path = message.body[0].stringValue else { continue }
                    post(.added(path: path, interfaces: message.body[1].interfaces()))
                }
            }
            group.addTask {
                for await message in removed where message.body.count >= 2 {
                    guard let path = message.body[0].stringValue else { continue }
                    post(.removed(path: path, interfaces: message.body[1].strings))
                }
            }
            group.addTask {
                for await message in changed where message.body.count >= 2 {
                    guard let path = message.path, let interface = message.body[0].stringValue,
                          interface.hasPrefix("org.bluez.") else { continue }
                    let invalidated = message.body.count >= 3 ? message.body[2].strings : []
                    post(.changed(path: path, interface: interface, changed: message.body[1].properties(), invalidated: invalidated))
                }
            }
            try await group.next()
        }
    }

    private static func send(
        _ connection: DBusClient.Connection,
        path: String,
        interface: String,
        method: String,
        body: [DBusValue] = [],
        signature: String? = nil
    ) async throws -> [DBusValue] {
        let request = DBusRequest.createMethodCall(destination: "org.bluez", path: path, interface: interface,
                                                   method: method, body: body, signature: signature)
        guard let reply = try await connection.send(request) else { return [] }
        if case .error = reply.messageType {
            let name = reply.headerFields.first { $0.code == .errorName }.flatMap { $0.variant.value.stringValue }
            throw BlueZError(name: name ?? "org.bluez.Error.Failed", message: reply.body.first?.stringValue ?? "")
        }
        return reply.body
    }

    public func call(
        _ path: String,
        _ interface: String,
        _ method: String,
        _ arguments: [DBusValue],
        signature: String?,
        reply: @escaping (Result<[DBusValue], BlueZError>) -> Void
    ) {
        let loop = self.loop
        guard let connection = state.get() else {
            loop.post { reply(.failure(BlueZError(name: "org.freedesktop.DBus.Error.ServiceUnknown", message: "BlueZ isn't connected"))) }
            return
        }
        Task.detached {
            let result: Result<[DBusValue], BlueZError>
            do {
                result = .success(try await Self.send(connection, path: path, interface: interface, method: method,
                                                      body: arguments, signature: signature))
            } catch let error as BlueZError {
                result = .failure(error)
            } catch {
                result = .failure(BlueZError(name: "org.freedesktop.DBus.Error.Failed", message: String(describing: error)))
            }
            loop.post { reply(result) }
        }
    }
}
