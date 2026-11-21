import DBus
import DynamicLocation
import DynamicRuntime
import Foundation
import LinuxDBus
import LinuxHost
import Testing
@testable import LinuxLocation

/// Records what a manager tells its delegate.
final class LocationLog: LocationManagerDelegate {

    var events: [String] = []

    var locations: [any Location] = []

    func didChangeAuthorization(_ manager: any LocationManager, status: Int32, accuracy: Int32) {
        events.append("authorization \(status) \(accuracy)")
    }

    func didUpdateLocations(_ manager: any LocationManager, locations: [any Location]) {
        self.locations += locations
        for location in locations {
            events.append("location \(location.latitude()) \(location.longitude())")
        }
    }

    func didUpdateHeading(_ manager: any LocationManager, heading: any Heading) {
        events.append("heading")
    }

    func didFail(_ manager: any LocationManager, error: Int32) {
        events.append("fail \(error)")
    }
}

/// Records what a module registers.
final class Registrar: ContractRegistrar {

    var names: [String] = []

    func register(_ descriptor: ContractDescriptor, statics: StaticMethodTable?) {
        names.append(descriptor.name)
    }
}

let notDetermined = "authorization \(LocationAuthorization.notDetermined.rawValue) 0"
let authorized = "authorization \(LocationAuthorization.authorizedAlways.rawValue) 0"
let denied = "authorization \(LocationAuthorization.denied.rawValue) 0"
let client = "/org/freedesktop/GeoClue2/Client/1"

/// Serialized: managers share one authorization and the shared main loop,
/// which each test drains.
@Suite(.serialized) struct LinuxLocationTests {

    /// A fresh GeoClue, and nothing decided.
    func geoClue() -> FakeGeoClue {
        MainLoop.shared.drain()
        let geoClue = FakeGeoClue()
        LinuxLocationManager.bus = geoClue
        LocationAuthority.shared = LocationAuthority()
        LinuxBundle.info = AppInfo(identifier: "org.example.Maps", abiVersion: 1)
        return geoClue
    }

    func manager(_ geoClue: FakeGeoClue) -> (LinuxLocationManager, LocationLog) {
        let log = LocationLog()
        let manager = LinuxLocationManager.make(log)
        MainLoop.shared.drain()
        return (manager, log)
    }

    // MARK: Authorization

    @Test func makingAManagerAsksNothing() {
        let geoClue = self.geoClue()
        let (_, log) = self.manager(geoClue)
        #expect(log.events == [notDetermined])
        #expect(geoClue.calls.isEmpty, "no client until one's needed")
        #expect(LinuxLocationManager.authorizationStatus() == LocationAuthorization.notDetermined.rawValue)
        #expect(LinuxLocationManager.accuracyAuthorization() == LocationAccuracyAuthorization.full.rawValue)
        #expect(LinuxLocationManager.isLocationServicesEnabled())
        #expect(geoClue.log == ["Get AvailableAccuracyLevel"])
        #expect(!LinuxLocationManager.isHeadingAvailable())
    }

