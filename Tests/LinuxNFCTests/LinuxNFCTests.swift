import DBus
import DynamicNFC
import DynamicRuntime
import Foundation
import LinuxDBus
import LinuxHost
import Testing
@testable import LinuxNFC

let uriRecord: [String: DBusMessageArgument] = ["Type": .string("URI"), "URI": .string("https://example.com/tag")]

let textRecord: [String: DBusMessageArgument] = [
    "Type": .string("Text"), "Encoding": .string("UTF-8"), "Language": .string("en"), "Representation": .string("Hello"),
]

/// `LinuxNFCReader.neard` is every test's, so one at a time.
@Suite(.serialized) struct LinuxNFCTests {

    func with<T>(_ neard: FakeNeard, timeout: Int64 = 50_000_000, _ body: () throws -> T) rethrows -> T {
        let previous = LinuxNFCReader.neard
        let previousTimeout = LinuxNFCReader.recordsTimeout
        LinuxNFCReader.neard = neard
        LinuxNFCReader.recordsTimeout = timeout
        defer {
            MainLoop.shared.drain()
            LinuxNFCReader.neard = previous
            LinuxNFCReader.recordsTimeout = previousTimeout
        }
        return try body()
    }

    /// Runs the main loop until `done`, for up to five seconds: a timer
    /// wakes it then, since nothing else may.
    func run(until done: () -> Bool) {
        var expired = false
        let timer = MainLoop.shared.schedule(after: 5_000_000_000) { expired = true }
        defer { MainLoop.shared.cancel(timer) }
        MainLoop.shared.run { done() || expired }
    }

    /// A session polling for ISO 14443 tags, and a tag found and connected.
    func connected(_ neard: FakeNeard, records: [[String: DBusMessageArgument]] = [uriRecord, textRecord], readOnly: Bool = false,
                   types: NFCTagTypes = .iso14443) throws -> (LinuxNFCReader, RecordingReaderDelegate, any NFCTag) {
        let delegate = RecordingReaderDelegate()
        let reader = LinuxNFCReader.make(delegate)
        reader.begin(types.rawValue, alertMessage: "Hold a tag near the reader")
        MainLoop.shared.drain()
        neard.addTag(readOnly: readOnly, records: records)
        MainLoop.shared.drain()
        let tag = try #require(delegate.tags.first)
        reader.connect(tag)
        MainLoop.shared.drain()
        #expect(delegate.events == ["active", "detect 1", "connect 0"])
        delegate.events = []
        return (reader, delegate, tag)
    }

    // MARK: Availability

    @Test func availability() {
        with(FakeNeard()) {
            #expect(LinuxNFCReader.availability() == NFCAvailability.available.rawValue)
        }
        with(FakeNeard(powered: false)) {
            #expect(LinuxNFCReader.availability() == NFCAvailability.disabled.rawValue)
        }
        let none = FakeNeard()
        none.objects = [:]
        with(none) {
            #expect(LinuxNFCReader.availability() == NFCAvailability.unsupported.rawValue, "no adapter")
        }
        let missing = FakeNeard()
        missing.unavailable = BusError(name: "org.freedesktop.DBus.Error.ServiceUnknown")
        with(missing) {
            #expect(LinuxNFCReader.availability() == NFCAvailability.unsupported.rawValue, "no neard")
        }
        // One adapter on of two is enough.
        let two = FakeNeard(powered: false)
        two.objects["/org/neard/nfc1"] = [Neard.adapter: ["Powered": .boolean(true)]]
        #expect(LinuxNFCReader.adapter(in: two.objects)?.path == "/org/neard/nfc1")
    }

    @Test func protocolsAsTheContractHasThem() {
        #expect(LinuxNFCReader.kind("ISO-DEP")?.type == .iso7816)
        #expect(LinuxNFCReader.kind("MIFARE")?.type == .miFare)
        #expect(LinuxNFCReader.kind("Jewel")?.family == .iso14443)
        #expect(LinuxNFCReader.kind("Felica")?.family == .iso18092)
        #expect(LinuxNFCReader.kind("ISO-15693")?.type == .iso15693)
        #expect(LinuxNFCReader.kind("NFC-DEP") == nil)
    }

    // MARK: Sessions

