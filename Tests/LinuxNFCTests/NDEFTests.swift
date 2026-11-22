import DBus
import DynamicNFC
import LinuxDBus
import Testing
@testable import LinuxNFC

@Suite struct NDEFTests {

    @Test func wellKnownRecords() throws {
        let uri = try #require(LinuxNDEFRecord.makeURI("https://www.example.com/a"))
        #expect(uri.payload() == [0x02] + Array("example.com/a".utf8), "the longest prefix's code")
        #expect(uri.uri() == "https://www.example.com/a")
        #expect(LinuxNDEFRecord.makeURI("not a uri") == nil)
        let text = LinuxNDEFRecord.makeText("Hej", locale: "sv")
        #expect(text.payload() == [2] + Array("sv".utf8) + Array("Hej".utf8))
        #expect(text.text() == "Hej" && text.textLanguage == "sv")
    }

    @Test func messagesEncodeAndDecode() throws {
        let message = LinuxNDEFMessage.make([
            try #require(LinuxNDEFRecord.makeURI("https://example.com")),
            LinuxNDEFRecord.make(format: NDEFTypeNameFormat.media.rawValue, type: Array("text/plain".utf8), identifier: [7],
                                 payload: [UInt8](repeating: 0x41, count: 300)),
        ])
        let bytes = message.encoded()
        #expect(bytes[0] == 0x91, "MB, SR, well-known")
        #expect(message.length() == Int32(bytes.count))
        let decoded = try #require(LinuxNDEFMessage.decode(bytes))
        #expect(decoded.recordList.map(\.recordPayload) == message.recordList.map(\.recordPayload))
        #expect(decoded.recordList[1].recordIdentifier == [7])
        #expect(LinuxNDEFMessage.make([]).encoded() == [0xD0, 0x00, 0x00])
        #expect(LinuxNDEFMessage.decode([0xD0, 0x00, 0x00])?.recordList.isEmpty == true)
        #expect(LinuxNDEFMessage.decode([0x91, 0x01]) == nil)
    }

    // MARK: neard's records

    @Test func neardsRecordsAsNDEF() throws {
        let objects: [String: NeardInterfaces] = [
            "/org/neard/nfc0/tag0": [Neard.tag: [:]],
            "/org/neard/nfc0/tag0/record10": [Neard.record: ["Type": .string("HandoverSelect")]],
            "/org/neard/nfc0/tag0/record2": [Neard.record: [
                "Type": .string("MIME"), "MIME": .string("application/json"), "MIMEPayload": .byteArray(Array("{}".utf8)),
            ]],
            "/org/neard/nfc0/tag0/record0": [Neard.record: ["Type": .string("URI"), "URI": .string("tel:+15551234")]],
            "/org/neard/nfc0/tag0/record1": [Neard.record: [
                "Type": .string("Text"), "Language": .string("de"), "Representation": .string("Hallo"),
            ]],
            "/org/neard/nfc0/tag0/record3": [Neard.record: [
                "Type": .string("SmartPoster"), "URI": .string("https://example.com"), "Representation": .string("Example"),
                "Language": .string("en"),
            ]],
            "/org/neard/nfc0/tag0/record4": [Neard.record: ["Type": .string("AAR"), "AAR": .string("com.example.app")]],
            "/org/neard/nfc0/tag1/record0": [Neard.record: ["Type": .string("URI"), "URI": .string("https://other.example")]],
        ]
        let records = NeardRecords.records(of: "/org/neard/nfc0/tag0", in: objects)
        #expect(records.count == 5, "in order, the handover left out, and only this tag's")
        #expect(records[0].uri() == "tel:+15551234" && records[0].payload().first == 0x05)
        #expect(records[1].text() == "Hallo" && records[1].textLanguage == "de")
        #expect(records[2].format == .media && records[2].type() == Array("application/json".utf8) && records[2].payload() == Array("{}".utf8))
        #expect(records[3].type() == NeardRecords.smartPosterType)
        let poster = try #require(LinuxNDEFMessage.decode(records[3].payload()))
        #expect(poster.recordList.map { $0.uri() ?? $0.text() } == ["https://example.com", "Example"])
        #expect(records[4].format == .external && records[4].type() == Array("android.com:pkg".utf8))
        #expect(records[4].payload() == Array("com.example.app".utf8))
    }

    @Test func ndefAsNeardWritesIt() throws {
        let uri = try #require(LinuxNDEFRecord.makeURI("mailto:someone@example.com"))
        #expect(NeardRecords.attributes(uri) == ["Type": .string("URI"), "URI": .string("mailto:someone@example.com")])
        let mime = LinuxNDEFRecord.make(format: NDEFTypeNameFormat.media.rawValue, type: Array("image/png".utf8), identifier: [],
                                        payload: [0x89, 0x50])
        #expect(NeardRecords.attributes(mime) == ["Type": .string("MIME"), "MIME": .string("image/png"), "Payload": .byteArray([0x89, 0x50])])
        // neard makes its own Wi-Fi record for this type.
        let wifi = LinuxNDEFRecord.make(format: NDEFTypeNameFormat.media.rawValue, type: Array("application/vnd.wfa.wsc".utf8),
                                        identifier: [], payload: [1])
        #expect(NeardRecords.attributes(wifi) == nil)
        let poster = LinuxNDEFRecord.make(format: NDEFTypeNameFormat.wellKnown.rawValue, type: NeardRecords.smartPosterType,
                                          identifier: [], payload: [])
        #expect(NeardRecords.attributes(poster) == nil)
        #expect(NeardRecords.attributes(LinuxNDEFMessage.make([uri, poster])) == nil, "every record or none")
    }
}