    @Test func requestingStartsAClientAsTheApp() {
        let geoClue = self.geoClue()
        let (manager, log) = self.manager(geoClue)
        manager.requestWhenInUseAuthorization()
        MainLoop.shared.drain()
        #expect(geoClue.log == [
            "CreateClient",
            "Set DesktopId org.example.Maps",
            "Set RequestedAccuracyLevel 8",
            "Set DistanceThreshold 0",
            "Set TimeThreshold 0",
            "Start",
            "Stop",
        ], "started for the agent to ask, then stopped: nothing wants updates")
        #expect(geoClue.active.isEmpty)
        #expect(log.events == [notDetermined, authorized], "once")
        #expect(LinuxLocationManager.authorizationStatus() == LocationAuthorization.authorizedAlways.rawValue)
        #expect(LocationPermission().status() == .granted)

        // Asking again answers at once, without GeoClue.
        let calls = geoClue.calls.count
        manager.requestAlwaysAuthorization()
        manager.requestFullAccuracy("Navigation")
        MainLoop.shared.drain()
        #expect(geoClue.calls.count == calls)
        #expect(log.events == [notDetermined, authorized, authorized, authorized])

        // A new manager hears the answer.
        let (_, other) = self.manager(geoClue)
        #expect(other.events == [authorized])
    }

    @Test func everyManagerHearsTheAnswerOnce() {
        let geoClue = self.geoClue()
        let (first, firstLog) = self.manager(geoClue)
        let (second, secondLog) = self.manager(geoClue)
        first.requestWhenInUseAuthorization()
        MainLoop.shared.drain()
        #expect(firstLog.events == [notDetermined, authorized])
        #expect(secondLog.events == [notDetermined, authorized])
        withExtendedLifetime(second) { }
    }

    @Test func aRefusal() {
        let geoClue = self.geoClue()
        geoClue.refusal = FakeGeoClue.rejected
        let (manager, log) = self.manager(geoClue)
        manager.requestWhenInUseAuthorization()
        MainLoop.shared.drain()
        #expect(log.events == [notDetermined, denied])
        #expect(LinuxLocationManager.authorizationStatus() == LocationAuthorization.denied.rawValue)
        #expect(LocationPermission().status() == .denied)
        #expect(geoClue.active.isEmpty)

        // Updates fail, and stop.
        log.events = []
        manager.startUpdatingLocation()
        MainLoop.shared.drain()
        #expect(log.events == ["fail \(LocationError.denied.rawValue)"])
        geoClue.locate(latitude: 1, longitude: 2)
        MainLoop.shared.drain()
        #expect(log.events == ["fail \(LocationError.denied.rawValue)"])

        // If the user changes their mind in Settings, the next start says
        // so.
        geoClue.refusal = nil
        manager.requestLocation()
        MainLoop.shared.drain()
        #expect(log.events.last == authorized)
    }

    @Test func permissionsAskWithAClientOfTheirOwn() {
        let geoClue = self.geoClue()
        let permission = LocationPermission()
        #expect(permission.status() == .notDetermined)
        var answers: [PermissionStatus] = []
        permission.request { answers.append($0) }
        MainLoop.shared.drain()
        #expect(answers == [.granted])
        #expect(geoClue.methods(on: client) == ["Set", "Set", "Set", "Set", "Start", "Stop"])
        permission.request { answers.append($0) }
        #expect(answers == [.granted, .granted])

        let refused = self.geoClue()
        refused.refusal = FakeGeoClue.rejected
        LocationPermission().request { answers.append($0) }
        MainLoop.shared.drain()
        #expect(answers.last == .denied)
    }

    // MARK: Updates

    @Test func updatesAndTheirValues() throws {
        let geoClue = self.geoClue()
        let (manager, log) = self.manager(geoClue)
        manager.startUpdatingLocation()
        MainLoop.shared.drain()
        #expect(geoClue.active == [client])
        #expect(log.events == [notDetermined, authorized], "GeoClue let it start")

        geoClue.locate(latitude: 51.5007, longitude: -0.1246, accuracy: 25, altitude: 30, speed: 1.5, heading: 90,
                       timestamp: (1_700_000_000, 250_000))
        MainLoop.shared.drain()
        #expect(log.events.last == "location 51.5007 -0.1246")
        let fix = try #require(log.locations.last)
        #expect(fix.horizontalAccuracy() == 25)
        #expect(fix.altitude() == 30)
        #expect(fix.speed() == 1.5)
        #expect(fix.course() == 90)
        #expect(fix.timestamp() == 1_700_000_000_250)
        #expect(fix.verticalAccuracy() < 0 && fix.speedAccuracy() < 0 && fix.courseAccuracy() < 0)
        #expect(fix.isSimulated() == -1)
        #expect(manager.lastLocation() === fix)

        // What GeoClue doesn't know.
        geoClue.locate(latitude: 48.8584, longitude: 2.2945, accuracy: 5000)
        MainLoop.shared.drain()
        let rough = try #require(log.locations.last)
        #expect(rough.altitude().isNaN)
        #expect(rough.speed() == -1 && rough.course() == -1)
        #expect(rough.horizontalAccuracy() == 5000)
        #expect(log.locations.count == 2)
    }

    @Test func oneLocation() {
        let geoClue = self.geoClue()
        let (manager, log) = self.manager(geoClue)
        manager.requestLocation()
        MainLoop.shared.drain()
        geoClue.locate(latitude: 1, longitude: 2)
        MainLoop.shared.drain()
        #expect(log.events.last == "location 1.0 2.0")
        #expect(geoClue.methods(on: client).suffix(2) == ["Start", "Stop"])
        geoClue.locate(latitude: 3, longitude: 4)
        MainLoop.shared.drain()
        #expect(log.locations.count == 1, "one, then stop")
    }

    @Test func theDistanceAndTimeThresholds() {
        let geoClue = self.geoClue()
        let (manager, log) = self.manager(geoClue)
        manager.setDistanceFilter(12.3)
        manager.startUpdatingLocation()
        MainLoop.shared.drain()
        #expect(geoClue.clients[client]?["DistanceThreshold"] == .uint32(13), "whole meters, rounded up")
        #expect(geoClue.clients[client]?["TimeThreshold"] == .uint32(0), "every update GeoClue has")

        // GeoClue keeps to the threshold; so does the manager, from the
        // last location it delivered.
        geoClue.locate(latitude: 51.5, longitude: 0)
        geoClue.locate(latitude: 51.50005, longitude: 0)  // 5.6 m
        geoClue.locate(latitude: 51.5001, longitude: 0)   // 11 m
        geoClue.locate(latitude: 51.5002, longitude: 0)   // 22 m
        MainLoop.shared.drain()
        #expect(log.locations.map { $0.latitude() } == [51.5, 51.5002])
        #expect(manager.lastLocation()?.latitude() == 51.5002)

        // A running client takes a new threshold at once.
        manager.setDistanceFilter(0)
        MainLoop.shared.drain()
        #expect(geoClue.log.last == "Set DistanceThreshold 0")
        geoClue.locate(latitude: 51.50021, longitude: 0)
        MainLoop.shared.drain()
        #expect(log.locations.count == 3)
        #expect(manager.client.distanceThreshold == 0)
        manager.setDistanceFilter(-5)
        #expect(manager.client.distanceThreshold == 0)
    }

    @Test func aGeoClueWithoutTimeThresholdOrCreateClient() {
        let geoClue = self.geoClue()
        geoClue.hasTimeThreshold = false
        geoClue.hasCreateClient = false
        let shared = "/org/freedesktop/GeoClue2/Client/0"
        var (manager, log) = self.manager(geoClue)
        manager.startUpdatingLocation()
        MainLoop.shared.drain()
        #expect(geoClue.log.prefix(2) == ["CreateClient", "GetClient"])
        #expect(geoClue.active == [shared])
        geoClue.locate(latitude: 1, longitude: 2)
        MainLoop.shared.drain()
        #expect(log.locations.count == 1)
        // GetClient's client is the process's, so it isn't deleted.
        manager = LinuxLocationManager(delegate: log, bus: geoClue, desktopID: "x")
        MainLoop.shared.drain()
        #expect(!geoClue.log.contains { $0.hasPrefix("DeleteClient") })
        #expect(geoClue.clients[shared] != nil)
    }

    @Test func accuracy() {
        let geoClue = self.geoClue()
        let (manager, _) = self.manager(geoClue)
        manager.setDesiredAccuracy(LocationAccuracy.hundredMeters.rawValue)
        manager.startUpdatingLocation()
        MainLoop.shared.drain()
        #expect(geoClue.clients[client]?["RequestedAccuracyLevel"] == .uint32(GeoClue.Accuracy.street.rawValue))

        // GeoClue reads it on Start, so a running client starts again.
        manager.setDesiredAccuracy(LocationAccuracy.kilometer.rawValue)
        MainLoop.shared.drain()
        #expect(geoClue.log.suffix(3) == ["Set RequestedAccuracyLevel 5", "Stop", "Start"])
        #expect(geoClue.active == [client])

        manager.setDesiredAccuracy(99)
        #expect(manager.client.accuracy == .neighborhood, "unknown tiers are ignored")
        #expect(LinuxLocationManager.accuracyLevel(LocationAccuracy.best.rawValue) == .exact)
        #expect(LinuxLocationManager.accuracyLevel(LocationAccuracy.nearestTenMeters.rawValue) == .exact)
        #expect(LinuxLocationManager.accuracyLevel(LocationAccuracy.reduced.rawValue) == .city)
    }

    // MARK: Stopping

    @Test func stopping() {
        let geoClue = self.geoClue()
        var (manager, log) = self.manager(geoClue)
        manager.startUpdatingLocation()
        MainLoop.shared.drain()
        geoClue.locate(latitude: 1, longitude: 2)
        MainLoop.shared.drain()
        manager.stopUpdatingLocation()
        MainLoop.shared.drain()
        #expect(geoClue.active.isEmpty)
        #expect(geoClue.log.last == "Stop")
        geoClue.locate(latitude: 3, longitude: 4)
        MainLoop.shared.drain()
        #expect(log.locations.count == 1)

        // Stopping before GeoClue answers still leaves it stopped.
        manager.startUpdatingLocation()
        manager.stopUpdatingLocation()
        MainLoop.shared.drain()
        #expect(geoClue.active.isEmpty)

        // A manager that goes away deletes its client.
        manager = LinuxLocationManager(delegate: log, bus: geoClue, desktopID: "x")
        MainLoop.shared.drain()
        #expect(geoClue.log.last == "DeleteClient \(client)")
        #expect(geoClue.clients.isEmpty)
        #expect(geoClue.subscriptionCount == 0)
    }

    @Test func heading() {
        let geoClue = self.geoClue()
        let (manager, log) = self.manager(geoClue)
        manager.startUpdatingHeading()
        manager.stopUpdatingHeading()
        MainLoop.shared.drain()
        #expect(log.events == [notDetermined, "fail \(LocationError.headingFailure.rawValue)"])
        #expect(geoClue.calls.isEmpty)
    }

    // MARK: Without GeoClue

    @Test func withoutGeoClue() {
        let geoClue = self.geoClue()
        geoClue.available = false
        #expect(!LinuxLocationManager.isLocationServicesEnabled())
        #expect(LocationPermission().status() == .unavailable)
        let (manager, log) = self.manager(geoClue)
        manager.startUpdatingLocation()
        MainLoop.shared.drain()
        #expect(log.events == [notDetermined, "fail \(LocationError.servicesDisabled.rawValue)"])

        // A request is answered `denied`, as with location off, though
        // it isn't the app's refusal.
        manager.requestWhenInUseAuthorization()
        MainLoop.shared.drain()
        #expect(log.events.last == denied)
        #expect(LinuxLocationManager.authorizationStatus() == LocationAuthorization.denied.rawValue)
        #expect(LocationPermission().status() == .unavailable)
        var answers: [PermissionStatus] = []
        LocationPermission().request { answers.append($0) }
        MainLoop.shared.drain()
        #expect(answers == [.unavailable])

        // GeoClue starting clears it.
        geoClue.available = true
        manager.requestWhenInUseAuthorization()
        MainLoop.shared.drain()
        #expect(LinuxLocationManager.authorizationStatus() == LocationAuthorization.authorizedAlways.rawValue)
        #expect(log.events.last == authorized)

        // GeoClue with no sources has nothing to give.
        geoClue.available = true
        geoClue.availableAccuracy = 0
        #expect(!LinuxLocationManager.isLocationServicesEnabled())
    }

    @Test func theDesktopsSwitchOff() {
        let geoClue = self.geoClue()
        geoClue.refusal = FakeGeoClue.disabled
        let (manager, log) = self.manager(geoClue)
        manager.startUpdatingLocation()
        MainLoop.shared.drain()
        #expect(log.events == [notDetermined, "fail \(LocationError.servicesDisabled.rawValue)"])
        #expect(LinuxLocationManager.authorizationStatus() == LocationAuthorization.notDetermined.rawValue, "not the app's refusal")
    }

    @Test func errors() {
        #expect(LinuxLocationManager.error(FakeGeoClue.missing) == .servicesDisabled)
        #expect(LinuxLocationManager.error(.noServer("no socket")) == .servicesDisabled)
        #expect(LinuxLocationManager.error(BusError(name: "org.freedesktop.DBus.Error.Spawn.ChildExited")) == .servicesDisabled)
        #expect(LinuxLocationManager.error(FakeGeoClue.rejected) == .denied)
        #expect(LinuxLocationManager.error(BusError(name: "org.freedesktop.DBus.Error.AccessDenied",
                                                    message: "'org.example.Maps' disallowed, no agent for UID 1000")) == .denied)
        #expect(LinuxLocationManager.error(FakeGeoClue.disabled) == .servicesDisabled)
        #expect(LinuxLocationManager.error(BusError(name: "org.freedesktop.DBus.Error.Failed")) == .unknown)
    }

    @Test func locationsFromGeoCluesProperties() throws {
        let fix = try #require(LinuxLocationFix([
            "Latitude": .double(10), "Longitude": .double(20), "Accuracy": .double(3),
            "Altitude": .double(-.greatestFiniteMagnitude), "Speed": .double(-1), "Heading": .double(359.5),
        ], now: Date(timeIntervalSince1970: 12)))
        #expect(fix.altitude().isNaN)
        #expect(fix.speed() == -1)
        #expect(fix.course() == 359.5)
        #expect(fix.timestamp() == 12_000, "no Timestamp: now")
        #expect(LinuxLocationFix(["Latitude": .double(1)]) == nil)
        let london = LinuxLocationFix(latitude: 51.5074, longitude: -0.1278, accuracy: 1, milliseconds: 0)
        let paris = LinuxLocationFix(latitude: 48.8566, longitude: 2.3522, accuracy: 1, milliseconds: 0)
        #expect(abs(london.distance(from: paris) - 343_500) < 1_000)
    }

    // MARK: The module

    @Test func moduleRegistersTheContracts() {
        let names = [
            "org.pureswift.location.LocationManager", "org.pureswift.location.LocationManagerDelegate",
            "org.pureswift.location.Location", "org.pureswift.location.Heading",
        ]
        #expect(LinuxLocation.contracts.map(\.name) == names)
        let registrar = Registrar()
        LinuxLocation.register(in: registrar)
        #expect(Set(registrar.names) == Set(names))
        #expect(LinuxLocation.permissionProviders()[.location] is LocationPermission)
    }
}
