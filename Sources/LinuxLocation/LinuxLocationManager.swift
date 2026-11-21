import DBus
import DynamicLocation
import DynamicRuntime
import Foundation
import LinuxDBus
import LinuxHost

/// The `LocationManager` contract over GeoClue 2 (`Plan.md` §11). Main loop
/// only.
///
/// Each manager has its own GeoClue client, made when it first needs one,
/// with the app's identifier as its desktop ID.
///
/// - **Authorization** is GeoClue's agent's: gnome-shell asks the user
///   when a client starts, and remembers the answer by desktop ID. So
///   `requestWhenInUseAuthorization()` starts the client (and stops it
///   again if nothing wants updates): it succeeds, and the status is
///   `authorizedAlways`, or GeoClue refuses with `AccessDenied`, and it's
///   `denied`. As on macOS, an app isn't suspended, so the answer covers
///   the background too, and accuracy is `full`. Until then it's
///   `notDetermined`. Every manager hears of a change once.
/// - **Services** are enabled when GeoClue answers on the system bus with
///   an available accuracy above none. Without GeoClue, starting fails
///   with `servicesDisabled`, and so does GeoClue's "Geolocation disabled"
///   (the desktop's location switch is off). A request then reads as
///   `denied`, as CoreLocation's does with location off, so the app hears
///   an answer; it isn't the app's refusal, and GeoClue starting clears it.
/// - **Updates** come from the client's `LocationUpdated` signal. GeoClue
///   keeps to the distance filter (`DistanceThreshold`), and so does the
///   manager, from the last location it delivered.
/// - **Heading** isn't available: there's no compass service on Linux.
public final class LinuxLocationManager: LocationManager {

    /// GeoClue; replaceable for tests.
    nonisolated(unsafe) static var bus: any GeoClueBus = SystemGeoClue()

    let delegate: any LocationManagerDelegate

    let client: GeoClueClient

    private var updating = false

    /// `requestLocation`: one location, then stop.
    private var oneShot = false

    private var distanceFilter = 0.0

    private(set) var newest: LinuxLocationFix?

    /// The last location delivered, for the distance filter.
    private var delivered: LinuxLocationFix?

    /// The last `(status, accuracy)` sent to the delegate.
    private var reported: (status: Int32, accuracy: Int32)?

    /// How many authorization reports were sent.
    private var reports = 0

    init(delegate: any LocationManagerDelegate, bus: any GeoClueBus, desktopID: String) {
        self.delegate = delegate
        self.client = GeoClueClient(bus: bus, desktopID: desktopID)
        client.onLocation = { [weak self] path in
            self?.locationUpdated(path)
        }
    }

    deinit {
        client.close()
    }

    // MARK: Static

    public static func authorizationStatus() -> Int32 {
        LocationAuthority.shared.status.rawValue
    }

    public static func accuracyAuthorization() -> Int32 {
        LocationAccuracyAuthorization.full.rawValue
    }

    /// Asks GeoClue for its `AvailableAccuracyLevel`, waiting up to two
    /// seconds: GeoClue starts when it's first asked.
    public static func isLocationServicesEnabled() -> Bool {
        LocationAuthority.servicesEnabled(bus)
    }

    public static func isHeadingAvailable() -> Bool {
        false
    }

    /// Doesn't ask GeoClue anything. The current authorization arrives
    /// through `didChangeAuthorization` on a later turn.
    public static func make(_ delegate: any LocationManagerDelegate) -> LinuxLocationManager {
        let manager = LinuxLocationManager(delegate: delegate, bus: bus, desktopID: LinuxBundle.info.identifier)
        LocationAuthority.shared.add(manager)
        MainLoop.shared.post { [weak manager] in
            manager?.reportAuthorization(force: false)
        }
        return manager
    }

    // MARK: Authorization

