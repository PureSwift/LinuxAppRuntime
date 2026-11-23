import DynamicMedia
import Foundation

/// What GStreamer says, as the contract has it: its errors, and which MIME
/// types it plays.
enum MediaValues {

    // MARK: Errors

    /// A `GError` from the pipeline's bus as a `MediaError`. `network` is
    /// whether the source is a URL: a resource that can't be read there is
    /// the connection, and in a file it's the file.
    static func error(domain: String, code: Int32, message: String, network: Bool) -> MediaError {
        switch (domain, code) {
        // GstResourceError: NOT_FOUND, and NOT_AUTHORIZED, which is a
        // server's 401 or 403.
        case ("gst-resource-error-quark", 3), ("gst-resource-error-quark", 15):
            return MediaError(.notFound, message: message)
        // OPEN_WRITE and OPEN_READ_WRITE: the sound server or the device
        // wouldn't open.
        case ("gst-resource-error-quark", 6), ("gst-resource-error-quark", 7):
            return MediaError(.unavailable, message: message)
        case ("gst-resource-error-quark", _):
            return MediaError(network ? .network : .notFound, message: message)
        // GstStreamError: NOT_IMPLEMENTED, TYPE_NOT_FOUND, WRONG_TYPE,
        // CODEC_NOT_FOUND and FORMAT; GstCoreError's MISSING_PLUGIN.
        case ("gst-stream-error-quark", 3), ("gst-stream-error-quark", 4), ("gst-stream-error-quark", 5),
             ("gst-stream-error-quark", 6), ("gst-stream-error-quark", 11), ("gst-core-error-quark", 12):
            return MediaError(.unsupportedFormat, message: message)
        // DECODE and DEMUX.
        case ("gst-stream-error-quark", 7), ("gst-stream-error-quark", 9):
            return MediaError(.decoding, message: message)
        default:
            return MediaError(.unknown, message: message)
        }
    }

    // MARK: Formats

    /// What GStreamer needs for a MIME type: caps a demuxer or parser
    /// takes, and the caps of the codecs the contract expects inside it
    /// (`MediaPlayer.md`'s formats).
    struct Format: Equatable {
        var container: String
        var codecs: [String]
    }

    static func format(_ mimeType: String) -> Format? {
        let type = mimeType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        switch type {
        case "video/mp4", "video/x-m4v", "video/quicktime":
            return Format(container: "video/quicktime", codecs: [h264, aac])
        case "audio/mp4", "audio/x-m4a", "audio/m4a", "audio/aac":
            return Format(container: "audio/x-m4a", codecs: [aac])
        case "audio/mpeg", "audio/mp3", "audio/mpeg3", "audio/x-mpeg-3":
            return Format(container: "audio/mpeg, mpegversion=(int)1", codecs: ["audio/mpeg, mpegversion=(int)1, layer=(int)3"])
        case "audio/wav", "audio/x-wav", "audio/wave", "audio/vnd.wave":
            return Format(container: "audio/x-wav", codecs: [])
        case "application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl":
            return Format(container: "application/x-hls", codecs: [])
        case "video/webm", "audio/webm":
            return Format(container: "video/webm", codecs: [])
        case "audio/ogg", "video/ogg", "application/ogg":
            return Format(container: "application/ogg", codecs: [])
        case "audio/flac", "audio/x-flac":
            return Format(container: "audio/x-flac", codecs: [])
        case "":
            return nil
        default:
            // GStreamer's own name for it, if it has one.
            return Format(container: type, codecs: [])
        }
    }

    static let h264 = "video/x-h264, stream-format=(string)avc"

    static let aac = "audio/mpeg, mpegversion=(int)4"

    /// Whether GStreamer plays a MIME type, from whether it has what reads
    /// the container and decodes what the contract puts inside: `probably`
    /// with both, `maybe` with the container alone, since a file can hold
    /// other codecs.
    static func support(_ mimeType: String, reads: (String) -> Bool, decodes: (String) -> Bool) -> MediaSupport {
        guard let format = format(mimeType), reads(format.container) else {
            return .no
        }
        return format.codecs.allSatisfy(decodes) ? .probably : .maybe
    }

    // MARK: Files

    /// An extension GStreamer's type finding is helped by, for bytes that
    /// become a file.
    static func fileExtension(_ mimeType: String) -> String {
        switch format(mimeType)?.container {
        case "video/quicktime": return "mp4"
        case "audio/x-m4a": return "m4a"
        case "audio/mpeg, mpegversion=(int)1": return "mp3"
        case "audio/x-wav": return "wav"
        case "application/x-hls": return "m3u8"
        case "video/webm": return "webm"
        case "application/ogg": return "ogg"
        case "audio/x-flac": return "flac"
        default: return "media"
        }
    }
}
