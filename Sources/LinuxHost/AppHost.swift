import CRuntime
import DynamicRuntime
import Foundation
import RuntimeABI
import RuntimeCore
import RuntimeNative

/// The app library's exports: a sealed slice's `rt_main`, `rt_dispatch` and
/// `rt_finalize`.
///
/// ```swift
/// AppEntryPoints(main: rt_main, dispatch: rt_dispatch, finalize: rt_finalize)
/// ```
public struct AppEntryPoints {

    public var main: () -> rt_status

    public var dispatch: NativeGuest.EntryPoints.Dispatch

    public var finalize: NativeGuest.EntryPoints.Finalize

    public init(
        main: @escaping () -> rt_status,
        dispatch: NativeGuest.EntryPoints.Dispatch,
        finalize: NativeGuest.EntryPoints.Finalize
    ) {
        self.main = main
        self.dispatch = dispatch
        self.finalize = finalize
    }
}

/// Starts an app (`Plan.md` §4): checks it against this host, sets up the
/// runtime, registers the built-ins and the modules it uses, and calls
/// `rt_main`. Main thread only.
public final class AppHost {

    public let info: AppInfo

    public let modules: [any HostModule.Type]

    public let native: NativeRuntime

    /// The universal bundle the app came from, for its resources.
    public let bundlePath: String?

    /// Warnings from the last `prepare()`, such as a contract this host
    /// implements at a lower version than the app was built against.
    public private(set) var warnings: [String] = []

    public init(
        info: AppInfo,
        modules: [any HostModule.Type],
        bundlePath: String? = nil,
        native: NativeRuntime = .shared,
        clock: HostClock = MainLoopClock()
    ) {
        self.info = info
        self.modules = modules
        self.bundlePath = bundlePath
        self.native = native
        native.runtime.clock = clock
    }

    /// Checks the app and registers everything it may use. Throws if the app
    /// needs more than this host has.
    public func prepare() throws(AppHostError) {
        warnings = []
        try check()
        native.bindDirectly()
        native.capabilities = info.capabilities
        registerBuiltins()
        let used = info.contractNames
        for module in modules where module.isUsed(by: used) {
            module.register(in: native)
        }
        for warning in warnings {
            HostLog.warning(warning)
        }
    }

    /// Calls the app's `rt_main`. Afterwards the app runs only when the host
    /// calls it, from the main loop.
    @discardableResult
    public func start(_ entry: AppEntryPoints) -> RuntimeStatus {
        let status = native.start(entry.main, dispatch: entry.dispatch, finalize: entry.finalize)
        if status != .ok {
            HostLog.error("rt_main failed: \(status)")
        }
        return status
    }

    // MARK: Checks

    /// Every contract and callback interface this host can register.
    public var providedContracts: [String: ContractDescriptor] {
        var provided = [String: ContractDescriptor]()
        for descriptor in BuiltinContracts.all + modules.flatMap({ $0.contracts }) {
            provided[descriptor.name] = descriptor
        }
        return provided
    }

    private func check() throws(AppHostError) {
        if info.abiVersion > runtimeABIVersion {
            throw .incompatible("the app needs rt ABI \(info.abiVersion); this host provides \(runtimeABIVersion)")
        }
        let provided = providedContracts
        var problems = [String]()
        for contract in info.contracts {
            guard let descriptor = provided[contract.name] else {
                problems.append("\(contract.name) isn't implemented by this host")
                continue
            }
            if descriptor.kind != contract.kind {
                problems.append("\(contract.name) is a different kind of interface on this host")
            } else if descriptor.version < contract.version {
                // Methods added later resolve as absent; the guest checks.
                warnings.append("\(contract.name) is version \(descriptor.version) on this host; the app was built against \(contract.version)")
            }
        }
        if !problems.isEmpty {
            throw .incompatible(problems.joined(separator: "; "))
        }
    }

    // MARK: Built-ins

    private func registerBuiltins() {
        var providers: [Capability: any PermissionProvider] = [:]
        for module in modules {
            providers.merge(module.permissionProviders()) { _, module in module }
        }
        LinuxPermissions.providers = providers
        LinuxPermissions.declared = info.capabilities
        PermissionsProxy.register(LinuxPermissions.self, in: native)
        PermissionsDelegateProxy.registerInterface(in: native)
        LinuxBundle.info = info
        LinuxBundle.resources = bundlePath.map { $0 + "/resources" }
        AppBundleProxy.register(LinuxBundle.self, in: native)
        ApplicationProxy.register(LinuxApplication.self, in: native)
        ApplicationDelegateProxy.registerInterface(in: native)
    }
}

/// Why the host can't run an app.
public enum AppHostError: Error, Equatable, CustomStringConvertible {

    case incompatible(String)

    public var description: String {
        switch self {
        case .incompatible(let reason): "This app can't run on this host: \(reason)"
        }
    }
}

/// The host's messages, on standard error.
public enum HostLog {

    /// Whether `debug` messages are written: `LINUXAPPRUNTIME_DEBUG=1`.
    nonisolated(unsafe) public static var verbose = ProcessInfo.processInfo.environment["LINUXAPPRUNTIME_DEBUG"] == "1"

    public static func debug(_ message: @autoclosure () -> String) {
        if verbose {
            write("debug", message())
        }
    }

    public static func warning(_ message: String) {
        write("warning", message)
    }

    public static func error(_ message: String) {
        write("error", message)
    }

    private static func write(_ level: String, _ message: String) {
        FileHandle.standardError.write(Data("linux-app-host: \(level): \(message)\n".utf8))
    }
}
