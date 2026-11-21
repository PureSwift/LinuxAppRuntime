import DBUS
import Foundation
import LinuxHost
import Testing
@testable import LinuxDBus

/// Runs `loop` until `done`, or for `seconds` at most.
func run(_ loop: MainLoop, for seconds: Double = 10, until done: () -> Bool) {
    let deadline = MainLoop.now() + Int64(seconds * 1_000_000_000)
    let timer = loop.schedule(at: deadline) { }
    loop.run { done() || MainLoop.now() >= deadline }
    loop.cancel(timer)
}

/// A bus daemon of its own, where `dbus-daemon` is installed.
final class Daemon {

    static let executable = ["/usr/bin/dbus-daemon", "/bin/dbus-daemon"].first { FileManager.default.isExecutableFile(atPath: $0) }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bus-\(UUID().uuidString)").path

    let process = Process()

    var address: String {
        "unix:path=\(directory)/bus"
    }

    init() throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        process.executableURL = URL(fileURLWithPath: Self.executable!)
        process.arguments = ["--session", "--nofork", "--nopidfile", "--address=\(address)"]
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: directory + "/bus"), Date() < deadline {
            usleep(10_000)
        }
    }

    deinit {
        kill(process.processIdentifier, SIGKILL)
        try? FileManager.default.removeItem(atPath: directory)
    }
}

@Suite struct LinuxDBusTests {

    // MARK: Match rules

