import DynamicMedia
import DynamicRuntime
import LinuxHost
import RuntimeCore
import RuntimeHost
import RuntimeMedia
import RuntimeNative

/// The media contracts (`MediaPlayer.md`, `Plan.md` §15): `MediaPlayback`
/// and its delegate, over GStreamer, and the pictures the player's
/// `VideoPlayer` view shows. Main loop only.
///
/// The contract is AppRuntime's `HostMediaPlayback`, which checks each
/// source, finds files through `HostFiles`, and keeps the rules every host
/// shares. This module gives it `playbin`s (`GStreamerEngine`). Without
/// GStreamer installed it has no players, and every load fails with
/// `unavailable`.
public enum LinuxMedia: HostModule {

    public static var contracts: [ContractDescriptor] {
        HostMediaModule.contracts
    }

    public static func register(in registrar: some ContractRegistrar) {
        // A source in the bundle or the app's files is found through
        // `HostFiles`, whether or not the app uses `Files` itself.
        LinuxFiles.configureIfNeeded()
        configure(clock: (registrar as? NativeRuntime)?.runtime.clock)
        HostMediaModule.register(in: registrar)
    }

    /// Points `HostMediaPlayback` at GStreamer, the guest's clock and the
    /// app's capabilities.
    public static func configure(clock: (any HostClock)?) {
        HostMediaPlayback.platform = GStreamer.shared == nil ? nil : platform
        HostMediaPlayback.clock = clock
        HostMediaPlayback.allowsNetwork = networkOverride ?? HostPermissions.declared.contains(.network)
        // The desktop doesn't send an app to the background, and nothing
        // here shows what's playing outside its window yet.
        HostMediaPlayback.allowsBackground = false
    }

    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        HostMediaModule.permissionProviders()
    }

    /// Whether GStreamer loads.
    public static var isAvailable: Bool {
        GStreamer.shared != nil
    }

    /// The engine of the player a `VideoPlayer` node names.
    public static func engine(for identifier: Int32) -> GStreamerEngine? {
        HostMediaPlayback.player(for: identifier)?.engine as? GStreamerEngine
    }

    // MARK: Settings

    /// A pipeline description for the sound, in place of GStreamer's
    /// choice of the desktop's sound server: `fakesink sync=true` for
    /// tests, where there's none.
    nonisolated(unsafe) public static var audioSink: String? = nil

    /// In place of the app's capabilities, for tests: whether URLs play.
    nonisolated(unsafe) public static var networkOverride: Bool? = nil

    nonisolated(unsafe) static let platform = GStreamerPlatform()
}

/// `HostMediaPlayback`'s platform: GStreamer's players, and what its
/// registry can play.
final class GStreamerPlatform: MediaPlatform {

    func makeEngine(for player: HostMediaPlayback) -> any MediaEngine {
        GStreamerEngine(playback: player) ?? UnavailableEngine(playback: player)
    }

    func canPlay(_ mimeType: String) -> MediaSupport {
        guard let gst = GStreamer.shared else { return .no }
        return MediaValues.support(mimeType, reads: { gst.hasElement(GStreamer.readers, accepting: $0) },
                                   decodes: { gst.hasElement(GStreamer.decoders, accepting: $0) })
    }
}

/// A player GStreamer couldn't make: every load fails.
final class UnavailableEngine: MediaEngine {

    private weak var playback: HostMediaPlayback?

    init(playback: HostMediaPlayback) {
        self.playback = playback
    }

    func load(_ source: HostMediaSource) {
        playback?.failed(MediaError(.unavailable, message: "GStreamer has no playbin"))
    }

    func unload() { }
    func play() { }
    func pause() { }
    func seek(to position: Double, completion: @escaping (Bool) -> Void) { completion(false) }
    var currentTime: Double { 0 }
    func setRate(_ rate: Float) { }
    func setVolume(_ volume: Float) { }
    func setMuted(_ muted: Bool) { }
    func setLooping(_ looping: Bool) { }
    func setTimeUpdateInterval(_ seconds: Double) { }
}
