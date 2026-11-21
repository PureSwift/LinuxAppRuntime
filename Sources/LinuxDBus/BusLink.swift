import DBUS
import Foundation
import LinuxHost
import Logging

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// One connection to a bus, on D-Bus's own threads (SwiftNIO's): a writer
/// task that sends requests in the order they were made, and a read loop
/// that hands replies to their callers and signals to `handler`.
///
/// It connects on the first request and, once closed, again on the next.
/// Callbacks run on D-Bus's threads; `Bus` posts them to the main loop.
final class BusLink: @unchecked Sendable {

    typealias Completion = @Sendable (Result<DBusMessage, BusError>) -> Void

    enum Event: Sendable {
        /// Said `Hello`; requests made while connecting are on their way.
        case connected
        case signal(BusSignal)
        /// The connection closed, or couldn't be made.
        case closed(BusError)
    }

    private struct Outgoing: @unchecked Sendable {
        let request: DBusRequest
        let completion: Completion
    }

    private enum Status {
        case idle
        case connecting
        case connected(AsyncStream<Outgoing>.Continuation)
    }

    private let address: @Sendable () throws -> DBusAddress

    /// Set once, before the first request.
    var handler: @Sendable (Event) -> Void = { _ in }

    private let lock = NSLock()

    private var status = Status.idle

    /// Requests made while connecting.
    private var waiting: [Outgoing] = []

    /// Callers waiting for replies, by the request's serial.
    private var pending: [UInt32: Completion] = [:]

    /// Replies that came before their caller was waiting.
    private var early: [UInt32: DBusMessage] = [:]

    init(address: @escaping @Sendable () throws -> DBusAddress) {
        self.address = address
    }

    private static let logger: Logger = {
        var logger = Logger(label: "linux-app-host.dbus")
        logger.logLevel = HostLog.verbose ? .debug : .critical
        return logger
    }()

    // MARK: Requests

    /// Sends `request`; `completion` gets its reply or error, on D-Bus's
    /// threads.
    func send(_ request: DBusRequest, _ completion: @escaping Completion) {
        let item = Outgoing(request: request, completion: completion)
        lock.lock()
        switch status {
        case .connected(let outgoing):
            let result = outgoing.yield(item)
            lock.unlock()
            if case .terminated = result {
                completion(.failure(.disconnected))
            }
        case .connecting:
            waiting.append(item)
            lock.unlock()
        case .idle:
            status = .connecting
            waiting.append(item)
            lock.unlock()
            start()
        }
    }

    // MARK: The connection

    private func start() {
        Task.detached { [self] in
            let connected = ConnectedFlag()
            var failure = BusError.disconnected
            do {
                let address = try self.address()
                try await DBusClient.withConnectionPair(to: address, auth: .external(userID: String(getuid())), logger: Self.logger) { replies, send in
                    try await self.run(&replies, send, connected: connected)
                }
            } catch let error as BusError {
                failure = error
            } catch {
                failure = connected.value ? .disconnected : .noServer(String(describing: error))
            }
            self.closed(failure)
        }
    }

    private final class ConnectedFlag: @unchecked Sendable {
        var value = false
    }

    private func run(_ replies: inout DBusClient.Replies, _ send: DBusClient.Send, connected: ConnectedFlag) async throws {
        let (outgoing, continuation) = AsyncStream.makeStream(of: Outgoing.self)
        let writer = Task {
            for await item in outgoing {
                do {
                    let serial = try await send.send(item.request)
                    self.expect(serial, item.completion)
                } catch {
                    item.completion(.failure(BusError(name: "org.freedesktop.DBus.Error.Failed", message: String(describing: error))))
                }
            }
        }
        defer {
            continuation.finish()
            writer.cancel()
        }
        // `Hello` first, then what was asked for while connecting, in order.
        continuation.yield(Outgoing(request: .createMethodCall(
            destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
            interface: "org.freedesktop.DBus", method: "Hello"), completion: { _ in }))
        open(continuation)
        connected.value = true
        handler(.connected)

        while let message = try await replies.next() {
            receive(message)
        }
    }

    /// Sends what waited, and from now on sends at once.
    private func open(_ continuation: AsyncStream<Outgoing>.Continuation) {
        lock.lock()
        status = .connected(continuation)
        for item in waiting {
            continuation.yield(item)
        }
        waiting = []
        lock.unlock()
    }

    private func expect(_ serial: UInt32, _ completion: @escaping Completion) {
        lock.lock()
        if let message = early.removeValue(forKey: serial) {
            lock.unlock()
            completion(Self.result(message))
        } else {
            pending[serial] = completion
            lock.unlock()
        }
    }

    private func receive(_ message: DBusMessage) {
        if let serial = message.replyTo {
            lock.lock()
            if let completion = pending.removeValue(forKey: serial) {
                lock.unlock()
                completion(Self.result(message))
            } else {
                early[serial] = message
                lock.unlock()
            }
        } else if case .signal = message.messageType, let path = message.path,
                  let interface = message.interface, let member = message.member {
            handler(.signal(BusSignal(sender: message.sender, path: path, interface: interface, member: member, body: message.body)))
        }
    }

    private func closed(_ failure: BusError) {
        lock.lock()
        status = .idle
        let stranded = Array(pending.values)
        let unsent = waiting
        pending = [:]
        early = [:]
        waiting = []
        lock.unlock()
        for completion in stranded {
            completion(.failure(.disconnected))
        }
        for item in unsent {
            item.completion(.failure(failure))
        }
        handler(.closed(failure))
    }

    /// A reply's values, or its error.
    static func result(_ message: DBusMessage) -> Result<DBusMessage, BusError> {
        guard case .error = message.messageType else {
            return .success(message)
        }
        let name = message.headerFields.first { $0.code == .errorName }.flatMap { $0.variant.value.text }
        return .failure(BusError(name: name ?? "org.freedesktop.DBus.Error.Failed", message: message.body.first?.text ?? ""))
    }
}
