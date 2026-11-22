import DBus
import DynamicNFC
import LinuxDBus
import LinuxHost

/// The `NFCTag` contract: one of neard's tags (`Plan.md` §14). Operations
/// run one at a time, in order, and each gets one delegate callback.
///
/// neard reads a tag's message when it finds it, and again after each
/// write, so reading answers with the records it read; it has no raw
/// commands and can't lock a tag, so those fail with `unsupported`.
public final class LinuxNFCTag: NFCTag {

    let path: String

    let tagType: NFCTagType

    let uid: [UInt8]

    private(set) var readOnly: Bool

    private(set) var records: [LinuxNDEFRecord]

    private(set) weak var reader: LinuxNFCReader?

    /// In the field. neard removes a tag that's gone.
    private(set) var present = true

    enum Operation {
        case queryNDEF, readNDEF, writeNDEF(LinuxNDEFMessage), lock, transceive
    }

    /// Operations asked for and not answered, the first running.
    private var operations: [Operation] = []

    private var running = false

    /// Counts drops, so an answer to an operation that was dropped is
    /// ignored.
    private var generation = 0

    /// neard is reading the records again after a write: the timer that
    /// stops waiting for it.
    private var rereading: MainLoop.TimerToken?

    /// An operation that waits for the records read again.
    private var afterReading: (() -> Void)?

    init(path: String, type: NFCTagType, properties: [String: DBusMessageArgument], records: [LinuxNDEFRecord], reader: LinuxNFCReader) {
        self.path = path
        self.tagType = type
        self.uid = properties["Uid"]?.bytes ?? []
        self.readOnly = properties["ReadOnly"]?.flag ?? false
        self.records = records
        self.reader = reader
    }

    deinit {
        if let rereading {
            MainLoop.shared.cancel(rereading)
        }
    }

    public func type() -> Int32 { tagType.rawValue }

    public func identifier() -> [UInt8] { reader?.ndefSession == true ? [] : uid }

    public func isAvailable() -> Bool {
        present && reader?.connected === self
    }

    public func historicalBytes() -> [UInt8]? { nil }

    public func selectedApplicationIdentifier() -> String? { nil }

    /// No raw commands through neard.
    public func maximumTransceiveLength() -> Int32 { 0 }

    public func queryNDEFStatus() { perform(.queryNDEF) }

    public func readNDEF() { perform(.readNDEF) }

    public func writeNDEF(_ message: any NDEFMessage) {
        perform(.writeNDEF(LinuxNDEFMessage.copy(of: message)))
    }

    public func writeLock() { perform(.lock) }

    public func transceive(_ data: [UInt8]) {
        guard reader?.ndefSession != true else {
            answer(.transceive, error: .notAvailableInNDEFSession)
            return
        }
        perform(.transceive)
    }

    // MARK: Operations

    /// Queues an operation if the tag's connected; otherwise its callback
    /// fails on the next turn.
    private func perform(_ operation: Operation) {
        guard let reader, reader.connected === self, reader.isActive() else {
            answer(operation, error: .tagNotConnected)
            return
        }
        guard present else {
            answer(operation, error: .tagConnectionLost)
            return
        }
        operations.append(operation)
        runNext()
    }

    private func runNext() {
        guard !running, let operation = operations.first else { return }
        running = true
        let generation = generation
        let finish = { [weak self] (error: NFCError?) in
            guard let self, self.generation == generation else { return }
            self.operations.removeFirst()
            self.running = false
            self.answer(operation, error: error)
            self.runNext()
        }
        afterRecords { [self] in
            switch operation {
            case .queryNDEF, .readNDEF:
                finish(nil)
            case .writeNDEF(let message):
                write(message, finish)
            case .lock, .transceive:
                finish(.unsupported)
            }
        }
    }

