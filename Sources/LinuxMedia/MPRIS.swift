import DBus
import DynamicMedia
import Foundation
import LinuxDBus
import LinuxHost
import RuntimeMedia

/// What's playing, on the session bus as an MPRIS player (`Plan.md` §15):
/// `org.mpris.MediaPlayer2.<app id>`, which the shell shows with its media
/// controls, and whose buttons and media keys come back as
/// `HostMediaPlayback.remote`'s commands. Main loop only.
///
/// The name is owned while the app describes a player, and given up when
/// it stops. Properties are read when the shell asks; what changes is said
/// with `PropertiesChanged` at each report, and a jump in the position with
/// `Seeked`.
final class MPRIS {

    static let root = "org.mpris.MediaPlayer2"

    static let player = "org.mpris.MediaPlayer2.Player"

    static let path = "/org/mpris/MediaPlayer2"

    let bus: Bus

    /// The well-known name.
    let name: String

    /// The app's name, and its desktop entry's (`<id>.desktop`).
    let identity: String

    let desktopEntry: String

    /// The last report, and when it came, on the main loop's clock.
    private(set) var current: HostNowPlaying?

    private var stamp: Int64 = 0

    /// The rate playback goes at when it plays: MPRIS's `Rate` isn't 0
    /// while paused.
    private var rate = 1.0

    /// `artUrl`'s file, for artwork that came as bytes.
    private var artworkFile: String?

    private var artworkData: [UInt8]?

    private var published: [String: DBusMessageArgument] = [:]

    private(set) var isServing = false

