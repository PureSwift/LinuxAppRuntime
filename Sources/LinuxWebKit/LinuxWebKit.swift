import DynamicRuntime
import DynamicWebKit
import LinuxHost
import RuntimeABI

/// The web view contracts (`WebKit.md`, `Plan.md` §8): pages in WPE WebKit,
/// shown by the player's `WebView` view. Main loop only.
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
        WPE.shared != nil
    }

    // MARK: The network

    /// In place of the app's capabilities, for tests: whether pages may
    /// reach the network.
    nonisolated(unsafe) public static var networkOverride: Bool? = nil {
        didSet { appliedNetwork = nil }
    }

    /// Whether pages may reach the network: the app declares `network`.
    /// Without it, remote loads are refused, and the rest go through a
    /// proxy that refuses them.
    static var hasNetwork: Bool {
        networkOverride ?? HostPermissions.declared.contains(.network)
    }

    nonisolated(unsafe) private static var appliedNetwork: Bool?

    /// Sets WebKit's proxy to match `hasNetwork`, once per change.
    static func applyNetworkPolicy() {
        guard let wpe = WPE.shared else { return }
        let allowed: Bool = hasNetwork
        guard appliedNetwork != allowed else { return }
        appliedNetwork = allowed
        if allowed {
            if let session = wpe.networkSessionGetDefault() {
                wpe.networkSessionSetProxySettings(session, 0, nil)    // the system's proxy
            }
        } else {
            wpe.blockNetwork()
        }
    }

    // MARK: GLib's main context

    /// How often the main loop runs GLib's context while there are pages.
    static let interval: Int64 = 8_000_000

    nonisolated(unsafe) private static var timer: MainLoop.TimerToken?

    /// Runs GLib's context on the main loop while any page is alive.
    static func pagesChanged() {
        if LinuxWebContent.count == 0 {
            if let timer {
                MainLoop.shared.cancel(timer)
                self.timer = nil
            }
        } else if timer == nil {
            schedule()
        }
    }

    private static func schedule() {
        timer = MainLoop.shared.schedule(after: interval) {
            timer = nil
            WPE.shared?.dispatch()
            if LinuxWebContent.count > 0 {
                schedule()
            }
        }
    }
}
