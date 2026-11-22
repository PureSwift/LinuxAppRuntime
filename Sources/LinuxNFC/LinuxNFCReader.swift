import DBus
import DynamicNFC
import DynamicRuntime
import LinuxDBus
import LinuxHost

/// The `NFCReader` contract over neard (`Plan.md` §14): one adapter's poll
/// loop, and the tags it finds. Linux shows no scan sheet, so the alert
/// message is ignored, and there's no time limit. Main loop only.
public final class LinuxNFCReader: NFCReader {

    /// neard, or a fake one in tests.
    nonisolated(unsafe) public static var neard: any NeardBus = SystemNeard()

    /// How long a tag that's found waits for neard to read its records,
    /// in nanoseconds: one without NDEF has none to read, and neard doesn't
    /// say so.
    nonisolated(unsafe) public static var recordsTimeout: Int64 = 1_000_000_000

    /// The session that's polling: neard has one poll loop per adapter.
    nonisolated(unsafe) static weak var polling: LinuxNFCReader?

    /// Kept strongly, as every host keeps a delegate.
    let delegate: any NFCReaderDelegate

    private enum Phase {
        case idle, starting, active, invalidated
    }

    private var phase = Phase.idle

    private var types = NFCTagTypes()

    private(set) var ndefSession = false

    /// The adapter's path, once the session has one.
    private var adapter: String?

    private var subscription: BusSubscription?

    /// Polling paused after a detection, until `restartPolling`.
    private var paused = false

    /// Polling should start again once the field is empty: neard won't
    /// start it with a tag there, nor by itself after one leaves.
    private var resumeWhenEmpty = false

    /// The adapter's tags in the field, by path.
    private var present: Set<String> = []

    /// Tags reported or left out, so each is decided once while it stays.
    private var decided: Set<String> = []

    /// Tags found and waiting for their records.
    private var waiting: [String: MainLoop.TimerToken] = [:]

    /// The tags of the last detection, and the one connected.
    private(set) var tags: [LinuxNFCTag] = []

    private(set) var connected: LinuxNFCTag?

    init(delegate: any NFCReaderDelegate) {
        self.delegate = delegate
    }

    deinit {
        if Self.polling === self, let adapter {
            Self.neard.call(adapter, Neard.adapter, "StopPollLoop", [], signature: nil) { _ in }
        }
        if let subscription {
            Self.neard.unsubscribe(subscription)
        }
        for timer in waiting.values {
            MainLoop.shared.cancel(timer)
        }
    }

    public static func make(_ delegate: any NFCReaderDelegate) -> LinuxNFCReader {
        LinuxNFCReader(delegate: delegate)
    }

    // MARK: Availability

    /// No neard, or no adapter: `unsupported`; adapters all off: `disabled`.
    public static func availability() -> Int32 {
        switch neard.objectsAndWait() {
        case .success(let objects):
            guard let adapter = adapter(in: objects) else {
                return NFCAvailability.unsupported.rawValue
            }
            return (adapter.powered ? NFCAvailability.available : .disabled).rawValue
        case .failure(let error):
            if !error.isServiceMissing {
                HostLog.error("nfc: can't ask neard: \(error)")
            }
            return NFCAvailability.unsupported.rawValue
        }
    }

    /// The first adapter that's on, else the first.
    static func adapter(in objects: [String: NeardInterfaces]) -> (path: String, powered: Bool)? {
        let adapters = objects.compactMap { path, interfaces in
            interfaces[Neard.adapter].map { (path: path, powered: $0["Powered"]?.flag == true) }
        }.sorted { $0.path < $1.path }
        return adapters.first { $0.powered } ?? adapters.first
    }

    // MARK: Session

    public func begin(_ tagTypes: Int32, alertMessage: String?) {
        switch phase {
        case .invalidated:
            let delegate = delegate
            MainLoop.shared.post { [self] in
                delegate.didInvalidate(self, error: NFCError.systemBusy.rawValue, message: "This reader was invalidated; make a new one.")
            }
            return
        case .starting, .active:
            return
        case .idle:
            break
        }
        let types = NFCTagTypes(rawValue: tagTypes)
        guard !types.isDisjoint(with: [.ndef, .iso14443, .iso15693, .iso18092]), !types.contains(.ndef) || types == .ndef else {
            invalidate(with: .invalidParameter, message: "NDEF can't be combined with other tag types.")
            return
        }
        self.types = types
        ndefSession = types == .ndef
        phase = .starting
        Self.neard.objects { [weak self] result in
            self?.start(result)
        }
    }

