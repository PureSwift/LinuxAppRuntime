import DynamicMedia
import Foundation
import LinuxHost
import RuntimeMedia

/// One picture of a video: RGBA, `width * 4` bytes a row.
public struct VideoFrame: Sendable {

    public var data: Data

    public var width: Int

    public var height: Int
}

/// `HostMediaPlayback`'s engine: a GStreamer `playbin`, one source at a
/// time (`Plan.md` §15). Main loop only.
///
/// GStreamer decodes, keeps time and syncs sound to picture on its own
/// threads. While there's a source, the main loop polls the pipeline's bus
/// for what happened, and reports it to the `HostMediaPlayback` this was
/// made for; a `VideoPlayer` view that shows it gets the latest picture at
/// each turn.
public final class GStreamerEngine: MediaEngine {

    private let gst: GStreamer

    private weak var playback: HostMediaPlayback?

    /// The `playbin`, and the `appsink` its pictures go to.
    private let pipeline: GStreamer.Pointer

    private let frames: GStreamer.Pointer?

    private let bus: GStreamer.Pointer?

    /// What was last reported: `nil` while a source loads, and without one.
    private var reported: MediaState?

    /// Whether a source is loading.
    private var loading = false

    /// The state asked of the pipeline: paused or playing.
    private var target = GStreamer.paused

    /// A pause this engine asked for, rather than the view's controls.
    private var expectsPause = false

    /// Waiting for data: the pipeline is paused while `target` is playing.
    private var buffering = false

    /// At the end, and not looping: playing starts again from the start.
    private var atEnd = false

    private var isNetwork = false

    private var rate: Float = 1

    private var looping = false

    private var interval: Int64 = 500_000_000

    private var lastTime: Int64 = 0

    private var lastBuffer: Double?

    private var seekCompletion: ((Bool) -> Void)?

    private var duration: Double?

    /// `loadData`'s bytes, as a file GStreamer reads.
    private var temporaryFile: String?

    private var timer: MainLoop.TimerToken?

    /// How often the main loop polls while there's a source.
    static let pollInterval: Int64 = 10_000_000

    /// The picture's size in pixels; zero for sound alone.
    public private(set) var videoSize = (width: 0, height: 0)

    /// The latest picture, while a view shows this player, and the one
    /// shown when playback last stopped.
    public private(set) var frame: VideoFrame?

    /// Called with each new picture while a view shows this player.
    public var display: ((VideoFrame) -> Void)? {
        didSet {
            if display != nil, let frame {
                display?(frame)
            }
        }
    }

    /// Called when what the player's controls show changes: whether it's
    /// playing, its time, its duration.
    public var changed: (() -> Void)?

    init?(playback: HostMediaPlayback) {
        guard let gst = GStreamer.shared, let playbin = gst.elementFactoryMake("playbin", nil) else {
            return nil
        }
        self.gst = gst
        self.playback = playback
        pipeline = gst.objectRefSink(playbin) ?? playbin
        // Pictures as RGBA, square pixels, at most one waiting: one that
        // isn't taken in time is dropped, and decoding never waits for the
        // main loop.
        let description = "videoconvert ! videoscale ! appsink name=frames max-buffers=1 drop=true enable-last-sample=false "
            + "caps=\"video/x-raw,format=RGBA,pixel-aspect-ratio=1/1\""
        var error: GStreamer.Pointer?
        if let sink = gst.parseBinFromDescription(description, 1, &error) {
            frames = gst.binGetByName(sink, "frames")
            gst.set(pipeline, "video-sink", object: sink)
        } else {
            frames = nil
            HostLog.error("media: no picture sink: \(error.map { GStreamer.message(of: $0) } ?? "")")
            if let error { gst.errorFree(error) }
        }
        if let audio = LinuxMedia.audioSink, let sink = gst.parseBinFromDescription(audio, 1, nil) {
            gst.set(pipeline, "audio-sink", object: sink)
        }
        // The contract's rates keep the pitch.
        if let tempo = gst.elementFactoryMake("scaletempo", nil) {
            gst.set(pipeline, "audio-filter", object: tempo)
        }
        bus = gst.elementGetBus(pipeline)
    }

    deinit {
        stopPolling()
        _ = gst.elementSetState(pipeline, GStreamer.null)
        if let frames { gst.objectUnref(frames) }
        if let bus { gst.objectUnref(bus) }
        gst.objectUnref(pipeline)
        removeTemporaryFile()
    }

    // MARK: Loading