    @Test func aSessionFindsATagAndReadsIt() throws {
        let neard = FakeNeard()
        try with(neard) {
            let (reader, delegate, tag) = try connected(neard)
            #expect(neard.calls.first == .init(path: FakeNeard.adapter, method: "StartPollLoop", arguments: [.string("Initiator")]))
            #expect(reader.isActive())
            #expect(tag.type() == NFCTagType.iso7816.rawValue)
            #expect(tag.identifier() == [0x04, 0xA2, 0x1B, 0x7C])
            #expect(tag.isAvailable())
            #expect(tag.maximumTransceiveLength() == 0 && tag.historicalBytes() == nil)

            tag.queryNDEFStatus()
            tag.readNDEF()
            MainLoop.shared.drain()
            #expect(delegate.events == ["query \(NDEFStatus.readWrite.rawValue) 0 0", "read 2 0"])
            let records = try #require(delegate.messages.first??.records())
            #expect(records[0].uri() == "https://example.com/tag")
            #expect(records[1].text() == "Hello")

            reader.invalidate(nil)
            MainLoop.shared.drain()
            #expect(neard.methods == ["StartPollLoop", "StopPollLoop"])
            #expect(delegate.events.last == "invalidate 0" && delegate.invalidations.last?.message == nil)
            #expect(!reader.isActive() && !tag.isAvailable())
            #expect(neard.subscribers == 0)
        }
    }

    @Test func theRecordsSignalCanComeFirst() throws {
        let neard = FakeNeard()
        try with(neard) {
            let delegate = RecordingReaderDelegate()
            let reader = LinuxNFCReader.make(delegate)
            reader.begin(NFCTagTypes.iso14443.rawValue, alertMessage: nil)
            MainLoop.shared.drain()
            neard.objects[FakeNeard.tagPath()] = [Neard.tag: ["Protocol": .string("MIFARE")]]
            neard.emit(.recordsRead(tag: FakeNeard.tagPath()))
            neard.emit(.added(path: FakeNeard.tagPath(), interfaces: [Neard.tag: [:]]))
            MainLoop.shared.drain()
            #expect(delegate.events == ["active", "detect 1"], "once")
            let tag = try #require(delegate.tags.first)
            #expect(tag.type() == NFCTagType.miFare.rawValue)
            reader.invalidate(nil)
        }
    }

    @Test func aTagWithoutRecordsIsFoundAfterAWhile() throws {
        let neard = FakeNeard()
        try with(neard, timeout: 20_000_000) {
            let delegate = RecordingReaderDelegate()
            let reader = LinuxNFCReader.make(delegate)
            reader.begin(NFCTagTypes.iso14443.rawValue, alertMessage: nil)
            MainLoop.shared.drain()
            neard.addTag(signalRecords: false)
            MainLoop.shared.drain()
            #expect(delegate.events == ["active"], "waiting for records")
            run { delegate.events.count > 1 }
            #expect(delegate.events == ["active", "detect 1"])
            let tag = try #require(delegate.tags.first)
            reader.connect(tag)
            tag.readNDEF()
            MainLoop.shared.drain()
            #expect(delegate.events.suffix(2) == ["connect 0", "read -1 0"], "an empty tag reads nil")
            reader.invalidate(nil)
        }
    }

    @Test func kindsNotAskedForAreLeftOut() throws {
        let neard = FakeNeard()
        with(neard) {
            let delegate = RecordingReaderDelegate()
            let reader = LinuxNFCReader.make(delegate)
            reader.begin(NFCTagTypes.iso15693.rawValue, alertMessage: nil)
            MainLoop.shared.drain()
            neard.addTag(protocol: "MIFARE")
            MainLoop.shared.drain()
            #expect(delegate.events == ["active"])
            // neard polls again only once the field is empty.
            neard.removeTag()
            MainLoop.shared.drain()
            #expect(neard.methods == ["StartPollLoop", "StartPollLoop"])
            neard.addTag(1, protocol: "ISO-15693")
            MainLoop.shared.drain()
            #expect(delegate.events == ["active", "detect 1"])
            reader.invalidate(nil)
        }
    }

