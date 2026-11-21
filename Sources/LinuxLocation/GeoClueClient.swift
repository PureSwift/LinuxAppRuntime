import DBUS
import LinuxDBus
import LinuxHost

/// One GeoClue client: made on first use (`CreateClient`, or `GetClient`
/// from a GeoClue before 2.5), given the app's desktop ID and the
/// requested accuracy and thresholds, then started and stopped. Main loop
/// only.
///
/// GeoClue asks its agent whether the app may have its location when the
/// client starts, so `Start` is where a refusal shows up.
final class GeoClueClient {

    let bus: any GeoClueBus

    /// The app's desktop file's name, without `.desktop`.
    let desktopID: String

    private(set) var accuracy = GeoClue.Accuracy.exact

    private(set) var distanceThreshold: UInt32 = 0

    /// The client's object path, once it's made and set up.
    private(set) var path: String?

    /// Whether `GetClient` made it, so it's shared with the process's
    /// other clients and isn't deleted.
    private var shared = false

    /// Whether it started, and hasn't stopped since.
    private(set) var isActive = false

    /// Waiting for `Start`'s reply.
    private var starting: [(Result<Void, BusError>) -> Void]?

    private var subscription: BusSubscription?

    /// Called with the path of each new `Location` object.
    var onLocation: (String) -> Void = { _ in }

    init(bus: any GeoClueBus, desktopID: String) {
        self.bus = bus
        self.desktopID = desktopID
    }

    // MARK: Settings

    /// Sets `RequestedAccuracyLevel` now if the client exists; otherwise
    /// it's set when it's made. GeoClue reads it on `Start`.
    func setAccuracy(_ accuracy: GeoClue.Accuracy) {
        self.accuracy = accuracy
        if let path {
            set(path, "RequestedAccuracyLevel", .uint32(accuracy.rawValue))
        }
    }

    /// Sets `DistanceThreshold`, which applies to the next update.
    func setDistanceThreshold(_ meters: UInt32) {
        distanceThreshold = meters
        if let path {
            set(path, "DistanceThreshold", .uint32(meters))
        }
    }

    private func set(_ path: String, _ name: String, _ value: DBusValue) {
        bus.setProperty(path, GeoClue.client, name, value) { result in
            if case .failure(let error) = result {
                HostLog.error("location: GeoClue didn't take \(name): \(error)")
            }
        }
    }

    // MARK: Starting and stopping

    /// Starts the client, making it first if need be; `completion` gets
    /// `Start`'s outcome. Calls while it starts wait for the same reply.
    func start(_ completion: @escaping (Result<Void, BusError>) -> Void) {
        if isActive {
            completion(.success(()))
            return
        }
        if starting != nil {
            starting?.append(completion)
            return
        }
        starting = [completion]
        prepare { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finishStarting(.failure(error))
            case .success(let path):
                self.bus.call(path, GeoClue.client, "Start", []) { [weak self] result in
                    self?.finishStarting(result.map { _ in })
                }
            }
        }
    }

    private func finishStarting(_ result: Result<Void, BusError>) {
        if case .success = result {
            isActive = true
        }
        let waiting = starting ?? []
        starting = nil
        for completion in waiting {
            completion(result)
        }
    }

    /// Stops the client if it's running.
    func stop() {
        guard isActive, let path else { return }
        isActive = false
        bus.call(path, GeoClue.client, "Stop", []) { result in
            if case .failure(let error) = result {
                HostLog.debug("location: GeoClue's Stop: \(error)")
            }
        }
    }

    /// Stops and deletes the client.
    func close() {
        stop()
        if let subscription {
            bus.unsubscribe(subscription)
            self.subscription = nil
        }
        if let path, !shared {
            bus.call(GeoClue.managerPath, GeoClue.manager, "DeleteClient", [.objectPath(path)]) { _ in }
        }
        path = nil
    }

    // MARK: Making the client

    /// The client's path, made and set up the first time.
    private func prepare(_ completion: @escaping (Result<String, BusError>) -> Void) {
        if let path {
            completion(.success(path))
            return
        }
        create { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let path):
                self.configure(path) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .failure:
                        if !self.shared {
                            self.bus.call(GeoClue.managerPath, GeoClue.manager, "DeleteClient", [.objectPath(path)]) { _ in }
                        }
                    case .success:
                        self.path = path
                        self.subscription = self.bus.subscribe(path, GeoClue.client, "LocationUpdated") { [weak self] arguments in
                            // (o old, o new)
                            guard arguments.count >= 2, let new = arguments[1].text, new != "/" else { return }
                            self?.onLocation(new)
                        }
                    }
                    completion(result.map { path })
                }
            }
        }
    }

    private func create(_ completion: @escaping (Result<String, BusError>) -> Void) {
        bus.call(GeoClue.managerPath, GeoClue.manager, "CreateClient", []) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let values):
                completion(Self.path(values))
            case .failure(let error) where error.isUnknownMember:
                self.bus.call(GeoClue.managerPath, GeoClue.manager, "GetClient", []) { [weak self] result in
                    self?.shared = true
                    completion(result.flatMap(Self.path))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private static func path(_ values: [DBusValue]) -> Result<String, BusError> {
        guard let path = values.first?.text else {
            return .failure(BusError(name: "org.freedesktop.DBus.Error.InvalidSignature", message: "no client path"))
        }
        return .success(path)
    }

    /// Sets the desktop ID, which GeoClue needs, then the accuracy and
    /// thresholds, in order. An older GeoClue without `TimeThreshold` is
    /// fine.
    private func configure(_ path: String, _ completion: @escaping (Result<Void, BusError>) -> Void) {
        let settings: [(name: String, value: DBusValue, required: Bool)] = [
            ("DesktopId", .string(desktopID), true),
            ("RequestedAccuracyLevel", .uint32(accuracy.rawValue), true),
            ("DistanceThreshold", .uint32(distanceThreshold), false),
            ("TimeThreshold", .uint32(0), false),
        ]
        func apply(_ index: Int) {
            guard index < settings.count else {
                completion(.success(()))
                return
            }
            let setting = settings[index]
            bus.setProperty(path, GeoClue.client, setting.name, setting.value) { result in
                if case .failure(let error) = result {
                    if setting.required || !error.isUnknownMember {
                        HostLog.error("location: GeoClue didn't take \(setting.name): \(error)")
                    }
                    if setting.required {
                        completion(.failure(error))
                        return
                    }
                }
                apply(index + 1)
            }
        }
        apply(0)
    }
}