    public func load(_ source: HostMediaSource) {
        clear()
        let uri: String
        switch source {
        case .url(let url):
            uri = url
            isNetwork = true
        case .file(let path):
            guard let found = fileURI(path) else {
                playback?.failed(MediaError(.notFound, message: "not a path GStreamer opens"))
                return
            }
            uri = found
        case .data(let bytes, let mimeType):
            let path = NSTemporaryDirectory() + "/media-\(UUID().uuidString).\(MediaValues.fileExtension(mimeType))"
            guard FileManager.default.createFile(atPath: path, contents: Data(bytes)), let found = fileURI(path) else {
                playback?.failed(MediaError(.unavailable, message: "couldn't keep the data"))
                return
            }
            temporaryFile = path
            uri = found
        }
        gst.set(pipeline, "uri", string: uri)
        loading = true
        target = GStreamer.paused
        startPolling()
        // Paused at the start: GStreamer prerolls, then says so.
        switch gst.elementSetState(pipeline, GStreamer.paused) {
        case GStreamer.changeSuccess:
            finishLoading()
        case GStreamer.changeNoPreroll:
            // Live: nothing to preroll, and no duration.
            finishLoading(live: true)
        case GStreamer.changeFailure:
            // The bus says why.
            poll()
            if loading {
                fail(MediaError(.unknown, message: "GStreamer didn't open the source"))
            }
        default:
            break
        }
    }

    public func unload() {
        clear()
    }

    private func clear() {
        stopPolling()
        _ = gst.elementSetState(pipeline, GStreamer.null)
        // What the last source left on the bus is of no interest now.
        if let bus {
            while let message = gst.busPop(bus) {
                gst.miniObjectUnref(message)
            }
        }
        completeSeek(false)
        reported = nil
        loading = false
        target = GStreamer.paused
        expectsPause = false
        buffering = false
        atEnd = false
        isNetwork = false
        duration = nil
        lastBuffer = nil
        videoSize = (0, 0)
        frame = nil
        removeTemporaryFile()
        changed?()
    }

    private func fileURI(_ path: String) -> String? {
        guard let uri = gst.filenameToURI(path, nil) else { return nil }
        defer { gst.free(uri) }
        return String(cString: uri)
    }

    private func removeTemporaryFile() {
        if let temporaryFile {
            try? FileManager.default.removeItem(atPath: temporaryFile)
            self.temporaryFile = nil
        }
    }

    /// The source has prerolled: what it holds is known.
    private func finishLoading(live: Bool = false) {
        guard loading else { return }
        loading = false
        let videos = gst.int(pipeline, "n-video")
        let audios = gst.int(pipeline, "n-audio")
        duration = live ? nil : queryDuration()
        if let frames, let sample = gst.appSinkTryPullPreroll(frames, 0) {
            take(sample)
        }
        reported = .paused
        // A live source's streams may not be known yet: it's taken to have
        // sound.
        playback?.loaded(duration: duration, width: videoSize.width, height: videoSize.height,
                         hasAudio: audios > 0 || (live && videos == 0), hasVideo: videos > 0 || videoSize.width > 0)
        reportBuffer()
        changed?()
    }

    private func queryDuration() -> Double? {
        var nanoseconds: Int64 = 0
        guard gst.elementQueryDuration(pipeline, GStreamer.formatTime, &nanoseconds) != 0, nanoseconds >= 0 else {
            return nil
        }
        return Double(nanoseconds) / 1e9
    }

    private func fail(_ error: MediaError) {
        loading = false
        reported = .failed
        completeSeek(false)
        stopPolling()
        _ = gst.elementSetState(pipeline, GStreamer.null)
        playback?.failed(error)
        changed?()
    }

    // MARK: Playing

    public func play() {
        guard let current = reported, current != .failed else { return }
        if atEnd {
            atEnd = false
            seek(nanoseconds: 0)
        }
        expectsPause = false
        target = GStreamer.playing
        if !buffering {
            _ = gst.elementSetState(pipeline, GStreamer.playing)
        }
    }

    public func pause() {
        pause(requested: true)
    }

    /// The player's controls: a pause the user asked for.
    public func userPause() {
        pause(requested: false)
    }

    /// The player's controls: play, through the contract, so a source that
    /// hasn't loaded starts when it has.
    public func userPlay() {
        playback?.play()
    }

    private func pause(requested: Bool) {
        guard target == GStreamer.playing else { return }
        expectsPause = requested
        target = GStreamer.paused
        _ = gst.elementSetState(pipeline, GStreamer.paused)
        if buffering {
            // Already paused for data: no change of state will come.
            report(.paused)
        }
    }