    @Test func matchRulesAsTheBusTakesThem() {
        let rule = MatchRule(sender: "org.freedesktop.GeoClue2", path: "/org/freedesktop/GeoClue2/Client/1",
                             interface: "org.freedesktop.GeoClue2.Client", member: "LocationUpdated")
        #expect(rule.description == "type='signal',sender='org.freedesktop.GeoClue2',path='/org/freedesktop/GeoClue2/Client/1',"
            + "interface='org.freedesktop.GeoClue2.Client',member='LocationUpdated'")
        #expect(MatchRule().description == "type='signal'")
        #expect(MatchRule(arg0: "it's").description == "type='signal',arg0='it'\\''s'")
    }

    @Test func matchingSignals() {
        let signal = BusSignal(sender: ":1.7", path: "/a", interface: "org.example.I", member: "Changed", body: [.string("first")])
        #expect(MatchRule().matches(signal))
        #expect(MatchRule(path: "/a", interface: "org.example.I", member: "Changed").matches(signal))
        #expect(!MatchRule(path: "/b").matches(signal))
        #expect(!MatchRule(interface: "org.example.J").matches(signal))
        #expect(!MatchRule(member: "Gone").matches(signal))
        #expect(MatchRule(arg0: "first").matches(signal))
        #expect(!MatchRule(arg0: "second").matches(signal))
        // A unique name is checked here; a well-known one is the bus's to.
        #expect(MatchRule(sender: ":1.7").matches(signal))
        #expect(!MatchRule(sender: ":1.8").matches(signal))
        #expect(MatchRule(sender: "org.example.Service").matches(signal))
    }

    // MARK: Errors and values

    @Test func errors() {
        #expect(BusError(name: "org.freedesktop.DBus.Error.AccessDenied").isAccessDenied)
        #expect(BusError(name: "org.bluez.Error.NotAuthorized").isAccessDenied)
        #expect(BusError(name: "org.freedesktop.DBus.Error.ServiceUnknown").isServiceMissing)
        #expect(BusError(name: "org.freedesktop.DBus.Error.Spawn.ExecFailed").isServiceMissing)
        #expect(BusError.noServer("no socket").isServiceMissing)
        #expect(BusError.disconnected.isServiceMissing)
        #expect(BusError(name: "org.freedesktop.DBus.Error.UnknownProperty").isUnknownMember)
        #expect(!BusError(name: "org.freedesktop.DBus.Error.Failed").isServiceMissing)
        #expect(BusError(name: "a.B", message: "c").description == "a.B: c")
        #expect(BusError(name: "a.B").description == "a.B")
    }

    @Test func values() {
        let variant = DBusValue.variant(DBusVariant(.variant(DBusVariant(.double(1.5)))))
        #expect(variant.contents == .double(1.5))
        #expect(variant.doubleValue == 1.5)
        #expect(DBusValue.uint32(7).doubleValue == 7)
        #expect(DBusValue.uint64(.max).int64Value == nil)
        #expect(DBusValue.objectPath("/a").text == "/a")
        #expect(DBusValue.boolean(true).flag == true)
        #expect(DBusValue.structure([.uint64(1), .uint64(2)]).fields == [.uint64(1), .uint64(2)])
        let dictionary = DBusValue.vardict(["Latitude": .double(1), "Name": .string("x")])
        #expect(dictionary.entries == ["Latitude": .double(1), "Name": .string("x")])
        #expect(DBusValue.string("x").entries.isEmpty)
    }

    // MARK: A bus

    @Test func noBusFailsOnTheMainLoop() {
        let loop = MainLoop()
        let bus = Bus(.address("unix:path=/nonexistent/linux-app-bus"), loop: loop)
        var result: Result<[DBusValue], BusError>?
        bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetId") { result = $0 }
        #expect(result == nil, "never inside the call")
        run(loop) { result != nil }
        guard case .failure(let error)? = result else {
            Issue.record("expected a failure, got \(String(describing: result))")
            return
        }
        #expect(error.isServiceMissing)
        let waited = bus.callAndWait("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetId")
        #expect((try? waited.get()) == nil, "and again, connecting afresh")
    }

    @Test(.enabled(if: Daemon.executable != nil, "needs dbus-daemon"))
    func callsPropertiesAndSignals() throws {
        let daemon = try Daemon()
        let loop = MainLoop()
        let bus = Bus(.address(daemon.address), loop: loop)
        let other = Bus(.address(daemon.address), loop: loop)

        // Waiting, without the main loop.
        let id = try bus.callAndWait("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetId").get()
        #expect(id.first?.text?.count == 32)
        let features = bus.propertyAndWait("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "Features")
        #expect((try? features.get()) != nil)

        // A reply on the main loop.
        var names: [String]?
        bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ListNames") { result in
            names = (try? result.get())?.first.map { value in
                if case .array(let names) = value { return names.compactMap(\.text) }
                return []
            }
        }
        run(loop) { names != nil }
        #expect(names?.contains("org.freedesktop.DBus") == true)

        var all: [String: DBusValue]?
        bus.properties("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus") { all = try? $0.get() }
        run(loop) { all != nil }
        #expect(all?["Features"] != nil)

        // An error.
        var missing: BusError?
        bus.call("org.example.Nobody", "/", "org.example.Nobody", "Hello") { result in
            if case .failure(let error) = result { missing = error }
        }
        run(loop) { missing != nil }
        #expect(missing?.isServiceMissing == true)

        // A signal, by match rule: the other connection takes a name.
        var signals: [BusSignal] = []
        let rule = MatchRule(sender: "org.freedesktop.DBus", interface: "org.freedesktop.DBus", member: "NameOwnerChanged",
                             arg0: "org.example.LinuxDBusTests")
        let subscription = bus.subscribe(rule) { signals.append($0) }
        var unrelated = 0
        bus.subscribe(MatchRule(member: "PropertiesChanged")) { _ in unrelated += 1 }
        // Requests go in order, so the rule is in place once this answers.
        _ = bus.callAndWait("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetId")
        let owner = try other.callAndWait("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                                          [.string("org.example.LinuxDBusTests"), .uint32(0)]).get()
        #expect(owner.first == .uint32(1), "the primary owner")
        run(loop) { !signals.isEmpty }
        #expect(signals.first?.member == "NameOwnerChanged")
        #expect(signals.first?.body.first?.text == "org.example.LinuxDBusTests")
        #expect(signals.first?.body.last?.text?.hasPrefix(":") == true)
        #expect(unrelated == 0)
        bus.unsubscribe(subscription)
    }
}