    /// Starts the client, which is when GeoClue's agent asks the user, and
    /// reports the authorization afterwards whatever happened.
    public func requestWhenInUseAuthorization() {
        if LocationAuthority.shared.status == .authorizedAlways {
            reportAuthorizationLater(force: true)
            return
        }
        client.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.answer { LocationAuthority.shared.decide(.authorizedAlways) }
                self.stopIfIdle()
            case .failure(let error):
                self.startFailed(error, requested: true)
            }
        }
    }

    /// The same as when-in-use: GeoClue doesn't tell them apart.
    public func requestAlwaysAuthorization() {
        requestWhenInUseAuthorization()
    }

    /// Accuracy is always full.
    public func requestFullAccuracy(_ purpose: String) {
        reportAuthorizationLater(force: true)
    }

    // MARK: Settings

    /// A tier as GeoClue's accuracy level. A running client starts again,
    /// since GeoClue reads the level on `Start`.
    public func setDesiredAccuracy(_ accuracy: Int32) {
        guard let level = Self.accuracyLevel(accuracy) else {
            HostLog.error("location: unknown LocationAccuracy \(accuracy); keeping the current accuracy")
            return
        }
        guard level != client.accuracy else { return }
        client.setAccuracy(level)
        if client.isActive {
            client.stop()
            begin()
        }
    }

    /// GeoClue's `DistanceThreshold`, in whole meters, rounded up.
    public func setDistanceFilter(_ meters: Double) {
        distanceFilter = meters > 0 && meters.isFinite ? meters : 0
        client.setDistanceThreshold(UInt32(min(distanceFilter.rounded(.up), Double(UInt32.max))))
    }

    /// An app isn't suspended, so updates carry on in the background
    /// anyway.
    public func setBackgroundUpdatesEnabled(_ enabled: Bool) { }

    // MARK: Location

    public func startUpdatingLocation() {
        updating = true
        begin()
    }

    /// Stops updates, and a `requestLocation` waiting for its location.
    public func stopUpdatingLocation() {
        updating = false
        oneShot = false
        client.stop()
    }

    public func requestLocation() {
        oneShot = true
        begin()
    }

    public func lastLocation() -> (any Location)? {
        newest
    }

    // MARK: Heading

    public func startUpdatingHeading() {
        failLater(.headingFailure)
    }

    public func stopUpdatingHeading() { }

    // MARK: GeoClue

    private func begin() {
        client.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                LocationAuthority.shared.decide(.authorizedAlways)
                self.stopIfIdle()
            case .failure(let error):
                self.startFailed(error, requested: false)
            }
        }
    }

    /// Stops a client nothing wants updates from.
    private func stopIfIdle() {
        if !updating && !oneShot {
            client.stop()
        }
    }

    private func startFailed(_ error: BusError, requested: Bool) {
        let failure = Self.error(error)
        HostLog.debug("location: GeoClue didn't start: \(error)")
        let decide = {
            if failure == .denied {
                LocationAuthority.shared.decide(.denied)
            } else if failure == .servicesDisabled && requested {
                LocationAuthority.shared.servicesUnavailable()
            }
        }
        if requested {
            answer(decide)
        } else {
            decide()
        }
        if updating || oneShot {
            fail(failure)
        }
    }

    private func locationUpdated(_ path: String) {
        guard updating || oneShot else { return }
        client.bus.properties(path, GeoClue.location) { [weak self] result in
            guard let self, self.updating || self.oneShot else { return }
            switch result {
            case .success(let properties):
                guard let fix = LinuxLocationFix(properties) else {
                    HostLog.error("location: GeoClue's \(path) has no coordinate")
                    return
                }
                self.deliver(fix)
            case .failure(let error):
                // GeoClue keeps only its latest locations.
                HostLog.debug("location: can't read \(path): \(error)")
            }
        }
    }

    private func deliver(_ fix: LinuxLocationFix) {
        newest = fix
        if !oneShot, distanceFilter > 0, let delivered, fix.distance(from: delivered) < distanceFilter {
            return
        }
        delivered = fix
        if oneShot {
            oneShot = false
            stopIfIdle()
        }
        delegate.didUpdateLocations(self, locations: [fix])
    }

    // MARK: Reporting

    /// Sends `didFail`, stopping updates for anything but
    /// `locationUnknown` and `headingFailure`.
    func fail(_ error: LocationError) {
        switch error {
        case .locationUnknown, .headingFailure:
            break
        default:
            updating = false
            oneShot = false
            client.stop()
        }
        delegate.didFail(self, error: error.rawValue)
    }

    private func failLater(_ error: LocationError) {
        MainLoop.shared.post { [weak self] in
            self?.fail(error)
        }
    }

    /// Sends the current authorization if it differs from the last one
    /// sent, or always with `force`.
    func reportAuthorization(force: Bool) {
        let current = (status: LocationAuthority.shared.status.rawValue, accuracy: LocationAccuracyAuthorization.full.rawValue)
        if !force, let reported, reported == current {
            return
        }
        reported = current
        reports += 1
        delegate.didChangeAuthorization(self, status: current.status, accuracy: current.accuracy)
    }

    /// Answers a request: `decide`'s change if it made one, else the
    /// current authorization again, so the delegate hears once either way.
    private func answer(_ decide: () -> Void) {
        let before = reports
        decide()
        if reports == before {
            reportAuthorization(force: true)
        }
    }

    private func reportAuthorizationLater(force: Bool) {
        MainLoop.shared.post { [weak self] in
            self?.reportAuthorization(force: force)
        }
    }

    // MARK: Mapping

    /// A `LocationAccuracy` code as GeoClue's level.
    static func accuracyLevel(_ accuracy: Int32) -> GeoClue.Accuracy? {
        switch LocationAccuracy(rawValue: accuracy) {
        case .best, .nearestTenMeters: .exact
        case .hundredMeters: .street
        case .kilometer: .neighborhood
        case .reduced: .city
        case nil: nil
        }
    }

    /// A D-Bus error from GeoClue as a `LocationError`: its agent's refusal
    /// is `denied`, but "Geolocation disabled" (the desktop's switch) and
    /// no GeoClue are `servicesDisabled`.
    static func error(_ error: BusError) -> LocationError {
        if error.isServiceMissing {
            return .servicesDisabled
        }
        if error.isAccessDenied {
            return error.message.localizedCaseInsensitiveContains("disabled") ? .servicesDisabled : .denied
        }
        return .unknown
    }
}

