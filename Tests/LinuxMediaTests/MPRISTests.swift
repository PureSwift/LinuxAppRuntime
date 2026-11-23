import DBus
import DynamicMedia
import Foundation
import LinuxDBus
import LinuxHost
import RuntimeHost
import RuntimeMedia
import Testing
@testable import LinuxMedia

/// A bus daemon of its own, where `dbus-daemon` is installed.
final class SessionDaemon {

    static let executable = ["/usr/bin/dbus-daemon", "/bin/dbus-daemon"].first { FileManager.default.isExecutableFile(atPath: $0) }

    let directory = NSTemporaryDirectory() + "/bus-\(UUID().uuidString)"

    let process = Process()

    var address: String {
        "unix:path=\(directory)/bus"
    }

    init() throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        process.executableURL = URL(fileURLWithPath: Self.executable!)
        process.arguments = ["--session", "--nofork", "--nopidfile", "--address=\(address)"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
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

// In GStreamerTests' suite, which runs one at a time: both use
// `HostMediaPlayback`'s players.
extension GStreamerTests {

    @Test(.enabled(if: SessionDaemon.executable != nil, "needs dbus-daemon"))
    func whatsPlayingIsAnMPRISPlayer() throws {
        let daemon = try SessionDaemon()
        LinuxBundle.info = AppInfo(identifier: "org.pureswift.MediaTests", abiVersion: 0)
        LinuxMedia.nowPlayingBus = Bus(.address(daemon.address))
        defer {
            LinuxMedia.platform.reset()
            LinuxMedia.nowPlayingBus = nil
        }
        let shell = Bus(.address(daemon.address))
        let name = "org.mpris.MediaPlayer2.org.pureswift.MediaTests"

        func call(_ interface: String, _ method: String, _ arguments: [DBusMessageArgument] = []) -> Result<[DBusMessageArgument], BusError>? {
            var result: Result<[DBusMessageArgument], BusError>?
            shell.call(name, MPRIS.path, interface, method, arguments) { result = $0 }
            run { result != nil }
            return result
        }
        func properties(_ interface: String = MPRIS.player) -> [String: DBusMessageArgument] {
            var all: [String: DBusMessageArgument]?
            shell.properties(name, MPRIS.path, interface) { all = try? $0.get() }
            run { all != nil }
            return all ?? [:]
        }
        var changes: [[String: DBusMessageArgument]] = []
        shell.subscribe(MatchRule(path: MPRIS.path, member: "PropertiesChanged")) { signal in
            changes.append(signal.body.dropFirst().first?.entries ?? [:])
        }
        var seeked: [Int64] = []
        shell.subscribe(MatchRule(interface: MPRIS.player, member: "Seeked")) { seeked.append($0.body.first?.int64Value ?? -1) }

        let path = file("song.wav", Self.wav(seconds: 10))
        let delegate = RecordingPlaybackDelegate()
        let player = HostMediaPlayback.make(delegate)
        player.loadFile(1, path: path)
        run { delegate.states.last?.state == 2 }
        player.setNowPlaying("Morning", artist: "The Examples", album: "Examples")
        player.setRemoteCommands(MediaRemoteCommands([.next, .previous]).rawValue, skipBackward: 0, skipForward: 0)

        // What the shell reads.
        var owner: Bool?
        shell.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", [.string(name)]) {
            owner = (try? $0.get())?.first?.flag
        }
        run { owner != nil }
        #expect(owner == true)
        let root = properties(MPRIS.root)
        #expect(root["DesktopEntry"]?.text == "org.pureswift.MediaTests" && root["Identity"]?.text == "MediaTests")
        let state = properties()
        #expect(state["PlaybackStatus"]?.text == "Paused")
        #expect(state["CanGoNext"]?.flag == true && state["CanSeek"]?.flag == true)
        let metadata = state["Metadata"]?.entries ?? [:]
        #expect(metadata["xesam:title"]?.text == "Morning" && metadata["xesam:album"]?.text == "Examples")
        #expect(metadata["xesam:artist"]?.elements?.first?.text == "The Examples")
        #expect(metadata["mpris:length"]?.int64Value.map { abs($0 - 10_000_000) < 50_000 } == true)
        let track = try #require(metadata["mpris:trackid"]?.text)

        // Its buttons: play, from the shell.
        _ = call(MPRIS.player, "Play")
        run { delegate.states.last?.state == 3 && changes.contains { $0["PlaybackStatus"]?.text == "Playing" } }
        #expect(delegate.states.last?.state == 3)
        #expect(changes.contains { $0["PlaybackStatus"]?.text == "Playing" })
        wait(0.3)
        let position = properties()["Position"]?.int64Value ?? 0
        #expect(position > 150_000 && position < 1_500_000, "moved on: \(position)")

        // Seeking there, which says where it went.
        _ = call(MPRIS.player, "SetPosition", [.path(track), .int64(2_000_000)])
        run { !seeked.isEmpty }
        #expect(seeked.first.map { abs($0 - 2_000_000) < 100_000 } == true, "\(seeked)")
        // Another track's is ignored.
        _ = call(MPRIS.player, "SetPosition", [.path("/org/example/other"), .int64(0)])

        // Next is the app's; pause is the user's.
        _ = call(MPRIS.player, "Next")
        run { delegate.commands == [1] }
        #expect(delegate.commands == [1])
        _ = call(MPRIS.player, "PlayPause")
        run { delegate.states.last?.state == 2 }
        #expect(delegate.states.last.map { $0.state == 2 && $0.reason == 1 } == true, "the user's pause")
        if case .failure(let error)? = call(MPRIS.player, "OpenUri", [.string("https://example.com")]) {
            #expect(error.name == "org.freedesktop.DBus.Error.NotSupported")
        } else {
            Issue.record("OpenUri succeeded")
        }

        // Nothing described: the name goes.
        player.setNowPlaying("", artist: nil, album: nil)
        wait(0.3)
        owner = nil
        shell.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", [.string(name)]) {
            owner = (try? $0.get())?.first?.flag
        }
        run { owner != nil }
        #expect(owner == false)
    }

    @Test func mprisNamesAreBusNames() {
        let bus = Bus(.address("unix:path=/nonexistent"))
        #expect(MPRIS(bus: bus, identifier: "org.example.My-App", identity: "").name == "org.mpris.MediaPlayer2.org.example.My_App")
        #expect(MPRIS(bus: bus, identifier: "com.3d.viewer", identity: "").name == "org.mpris.MediaPlayer2.com._3d.viewer")
        #expect(MPRIS(bus: bus, identifier: "", identity: "").name == "org.mpris.MediaPlayer2.AppRuntime")
    }
}
