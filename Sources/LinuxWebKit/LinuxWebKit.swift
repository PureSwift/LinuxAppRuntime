import DynamicRuntime
import DynamicWebKit
import LinuxHost
import RuntimeABI
import WPEWebKit

/// The web view contracts (`WebKit.md`, `Plan.md` §8): pages in WPE WebKit,
/// through PureSwift/WebKit, shown by the player's `WebView` view. Main
/// loop only.
public enum LinuxWebKit: HostModule {

    public static var contracts: [ContractDescriptor] {
        [WebContentProxy.descriptor, WebContentDelegateProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        WebContentProxy.register(LinuxWebContent.self, in: registrar)
        WebContentDelegateProxy.registerInterface(in: registrar)
    }

    /// Whether WPE WebKit loads. Without it a page loads nothing, and says
    /// so.
    public static var isAvailable: Bool {
        WPEEngine.isAvailable
    }

    // MARK: The network

    /// In place of the app's capabilities, for tests: whether pages may
    /// reach the network.
    nonisolated(unsafe) public static var networkOverride: Bool? = nil

    /// Whether pages may reach the network: the app declares `network`.
    /// Without it, remote loads are refused, and the rest go through a
    /// proxy that refuses them.
    static var hasNetwork: Bool {
        networkOverride ?? HostPermissions.declared.contains(.network)
    }

    /// Gives the engine the app's network, which it applies once per
    /// change.
    static func applyNetworkPolicy() {
        WPEEngine.isNetworkAllowed = hasNetwork
    }

    // MARK: The engine's loop

    nonisolated(unsafe) private static var isPrepared = false

    /// Before the first page: the engine logs to the host's log, and its
    /// loop runs on the main loop, which it wakes when its pages have work.
    static func prepare() {
        applyNetworkPolicy()
        guard !isPrepared else { return }
        isPrepared = true
        WPEEngine.logger = { HostLog.warning("web: \($0)") }
        WPEEngine.onReady = { MainLoop.shared.post { WPEEngine.pump() } }
    }

    /// Runs the engine's loop on the main loop's next turn, after the guest's
    /// call that set it off has returned, so the guest doesn't hear from
    /// its pages while it's calling them.
    static func pump() {
        guard !isPumpPosted else { return }
        isPumpPosted = true
        MainLoop.shared.post {
            isPumpPosted = false
            WPEEngine.pump()
        }
    }

    nonisolated(unsafe) private static var isPumpPosted = false
}
