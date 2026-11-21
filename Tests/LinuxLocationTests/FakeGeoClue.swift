import DBus
import LinuxDBus
import LinuxHost
@testable import LinuxLocation

/// Plays GeoClue 2: a manager that makes clients, clients that take their
/// properties and start and stop, an agent that allows or refuses, and
/// locations on demand. Replies come on the next turn of the main loop, as
/// the system bus's do.
final class FakeGeoClue: GeoClueBus {

    struct Call: Equatable, CustomStringConvertible {
        var path: String
        var method: String
        var arguments: [DBusMessageArgument]

        var description: String {
            ([method] + arguments.map { $0.text ?? $0.int64Value.map(String.init) ?? "\($0)" }).joined(separator: " ")
        }
    }

    /// Whether GeoClue is on the bus.
    var available = true

    /// What the agent answers `Start` with, if it refuses.
    var refusal: BusError?

    /// `AvailableAccuracyLevel`.
    var availableAccuracy: UInt32 = GeoClue.Accuracy.exact.rawValue

    /// GeoClue 2.5 and later: `CreateClient`; before, only `GetClient`.
    var hasCreateClient = true

    /// GeoClue 2.4.4 and later.
    var hasTimeThreshold = true

    private(set) var calls: [Call] = []

    /// Each client's properties.
    private(set) var clients: [String: [String: DBusMessageArgument]] = [:]

    private(set) var active: Set<String> = []

    private(set) var locations: [String: [String: DBusMessageArgument]] = [:]

    private var subscribers: [UInt64: (path: String, member: String, handler: ([DBusMessageArgument]) -> Void)] = [:]

    private var nextClient = 0

    private var nextLocation = 0

    private var nextSubscriber: UInt64 = 0

    static let missing = BusError(name: "org.freedesktop.DBus.Error.ServiceUnknown",
                                  message: "The name org.freedesktop.GeoClue2 was not provided by any .service files")

    static let rejected = BusError(name: "org.freedesktop.DBus.Error.AccessDenied",
                                   message: "Agent rejected 'org.example.Maps' for user 'ada'.")

    static let disabled = BusError(name: "org.freedesktop.DBus.Error.AccessDenied", message: "Geolocation disabled for UID 1000")

    /// What was asked, as `Method arguments`, `Set Name value` for
    /// properties.
    var log: [String] {
        calls.map(\.description)
    }

    func methods(on path: String) -> [String] {
        calls.filter { $0.path == path }.map(\.method)
    }

    // MARK: GeoClueBus

    func call(_ path: String, _ interface: String, _ method: String, _ arguments: [DBusMessageArgument],
              reply: @escaping (Result<[DBusMessageArgument], BusError>) -> Void) {
        calls.append(Call(path: path, method: method, arguments: arguments))
        let result = answer(path, method, arguments)
        MainLoop.shared.post { reply(result) }
    }

    private func answer(_ path: String, _ method: String, _ arguments: [DBusMessageArgument]) -> Result<[DBusMessageArgument], BusError> {
        guard available else { return .failure(Self.missing) }
        switch method {
        case "CreateClient" where hasCreateClient:
            nextClient += 1
            let client = "/org/freedesktop/GeoClue2/Client/\(nextClient)"
            clients[client] = [:]
            return .success([.path(client)])
        case "GetClient":
            let client = "/org/freedesktop/GeoClue2/Client/0"
            clients[client] = clients[client] ?? [:]
            return .success([.path(client)])
        case "DeleteClient":
            if let client = arguments.first?.text {
                clients[client] = nil
                active.remove(client)
            }
            return .success([])
        case "Start":
            guard let client = clients[path] else { return .failure(unknownObject(path)) }
            guard client["DesktopId"] != nil else {
                return .failure(BusError(name: "org.freedesktop.DBus.Error.AccessDenied", message: "'DesktopId' property must be set"))
            }
            if let refusal {
                return .failure(refusal)
            }
            active.insert(path)
            return .success([])
        case "Stop":
            active.remove(path)
            return .success([])
        default:
            return .failure(BusError(name: "org.freedesktop.DBus.Error.UnknownMethod", message: method))
        }
    }

    private func unknownObject(_ path: String) -> BusError {
        BusError(name: "org.freedesktop.DBus.Error.UnknownObject", message: path)
    }

    func propertyAndWait(_ path: String, _ interface: String, _ name: String) -> Result<DBusMessageArgument, BusError> {
        calls.append(Call(path: path, method: "Get", arguments: [.string(name)]))
        guard available else { return .failure(Self.missing) }
        return .success(.uint32(availableAccuracy))
    }

    func properties(_ path: String, _ interface: String, reply: @escaping (Result<[String: DBusMessageArgument], BusError>) -> Void) {
        let result: Result<[String: DBusMessageArgument], BusError>
        if !available {
            result = .failure(Self.missing)
        } else if let location = locations[path] {
            result = .success(location)
        } else {
            result = .failure(unknownObject(path))
        }
        MainLoop.shared.post { reply(result) }
    }

    func setProperty(_ path: String, _ interface: String, _ name: String, _ value: DBusMessageArgument,
                     reply: @escaping (Result<Void, BusError>) -> Void) {
        calls.append(Call(path: path, method: "Set", arguments: [.string(name), value]))
        let result: Result<Void, BusError>
        if !available {
            result = .failure(Self.missing)
        } else if clients[path] == nil {
            result = .failure(unknownObject(path))
        } else if name == "TimeThreshold" && !hasTimeThreshold {
            result = .failure(BusError(name: "org.freedesktop.DBus.Error.UnknownProperty", message: name))
        } else {
            clients[path]?[name] = value
            result = .success(())
        }
        MainLoop.shared.post { reply(result) }
    }

    func subscribe(_ path: String, _ interface: String, _ member: String, _ handler: @escaping ([DBusMessageArgument]) -> Void) -> BusSubscription {
        nextSubscriber += 1
        subscribers[nextSubscriber] = (path, member, handler)
        return BusSubscription(id: nextSubscriber)
    }

    func unsubscribe(_ subscription: BusSubscription) {
        subscribers[subscription.id] = nil
    }

    var subscriptionCount: Int {
        subscribers.count
    }

    // MARK: Locations

    /// GeoClue finds a location: a new `Location` object, and
    /// `LocationUpdated` to each started client.
    func locate(
        latitude: Double, longitude: Double, accuracy: Double = 20, altitude: Double = GeoClue.unknownAltitude,
        speed: Double = -1, heading: Double = -1, timestamp: (UInt64, UInt64) = (1_700_000_000, 0)
    ) {
        let old = nextLocation == 0 ? "/" : "/org/freedesktop/GeoClue2/Location/\(nextLocation)"
        nextLocation += 1
        let path = "/org/freedesktop/GeoClue2/Location/\(nextLocation)"
        locations[path] = [
            "Latitude": .double(latitude), "Longitude": .double(longitude), "Accuracy": .double(accuracy),
            "Altitude": .double(altitude), "Speed": .double(speed), "Heading": .double(heading),
            "Description": .string(""), "Timestamp": .structure([.uint64(timestamp.0), .uint64(timestamp.1)]),
        ]
        for client in active.sorted() {
            for subscriber in subscribers.values where subscriber.path == client && subscriber.member == "LocationUpdated" {
                subscriber.handler([.path(old), .path(path)])
            }
        }
    }
}
