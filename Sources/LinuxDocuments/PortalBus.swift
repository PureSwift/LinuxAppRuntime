import DBus
import LinuxDBus

/// The desktop portal on the session bus, as the file chooser needs it;
/// replaceable for tests. Everything is answered on the main loop.
public protocol PortalBus: AnyObject {

    /// Calls a method of the portal's object.
    func call(_ interface: String, _ method: String, _ arguments: [DBusMessageArgument], signature: String,
              reply: @escaping (Result<[DBusMessageArgument], BusError>) -> Void)

    /// One property of the portal's object.
    func property(_ interface: String, _ name: String, reply: @escaping (Result<DBusMessageArgument, BusError>) -> Void)

    /// Calls `handler` with each request's `Response`: the request's path
    /// and the signal's arguments.
    func subscribeToResponses(_ handler: @escaping (_ path: String, _ arguments: [DBusMessageArgument]) -> Void) -> BusSubscription

    /// Calls `handler` when the bus closes, or can't be reached.
    func subscribeToDisconnect(_ handler: @escaping () -> Void) -> BusSubscription
}

/// The portal's names and values (xdg-desktop-portal's
/// `org.freedesktop.portal.FileChooser`).
public enum Portal {

    public static let service = "org.freedesktop.portal.Desktop"

    public static let path = "/org/freedesktop/portal/desktop"

    public static let fileChooser = "org.freedesktop.portal.FileChooser"

    public static let request = "org.freedesktop.portal.Request"

    /// A request's `Response` codes.
    public enum Response: UInt32 {
        case success = 0
        case cancelled = 1
        case ended = 2
    }

    /// Filter patterns: a glob, or a MIME type.
    public enum Pattern: UInt32 {
        case glob = 0
        case mimeType = 1
    }
}

/// The portal on the session bus.
public final class SessionPortal: PortalBus {

    private let bus: Bus

    public init(bus: Bus = .session) {
        self.bus = bus
    }

    public func call(_ interface: String, _ method: String, _ arguments: [DBusMessageArgument], signature: String,
                     reply: @escaping (Result<[DBusMessageArgument], BusError>) -> Void) {
        bus.call(Portal.service, Portal.path, interface, method, arguments, signature: signature, reply: reply)
    }

    public func property(_ interface: String, _ name: String, reply: @escaping (Result<DBusMessageArgument, BusError>) -> Void) {
        bus.property(Portal.service, Portal.path, interface, name, reply: reply)
    }

    public func subscribeToResponses(_ handler: @escaping (_ path: String, _ arguments: [DBusMessageArgument]) -> Void) -> BusSubscription {
        bus.subscribe(MatchRule(sender: Portal.service, interface: Portal.request, member: "Response")) { signal in
            handler(signal.path, signal.body)
        }
    }

    public func subscribeToDisconnect(_ handler: @escaping () -> Void) -> BusSubscription {
        bus.subscribe(.disconnected) { _ in handler() }
    }
}
