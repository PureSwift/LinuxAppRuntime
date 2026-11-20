import DBUS
import LinuxDBus

/// GeoClue 2 on the system bus (`Plan.md` §11), or a fake one in tests.
/// Every call goes to `org.freedesktop.GeoClue2`, and everything it reports
/// arrives on the main loop.
public protocol GeoClueBus: AnyObject {

    /// Calls a method of one of GeoClue's objects.
    func call(_ path: String, _ interface: String, _ method: String, _ arguments: [DBusValue],
              reply: @escaping (Result<[DBusValue], BusError>) -> Void)

    /// Reads one property, waiting for it: for the contract's synchronous
    /// calls.
    func propertyAndWait(_ path: String, _ interface: String, _ name: String) -> Result<DBusValue, BusError>

    /// Every property of one of GeoClue's objects.
    func properties(_ path: String, _ interface: String, reply: @escaping (Result<[String: DBusValue], BusError>) -> Void)

    func setProperty(_ path: String, _ interface: String, _ name: String, _ value: DBusValue,
                     reply: @escaping (Result<Void, BusError>) -> Void)

    /// Calls `handler` with the arguments of each of the object's `member`
    /// signals.
    func subscribe(_ path: String, _ interface: String, _ member: String, _ handler: @escaping ([DBusValue]) -> Void) -> BusSubscription

    func unsubscribe(_ subscription: BusSubscription)
}

/// GeoClue's names and values.
public enum GeoClue {

    public static let service = "org.freedesktop.GeoClue2"

    public static let managerPath = "/org/freedesktop/GeoClue2/Manager"

    public static let manager = "org.freedesktop.GeoClue2.Manager"

    public static let client = "org.freedesktop.GeoClue2.Client"

    public static let location = "org.freedesktop.GeoClue2.Location"

    /// `GClueAccuracyLevel`.
    public enum Accuracy: UInt32, Sendable {
        case none = 0
        case country = 1
        case city = 4
        case neighborhood = 5
        case street = 6
        case exact = 8
    }

    /// The altitude of a location without one (`-G_MAXDOUBLE`).
    public static let unknownAltitude = -Double.greatestFiniteMagnitude
}

/// GeoClue on the system bus, through LinuxDBus.
public final class SystemGeoClue: GeoClueBus {

    private let bus: Bus

    public init(bus: Bus = .system) {
        self.bus = bus
    }

    public func call(_ path: String, _ interface: String, _ method: String, _ arguments: [DBusValue],
                     reply: @escaping (Result<[DBusValue], BusError>) -> Void) {
        bus.call(GeoClue.service, path, interface, method, arguments, reply: reply)
    }

    public func propertyAndWait(_ path: String, _ interface: String, _ name: String) -> Result<DBusValue, BusError> {
        bus.propertyAndWait(GeoClue.service, path, interface, name)
    }

    public func properties(_ path: String, _ interface: String, reply: @escaping (Result<[String: DBusValue], BusError>) -> Void) {
        bus.properties(GeoClue.service, path, interface, reply: reply)
    }

    public func setProperty(_ path: String, _ interface: String, _ name: String, _ value: DBusValue,
                            reply: @escaping (Result<Void, BusError>) -> Void) {
        bus.setProperty(GeoClue.service, path, interface, name, value, reply: reply)
    }

    public func subscribe(_ path: String, _ interface: String, _ member: String, _ handler: @escaping ([DBusValue]) -> Void) -> BusSubscription {
        bus.subscribe(MatchRule(sender: GeoClue.service, path: path, interface: interface, member: member)) { signal in
            handler(signal.body)
        }
    }

    public func unsubscribe(_ subscription: BusSubscription) {
        bus.unsubscribe(subscription)
    }
}