    private func start(_ result: Result<[String: NeardInterfaces], BusError>) {
        guard phase == .starting else { return }
        let objects: [String: NeardInterfaces]
        switch result {
        case .success(let all):
            objects = all
        case .failure(let error):
            invalidate(with: .unsupported, message: "neard isn't running (\(error)).")
            return
        }
        guard let adapter = Self.adapter(in: objects) else {
            invalidate(with: .unsupported, message: "This computer has no NFC adapter.")
            return
        }
        guard adapter.powered else {
            invalidate(with: .disabled, message: "NFC is turned off.")
            return
        }
        guard Self.polling == nil else {
            invalidate(with: .systemBusy, message: "Another NFC session is active.")
            return
        }
        self.adapter = adapter.path
        Self.polling = self
        present = Set(objects.keys.filter { isTag($0) && objects[$0]?[Neard.tag] != nil })
        subscription = Self.neard.subscribe { [weak self] event in
            self?.handle(event)
        }
        let begun = { [self] in
            phase = .active
            delegate.didBecomeActive(self)
        }
        // A tag already in the field is found as it is; neard won't poll
        // over it.
        if let tag = present.sorted().first {
            begun()
            detect(tag)
            return
        }
        startPolling { [weak self] error in
            guard let self, self.phase == .starting else { return }
            if let error {
                self.invalidate(with: error, message: nil)
            } else {
                begun()
            }
        }
    }

    public func setAlertMessage(_ message: String) {}

    public func restartPolling() {
        guard phase == .active else { return }
        dropTags()
        paused = false
        if present.isEmpty {
            startPolling { error in
                if let error {
                    HostLog.error("nfc: can't poll again: \(error)")
                }
            }
        } else {
            resumeWhenEmpty = true
        }
    }

    public func connect(_ tag: any NFCTag) {
        guard let tag = LinuxNFC.resolve(tag, as: LinuxNFCTag.self) else { return }
        let error: NFCError?
        if tag.reader !== self || phase != .active || !tags.contains(where: { $0 === tag }) {
            error = .tagNotConnected
        } else if !tag.present {
            error = .tagConnectionLost
        } else {
            error = nil
            connected = tag
        }
        let delegate = delegate
        MainLoop.shared.post { [self] in
            delegate.didConnect(self, tag: tag, error: error?.rawValue ?? 0)
        }
    }

    public func invalidate(_ errorMessage: String?) {
        invalidate(with: nil, message: errorMessage)
    }

    public func isActive() -> Bool {
        phase == .active
    }

    /// Ends the session and tells the delegate once, on the next turn.
    func invalidate(with error: NFCError?, message: String?) {
        guard phase != .invalidated else { return }
        phase = .invalidated
        for timer in waiting.values {
            MainLoop.shared.cancel(timer)
        }
        waiting = [:]
        if let subscription {
            Self.neard.unsubscribe(subscription)
            self.subscription = nil
        }
        if Self.polling === self {
            Self.polling = nil
            if let adapter {
                // Not polling, after a detection, is an error to ignore.
                Self.neard.call(adapter, Neard.adapter, "StopPollLoop", [], signature: nil) { _ in }
            }
        }
        dropTags()
        let delegate = delegate
        MainLoop.shared.post { [self] in
            delegate.didInvalidate(self, error: error?.rawValue ?? 0, message: error == nil ? nil : message)
        }
    }

    private func dropTags() {
        for tag in tags {
            tag.drop()
        }
        tags = []
        connected = nil
    }

    private func startPolling(_ done: @escaping (NFCError?) -> Void) {
        guard let adapter else { return }
        Self.neard.call(adapter, Neard.adapter, "StartPollLoop", [.string("Initiator")], signature: "s") { result in
            switch result {
            case .success:
                done(nil)
            case .failure(let error):
                done(Self.error(polling: error))
            }
        }
    }

    // MARK: neard's changes

