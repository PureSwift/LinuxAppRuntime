import DBus
import Dispatch
import Foundation
import LinuxHost

/// A D-Bus bus, for the modules that talk to system services (`Plan.md`
/// §11): method calls, property reads and writes, and signals by match
/// rule; and objects this process serves, with the names it owns
/// (`BusObjects.swift`). Main loop only.
///
/// The connection, PureSwift/DBus's, lives on Swift's own threads; every
/// reply and signal is posted to the main loop. It's made on first use
/// and, if it closes, made again on the next, with the subscriptions' match
/// rules added again, and its objects served and its names asked for
/// again; subscribers to `MatchRule.disconnected` hear when it
/// closes. Requests are started in the order they're made, and one to the
/// bus itself, such as `AddMatch`, is answered before the next starts.
///
/// `system` and `session` are shared, so the process has one connection to
/// each, whichever modules use them.
public final class Bus {

    /// Which bus.
    public enum Kind: Sendable, Equatable {
        /// `DBUS_SYSTEM_BUS_ADDRESS`, or `/var/run/dbus/system_bus_socket`.
        case system
        /// `DBUS_SESSION_BUS_ADDRESS`, or `$XDG_RUNTIME_DIR/bus`.
        case session
        /// A D-Bus address, such as `unix:path=/run/dbus/test`.
        case address(String)
    }

    /// The system bus: BlueZ's, GeoClue's, iio-sensor-proxy's, neard's.
    nonisolated(unsafe) public static let system = Bus(.system)

    /// The session bus: the desktop portal's, and the shell's media
    /// controls'.
    nonisolated(unsafe) public static let session = Bus(.session)

    public let kind: Kind

    let loop: MainLoop

    let link: BusLink

    /// The objects this process serves, by path, and the names it asked
    /// for.
    var exports: [String: [BusInterface]] = [:]

    var names: Set<String> = []

    private var subscriptions: [UInt64: (rule: MatchRule, handler: (BusSignal) -> Void)] = [:]

    private var nextSubscription: UInt64 = 0

    /// The rules the bus has for this connection.
    private var matched: Set<MatchRule> = []

    public init(_ kind: Kind, loop: MainLoop = .shared) {
        self.kind = kind
        self.loop = loop
        self.link = BusLink(connect: {
            switch kind {
            case .system: try await DBusConnection.connect(to: .system)
            case .session: try await DBusConnection.connect(to: Self.sessionAddress)
            case .address(let address): try await DBusConnection.connect(to: address)
            }
        })
        link.handler = { [weak self, loop] event in
            loop.post { self?.handle(event) }
        }
    }

    /// `DBUS_SESSION_BUS_ADDRESS`, or `$XDG_RUNTIME_DIR/bus`, which
    /// PureSwift/DBus doesn't look for.
    static var sessionAddress: String {
        let environment = ProcessInfo.processInfo.environment
        if let address = environment["DBUS_SESSION_BUS_ADDRESS"] {
            return address
        }
        return environment["XDG_RUNTIME_DIR"].map { "unix:path=\($0)/bus" } ?? ""
    }

    // MARK: Methods

    /// Calls `method`; its reply's values, or its error, arrive on the main
    /// loop.
    public func call(
        _ destination: String,
        _ path: String,
        _ interface: String,
        _ method: String,
        _ arguments: [DBusMessageArgument] = [],
        signature: String? = nil,
        reply: @escaping (Result<[DBusMessageArgument], BusError>) -> Void
    ) {
        let loop = self.loop
        let message: DBusMessage
        switch Self.message(destination, path, interface, method, arguments, signature: signature) {
        case .success(let made):
            message = made
        case .failure(let error):
            loop.post { reply(.failure(error)) }
            return
        }
        link.send(message) { result in
            loop.post { reply(result) }
        }
    }

    /// Calls `method` and waits up to `timeout` seconds for the reply, for
    /// a contract that answers at once. The reply doesn't need the main
    /// loop, so the main thread can wait for it.
    public func callAndWait(
        _ destination: String,
        _ path: String,
        _ interface: String,
        _ method: String,
        _ arguments: [DBusMessageArgument] = [],
        signature: String? = nil,
        timeout: Double = 2
    ) -> Result<[DBusMessageArgument], BusError> {
        let message: DBusMessage
        switch Self.message(destination, path, interface, method, arguments, signature: signature) {
        case .success(let made):
            message = made
        case .failure(let error):
            return .failure(error)
        }
        let answer = Answer()
        link.send(message) { result in
            answer.set(result)
        }
        return answer.wait(timeout: timeout)
            ?? .failure(BusError(name: "org.freedesktop.DBus.Error.NoReply", message: "no reply in \(timeout) s"))
    }

    /// A method call; `signature`, if given, must be the arguments'.
    static func message(
        _ destination: String,
        _ path: String,
        _ interface: String,
        _ method: String,
        _ arguments: [DBusMessageArgument],
        signature: String?
    ) -> Result<DBusMessage, BusError> {
        guard let name = DBusBusName(rawValue: destination), let objectPath = DBusObjectPath(rawValue: path),
              let interfaceName = DBusInterface(rawValue: interface), let member = DBusMember(rawValue: method) else {
            return .failure(BusError(name: "org.freedesktop.DBus.Error.InvalidArgs",
                                     message: "not a method: \(destination) \(path) \(interface).\(method)"))
        }
        let actual = String(arguments.map(\.type))
        if let signature, signature != actual {
            return .failure(BusError(name: "org.freedesktop.DBus.Error.InvalidSignature",
                                     message: "arguments of signature \(actual), not \(signature)"))
        }
        let call = DBusMessage.MethodCall(destination: name, path: objectPath,
                                          interface: interfaceName, method: member)
        return .success(DBusMessage(methodCall: call, arguments: arguments))
    }