    /// Says a state, once.
    private func report(_ state: MediaState) {
        guard let current = reported, current != .failed, current != state else { return }
        reported = state
        reportTime()
        if state == .paused {
            let reason: MediaPauseReason = expectsPause ? .requested : .user
            expectsPause = false
            playback?.stateChanged(.paused, reason: reason)
        } else {
            playback?.stateChanged(state)
        }
        changed?()
    }

    private func reachedEnd() {
        guard reported != nil else { return }
        if looping {
            seek(nanoseconds: 0)
            reportTime()
            return
        }
        target = GStreamer.paused
        _ = gst.elementSetState(pipeline, GStreamer.paused)
        atEnd = true
        reported = .paused
        reportTime(rate: 0)
        playback?.ended()
        changed?()
    }

    // MARK: Time

    public var currentTime: Double {
        if atEnd, let duration {
            return duration
        }
        var nanoseconds: Int64 = 0
        guard gst.elementQueryPosition(pipeline, GStreamer.formatTime, &nanoseconds) != 0, nanoseconds >= 0 else {
            return 0
        }
        return Double(nanoseconds) / 1e9
    }

    /// The source's duration, once it's loaded: `nil` for a live stream.
    public var knownDuration: Double? {
        duration
    }

    /// Whether it's playing, or about to.
    public var isPlaying: Bool {
        target == GStreamer.playing
    }

    public func seek(to position: Double, completion: @escaping (Bool) -> Void) {
        guard reported != nil, reported != .failed else {
            completion(false)
            return
        }
        completeSeek(false)
        atEnd = false
        guard seek(nanoseconds: Int64(max(position, 0) * 1e9)) else {
            completion(false)
            return
        }
        seekCompletion = completion
    }

    /// The player's controls: a seek the guest learns of from the time.
    public func userSeek(to position: Double) {
        seek(to: position) { [weak self] _ in
            self?.reportTime()
            self?.changed?()
        }
    }

    /// Flushes and goes exactly there, at the rate.
    @discardableResult
    private func seek(nanoseconds: Int64) -> Bool {
        gst.elementSeek(pipeline, Double(rate), GStreamer.formatTime, GStreamer.seekFlushAccurate,
                        GStreamer.seekSet, nanoseconds, GStreamer.seekNone, -1) != 0
    }

    private func completeSeek(_ finished: Bool) {
        if let completion = seekCompletion {
            seekCompletion = nil
            completion(finished)
        }
    }

    private func reportTime(rate: Float? = nil) {
        lastTime = MainLoop.now()
        playback?.timeChanged(position: currentTime, rate: rate ?? (reported == .playing ? self.rate : 0))
    }

    public func setTimeUpdateInterval(_ seconds: Double) {
        interval = Int64(seconds * 1e9)
    }

    /// Seconds loaded past the position: what the buffering query says for
    /// a URL, and the rest of a file.
    private func reportBuffer() {
        let position = currentTime
        var seconds: Double?
        if isNetwork {
            if let query = gst.queryNewBuffering(GStreamer.formatTime) {
                if gst.elementQuery(pipeline, query) != 0 {
                    var format: Int32 = 0
                    var stop: Int64 = -1
                    gst.queryParseBufferingRange(query, &format, nil, &stop, nil)
                    if stop >= 0, format == GStreamer.formatTime {
                        seconds = Double(stop) / 1e9 - position
                    } else if stop >= 0, format == GStreamer.formatPercent, let duration {
                        seconds = Double(stop) / Double(GStreamer.percentMax) * duration - position
                    }
                }
                gst.miniObjectUnref(query)
            }
        } else if let duration {
            seconds = duration - position
        }
        guard let seconds else { return }
        let buffered = max(seconds, 0)
        guard lastBuffer.map({ abs($0 - buffered) >= 0.25 }) ?? true else { return }
        lastBuffer = buffered
        playback?.bufferChanged(buffered)
    }

    // MARK: Settings

    public func setRate(_ rate: Float) {
        self.rate = rate
        guard reported != nil, reported != .failed, !loading else { return }
        // A seek where it is, at the new rate.
        let position = Int64(currentTime * 1e9)
        seek(nanoseconds: position)
        reportTime()
    }

    public func setVolume(_ volume: Float) {
        gst.set(pipeline, "volume", double: Double(min(max(volume, 0), 1)))
    }

