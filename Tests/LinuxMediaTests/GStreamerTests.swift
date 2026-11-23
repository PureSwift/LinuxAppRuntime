import DynamicMedia
import Foundation
import LinuxHost
import RuntimeMedia
import Testing
@testable import LinuxMedia

/// The contract over real GStreamer: `HostMediaPlayback` and its engine,
/// with sound going nowhere, and files the tests make.
@Suite(.serialized, .enabled(if: LinuxMedia.isAvailable, "GStreamer isn't installed"))
final class GStreamerTests {

    let directory: String

    init() throws {
        directory = NSTemporaryDirectory() + "/linux-media-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        // No sound server here; the clock still runs.
        LinuxMedia.audioSink = "fakesink sync=true"
        LinuxMedia.networkOverride = false
        LinuxMedia.configure(clock: nil)
        // The tests' files are absolute paths.
        HostMediaPlayback.findFile = { _, path in path }
    }

    deinit {
        HostMediaPlayback.reset()
        LinuxMedia.audioSink = nil
        LinuxMedia.networkOverride = nil
        try? FileManager.default.removeItem(atPath: directory)
    }

    // MARK: Helpers

    /// Runs the main loop until `done`, for up to `seconds`: a timer wakes
    /// it then, since nothing else may.
    func run(for seconds: Double = 5, until done: () -> Bool) {
        var expired = false
        let timer = MainLoop.shared.schedule(after: Int64(seconds * 1e9)) { expired = true }
        defer { MainLoop.shared.cancel(timer) }
        MainLoop.shared.run { done() || expired }
    }

    func wait(_ seconds: Double) {
        run(for: seconds) { false }
    }

    /// A mono 16-bit WAV of silence.
    static func wav(seconds: Double, rate: Int = 8000) -> [UInt8] {
        let samples = Int(Double(rate) * seconds)
        var bytes: [UInt8] = []
        func append(_ value: UInt32, _ size: Int) {
            for index in 0..<size { bytes.append(UInt8(truncatingIfNeeded: value >> (8 * index))) }
        }
        bytes += Array("RIFF".utf8); append(UInt32(36 + samples * 2), 4); bytes += Array("WAVE".utf8)
        bytes += Array("fmt ".utf8); append(16, 4); append(1, 2); append(1, 2); append(UInt32(rate), 4)
        append(UInt32(rate * 2), 4); append(2, 2); append(16, 2)
        bytes += Array("data".utf8); append(UInt32(samples * 2), 4)
        bytes += [UInt8](repeating: 0, count: samples * 2)
        return bytes
    }

    func file(_ name: String, _ bytes: [UInt8]) -> String {
        let path = directory + "/" + name
        FileManager.default.createFile(atPath: path, contents: Data(bytes))
        return path
    }

    /// A second of 64 by 48 pictures, ten a second, as Motion JPEG in AVI,
    /// which GStreamer makes.
    func video() throws -> String {
        let path = directory + "/video.avi"
        let gst = try #require(GStreamer.shared)
        let description = "videotestsrc num-buffers=10 ! video/x-raw,width=64,height=48,framerate=10/1 ! jpegenc ! avimux ! filesink location=\(path)"
        let pipeline = try #require(gst.parseLaunch(description, nil))
        defer {
            _ = gst.elementSetState(pipeline, GStreamer.null)
            gst.objectUnref(pipeline)
        }
        let bus = try #require(gst.elementGetBus(pipeline))
        defer { gst.objectUnref(bus) }
        _ = gst.elementSetState(pipeline, GStreamer.playing)
        var finished = false
        run {
            while !finished, let message = gst.busPop(bus) {
                let type = gst.type(of: message)
                finished = type == GStreamer.messageEOS || type == GStreamer.messageError
                gst.miniObjectUnref(message)
            }
            return finished
        }
        #expect(finished)
        return path
    }

    // MARK: Sound

