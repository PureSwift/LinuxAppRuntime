import DBus
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

    let directory: String

    let process = Process()

    var address: String {
        "unix:path=\(directory)/bus"
    }

    /// In `directory`, if one's given: another daemon's, once it's gone.
    init(directory: String? = nil) throws {
        self.directory = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("bus-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: self.directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: self.directory + "/bus")
        process.executableURL = URL(fileURLWithPath: Self.executable!)
        process.arguments = ["--session", "--nofork", "--nopidfile", "--address=\(address)"]
        // Not the runner's: a daemon outliving a crashed runner would keep
        // its output open, and `swift test` waiting.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: self.directory + "/bus"), Date() < deadline {
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
        let variant = DBusMessageArgument.variant(.init(.variant(.init(.double(1.5)))))
        #expect(variant.contents == .double(1.5))
        #expect(variant.doubleValue == 1.5)
        #expect(DBusMessageArgument.uint32(7).doubleValue == 7)
        #expect(DBusMessageArgument.uint64(.max).int64Value == nil)
        #expect(DBusMessageArgument.path("/a").text == "/a")
        #expect(DBusMessageArgument.boolean(true).flag == true)
        #expect(DBusMessageArgument.structure([.uint64(1), .uint64(2)]).fields == [.uint64(1), .uint64(2)])
        #expect(DBusMessageArgument.stringArray(["a", "b"]).elements == [.string("a"), .string("b")])
        let dictionary = DBusMessageArgument.vardict(["Latitude": .double(1), "Name": .string("x")])
        #expect(dictionary.entries == ["Latitude": .double(1), "Name": .string("x")])
        #expect(DBusMessageArgument.string("x").entries.isEmpty)
        // Typed, though empty.
        #expect(String([DBusMessageArgument.vardict([:]), .stringArray([]), dictionary].map(\.type)) == "a{sv}asa{sv}")
    }

    @Test func signatures() throws {
        let message = try Bus.message("org.example", "/a", "org.example.I", "M", [.string("x"), .vardict([:])], signature: "sa{sv}").get()
        #expect(message.arguments.count == 2)
        #expect(message.destination?.rawValue == "org.example")
        guard case .failure(let error) = Bus.message("org.example", "/a", "org.example.I", "M", [.string("x")], signature: "u") else {
            Issue.record("the wrong signature was taken")
            return
        }
        #expect(error.name == "org.freedesktop.DBus.Error.InvalidSignature")
        guard case .failure(let invalid) = Bus.message("org.example", "a", "org.example.I", "M", [], signature: nil) else {
            Issue.record("an invalid path was taken")
            return
        }
        #expect(invalid.name == "org.freedesktop.DBus.Error.InvalidArgs")
    }

    // MARK: A bus

    @Test func noBusFailsOnTheMainLoop() {
        let loop = MainLoop()
        let bus = Bus(.address("unix:path=/nonexistent/linux-app-bus"), loop: loop)
        var result: Result<[DBusMessageArgument], BusError>?
        var disconnected: [BusSignal] = []
        bus.subscribe(.disconnected) { disconnected.append($0) }
        bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetId") { result = $0 }
        #expect(result == nil, "never inside the call")
        run(loop) { result != nil && !disconnected.isEmpty }
        #expect(disconnected.count == 1, "the local signal, for the connection that couldn't be made")
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

        var all: [String: DBusMessageArgument]?
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

    @Test(.enabled(if: Daemon.executable != nil, "needs dbus-daemon"))
    func reconnectsWithItsMatchRules() throws {
        var daemon: Daemon? = try Daemon()
        let directory = daemon!.directory
        let loop = MainLoop()
        let bus = Bus(.address(daemon!.address), loop: loop)
        var signals: [BusSignal] = []
        bus.subscribe(MatchRule(sender: "org.freedesktop.DBus", interface: "org.freedesktop.DBus", member: "NameOwnerChanged",
                                arg0: "org.example.LinuxDBusTests.Again")) { signals.append($0) }
        var disconnected = 0
        bus.subscribe(.disconnected) { _ in disconnected += 1 }
        _ = try bus.callAndWait("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetId").get()

        // The daemon goes, and another comes at the same address.
        daemon = nil
        run(loop) { disconnected > 0 }
        #expect(disconnected == 1)
        let again = try Daemon(directory: directory)
        defer { withExtendedLifetime(again) { } }

        // The next request connects again, and the rule is added again.
        _ = try bus.callAndWait("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetId").get()
        run(loop, for: 0.2) { false }
        _ = bus.callAndWait("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetId")
        let other = Bus(.address(again.address), loop: loop)
        _ = try other.callAndWait("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                                  [.string("org.example.LinuxDBusTests.Again"), .uint32(0)]).get()
        run(loop) { !signals.isEmpty }
        #expect(signals.first?.body.first?.text == "org.example.LinuxDBusTests.Again")
    }

    @Test(.enabled(if: Daemon.executable != nil, "needs dbus-daemon"))
    func servesObjectsAndOwnsNames() throws {
        let daemon = try Daemon()
        let loop = MainLoop()
        let bus = Bus(.address(daemon.address), loop: loop)
        let other = Bus(.address(daemon.address), loop: loop)
        var volume = 0.5
        var greeted: [String] = []
        bus.export("/org/example/Thing", [BusInterface("org.example.Thing", methods: [
            BusMethod("Greet", input: "s", output: "s") { arguments in
                greeted.append(arguments.first?.text ?? "")
                return .success([.string("Hello, \(arguments.first?.text ?? "")")])
            },
            BusMethod("Refuse") { _ in .failure(BusError(name: "org.example.Error.No", message: "no")) },
        ], properties: [
            BusProperty("Name", "s") { .string("thing") },
            BusProperty("Volume", "d", get: { .double(volume) }, set: { value in
                volume = value.doubleValue ?? volume
                return .success(())
            }),
        ])])
        var owned: Bool?
        bus.requestName("org.example.Served") { owned = try? $0.get() }
        run(loop) { owned != nil }
        #expect(owned == true)

        func call(_ method: String, _ arguments: [DBusMessageArgument] = [], interface: String = "org.example.Thing")
            -> Result<[DBusMessageArgument], BusError>? {
            var result: Result<[DBusMessageArgument], BusError>?
            other.call("org.example.Served", "/org/example/Thing", interface, method, arguments) { result = $0 }
            run(loop) { result != nil }
            return result
        }
        // Answered on the main loop, which the handlers run on.
        #expect(try call("Greet", [.string("bus")])?.get().first?.text == "Hello, bus")
        #expect(greeted == ["bus"])
        if case .failure(let error)? = call("Refuse") {
            #expect(error.name == "org.example.Error.No")
        } else {
            Issue.record("Refuse succeeded")
        }

        var all: [String: DBusMessageArgument]?
        other.properties("org.example.Served", "/org/example/Thing", "org.example.Thing") { all = try? $0.get() }
        run(loop) { all != nil }
        #expect(all?["Name"]?.text == "thing" && all?["Volume"]?.doubleValue == 0.5)
        var set: Result<Void, BusError>?
        other.setProperty("org.example.Served", "/org/example/Thing", "org.example.Thing", "Volume", .double(0.8)) { set = $0 }
        run(loop) { set != nil }
        #expect(volume == 0.8)
        var introspected: String?
        if case .success(let values)? = call("Introspect", interface: "org.freedesktop.DBus.Introspectable") {
            introspected = values.first?.text
        }
        #expect(introspected?.contains("org.example.Thing") == true)

        // Signals from the object.
        var changes: [BusSignal] = []
        other.subscribe(MatchRule(path: "/org/example/Thing", member: "PropertiesChanged")) { changes.append($0) }
        var pings: [BusSignal] = []
        other.subscribe(MatchRule(interface: "org.example.Thing", member: "Pinged")) { pings.append($0) }
        _ = call("Greet", [.string("again")])
        bus.emitPropertiesChanged("/org/example/Thing", "org.example.Thing", ["Volume": .double(0.8)])
        bus.emit("/org/example/Thing", "org.example.Thing", "Pinged", [.int64(7)])
        run(loop) { !changes.isEmpty && !pings.isEmpty }
        #expect(changes.first?.body.first?.text == "org.example.Thing")
        #expect(changes.first?.body.dropFirst().first?.entries["Volume"]?.doubleValue == 0.8)
        #expect(pings.first?.body.first?.int64Value == 7)

        // Given up.
        var released = false
        bus.releaseName("org.example.Served") { _ in released = true }
        run(loop) { released }
        bus.unexport("/org/example/Thing")
        var has: Bool?
        other.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner",
                   [.string("org.example.Served")]) { has = (try? $0.get())?.first?.flag }
        run(loop) { has != nil }
        #expect(has == false)
    }
}
