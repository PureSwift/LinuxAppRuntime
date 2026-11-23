import DBus
import Foundation

/// One connection to a bus, a PureSwift/DBus `DBusConnection`, on Swift's
/// own threads: a writer task that starts requests in the order they were
/// made, and the connection's read loop, which answers them and hands
/// signals to `handler`.
///
/// It connects on the first request and, once closed, again on the next.
/// Callbacks run on Swift's threads; `Bus` posts them to the main loop.
final class BusLink: @unchecked Sendable {

    typealias Completion = @Sendable (Result<[DBusMessageArgument], BusError>) -> Void

    /// Work on the connection itself, such as exporting an object or
    /// emitting a signal, in order with the requests.
    typealias Action = @Sendable (DBusConnection) async -> Void

    enum Event: Sendable {
        /// Connected and said `Hello`; requests made while connecting are
        /// on their way.
        case connected
        case signal(BusSignal)
        /// The connection closed, or couldn't be made.
        case closed(BusError)
    }

    private struct Outgoing: Sendable {
        let message: DBusMessage?
        let completion: Completion
        var action: Action?

        /// A request to the bus itself (`AddMatch`, `RemoveMatch`): the
        /// next isn't started until it's answered, so a match rule is in
        /// place before what was asked after it.
        var isBarrier: Bool {
            message?.destination == DBusWellKnown.busName
        }
    }

    private enum Status {
        case idle
        case connecting
        case connected(AsyncStream<Outgoing>.Continuation)
    }

    private let connect: @Sendable () async throws -> DBusConnection

    /// Set once, before the first request.
    var handler: @Sendable (Event) -> Void = { _ in }

    private let lock = NSLock()

    private var status = Status.idle

    /// Requests made while connecting.
    private var waiting: [Outgoing] = []

    init(connect: @escaping @Sendable () async throws -> DBusConnection) {
        self.connect = connect
    }

    // MARK: Requests

    /// Sends `message`; `completion` gets its reply's values or its error,
    /// on Swift's threads.
    func send(_ message: DBusMessage, _ completion: @escaping Completion) {
        enqueue(Outgoing(message: message, completion: completion))
    }

    /// Runs `action` on the connection, connecting first if need be, after
    /// what was asked before it. Without a connection it's dropped.
    func perform(_ action: @escaping Action) {
        enqueue(Outgoing(message: nil, completion: { _ in }, action: action))
    }

    private func enqueue(_ item: Outgoing) {
        let completion = item.completion
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
            let connection: DBusConnection
            do {
                connection = try await self.connect()
            } catch {
                self.closed(.noServer(String(describing: error)))
                return
            }
            await self.run(connection)
        }
    }

    private func run(_ connection: DBusConnection) async {
        let handler = self.handler
        await connection.setMessageHandler { message in
            guard message.type == .signal, let path = message.path, let interface = message.interface,
                  let member = message.member else { return }
            handler(.signal(BusSignal(sender: message.sender?.rawValue, path: path.rawValue, interface: interface.rawValue,
                                      member: member.rawValue, body: message.arguments)))
        }
        // The connection says when it closes only by ending its streams of
        // signals: this one's, for a signal that never comes over the wire.
        let closing: AsyncStream<DBusMessage>
        do {
            closing = try await connection.signals(matching: DBusMatchRule(
                type: .signal, interface: DBusInterface(rawValue: Bus.local)!, member: DBusMember(rawValue: "Disconnected")!,
                path: DBusObjectPath(rawValue: Bus.localPath)!))
        } catch {
            await connection.close()
            closed(Self.error(error, connected: false))
            return
        }

        let (outgoing, continuation) = AsyncStream.makeStream(of: Outgoing.self)
        let writer = Task {
            for await item in outgoing {
                if let action = item.action {
                    await action(connection)
                } else if let message = item.message {
                    if item.isBarrier {
                        item.completion(await Self.send(message, on: connection))
                    } else {
                        await connection.begin(message, item.completion)
                    }
                }
            }
        }
        open(continuation)
        handler(.connected)

        for await _ in closing { }
        continuation.finish()
        await writer.value
        closed(.disconnected)
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

    private func closed(_ failure: BusError) {
        lock.lock()
        status = .idle
        let stranded = waiting
        waiting = []
        lock.unlock()
        for item in stranded {
            item.completion(.failure(failure))
        }
        handler(.closed(failure))
    }

    static func send(_ message: DBusMessage, on connection: DBusConnection) async -> Result<[DBusMessageArgument], BusError> {
        do {
            return .success(try await connection.send(message).arguments)
        } catch {
            return .failure(Self.error(error, connected: await connection.isConnected))
        }
    }

    /// A failed request's error: the one it was answered with, or
    /// `disconnected` if the connection closed under it.
    static func error(_ error: any Error, connected: Bool) -> BusError {
        if let error = error as? DBusError {
            return error.name == .disconnected ? .disconnected : BusError(name: error.name.rawValue, message: error.message)
        }
        return connected ? BusError(name: "org.freedesktop.DBus.Error.Failed", message: String(describing: error)) : .disconnected
    }
}

extension DBusConnection {

    /// Starts sending `message` on the connection's own executor, so
    /// requests begun in order are given serials, and written, in order;
    /// `completion` gets the reply.
    func begin(_ message: DBusMessage, _ completion: @escaping BusLink.Completion) {
        Task {
            // `send` is the connection's, so this doesn't leave its
            // executor before the message has its serial.
            do {
                completion(.success(try await self.send(message).arguments))
            } catch {
                completion(.failure(BusLink.error(error, connected: self.isConnected)))
            }
        }
    }
}