    @Test func aFileLoadsPlaysAndEnds() {
        let path = file("second.wav", Self.wav(seconds: 1))
        let delegate = RecordingPlaybackDelegate()
        let player = HostMediaPlayback.make(delegate)
        player.setTimeUpdateInterval(0.1)
        player.loadFile(1, path: path)
        // Remembered until it has loaded.
        player.play()
        run { delegate.ended }
        let loaded = delegate.loaded.first
        #expect(loaded.map { abs($0.duration - 1) < 0.05 } == true, "\(String(describing: loaded))")
        #expect(loaded?.hasAudio == true && loaded?.hasVideo == false && loaded?.width == 0)
        #expect(delegate.states.prefix(3).map(\.state) == [1, 2, 3], "loading, paused, playing")
        #expect(delegate.states.last.map { $0.state == 2 && $0.reason == 4 } == true, "paused at the end")
        #expect(delegate.times.count >= 3, "times while playing")
        #expect(delegate.times.contains { $0.rate == 1 })
        #expect(delegate.failures.isEmpty)
    }

    @Test func pausingAndSeeking() {
        let path = file("long.wav", Self.wav(seconds: 3))
        let delegate = RecordingPlaybackDelegate()
        let player = HostMediaPlayback.make(delegate)
        player.loadFile(1, path: path)
        player.play()
        run { delegate.states.last?.state == 3 }
        wait(0.3)
        player.pause()
        run { delegate.states.last?.state == 2 }
        #expect(delegate.states.last?.reason == 0, "the app asked")
        let paused = player.engine?.currentTime ?? 0
        #expect(paused > 0.1 && paused < 1.5, "\(paused)")
        player.seek(2, request: 7)
        run { !delegate.seeks.isEmpty }
        #expect(delegate.seeks.first.map { $0.request == 7 && $0.finished } == true)
        #expect(delegate.times.last.map { abs($0.position - 2) < 0.05 && $0.rate == 0 } == true, "\(String(describing: delegate.times.last))")
        // Two seeks at once: the first is replaced.
        player.seek(0.5, request: 8)
        player.seek(1, request: 9)
        run { delegate.seeks.count == 3 }
        #expect(delegate.seeks.dropFirst().map(\.request) == [8, 9])
        #expect(delegate.seeks.dropFirst().map(\.finished) == [false, true])
        #expect(delegate.failures.isEmpty)
    }

    @Test func theControlsPauseAsTheUser() throws {
        let path = file("controls.wav", Self.wav(seconds: 2))
        let delegate = RecordingPlaybackDelegate()
        let player = HostMediaPlayback.make(delegate)
        player.loadFile(1, path: path)
        run { delegate.states.last?.state == 2 }
        let engine = try #require(player.engine as? GStreamerEngine)
        engine.userPlay()
        run { delegate.states.last?.state == 3 }
        engine.userPause()
        run { delegate.states.last?.state == 2 }
        #expect(delegate.states.last?.reason == 1, "the user's")
        engine.userSeek(to: 1.5)
        run { delegate.times.last.map { abs($0.position - 1.5) < 0.05 } == true }
        #expect(delegate.seeks.isEmpty, "no request of the guest's")
    }

    @Test func loopingStartsAgain() {
        let path = file("loop.wav", Self.wav(seconds: 0.4))
        let delegate = RecordingPlaybackDelegate()
        let player = HostMediaPlayback.make(delegate)
        player.setLooping(true)
        player.loadFile(1, path: path)
        player.play()
        wait(1.3)
        #expect(!delegate.ended, "looping")
        #expect(delegate.states.last?.state == 3)
        player.setLooping(false)
        run { delegate.ended }
        #expect(delegate.ended)
    }

    @Test func rateIsReported() {
        let path = file("rate.wav", Self.wav(seconds: 3))
        let delegate = RecordingPlaybackDelegate()
        let player = HostMediaPlayback.make(delegate)
        player.loadFile(1, path: path)
        player.play()
        run { delegate.states.last?.state == 3 }
        player.setRate(2)
        let start = player.engine?.currentTime ?? 0
        wait(0.5)
        let advanced = (player.engine?.currentTime ?? 0) - start
        #expect(delegate.times.contains { $0.rate == 2 })
        #expect(advanced > 0.7, "twice as fast: \(advanced)")
    }

    @Test func bytesPlayAsAFile() {
        let delegate = RecordingPlaybackDelegate()
        let player = HostMediaPlayback.make(delegate)
        player.loadData(Self.wav(seconds: 0.5), mimeType: "audio/wav")
        run { !delegate.loaded.isEmpty || !delegate.failures.isEmpty }
        #expect(delegate.loaded.first.map { abs($0.duration - 0.5) < 0.05 } == true)
        player.unload()
        #expect(delegate.states.last?.state == 0)
    }