    @Test func anNDEFSessionFindsEveryKind() throws {
        let neard = FakeNeard()
        try with(neard) {
            let (reader, delegate, tag) = try connected(neard, types: .ndef)
            #expect(tag.type() == NFCTagType.ndef.rawValue)
            #expect(tag.identifier().isEmpty, "no UID in an NDEF session, as on iOS")
            tag.transceive([0x00, 0xA4])
            MainLoop.shared.drain()
            #expect(delegate.events == ["transceive 0 \(NFCError.notAvailableInNDEFSession.rawValue)"])
            reader.invalidate(nil)
        }
    }

    @Test func restartingPollingWaitsForTheFieldToEmpty() throws {
        let neard = FakeNeard()
        try with(neard) {
            let (reader, delegate, tag) = try connected(neard)
            // The same tag isn't found again while it stays.
            reader.restartPolling()
            MainLoop.shared.drain()
            #expect(neard.methods == ["StartPollLoop"])
            #expect(!tag.isAvailable(), "the detection's tags are dropped")
            tag.readNDEF()
            MainLoop.shared.drain()
            #expect(delegate.events == ["read -1 \(NFCError.tagNotConnected.rawValue)"])

            neard.removeTag()
            MainLoop.shared.drain()
            #expect(neard.methods == ["StartPollLoop", "StartPollLoop"])
            neard.addTag(1, records: [textRecord])
            MainLoop.shared.drain()
            #expect(delegate.events.last == "detect 1")
            reader.invalidate(nil)
        }
    }

    @Test func aTagAlreadyInTheFieldIsFound() throws {
        let neard = FakeNeard()
        neard.objects[FakeNeard.tagPath()] = [Neard.tag: ["Protocol": .string("ISO-DEP")]]
        neard.objects[FakeNeard.tagPath() + "/record0"] = [Neard.record: uriRecord]
        with(neard) {
            let delegate = RecordingReaderDelegate()
            let reader = LinuxNFCReader.make(delegate)
            reader.begin(NFCTagTypes.iso14443.rawValue, alertMessage: nil)
            MainLoop.shared.drain()
            #expect(delegate.events == ["active", "detect 1"])
            #expect(neard.methods.isEmpty, "neard won't poll over a tag")
            reader.invalidate(nil)
        }
    }

    @Test func sessionsThatCantBegin() throws {
        func outcome(_ neard: FakeNeard, _ types: NFCTagTypes = .iso14443) -> [Int32] {
            with(neard) {
                let delegate = RecordingReaderDelegate()
                let reader = LinuxNFCReader.make(delegate)
                reader.begin(types.rawValue, alertMessage: nil)
                MainLoop.shared.drain()
                #expect(!reader.isActive())
                return delegate.invalidations.map(\.error)
            }
        }
        let missing = FakeNeard()
        missing.unavailable = BusError(name: "org.freedesktop.DBus.Error.ServiceUnknown")
        #expect(outcome(missing) == [NFCError.unsupported.rawValue])
        let none = FakeNeard()
        none.objects = [:]
        #expect(outcome(none) == [NFCError.unsupported.rawValue])
        #expect(outcome(FakeNeard(powered: false)) == [NFCError.disabled.rawValue])
        #expect(outcome(FakeNeard(), [.ndef, .iso14443]) == [NFCError.invalidParameter.rawValue])
        #expect(outcome(FakeNeard(), []) == [NFCError.invalidParameter.rawValue])
        let busy = FakeNeard()
        busy.errors["StartPollLoop"] = BusError(name: "org.neard.Error.Failed", message: "Device or resource busy")
        #expect(outcome(busy) == [NFCError.systemBusy.rawValue])
        #expect(busy.subscribers == 0)
    }

    @Test func oneSessionAtATime() throws {
        let neard = FakeNeard()
        with(neard) {
            let first = RecordingReaderDelegate()
            let reader = LinuxNFCReader.make(first)
            reader.begin(NFCTagTypes.iso14443.rawValue, alertMessage: nil)
            let second = RecordingReaderDelegate()
            let other = LinuxNFCReader.make(second)
            other.begin(NFCTagTypes.iso14443.rawValue, alertMessage: nil)
            MainLoop.shared.drain()
            #expect(first.events == ["active"])
            #expect(second.invalidations.map(\.error) == [NFCError.systemBusy.rawValue])

            reader.invalidate("Couldn't read the tag")
            MainLoop.shared.drain()
            #expect(first.invalidations.map(\.error) == [0])
            // A reader is single-use; the next can begin.
            reader.begin(NFCTagTypes.iso14443.rawValue, alertMessage: nil)
            MainLoop.shared.drain()
            #expect(first.invalidations.map(\.error) == [0, NFCError.systemBusy.rawValue])
            let third = RecordingReaderDelegate()
            let next = LinuxNFCReader.make(third)
            next.begin(NFCTagTypes.iso14443.rawValue, alertMessage: nil)
            MainLoop.shared.drain()
            #expect(third.events == ["active"])
            next.invalidate(nil)
        }
    }

