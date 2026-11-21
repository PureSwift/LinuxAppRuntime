import DynamicRuntime
import Foundation
import LinuxHost
import RuntimeDocuments
import RuntimeHost

/// The `Documents` contracts (`Plan.md` §12): AppRuntime's `HostDocuments`,
/// with the desktop portal's pickers and bookmarks kept in the app's data.
/// Main loop only.
public enum LinuxDocuments: HostModule {

    /// The portal the pickers use; replaceable for tests, before `register`.
    nonisolated(unsafe) public static var bus: any PortalBus = SessionPortal()

    public static var contracts: [ContractDescriptor] {
        HostDocumentsModule.contracts
    }

    public static func register(in registrar: some ContractRegistrar) {
        HostDocuments.reset()
        HostDocuments.deliver = { MainLoop.shared.post($0) }
        let bookmarks = BookmarkStore(identifier: LinuxBundle.info.identifier, environment: LinuxFiles.environment)
        HostDocuments.presenter = LinuxDocumentPresenter(bus: bus, bookmarks: bookmarks)
        HostDocumentsModule.register(in: registrar)
    }

    /// Nothing to ask: the user's pick is the permission.
    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        HostDocumentsModule.permissionProviders()
    }

    /// Opens the app with the file `argument` names, a `file:` URI or an
    /// absolute path, as a file manager passes one through the desktop
    /// entry's `%u`. Whether it was a file: anything else, such as an
    /// `https:` URL, is the `Application` contract's.
    @discardableResult
    public static func open(_ argument: String) -> Bool {
        guard let path = documentPath(argument) else { return false }
        guard let kind = HostFiles.kind(ofItemAt: path) else {
            HostLog.error("documents: can't open \(path): there's nothing there")
            return true
        }
        HostDocuments.open([HostDocument(path: path, kind: kind, isWritable: LinuxDocumentPresenter.isWritable(path))])
        return true
    }

    /// The path of a `file:` URI or an absolute path; `nil` for anything
    /// else.
    static func documentPath(_ argument: String) -> String? {
        if argument.hasPrefix("/") {
            return argument
        }
        guard argument.lowercased().hasPrefix("file:"), let url = URL(string: argument), url.isFileURL, !url.path.isEmpty else {
            return nil
        }
        return url.path
    }
}