    private func handle(_ event: NeardEvent) {
        switch event {
        case .added(let path, let interfaces):
            guard isTag(path), interfaces[Neard.tag] != nil else { return }
            present.insert(path)
            guard phase == .active, !paused, !decided.contains(path), waiting[path] == nil else { return }
            waiting[path] = MainLoop.shared.schedule(after: Self.recordsTimeout) { [weak self] in
                self?.waiting[path] = nil
                self?.detect(path)
            }
        case .recordsRead(let path):
            guard isTag(path) else { return }
            if let tag = tags.first(where: { $0.path == path }) {
                tag.recordsRead()
                return
            }
            // neard says so before it publishes the tag, sometimes.
            present.insert(path)
            if let timer = waiting.removeValue(forKey: path) {
                MainLoop.shared.cancel(timer)
            }
            guard phase == .active, !paused, !decided.contains(path) else { return }
            detect(path)
        case .removed(let path, let interfaces):
            if path == adapter, interfaces.contains(Neard.adapter) {
                invalidate(with: .unsupported, message: "The NFC adapter went away.")
                return
            }
            guard isTag(path), interfaces.contains(Neard.tag) else { return }
            present.remove(path)
            decided.remove(path)
            if let timer = waiting.removeValue(forKey: path) {
                MainLoop.shared.cancel(timer)
            }
            tags.first { $0.path == path }?.leave()
            if present.isEmpty, resumeWhenEmpty, phase == .active {
                resumeWhenEmpty = false
                startPolling { error in
                    if let error {
                        HostLog.error("nfc: can't poll again: \(error)")
                    }
                }
            }
        case .changed(let path, let interface, let changed):
            if path == adapter, interface == Neard.adapter, changed["Powered"]?.flag == false {
                invalidate(with: .disabled, message: "NFC was turned off.")
            }
        case .closed:
            invalidate(with: .unknown, message: "neard's bus closed.")
        }
    }

    /// A tag of the session's adapter: `<adapter>/tagN`.
    private func isTag(_ path: String) -> Bool {
        guard let adapter, path.hasPrefix(adapter + "/tag") else { return false }
        return !path.dropFirst(adapter.count + 1).contains("/")
    }

    /// Reports the tag at `path`, with its records, if it's a kind asked
    /// for.
    private func detect(_ path: String) {
        decided.insert(path)
        Self.neard.objects { [weak self] result in
            guard let self, self.phase == .active, !self.paused,
                  case .success(let objects) = result, let properties = objects[path]?[Neard.tag] else {
                return
            }
            let kind = Self.kind(properties["Protocol"]?.text)
            guard let kind, self.ndefSession || self.types.contains(kind.family) else {
                HostLog.debug("nfc: \(path) (\(properties["Protocol"]?.text ?? "no protocol")) isn't a kind asked for")
                self.resumeWhenEmpty = true
                return
            }
            let tag = LinuxNFCTag(
                path: path,
                type: self.ndefSession ? .ndef : kind.type,
                properties: properties,
                records: NeardRecords.records(of: path, in: objects),
                reader: self
            )
            self.dropTags()
            self.tags = [tag]
            self.paused = true
            self.delegate.didDetect(self, tags: self.tags)
        }
    }

    // MARK: Mapping

    /// A tag's `Protocol`, as the contract has it, and the polling option
    /// that finds it.
    static func kind(_ name: String?) -> (type: NFCTagType, family: NFCTagTypes)? {
        switch name {
        case "ISO-DEP": (.iso7816, .iso14443)
        case "MIFARE": (.miFare, .iso14443)
        // NFC Forum Type 1 (Topaz), also ISO 14443-A.
        case "Jewel": (.unknown, .iso14443)
        case "Felica": (.feliCa, .iso18092)
        case "ISO-15693", "ISO15693": (.iso15693, .iso15693)
        default: nil
        }
    }

    /// `StartPollLoop`'s errors. neard answers most as `Failed`, with
    /// `strerror`'s text.
    static func error(polling error: BusError) -> NFCError {
        switch error.name {
        case "org.neard.Error.InProgress":
            return .systemBusy
        case "org.neard.Error.Failed" where error.message.contains("busy"):
            return .systemBusy
        case "org.neard.Error.Failed" where error.message.contains("No such device"):
            return .disabled
        default:
            if error.isServiceMissing {
                return .unsupported
            }
            HostLog.error("nfc: can't poll: \(error)")
            return .unknown
        }
    }
}
