import DynamicRuntime
import Foundation
import RuntimeABI
import RuntimeHost

/// The `Defaults` contract (AppRuntime's `Defaults.md`): `RuntimeHost`'s
/// `HostDefaults` over a `FileDefaultsStorage`, one file of the app's
/// settings (`Plan.md` §9).
///
/// | `LINUXAPPRUNTIME_CONTAINER` set | Otherwise (XDG) |
/// |---|---|
/// | `<container>/Defaults` | `$XDG_CONFIG_HOME/<id>/Defaults` |
///
/// `<id>` is the app's bundle identifier, and `XDG_CONFIG_HOME` defaults to
/// `~/.config`.
public enum LinuxDefaults: HostModule {

    public static var contracts: [ContractDescriptor] {
        HostDefaultsModule.contracts
    }

    /// Opens the app's settings, then registers `Defaults`. Without them,
    /// reads find nothing and writes are refused.
    public static func register(in registrar: some ContractRegistrar) {
        do {
            let path = try self.path(identifier: LinuxBundle.info.identifier, environment: LinuxFiles.environment)
            HostDefaults.storage = try FileDefaultsStorage(path: path)
            HostLog.debug("defaults: \(path)")
        } catch {
            HostLog.error("defaults: \(error)")
        }
        HostDefaultsModule.register(in: registrar)
    }

    /// Where the settings of the app `identifier` are kept.
    public static func path(identifier: String, environment: [String: String]) throws(LinuxFilesError) -> String {
        guard LinuxFiles.isPathComponent(identifier) else {
            throw LinuxFilesError("the bundle identifier \"\(identifier)\" can't name a directory")
        }
        if let container = LinuxFiles.nonEmpty(environment["LINUXAPPRUNTIME_CONTAINER"]) {
            guard container.hasPrefix("/") else {
                throw LinuxFilesError("LINUXAPPRUNTIME_CONTAINER must be an absolute path")
            }
            return container + "/Defaults"
        }
        if let config = LinuxFiles.absolute(environment["XDG_CONFIG_HOME"]) {
            return config + "/" + identifier + "/Defaults"
        }
        guard let home = LinuxFiles.nonEmpty(environment["HOME"]) else {
            throw LinuxFilesError("neither LINUXAPPRUNTIME_CONTAINER nor HOME is set")
        }
        return home + "/.config/" + identifier + "/Defaults"
    }
}