    @Test func invalidatingBeforeNeardAnswers() {
        let neard = FakeNeard()
        with(neard) {
            let delegate = RecordingReaderDelegate()
            let reader = LinuxNFCReader.make(delegate)
            reader.begin(NFCTagTypes.iso14443.rawValue, alertMessage: nil)
            reader.invalidate(nil)
            MainLoop.shared.drain()
            #expect(delegate.events == ["invalidate 0"])
            #expect(neard.calls.isEmpty && neard.subscribers == 0)
        }
    }

    @Test func theAdapterGoingEndsTheSession() throws {
        for event in [
            NeardEvent.changed(path: FakeNeard.adapter, interface: Neard.adapter, changed: ["Powered": .boolean(false)]),
            .removed(path: FakeNeard.adapter, interfaces: [Neard.adapter]),
            .closed,
        ] {
            let neard = FakeNeard()
            try with(neard) {
                let (reader, delegate, tag) = try connected(neard)
                tag.readNDEF()
                neard.emit(event)
                MainLoop.shared.drain()
                #expect(!reader.isActive())
                #expect(delegate.events.count == 2 && delegate.events[1].hasPrefix("invalidate "))
                #expect(delegate.invalidations.first.map { $0.error != 0 && $0.message != nil } == true)
            }
        }
    }

    // MARK: Tags

    @Test func operationsNeedAConnection() throws {
        let neard = FakeNeard()
        try with(neard) {
            let delegate = RecordingReaderDelegate()
            let reader = LinuxNFCReader.make(delegate)
            reader.begin(NFCTagTypes.iso14443.rawValue, alertMessage: nil)
            MainLoop.shared.drain()
            neard.addTag(records: [uriRecord])
            MainLoop.shared.drain()
            let tag = try #require(delegate.tags.first)
            delegate.events = []
            tag.readNDEF()
            tag.writeLock()
            MainLoop.shared.drain()
            #expect(delegate.events == ["read -1 \(NFCError.tagNotConnected.rawValue)", "lock \(NFCError.tagNotConnected.rawValue)"])
            reader.invalidate(nil)
        }
    }

    @Test func aTagLeavingFailsWhatWaits() throws {
        let neard = FakeNeard()
        try with(neard) {
            let (reader, delegate, tag) = try connected(neard)
            let message = LinuxNDEFMessage.make([LinuxNDEFRecord.makeText("Bye", locale: "en")])
            tag.writeNDEF(message)
            tag.readNDEF()
            neard.removeTag()
            MainLoop.shared.drain()
            // The write was answered; the read waited for neard to read the
            // tag again.
            #expect(delegate.events == ["write 0", "read -1 \(NFCError.tagConnectionLost.rawValue)"])
            #expect(!tag.isAvailable())
            tag.queryNDEFStatus()
            reader.connect(tag)
            MainLoop.shared.drain()
            #expect(delegate.events.suffix(2) == ["query 0 0 \(NFCError.tagConnectionLost.rawValue)", "connect \(NFCError.tagConnectionLost.rawValue)"])
            reader.invalidate(nil)
        }
    }

    @Test func writingAndReadingAgain() throws {
        let neard = FakeNeard()
        try with(neard) {
            let (reader, delegate, tag) = try connected(neard)
            let message = LinuxNDEFMessage.make([
                try #require(LinuxNDEFRecord.makeURI("https://example.org/")),
                LinuxNDEFRecord.makeText("Written", locale: "en"),
            ])
            tag.writeNDEF(message)
            tag.readNDEF()
            MainLoop.shared.drain()
            #expect(delegate.events == ["write 0"], "the read waits for neard to read the tag again")
            let write = try #require(neard.calls.last)
            #expect(write.path == FakeNeard.tagPath() && write.method == "Write")
            let records = try #require(write.arguments.first?.entries["Records"]?.elements)
            #expect(records.map(\.entries) == [
                ["Type": .string("URI"), "URI": .string("https://example.org/")],
                ["Type": .string("Text"), "Encoding": .string("UTF-8"), "Language": .string("en"), "Representation": .string("Written")],
            ])

