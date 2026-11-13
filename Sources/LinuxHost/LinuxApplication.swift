import DynamicRuntime

/// The built-in `Application` contract: the app's state and the URLs it's
/// asked to open. The window reports focus (`active` / `inactive`) and
/// minimizing (`background`); the command line can pass a URL.
public final class LinuxApplication: Application {

    /// The app's state now.
    nonisolated(unsafe) public private(set) static var current: ApplicationState = .active

    nonisolated(unsafe) private static var instances: [Weak] = []

    let delegate: any ApplicationDelegate

    init(delegate: any ApplicationDelegate) {
        self.delegate = delegate
    }

    public static func make(_ delegate: any ApplicationDelegate) -> LinuxApplication {
        let application = LinuxApplication(delegate: delegate)
        instances.removeAll { $0.object == nil }
        instances.append(Weak(object: application))
        return application
    }

    public func state() -> Int32 {
        Self.current.rawValue
    }

    // MARK: Host side

    /// Reports a new state to every `Application` the guest made. Main loop.
    public static func setState(_ state: ApplicationState) {
        guard state != current else { return }
        current = state
        for application in live {
            application.delegate.didChangeState(application, state: state.rawValue)
        }
    }

    /// Asks the guest to open `url`; whether any `Application` handled it.
    @discardableResult
    public static func open(_ url: String) -> Bool {
        var handled = false
        for application in live where application.delegate.open(application, url: url) {
            handled = true
        }
        return handled
    }

    public static func didReceiveMemoryWarning() {
        for application in live {
            application.delegate.didReceiveMemoryWarning(application)
        }
    }

    private static var live: [LinuxApplication] {
        instances.compactMap(\.object)
    }

    private struct Weak {
        weak var object: LinuxApplication?
    }
}