    init(bus: Bus, identifier: String, identity: String) {
        self.bus = bus
        // A bus name's elements are letters, digits and underscores.
        let element = String(identifier.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") ? $0 : "_" })
            .split(separator: ".").map { $0.first?.isNumber == true ? "_" + $0 : String($0) }.joined(separator: ".")
        name = Self.root + "." + (element.isEmpty ? "AppRuntime" : element)
        self.identity = identity
        desktopEntry = identifier
    }

    deinit {
        removeArtwork()
    }

    /// Shows what's playing, or, with `nil`, nothing.
    func show(_ nowPlaying: HostNowPlaying?) {
        guard let nowPlaying else {
            stop()
            return
        }
        let previous = current.map { (position: position, at: $0) }
        current = nowPlaying
        stamp = MainLoop.now()
        if nowPlaying.rate > 0 {
            rate = Double(nowPlaying.rate)
        }
        updateArtwork(nowPlaying.artwork)
        if !isServing {
            isServing = true
            published = [:]
            bus.export(Self.path, interfaces)
            bus.requestName(name) { [name] result in
                if case .success(false) = result {
                    HostLog.warning("media: \(name) is another's; what's playing isn't shown")
                } else if case .failure(let error) = result {
                    HostLog.debug("media: no MPRIS: \(error)")
                }
            }
        }
        let properties = changing
        let changed = properties.filter { published[$0.key] != $0.value }
        published = properties
        if !changed.isEmpty, previous != nil {
            bus.emitPropertiesChanged(Self.path, Self.player, changed)
        }
        // A jump: the shell's position moves on its own from the last one
        // it read, at the rate.
        if let previous, previous.at.player == nowPlaying.player, abs(previous.position - nowPlaying.position) > 0.5 {
            bus.emit(Self.path, Self.player, "Seeked", [.int64(Self.microseconds(nowPlaying.position))])
        }
    }

    private func stop() {
        guard isServing else { return }
        isServing = false
        current = nil
        published = [:]
        bus.releaseName(name)
        bus.unexport(Self.path)
        removeArtwork()
    }

    // MARK: Properties

    /// Where playback is now: the last report, moved on at its rate.
    var position: Double {
        guard let current else { return 0 }
        var seconds = current.position
        if current.isPlaying {
            seconds += Double(MainLoop.now() - stamp) / 1e9 * Double(current.rate)
        }
        if let duration = current.duration {
            seconds = min(seconds, duration)
        }
        return max(seconds, 0)
    }

    var playbackStatus: String {
        guard let current else { return "Stopped" }
        return current.isPlaying ? "Playing" : "Paused"
    }

    /// The track's identifier: one per player, since a track's changes
    /// come as the player's.
    var trackID: String {
        "/org/pureswift/AppRuntime/track/\(current?.player ?? 0)"
    }

    var metadata: [String: DBusMessageArgument] {
        guard let current else { return [:] }
        var metadata: [String: DBusMessageArgument] = [
            "mpris:trackid": .path(trackID),
            "xesam:title": .string(current.title),
        ]
        if let artist = current.artist {
            metadata["xesam:artist"] = .stringArray([artist])
        }
        if let album = current.album {
            metadata["xesam:album"] = .string(album)
        }
        if let duration = current.duration {
            metadata["mpris:length"] = .int64(Self.microseconds(duration))
        }
        if let url = artURL {
            metadata["mpris:artUrl"] = .string(url)
        }
        return metadata
    }

    private var artURL: String? {
        switch current?.artwork {
        case .file(let path)?:
            return URL(fileURLWithPath: path).absoluteString
        case .data?:
            return artworkFile.map { URL(fileURLWithPath: $0).absoluteString }
        case nil:
            return nil
        }
    }

    /// The `Player` properties a report can change, as they're published.
    var changing: [String: DBusMessageArgument] {
        let commands = current?.commands ?? []
        return [
            "PlaybackStatus": .string(playbackStatus),
            "Metadata": .vardict(metadata),
            "Rate": .double(rate),
            "CanGoNext": .boolean(commands.contains(.next)),
            "CanGoPrevious": .boolean(commands.contains(.previous)),
            "CanSeek": .boolean(current?.duration != nil),
        ]
    }

    static func microseconds(_ seconds: Double) -> Int64 {
        Int64((seconds * 1e6).rounded())
    }

    // MARK: Artwork

    private func updateArtwork(_ artwork: HostArtwork?) {
        guard case .data(let bytes, let mimeType)? = artwork else {
            removeArtwork()
            return
        }
        guard bytes != artworkData else { return }
        removeArtwork()
        let type = mimeType.lowercased()
        let suffix = type.hasSuffix("png") ? "png" : type.hasSuffix("jpeg") || type.hasSuffix("jpg") ? "jpg" : "image"
        let path = NSTemporaryDirectory() + "/mpris-\(getpid())-\(UUID().uuidString).\(suffix)"
        if FileManager.default.createFile(atPath: path, contents: Data(bytes)) {
            artworkFile = path
            artworkData = bytes
        }
    }

    private func removeArtwork() {
        if let artworkFile {
            try? FileManager.default.removeItem(atPath: artworkFile)
        }
        artworkFile = nil
        artworkData = nil
    }

    // MARK: The object

    private var interfaces: [BusInterface] {
        [
            BusInterface(Self.root, methods: [
                // The app's window isn't the host's to raise, and quitting
                // is the app's.
                BusMethod("Raise") { _ in .success([]) },
                BusMethod("Quit") { _ in .success([]) },
            ], properties: [
                BusProperty("CanQuit", "b") { .boolean(false) },
                BusProperty("CanRaise", "b") { .boolean(false) },
                BusProperty("HasTrackList", "b") { .boolean(false) },
                BusProperty("Identity", "s") { [identity] in .string(identity) },
                BusProperty("DesktopEntry", "s") { [desktopEntry] in .string(desktopEntry) },
                BusProperty("SupportedUriSchemes", "as") { .stringArray([]) },
                BusProperty("SupportedMimeTypes", "as") { .stringArray([]) },
            ]),
            BusInterface(Self.player, methods: [
                BusMethod("Next") { _ in Self.command(.next) },
                BusMethod("Previous") { _ in Self.command(.previous) },
                BusMethod("Pause") { _ in Self.command(.pause) },
                BusMethod("PlayPause") { _ in Self.command(.togglePlayPause) },
                // There's no stopped state to go to: a pause.
                BusMethod("Stop") { _ in Self.command(.pause) },
                BusMethod("Play") { _ in Self.command(.play) },
                BusMethod("Seek", input: "x") { [weak self] arguments in
                    guard let self, let offset = arguments.first?.int64Value else { return .success([]) }
                    return Self.command(.seek(to: self.position + Double(offset) / 1e6))
                },
                BusMethod("SetPosition", input: "ox") { [weak self] arguments in
                    // One for another track is ignored, as MPRIS says.
                    guard let self, arguments.first?.text == self.trackID, let position = arguments.last?.int64Value,
                          position >= 0 else { return .success([]) }
                    return Self.command(.seek(to: Double(position) / 1e6))
                },
                BusMethod("OpenUri", input: "s") { _ in
                    .failure(BusError(name: "org.freedesktop.DBus.Error.NotSupported", message: "the app chooses what it plays"))
                },
            ], properties: [
                BusProperty("PlaybackStatus", "s") { [weak self] in .string(self?.playbackStatus ?? "Stopped") },
                BusProperty("Rate", "d") { [weak self] in .double(self?.rate ?? 1) },
                BusProperty("Metadata", "a{sv}") { [weak self] in .vardict(self?.metadata ?? [:]) },
                BusProperty("Volume", "d") { .double(1) },
                BusProperty("Position", "x") { [weak self] in .int64(Self.microseconds(self?.position ?? 0)) },
                BusProperty("MinimumRate", "d") { .double(0.5) },
                BusProperty("MaximumRate", "d") { .double(2) },
                BusProperty("CanGoNext", "b") { [weak self] in .boolean(self?.current?.commands.contains(.next) ?? false) },
                BusProperty("CanGoPrevious", "b") { [weak self] in .boolean(self?.current?.commands.contains(.previous) ?? false) },
                BusProperty("CanPlay", "b") { [weak self] in .boolean(self?.current != nil) },
                BusProperty("CanPause", "b") { [weak self] in .boolean(self?.current != nil) },
                BusProperty("CanSeek", "b") { [weak self] in .boolean(self?.current?.duration != nil) },
                BusProperty("CanControl", "b") { .boolean(true) },
            ]),
        ]
    }

    /// A button, to the now-playing player; one nothing answers is ignored,
    /// as MPRIS asks.
    private static func command(_ command: HostRemoteCommand) -> Result<[DBusMessageArgument], BusError> {
        HostMediaPlayback.remote(command)
        return .success([])
    }
}