/// What this process knows of GeoClue's answer for the app, shared by the
/// managers and `Permissions`. Main loop only.
final class LocationAuthority {

    nonisolated(unsafe) static var shared = LocationAuthority()

    /// GeoClue's answer for the app.
    private(set) var answer = LocationAuthorization.notDetermined

    /// A request found GeoClue missing or the desktop's switch off.
    private(set) var servicesOff = false

    /// The answer, or `denied` while a request found location off.
    var status: LocationAuthorization {
        answer == .notDetermined && servicesOff ? .denied : answer
    }

    private var managers: [Weak] = []

    private struct Weak {
        weak var manager: LinuxLocationManager?
    }

    /// For `Permissions.request`, which has no manager of its own.
    private var probe: GeoClueClient?

    func add(_ manager: LinuxLocationManager) {
        managers.removeAll { $0.manager == nil }
        managers.append(Weak(manager: manager))
    }

    /// Records an answer, telling every manager if the status changed.
    func decide(_ answer: LocationAuthorization) {
        change {
            self.answer = answer
            servicesOff = false
        }
    }

    /// A request found location off: `denied` until GeoClue answers.
    func servicesUnavailable() {
        change { servicesOff = true }
    }

    private func change(_ body: () -> Void) {
        let before = status
        body()
        guard status != before else { return }
        managers.removeAll { $0.manager == nil }
        for entry in managers {
            entry.manager?.reportAuthorization(force: false)
        }
    }

    /// Starts a client of its own, then stops it, so GeoClue's agent asks
    /// the user; `completion` gets the error, if there was one.
    func ask(_ bus: any GeoClueBus, desktopID: String, _ completion: @escaping (BusError?) -> Void) {
        let probe = self.probe ?? GeoClueClient(bus: bus, desktopID: desktopID)
        self.probe = probe
        probe.start { [weak self] result in
            switch result {
            case .success:
                probe.stop()
                self?.decide(.authorizedAlways)
                completion(nil)
            case .failure(let error):
                switch LinuxLocationManager.error(error) {
                case .denied: self?.decide(.denied)
                case .servicesDisabled: self?.servicesUnavailable()
                default: break
                }
                completion(error)
            }
        }
    }

    /// Whether GeoClue answers with an accuracy above none.
    static func servicesEnabled(_ bus: any GeoClueBus) -> Bool {
        switch bus.propertyAndWait(GeoClue.managerPath, GeoClue.manager, "AvailableAccuracyLevel") {
        case .success(let level):
            return (level.int64Value ?? 0) > 0
        case .failure(let error):
            HostLog.debug("location: GeoClue isn't available: \(error)")
            return false
        }
    }
}
