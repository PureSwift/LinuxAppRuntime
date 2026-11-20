import DBUS
import Dispatch
import Foundation
import LinuxHost

/// A D-Bus bus, for the modules that talk to system services (`Plan.md`
/// §11): method calls, property reads and writes, and signals by match
/// rule. Main loop only.
///
/// The connection lives on D-Bus's own threads; every reply and signal is
/// posted to the main loop. It's made on first use and, if it closes, made
/// again on the next, with the subscriptions' match rules added again.
/// Requests are sent in the order they're made.
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

    /// The session bus: the desktop portal's.
    nonisolated(unsafe) public static let session = Bus(.session)

    public let kind: Kind

    private let loop: MainLoop

    private let link: BusLink

    private var subscriptions: [UInt64: (rule: MatchRule, handler: (BusSignal) -> Void)] = [:]

    private var nextSubscription: UInt64 = 0

    /// The rules the bus has for this connection.
    private var matched: Set<MatchRule> = []

    public init(_ kind: Kind, loop: MainLoop = .shared) {
        self.kind = kind
        self.loop = loop
        self.link = BusLink(address: {
            switch kind {
            case .system: try DBusAddress.systemBusAddress()
            case .session: try DBusAddress.sessionBusAddress()
            case .address(let address): try DBusAddress.parse(address)
            }
        })
        link.handler = { [weak self, loop] event in
            loop.post { self?.handle(event) }
        }
    }

    // MARK: Methods

    /// Calls `method`; its reply's values, or its error, arrive on the main
    /// loop.
    public func call(
        _ destination: String,
        _ path: String,
        _ interface: String,
        _ method: String,
        _ arguments: [DBusValue] = [],
        signature: String? = nil,
        reply: @escaping (Result<[DBusValue], BusError>) -> Void
    ) {
        let loop = self.loop
        link.send(.createMethodCall(destination: destination, path: path, interface: interface, method: method,
                                    body: arguments, signature: signature)) { result in
            loop.post { reply(result.map(\.body)) }
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
        _ arguments: [DBusValue] = [],
        signature: String? = nil,
        timeout: Double = 2
    ) -> Result<[DBusValue], BusError> {
        let answer = Answer()
        link.send(.createMethodCall(destination: destination, path: path, interface: interface, method: method,
                                    body: arguments, signature: signature)) { result in
            answer.set(result.map(\.body))
        }
        return answer.wait(timeout: timeout)
            ?? .failure(BusError(name: "org.freedesktop.DBus.Error.NoReply", message: "no reply in \(timeout) s"))
    }

    private final class Answer: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private var result: Result<[DBusValue], BusError>?

        func set(_ result: Result<[DBusValue], BusError>) {
            self.result = result
            semaphore.signal()
        }

        func wait(timeout: Double) -> Result<[DBusValue], BusError>? {
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
        reply: @escaping (Result<DBusValue, BusError>) -> Void
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
    ) -> Result<DBusValue, BusError> {
        callAndWait(destination, path, Self.properties, "Get", [.string(interface), .string(name)], timeout: timeout)
            .flatMap(Self.single)
    }

    /// Every property of `interface`, the variants unwrapped
    /// (`Properties.GetAll`).
    public func properties(
        _ destination: String,
        _ path: String,
        _ interface: String,
        reply: @escaping (Result<[String: DBusValue], BusError>) -> Void
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
        _ value: DBusValue,
        reply: @escaping (Result<Void, BusError>) -> Void = { _ in }
    ) {
        call(destination, path, Self.properties, "Set", [.string(interface), .string(name), .variant(DBusVariant(value))],
             signature: "ssv") { result in
            reply(result.map { _ in })
        }
    }

    private static func single(_ values: [DBusValue]) -> Result<DBusValue, BusError> {
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

    private func addMatch(_ rule: MatchRule) {
        guard matched.insert(rule).inserted else { return }
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
        case .signal(let signal):
            for id in subscriptions.keys.sorted() {
                // A handler may unsubscribe others.
                guard let subscription = subscriptions[id], subscription.rule.matches(signal) else { continue }
                subscription.handler(signal)
            }
        case .closed(let error):
            HostLog.debug("dbus: \(kind) bus closed: \(error)")
            matched = []
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
