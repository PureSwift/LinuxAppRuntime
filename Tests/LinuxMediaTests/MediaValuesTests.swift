import DynamicMedia
import Testing
@testable import LinuxMedia

@Suite struct MediaValuesTests {

    @Test func gstreamersErrorsAsTheContractsCodes() {
        func code(_ domain: String, _ value: Int32, network: Bool = false) -> MediaError.Code {
            MediaValues.error(domain: domain, code: value, message: "", network: network).code
        }
        let resource = "gst-resource-error-quark", stream = "gst-stream-error-quark"
        #expect(code(resource, 3) == .notFound)
        #expect(code(resource, 15, network: true) == .notFound, "a server's 401 or 403")
        #expect(code(resource, 5, network: true) == .network, "a URL that can't be read is the connection")
        #expect(code(resource, 5) == .notFound, "a file that can't be read is the file")
        #expect(code(resource, 6) == .unavailable, "the sound server wouldn't open")
        #expect(code(stream, 4) == .unsupportedFormat, "type not found")
        #expect(code(stream, 6) == .unsupportedFormat, "no decoder")
        #expect(code("gst-core-error-quark", 12) == .unsupportedFormat, "a missing plugin")
        #expect(code(stream, 7) == .decoding)
        #expect(code(stream, 9) == .decoding, "demuxing")
        #expect(code("gst-library-error-quark", 1) == .unknown)
        #expect(MediaValues.error(domain: resource, code: 3, message: "Not found", network: false).message == "Not found")
    }

    @Test func mimeTypesAsWhatGStreamerReads() {
        #expect(MediaValues.format("video/mp4; codecs=\"avc1.42E01E\"") == MediaValues.Format(
            container: "video/quicktime", codecs: [MediaValues.h264, MediaValues.aac]))
        #expect(MediaValues.format("Audio/WAV")?.container == "audio/x-wav")
        #expect(MediaValues.format("application/vnd.apple.mpegurl")?.container == "application/x-hls")
        #expect(MediaValues.format("audio/x-unheard")?.container == "audio/x-unheard", "GStreamer's own name")
        #expect(MediaValues.format("") == nil)
        #expect(MediaValues.fileExtension("audio/mpeg") == "mp3")
        #expect(MediaValues.fileExtension("application/x-unknown") == "media")
    }

    @Test func supportIsTheContainerAndTheContractsCodecs() {
        let all: (String) -> Bool = { _ in true }
        let none: (String) -> Bool = { _ in false }
        #expect(MediaValues.support("video/mp4", reads: all, decodes: all) == .probably)
        #expect(MediaValues.support("video/mp4", reads: all, decodes: { $0 == MediaValues.aac }) == .maybe, "no H.264")
        #expect(MediaValues.support("video/mp4", reads: none, decodes: all) == .no)
        #expect(MediaValues.support("audio/wav", reads: all, decodes: none) == .probably, "PCM needs no decoder")
        #expect(MediaValues.support("", reads: all, decodes: all) == .no)
    }
}