    private func write(_ message: LinuxNDEFMessage, _ finish: @escaping (NFCError?) -> Void) {
        guard !readOnly else {
            finish(.tagReadOnly)
            return
        }
        guard let attributes = NeardRecords.attributes(message) else {
            HostLog.error("nfc: neard writes text, URI and MIME records only, and at least one")
            finish(.invalidParameter)
            return
        }
        LinuxNFCReader.neard.call(path, Neard.tag, "Write", [.vardict(attributes)], signature: "a{sv}") { [weak self] result in
            switch result {
            case .success:
                self?.startRereading()
                finish(nil)
            case .failure(let error):
                finish(Self.error(writing: error))
            }
        }
    }

    /// The delegate's callback for `operation`, on the next turn, so it's
    /// never inside the guest's own call, and in order.
    private func answer(_ operation: Operation, error: NFCError?) {
        guard let reader else { return }
        let delegate = reader.delegate
        let code = error?.rawValue ?? 0
        let status = readOnly ? NDEFStatus.readOnly : .readWrite
        let message = records.isEmpty ? nil : LinuxNDEFMessage(records)
        MainLoop.shared.post { [self] in
            switch operation {
            case .queryNDEF:
                // neard doesn't say how much a tag holds.
                delegate.didQueryNDEF(reader, tag: self, status: (error == nil ? status : .notSupported).rawValue, capacity: 0, error: code)
            case .readNDEF:
                delegate.didReadNDEF(reader, tag: self, message: error == nil ? message : nil, error: code)
            case .writeNDEF:
                delegate.didWriteNDEF(reader, tag: self, error: code)
            case .lock:
                delegate.didLock(reader, tag: self, error: code)
            case .transceive:
                delegate.didTransceive(reader, tag: self, response: [], error: code)
            }
        }
    }

    // MARK: Records

    /// Runs `body` now, or once neard has read the records again after a
    /// write.
    private func afterRecords(_ body: @escaping () -> Void) {
        if rereading == nil {
            body()
        } else {
            afterReading = body
        }
    }

    private func startRereading() {
        if let rereading {
            MainLoop.shared.cancel(rereading)
        }
        rereading = MainLoop.shared.schedule(after: LinuxNFCReader.recordsTimeout) { [weak self] in
            self?.rereading = nil
            self?.refresh()
        }
    }

    /// neard read the records again.
    func recordsRead() {
        guard let rereading else { return }
        MainLoop.shared.cancel(rereading)
        self.rereading = nil
        refresh()
    }

    /// Reads the records and `ReadOnly` from neard again, then runs what
    /// waited for them.
    private func refresh() {
        let generation = generation
        LinuxNFCReader.neard.objects { [weak self] result in
            guard let self, self.generation == generation else { return }
            if case .success(let objects) = result, let properties = objects[self.path]?[Neard.tag] {
                self.records = NeardRecords.records(of: self.path, in: objects)
                self.readOnly = properties["ReadOnly"]?.flag ?? self.readOnly
            }
            let waiting = self.afterReading
            self.afterReading = nil
            waiting?()
        }
    }

    // MARK: Leaving

    /// The tag left the field.
    func leave() {
        present = false
        drop()
    }

    /// Every operation waiting fails: the tag or the session went.
    func drop() {
        generation += 1
        if let rereading {
            MainLoop.shared.cancel(rereading)
            self.rereading = nil
        }
        afterReading = nil
        let waiting = operations
        operations = []
        running = false
        for operation in waiting {
            answer(operation, error: .tagConnectionLost)
        }
    }

    /// `Write`'s errors.
    static func error(writing error: BusError) -> NFCError {
        switch error.name {
        case "org.neard.Error.PermissionDenied":
            return .tagReadOnly
        case "org.neard.Error.InProgress":
            return .systemBusy
        case "org.neard.Error.NotSupported":
            return .ndefNotSupported
        case "org.freedesktop.DBus.Error.UnknownObject", "org.freedesktop.DBus.Error.UnknownMethod":
            return .tagConnectionLost
        default:
            if error.isServiceMissing || error == .disconnected {
                return .tagConnectionLost
            }
            // neard answers a failed write as InvalidArguments.
            HostLog.error("nfc: can't write: \(error)")
            return .unknown
        }
    }
}