    private final class Answer: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private var result: Result<[DBusMessageArgument], BusError>?

        func set(_ result: Result<[DBusMessageArgument], BusError>) {
            self.result = result
            semaphore.signal()
        }

        func wait(timeout: Double) -> Result<[DBusMessageArgument], BusError>? {
            guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
            return result
        }
    }

    // MARK: Properties

    static let properties = "org.freedesktop.DBus.Properties"

    /// One property's value, its variant unwrapped (`Properties.Get`).
    public func property(
        _ destination: String,
        _ path: String,
        _ interface: String,
        _ name: String,
        reply: @escaping (Result<DBusMessageArgument, BusError>) -> Void
    ) {
        call(destination, path, Self.properties, "Get", [.string(interface), .string(name)]) { result in
            reply(result.flatMap(Self.single))
        }
    }

    /// One property's value, waiting up to `timeout` seconds.
    public func propertyAndWait(
        _ destination: String,
        _ path: String,
        _ interface: String,
        _ name: String,
        timeout: Double = 2
    ) -> Result<DBusMessageArgument, BusError> {
        callAndWait(destination, path, Self.properties, "Get", [.string(interface), .string(name)], timeout: timeout)
            .flatMap(Self.single)
    }

    /// Every property of `interface`, the variants unwrapped
    /// (`Properties.GetAll`).
    public func properties(
        _ destination: String,
        _ path: String,
        _ interface: String,
        reply: @escaping (Result<[String: DBusMessageArgument], BusError>) -> Void
    ) {
        call(destination, path, Self.properties, "GetAll", [.string(interface)]) { result in
            reply(result.map { $0.first?.entries ?? [:] })
        }
    }

    /// Sets a property (`Properties.Set`); `value` goes in a variant of its
    /// own type.
    public func setProperty(
        _ destination: String,
        _ path: String,
        _ interface: String,
        _ name: String,
        _ value: DBusMessageArgument,
        reply: @escaping (Result<Void, BusError>) -> Void = { _ in }
    ) {
        call(destination, path, Self.properties, "Set", [.string(interface), .string(name), .variant(.init(value))],
             signature: "ssv") { result in
            reply(result.map { _ in })
        }
    }

    private static func single(_ values: [DBusMessageArgument]) -> Result<DBusMessageArgument, BusError> {
        guard let value = values.first else {
            return .failure(BusError(name: "org.freedesktop.DBus.Error.InvalidSignature", message: "an empty reply"))
        }
        return .success(value.contents)
    }

    // MARK: Signals

    /// Calls `handler` on the main loop with each signal `rule` matches,
    /// until `unsubscribe`. The rule is added to the bus once, however many
    /// subscriptions share it.
    @discardableResult
    public func subscribe(_ rule: MatchRule, _ handler: @escaping (BusSignal) -> Void) -> BusSubscription {
        nextSubscription += 1
        subscriptions[nextSubscription] = (rule, handler)
        addMatch(rule)
        return BusSubscription(id: nextSubscription)
    }

    /// Stops a subscription; the last one of its rule removes the rule.
    public func unsubscribe(_ subscription: BusSubscription) {
        guard let rule = subscriptions.removeValue(forKey: subscription.id)?.rule else { return }
        guard !subscriptions.values.contains(where: { $0.rule == rule }), matched.remove(rule) != nil else { return }
        call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RemoveMatch", [.string(rule.description)]) { _ in }
    }

    /// `org.freedesktop.DBus.Local`, whose signals don't come over the wire.
    static let local = "org.freedesktop.DBus.Local"

    static let localPath = "/org/freedesktop/DBus/Local"

    private func addMatch(_ rule: MatchRule) {
        guard rule.interface != Self.local, matched.insert(rule).inserted else { return }
        call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch", [.string(rule.description)]) { [weak self] result in
            if case .failure(let error) = result {
                HostLog.error("dbus: can't add the match rule \(rule): \(error)")
                if error != .disconnected {
                    self?.matched.remove(rule)
                }
            }
        }
    }

    private func handle(_ event: BusLink.Event) {
        switch event {
        case .connected:
            for rule in Set(subscriptions.values.map(\.rule)) {
                addMatch(rule)
            }
            serveAgain()
        case .signal(let signal):
            deliver(signal)
        case .closed(let error):
            HostLog.debug("dbus: \(kind) bus closed: \(error)")
            matched = []
            deliver(BusSignal(path: Self.localPath, interface: Self.local, member: "Disconnected", body: [.string(error.description)]))
        }
    }

    private func deliver(_ signal: BusSignal) {
        for id in subscriptions.keys.sorted() {
            // A handler may unsubscribe others.
            guard let subscription = subscriptions[id], subscription.rule.matches(signal) else { continue }
            subscription.handler(signal)
        }
    }
}

/// A subscription to signals, for `Bus.unsubscribe`.
public struct BusSubscription: Hashable, Sendable {

    public let id: UInt64

    public init(id: UInt64) {
        self.id = id
    }
}
