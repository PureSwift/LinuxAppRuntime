import DynamicFiles
import DynamicRuntime
import Foundation
import LinuxHost
import RuntimeABI
import RuntimeCoreModel
import RuntimeHost

/// The model store (AppRuntime's `Persistence.md`): the guest's CoreModel
/// through the `ModelStore` contracts to `RuntimeCoreModel`'s
/// `HostModelStore`, over CoreModel-SQLite (`Plan.md` §9).
///
/// | `LINUXAPPRUNTIME_CONTAINER` set | Otherwise (XDG) |
/// |---|---|
/// | `<container>/Stores/<name>.sqlite` | `$XDG_DATA_HOME/<id>/Stores/<name>.sqlite` |
///
/// Beside the app's `Documents` and `Data` (`LinuxFiles`), but not in
/// them: the app's files can't reach its stores.
public enum LinuxModelStore: HostModule {

    public static var contracts: [ContractDescriptor] {
        HostModelStoreModule.contracts
    }

    /// Says where the app's stores are, then registers the contracts.
    /// Without a directory, `open` fails with `unavailable`.
    public static func register(in registrar: some ContractRegistrar) {
        do {
            let directory = try self.directory(identifier: LinuxBundle.info.identifier, environment: LinuxFiles.environment)
            HostModelStore.configure(HostModelStore.Configuration(
                provider: SQLiteModelStorageProvider(directory: directory),
                deliver: deliver))
            HostLog.debug("model stores: \(directory)")
        } catch {
            HostLog.error("model stores: \(error)")
        }
        HostModelStoreModule.register(in: registrar)
    }

    /// Answers go to the main loop, from the stores' tasks.
    static let deliver: @Sendable (@escaping @Sendable () -> Void) -> Void = { answer in
        MainLoop.shared.post(answer)
    }

    /// The directory of the app `identifier`'s stores: beside its
    /// documents.
    public static func directory(identifier: String, environment: [String: String]) throws(LinuxFilesError) -> String {
        let directories = try LinuxFiles.directories(identifier: identifier, resources: nil, environment: environment)
        // `documents` is always there; it's `<base>/Documents`.
        let documents = directories[.documents]!
        return String(documents.dropLast("/Documents".count)) + "/Stores"
    }
}
