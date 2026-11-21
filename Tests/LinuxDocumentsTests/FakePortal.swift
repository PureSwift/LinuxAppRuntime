import DBus
import LinuxDBus
import LinuxHost
@testable import LinuxDocuments

/// Plays the desktop portal's file chooser: records each call, and answers
/// on the main loop, as the bus does.
final class FakePortal: PortalBus {

    struct Call {
        var method: String
        var parentWindow: String
        var title: String
        var options: [String: DBusMessageArgument]

        var token: String? { options["handle_token"]?.text }
    }

    /// The file chooser's `version`; `nil` answers that there's no portal.
    var version: UInt32? = 4

    /// Fails every call, as the bus does without a portal.
    var error: BusError?

    /// Names requests itself, as a portal from before `handle_token` does.
    var ignoresTokens = false

    private(set) var calls: [Call] = []

    /// The path each call's reply named, in order.
    private(set) var requests: [String] = []

    private var responses: [UInt64: (String, [DBusMessageArgument]) -> Void] = [:]

    private var disconnects: [UInt64: () -> Void] = [:]

    private var next: UInt64 = 0

    static let sender = "1_42"

    func call(_ interface: String, _ method: String, _ arguments: [DBusMessageArgument], signature: String,
              reply: @escaping (Result<[DBusMessageArgument], BusError>) -> Void) {
        precondition(interface == Portal.fileChooser && signature == "ssa{sv}" && String(arguments.map(\.type)) == signature)
        if let error {
            MainLoop.shared.post { reply(.failure(error)) }
            return
        }
        let call = Call(method: method, parentWindow: arguments[0].text ?? "", title: arguments[1].text ?? "",
                        options: arguments[2].entries)
        calls.append(call)
        let token = ignoresTokens ? "\(calls.count * 7)" : call.token ?? "none"
        let path = "\(Portal.path)/request/\(Self.sender)/\(token)"
        requests.append(path)
        MainLoop.shared.post { reply(.success([.path(path)])) }
    }

    func property(_ interface: String, _ name: String, reply: @escaping (Result<DBusMessageArgument, BusError>) -> Void) {
        let answer: Result<DBusMessageArgument, BusError>
        if let error {
            answer = .failure(error)
        } else if interface == Portal.fileChooser, name == "version", let version {
            answer = .success(.uint32(version))
        } else {
            answer = .failure(BusError(name: "org.freedesktop.DBus.Error.UnknownProperty"))
        }
        MainLoop.shared.post { reply(answer) }
    }

    func subscribeToResponses(_ handler: @escaping (String, [DBusMessageArgument]) -> Void) -> BusSubscription {
        next += 1
        responses[next] = handler
        return BusSubscription(id: next)
    }

    func subscribeToDisconnect(_ handler: @escaping () -> Void) -> BusSubscription {
        next += 1
        disconnects[next] = handler
        return BusSubscription(id: next)
    }

    // MARK: The user

    /// Ends the last request with `response` and `uris`.
    func respond(_ response: Portal.Response, uris: [String] = []) {
        let path = requests.last!
        var results: [String: DBusMessageArgument] = [:]
        if !uris.isEmpty {
            results["uris"] = .stringArray(uris)
        }
        let arguments: [DBusMessageArgument] = [.uint32(response.rawValue), .vardict(results)]
        MainLoop.shared.post { [responses] in
            for id in responses.keys.sorted() {
                responses[id]?(path, arguments)
            }
        }
    }

    /// The bus closes.
    func disconnect() {
        MainLoop.shared.post { [disconnects] in
            for id in disconnects.keys.sorted() {
                disconnects[id]?()
            }
        }
    }
}
