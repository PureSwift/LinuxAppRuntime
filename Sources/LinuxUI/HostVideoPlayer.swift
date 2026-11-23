// `VideoPlayer` nodes: a `GStreamerEngine`'s pictures, scaled as the node
// asks, with this host's controls (`MediaPlayer.md`). Scripts/sync-darwinui.sh
// keeps this file.
#if os(Linux)
import DynamicUI
import Foundation
import LinuxHost
import LinuxMedia
import SwiftUI

/// A player's picture in the space the view is offered, and its controls
/// unless the node asks for none.
struct HostVideoPlayer: View {

    let identifier: Int32

    /// `fit`, `fill` or `stretch`.
    let scaling: String?

    /// `platform` or `none`.
    let controls: String?

    @StateObject private var model = HostVideoPlayerModel()

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            picture
            if controls != "none" {
                HostVideoControls(model: model)
            }
        }
        .clipped()
        .onAppear { model.attach(identifier) }
        .onDisappear { model.detach() }
    }

    @ViewBuilder
    private var picture: some View {
        if let frame = model.frame {
            let image = Image(pixels: frame.data, width: frame.width, height: frame.height, bytesPerRow: frame.width * 4)
                .resizable()
            switch scaling {
            case "fill":
                image.aspectRatio(CGFloat(frame.width) / CGFloat(frame.height), contentMode: .fill)
            case "stretch":
                image
            default:
                image.aspectRatio(CGFloat(frame.width) / CGFloat(frame.height), contentMode: .fit)
            }
        }
    }
}

/// Play and pause, where playback is, and a scrubber when the duration is
/// known.
struct HostVideoControls: View {

    @ObservedObject var model: HostVideoPlayerModel

    var body: some View {
        HStack(spacing: 12) {
            Button(action: model.toggle) {
                if model.isPlaying {
                    HStack(spacing: 4) {
                        Rectangle().frame(width: 4, height: 14)
                        Rectangle().frame(width: 4, height: 14)
                    }
                } else {
                    Text("▶")
                }
            }
            .foregroundColor(.white)
            if let duration = model.duration, duration > 0 {
                Slider(value: Binding(get: { model.position }, set: { model.scrub(to: $0) }), in: 0...duration,
                       onEditingChanged: { editing in model.scrubbing(editing) })
                Text(HostVideoPlayerModel.time(model.position) + " / " + HostVideoPlayerModel.time(duration))
                    .foregroundColor(.white)
            } else {
                Spacer()
                Text(HostVideoPlayerModel.time(model.position))
                    .foregroundColor(.white)
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.5))
    }
}

/// The view's player, its latest picture and what its controls show.
final class HostVideoPlayerModel: ObservableObject {

    @Published private(set) var frame: VideoFrame?

    @Published private(set) var isPlaying = false

    @Published private(set) var position = 0.0

    @Published private(set) var duration: Double?

    private var engine: GStreamerEngine?

    /// Where the user is dragging the scrubber to: it seeks when they let
    /// go.
    private var scrubbed: Double?

    func attach(_ identifier: Int32) {
        guard engine == nil else { return }
        guard let engine = LinuxMedia.engine(for: identifier) else {
            HostLog.warning("media: no player \(identifier) for a VideoPlayer")
            return
        }
        self.engine = engine
        engine.changed = { [weak self] in self?.refresh() }
        engine.display = { [weak self] frame in self?.frame = frame }
        refresh()
    }

    func detach() {
        engine?.display = nil
        engine?.changed = nil
        engine = nil
    }

    private func refresh() {
        guard let engine else { return }
        isPlaying = engine.isPlaying
        duration = engine.knownDuration
        if scrubbed == nil {
            position = engine.currentTime
        }
        if engine.videoSize.width == 0 {
            frame = nil
        }
    }

    func toggle() {
        guard let engine else { return }
        if engine.isPlaying {
            engine.userPause()
        } else {
            engine.userPlay()
        }
        refresh()
    }

    func scrub(to position: Double) {
        scrubbed = position
        self.position = position
    }

    func scrubbing(_ editing: Bool) {
        guard !editing, let target = scrubbed else { return }
        scrubbed = nil
        engine?.userSeek(to: target)
    }

    /// `m:ss`, or `h:mm:ss` from an hour.
    static func time(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded(.down))
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        let padded = rest < 10 ? "0\(rest)" : "\(rest)"
        if hours > 0 {
            return "\(hours):" + (minutes < 10 ? "0\(minutes)" : "\(minutes)") + ":" + padded
        }
        return "\(minutes):" + padded
    }
}
#endif