    // MARK: Failures

    @Test func whatIsntMediaFails() {
        let path = file("noise.wav", Array("this is not a sound".utf8))
        let delegate = RecordingPlaybackDelegate()
        let player = HostMediaPlayback.make(delegate)
        player.loadFile(1, path: path)
        run { !delegate.failures.isEmpty }
        #expect(delegate.failures.first?.code == MediaError.Code.unsupportedFormat.rawValue, "\(delegate.failures)")
        #expect(delegate.states.last?.state == 5)
    }

    @Test func aMissingFileIsntFound() {
        let delegate = RecordingPlaybackDelegate()
        let player = HostMediaPlayback.make(delegate)
        player.loadFile(1, path: directory + "/nothing.wav")
        run { !delegate.failures.isEmpty }
        #expect(delegate.failures.first?.code == MediaError.Code.notFound.rawValue, "\(delegate.failures)")
    }

    @Test func urlsNeedTheNetwork() {
        let delegate = RecordingPlaybackDelegate()
        let player = HostMediaPlayback.make(delegate)
        player.loadURL("https://example.com/song.mp3")
        #expect(delegate.failures.first?.code == MediaError.Code.notPermitted.rawValue)
    }

    // MARK: Pictures

    @Test func aVideoHasItsSizeAndPictures() throws {
        let path = try video()
        let delegate = RecordingPlaybackDelegate()
        let player = HostMediaPlayback.make(delegate)
        player.loadFile(1, path: path)
        run { !delegate.loaded.isEmpty || !delegate.failures.isEmpty }
        let loaded = try #require(delegate.loaded.first, "\(delegate.failures)")
        #expect(loaded.width == 64 && loaded.height == 48 && loaded.hasVideo && !loaded.hasAudio)
        #expect(abs(loaded.duration - 1) < 0.15, "\(loaded.duration)")
        let engine = try #require(LinuxMedia.engine(for: player.identifier()))
        let first = try #require(engine.frame, "the preroll's picture")
        #expect(first.width == 64 && first.height == 48 && first.data.count == 64 * 48 * 4)
        var shown = 0
        engine.display = { _ in shown += 1 }
        #expect(shown == 1, "what's there, at once")
        player.play()
        run { delegate.ended }
        #expect(shown >= 5, "pictures as it plays: \(shown)")
        // Seeking while paused shows where it landed.
        shown = 0
        player.seek(0.5, request: 1)
        run { !delegate.seeks.isEmpty }
        #expect(shown == 1)
        engine.display = nil
    }

    @Test func whatGStreamerPlays() {
        #expect(HostMediaPlayback.canPlay("audio/wav") == MediaSupport.probably.rawValue)
        #expect(HostMediaPlayback.canPlay("audio/mpeg") == MediaSupport.probably.rawValue)
        #expect(HostMediaPlayback.canPlay("video/mp4") != MediaSupport.no.rawValue)
        #expect(HostMediaPlayback.canPlay("application/x-nothing-plays-this") == MediaSupport.no.rawValue)
    }
}

/// What a player tells the guest.
final class RecordingPlaybackDelegate: MediaPlaybackDelegate {

    var loaded: [(duration: Double, width: Int32, height: Int32, hasAudio: Bool, hasVideo: Bool)] = []

    var states: [(state: Int32, reason: Int32)] = []

    var times: [(position: Double, rate: Float)] = []

    var buffers: [Double] = []

    var seeks: [(request: Int32, finished: Bool)] = []

    var ended = false

    var failures: [(code: Int32, message: String)] = []

    func didLoad(_ duration: Double, width: Int32, height: Int32, hasAudio: Bool, hasVideo: Bool) {
        loaded.append((duration, width, height, hasAudio, hasVideo))
    }

    func didChangeState(_ state: Int32, reason: Int32) { states.append((state, reason)) }

    func didChangeTime(_ position: Double, timestamp: Int64, rate: Float) { times.append((position, rate)) }

    func didChangeBuffer(_ seconds: Double) { buffers.append(seconds) }

    func didSeek(_ request: Int32, finished: Bool) { seeks.append((request, finished)) }

    func didEnd() { ended = true }

    func didFail(_ code: Int32, message: String) { failures.append((code, message)) }

    func didReceiveCommand(_ command: Int32) { }
}
