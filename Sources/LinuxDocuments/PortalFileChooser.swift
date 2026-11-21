import DBus
import LinuxDBus

/// Requests to the portal's file chooser, and their answers. Main loop
/// only.
///
/// A request is a method call that returns at once with the path of a
/// `Request` object, and a `Response` signal from that object once the user
/// is done. Every request is named by a `handle_token` of its own, and the
/// response subscribed to before the call, so a response can't come before
/// it's listened for. The path is the caller's unique name and the token,
/// so the token alone tells this connection's requests apart.
final class PortalFileChooser {

    /// What a request ended with: how, and the results.
    typealias Answer = Result<(response: Portal.Response, results: [String: DBusMessageArgument]), BusError>

    let bus: any PortalBus

    /// The app's window, as the portal names a parent: `x11:<XID>` or
    /// `wayland:<handle>`; empty for none.
    var parentWindow = ""

    /// Requests waiting for their response, by the last component of their
    /// path.
    private var waiting: [String: (Answer) -> Void] = [:]

    private var subscriptions: [BusSubscription] = []

    private var next = 0

    private var version: UInt32?

    init(bus: any PortalBus) {
        self.bus = bus
    }

    /// Calls `method` (`OpenFile` or `SaveFile`) and answers with its
    /// response.
    func request(_ method: String, title: String, options: [String: DBusMessageArgument], completion: @escaping (Answer) -> Void) {
        subscribe()
        next += 1
        let token = "linuxapp\(next)"
        waiting[token] = completion
        var options = options
        options["handle_token"] = .string(token)
        bus.call(Portal.fileChooser, method, [.string(parentWindow), .string(title), .vardict(options)], signature: "ssa{sv}") { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                waiting.removeValue(forKey: token)?(.failure(error))
            case .success(let values):
                // A portal from before `handle_token` (0.9) names the
                // request itself.
                guard let handle = values.first?.text, let last = Self.lastComponent(handle), last != token,
                      let completion = waiting.removeValue(forKey: token) else { return }
                waiting[last] = completion
            }
        }
    }

    /// The file chooser's version: 3 and later can pick a folder. Read once.
    func fileChooserVersion(_ completion: @escaping (Result<UInt32, BusError>) -> Void) {
        if let version {
            completion(.success(version))
            return
        }
        bus.property(Portal.fileChooser, "version") { [weak self] result in
            switch result {
            case .success(let value):
                let version = value.int64Value.flatMap { UInt32(exactly: $0) } ?? 0
                self?.version = version
                completion(.success(version))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func subscribe() {
        guard subscriptions.isEmpty else { return }
        subscriptions.append(bus.subscribeToResponses { [weak self] path, arguments in
            self?.respond(path, arguments)
        })
        subscriptions.append(bus.subscribeToDisconnect { [weak self] in
            self?.disconnected()
        })
    }

    private func respond(_ path: String, _ arguments: [DBusMessageArgument]) {
        guard let last = Self.lastComponent(path), let completion = waiting.removeValue(forKey: last) else { return }
        let code = arguments.first?.int64Value.flatMap { UInt32(exactly: $0) }
        let response = code.flatMap(Portal.Response.init(rawValue:)) ?? .ended
        let results = arguments.count > 1 ? arguments[1].entries : [:]
        completion(.success((response, results)))
    }

    /// The bus closed: no response is coming.
    private func disconnected() {
        let pending = waiting
        waiting = [:]
        version = nil
        for completion in pending.values {
            completion(.failure(.disconnected))
        }
    }

    static func lastComponent(_ path: String) -> String? {
        guard let slash = path.lastIndex(of: "/") else { return nil }
        let last = path[path.index(after: slash)...]
        return last.isEmpty ? nil : String(last)
    }
}