            neard.setRecords([["Type": .string("URI"), "URI": .string("https://example.org/")], textRecord], of: FakeNeard.tagPath())
            neard.emit(.recordsRead(tag: FakeNeard.tagPath()))
            MainLoop.shared.drain()
            #expect(delegate.events == ["write 0", "read 2 0"])
            #expect(delegate.messages.last??.records().first?.uri() == "https://example.org/")

            // One record is written as itself.
            tag.writeNDEF(LinuxNDEFMessage.make([LinuxNDEFRecord.makeText("One", locale: "fr")]))
            MainLoop.shared.drain()
            #expect(neard.calls.last?.arguments.first?.entries["Language"] == .string("fr"))
            reader.invalidate(nil)
        }
    }

    @Test func readingAgainGivesUpAfterAWhile() throws {
        let neard = FakeNeard()
        try with(neard, timeout: 20_000_000) {
            let (reader, delegate, tag) = try connected(neard)
            tag.writeNDEF(LinuxNDEFMessage.make([LinuxNDEFRecord.makeText("Bye", locale: "en")]))
            tag.readNDEF()
            neard.setRecords([textRecord], of: FakeNeard.tagPath())
            run { delegate.events.count == 2 }
            #expect(delegate.events == ["write 0", "read 1 0"])
            reader.invalidate(nil)
        }
    }

    @Test func writesNeardCantMake() throws {
        let neard = FakeNeard()
        try with(neard) {
            let (reader, delegate, tag) = try connected(neard)
            tag.writeNDEF(LinuxNDEFMessage.make([]))
            tag.writeNDEF(LinuxNDEFMessage.make([LinuxNDEFRecord.make(format: NDEFTypeNameFormat.external.rawValue, type: Array("example.com:t".utf8), identifier: [], payload: [1])]))
            neard.errors["Write"] = BusError(name: "org.neard.Error.InProgress")
            tag.writeNDEF(LinuxNDEFMessage.make([LinuxNDEFRecord.makeText("Hi", locale: "en")]))
            tag.writeLock()
            tag.transceive([0x30, 0x04])
            MainLoop.shared.drain()
            let invalid = NFCError.invalidParameter.rawValue
            let unsupported = NFCError.unsupported.rawValue
            #expect(delegate.events == ["write \(invalid)", "write \(invalid)", "write \(NFCError.systemBusy.rawValue)",
                                        "lock \(unsupported)", "transceive 0 \(unsupported)"])
            #expect(neard.methods.filter { $0 == "Write" }.count == 1)
            reader.invalidate(nil)
        }
        let locked = FakeNeard()
        try with(locked) {
            let (reader, delegate, tag) = try connected(locked, readOnly: true)
            tag.queryNDEFStatus()
            tag.writeNDEF(LinuxNDEFMessage.make([LinuxNDEFRecord.makeText("Hi", locale: "en")]))
            MainLoop.shared.drain()
            #expect(delegate.events == ["query \(NDEFStatus.readOnly.rawValue) 0 0", "write \(NFCError.tagReadOnly.rawValue)"])
            #expect(!locked.methods.contains("Write"))
            reader.invalidate(nil)
        }
        #expect(LinuxNFCTag.error(writing: BusError(name: "org.neard.Error.PermissionDenied")) == .tagReadOnly)
        #expect(LinuxNFCTag.error(writing: .disconnected) == .tagConnectionLost)
    }

    // MARK: Module

    @Test func moduleRegistersTheContracts() {
        #expect(LinuxNFC.contracts.map(\.name) == [
            "org.pureswift.nfc.Reader", "org.pureswift.nfc.ReaderDelegate", "org.pureswift.nfc.Tag",
            "org.pureswift.nfc.NDEFMessage", "org.pureswift.nfc.NDEFRecord",
        ])
        #expect(LinuxNFC.permissionProviders().keys.contains(.nfc))
    }
}