    public func setMuted(_ muted: Bool) {
        gst.set(pipeline, "mute", bool: muted)
    }

    public func setLooping(_ looping: Bool) {
        self.looping = looping
    }

    // MARK: Polling

    private func startPolling() {
        guard timer == nil else { return }
        timer = MainLoop.shared.schedule(after: Self.pollInterval) { [weak self] in
            guard let self else { return }
            self.timer = nil
            self.poll()
            if self.reported != .failed, self.reported != nil || self.loading {
                self.startPolling()
            }
        }
    }

    private func stopPolling() {
        if let timer {
            MainLoop.shared.cancel(timer)
            self.timer = nil
        }
    }

    /// What happened since the last turn, then the latest picture and the
    /// time.
    func poll() {
        if let bus {
            while let message = gst.busPop(bus) {
                handle(message)
                gst.miniObjectUnref(message)
                if reported == .failed { return }
            }
        }
        if display != nil, let frames, let sample = gst.appSinkTryPullSample(frames, 0) {
            take(sample)
        }
        if reported == .playing, MainLoop.now() - lastTime >= interval {
            reportTime()
            reportBuffer()
            changed?()
        }
    }

    private func handle(_ message: GStreamer.Pointer) {
        switch gst.type(of: message) {
        case GStreamer.messageError:
            let error = gst.error(in: message)
            HostLog.debug("media: \(error.domain) \(error.code): \(error.message)")
            fail(MediaValues.error(domain: error.domain, code: error.code, message: error.message, network: isNetwork))
        case GStreamer.messageEOS:
            reachedEnd()
        case GStreamer.messageAsyncDone:
            if loading {
                finishLoading()
            } else if seekCompletion != nil {
                if target == GStreamer.paused, let frames, let sample = gst.appSinkTryPullPreroll(frames, 0) {
                    // The picture where the seek landed.
                    take(sample)
                }
                completeSeek(true)
                reportBuffer()
            }
        case GStreamer.messageStateChanged:
            guard gst.source(of: message) == pipeline, !loading else { return }
            var new: Int32 = 0
            gst.messageParseStateChanged(message, nil, &new, nil)
            if new == GStreamer.playing {
                report(.playing)
            } else if new == GStreamer.paused {
                if target == GStreamer.paused {
                    report(.paused)
                } else if buffering {
                    report(.buffering)
                }
                // Otherwise a flushing seek while playing, on its way back.
            }
        case GStreamer.messageBuffering:
            var percent: Int32 = 100
            gst.messageParseBuffering(message, &percent)
            buffering(percent)
        default:
            break
        }
    }

    /// A network source fills its buffer: it's paused while it does, and
    /// plays again when it's full, if it should.
    private func buffering(_ percent: Int32) {
        guard isNetwork, !loading else { return }
        if percent < 100, !buffering {
            buffering = true
            if target == GStreamer.playing {
                _ = gst.elementSetState(pipeline, GStreamer.paused)
            }
        } else if percent >= 100, buffering {
            buffering = false
            if target == GStreamer.playing {
                _ = gst.elementSetState(pipeline, GStreamer.playing)
            }
        }
    }

    // MARK: Pictures

    /// Copies a sample's picture, and gives it to the view.
    private func take(_ sample: GStreamer.Pointer) {
        defer { gst.miniObjectUnref(sample) }
        guard let caps = gst.sampleGetCaps(sample), let structure = gst.capsGetStructure(caps, 0),
              let buffer = gst.sampleGetBuffer(sample) else { return }
        var width: Int32 = 0
        var height: Int32 = 0
        guard gst.structureGetInt(structure, "width", &width) != 0, gst.structureGetInt(structure, "height", &height) != 0,
              width > 0, height > 0 else { return }
        let info = UnsafeMutableRawPointer.allocate(byteCount: GStreamer.mapInfoSize, alignment: 8)
        defer { info.deallocate() }
        guard gst.bufferMap(buffer, info, GStreamer.mapRead) != 0 else { return }
        defer { gst.bufferUnmap(buffer, info) }
        let size = Int(width) * Int(height) * 4
        guard let data = info.load(fromByteOffset: GStreamer.mapDataOffset, as: UnsafeRawPointer?.self),
              info.load(fromByteOffset: GStreamer.mapSizeOffset, as: Int.self) >= size else { return }
        videoSize = (Int(width), Int(height))
        let picture = VideoFrame(data: Data(bytes: data, count: size), width: Int(width), height: Int(height))
        frame = picture
        display?(picture)
    }
}
