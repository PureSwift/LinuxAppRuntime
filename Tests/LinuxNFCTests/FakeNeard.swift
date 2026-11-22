import DBus
import DynamicNFC
import LinuxDBus
import LinuxHost
@testable import LinuxNFC

/// Plays neard: its objects, the methods called on them, and its signals,
/// answering on the main loop as the bus does.
final class FakeNeard: NeardBus {

    var objects: [String: NeardInterfaces] = [:]

    /// Fails every call, as the bus does without neard.
    var unavailable: BusError?

    /// Errors to answer a method with, by name, once each.
    var errors: [String: BusError] = [:]

    struct Call: Equatable {
        var path: String
        var method: String
        var arguments: [DBusMessageArgument]
    }

    private(set) var calls: [Call] = []

    private var handlers: [UInt64: (NeardEvent) -> Void] = [:]

    private var next: UInt64 = 0

    var subscribers: Int { handlers.count }

    static let adapter = "/org/neard/nfc0"

    /// An adapter, on or off.
    init(powered: Bool = true) {
        objects[Self.adapter] = [Neard.adapter: ["Powered": .boolean(powered), "Mode": .string("Idle"), "Polling": .boolean(false)]]
    }

    var methods: [String] { calls.map(\.method) }

    func objects(reply: @escaping (Result<[String: NeardInterfaces], BusError>) -> Void) {
        let answer: Result<[String: NeardInterfaces], BusError> = unavailable.map { .failure($0) } ?? .success(objects)
        MainLoop.shared.post { reply(answer) }
    }

    func objectsAndWait() -> Result<[String: NeardInterfaces], BusError> {
        unavailable.map { .failure($0) } ?? .success(objects)
    }

    func call(
        _ path: String,
        _ interface: String,
        _ method: String,
        _ arguments: [DBusMessageArgument],
        signature: String?,
        reply: @escaping (Result<Void, BusError>) -> Void
    ) {
        calls.append(Call(path: path, method: method, arguments: arguments))
        let answer: Result<Void, BusError>
        if let error = unavailable ?? errors.removeValue(forKey: method) {
            answer = .failure(error)
        } else {
            answer = .success(())
        }
        MainLoop.shared.post { reply(answer) }
    }

    func subscribe(_ handler: @escaping (NeardEvent) -> Void) -> BusSubscription {
        next += 1
        handlers[next] = handler
        return BusSubscription(id: next)
    }

    func unsubscribe(_ subscription: BusSubscription) {
        handlers[subscription.id] = nil
    }

    /// Sends an event to every subscriber, on the main loop.
    func emit(_ event: NeardEvent) {
        MainLoop.shared.post { [handlers] in
            for id in handlers.keys.sorted() {
                handlers[id]?(event)
            }
        }
    }

    // MARK: Tags

    static func tagPath(_ index: Int = 0) -> String { adapter + "/tag\(index)" }

    /// A tag in the field, and its records, as neard publishes them once it
    /// has read them: the tag, then the records' signal.
    func addTag(
        _ index: Int = 0,
        protocol name: String = "ISO-DEP",
        uid: [UInt8] = [0x04, 0xA2, 0x1B, 0x7C],
        readOnly: Bool = false,
        records: [[String: DBusMessageArgument]] = [],
        signalRecords: Bool = true
    ) {
        let path = Self.tagPath(index)
        let tag: [String: DBusMessageArgument] = [
            "Type": .string("Type 4A"), "Protocol": .string(name), "ReadOnly": .boolean(readOnly),
            "Adapter": .path(Self.adapter), "Uid": .byteArray(uid),
        ]
        objects[path] = [Neard.tag: tag]
        setRecords(records, of: path)
        emit(.added(path: path, interfaces: [Neard.tag: tag]))
        if signalRecords {
            emit(.recordsRead(tag: path))
        }
    }

    /// Replaces a tag's records, as neard does when it reads it again.
    func setRecords(_ records: [[String: DBusMessageArgument]], of path: String) {
        for key in objects.keys where key.hasPrefix(path + "/record") {
            objects[key] = nil
        }
        for (index, record) in records.enumerated() {
            objects[path + "/record\(index)"] = [Neard.record: record]
        }
    }

    func removeTag(_ index: Int = 0) {
        let path = Self.tagPath(index)
        for key in objects.keys where key.hasPrefix(path) {
            objects[key] = nil
        }
        emit(.removed(path: path, interfaces: [Neard.tag]))
    }
}

/// Records what the reader tells its delegate, and keeps the tags it found.
final class RecordingReaderDelegate: NFCReaderDelegate {

    var events: [String] = []

    var tags: [any NFCTag] = []

    var messages: [(any NDEFMessage)?] = []

    var invalidations: [(error: Int32, message: String?)] = []

    func didBecomeActive(_ reader: any NFCReader) { events.append("active") }

    func didDetect(_ reader: any NFCReader, tags: [any NFCTag]) {
        self.tags = tags
        events.append("detect \(tags.count)")
    }

    func didConnect(_ reader: any NFCReader, tag: any NFCTag, error: Int32) { events.append("connect \(error)") }

    func didQueryNDEF(_ reader: any NFCReader, tag: any NFCTag, status: Int32, capacity: Int32, error: Int32) {
        events.append("query \(status) \(capacity) \(error)")
    }

    func didReadNDEF(_ reader: any NFCReader, tag: any NFCTag, message: (any NDEFMessage)?, error: Int32) {
        messages.append(message)
        events.append("read \(message?.records().count ?? -1) \(error)")
    }

    func didWriteNDEF(_ reader: any NFCReader, tag: any NFCTag, error: Int32) { events.append("write \(error)") }

    func didLock(_ reader: any NFCReader, tag: any NFCTag, error: Int32) { events.append("lock \(error)") }

    func didTransceive(_ reader: any NFCReader, tag: any NFCTag, response: [UInt8], error: Int32) {
        events.append("transceive \(response.count) \(error)")
    }

    func didInvalidate(_ reader: any NFCReader, error: Int32, message: String?) {
        invalidations.append((error, message))
        events.append("invalidate \(error)")
    }
}
